#!/usr/bin/env bash
#
# home_inventory.bash - list the databases that use one ORACLE_HOME (shared ORACLE_HOME detection).
#
# Usage: home_inventory.bash <ORACLE_HOME>
#
# Prints one line per database SID that uses the home, tab-separated:
#   <SID>\t<running|stopped>\t<sources>
# where sources is a comma-separated list, in this order, of:
#   oratab   an ORA_ORATAB entry "<SID>:<ORACLE_HOME>:..." names the home
#   pmon     a running ora_pmon_<SID> process runs from the home
#   envfile  an environment file matching ORA_ENV_GLOB sets ORACLE_HOME to the home
# A SID is "running" when an ora_pmon_<SID> process exists whose home is this home or cannot be resolved (see
# below); otherwise "stopped".
#
# How the home of a running ora_pmon_<SID> process is resolved:
#   Linux: readlink <ORA_PROC_ROOT>/<pid>/exe, which is <ORACLE_HOME>/bin/oracle (a " (deleted)" suffix, left
#          when the binary was relinked, is ignored). Needs the same user as the process, or root.
#   AIX (best effort): "ps eww <pid>" prints the environment of the process; its ORACLE_HOME= value is used.
#          Needs the same user as the process, or root.
#   Other systems: the Linux method, then the AIX method.
# When the home cannot be resolved a warning is written to stderr; the process is then counted as running for
# a SID already found through oratab or an environment file. With ORA_HOME_INVENTORY_STRICT=true an
# unresolved process is an error instead (exit 1).
#
# Environment files are parsed, never sourced: simple "[export] NAME=value" assignments, where value may
# reference variables assigned earlier in the same file ($NAME or ${NAME}). The SID is the file's ORACLE_SID,
# or the file name without ".env".
#
# Read-only: never modifies anything. Exit codes: 0 success (also when no database uses the home), 1 error.
#
# Optional environment inputs:
#   ORA_ORATAB                oratab file                                   (default /etc/oratab)
#   ORA_ENV_GLOB              environment files                             (default /local/*.env)
#   ORA_PROC_ROOT             proc file system root (Linux)                 (default /proc)
#   ORA_HOME_INVENTORY_STRICT true: an unresolvable ora_pmon process is an error (default false)

set -u

readonly RE_SID='^[A-Za-z+-][A-Za-z0-9_$#]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'
readonly RE_SAFE_GLOB='^/[A-Za-z0-9._/*?-]*$'
readonly RE_ASSIGNMENT='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
readonly RE_VAR_REF='\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?'

TARGET_HOME=""
TARGET_HOME_PHYSICAL=""
STRICT=false

# Parallel arrays (bash 3.2 has no associative arrays).
SIDS=()
FROM_ORATAB=()
FROM_PMON=()
FROM_ENVFILE=()
RUNNING=()

log_warn() { printf 'WARNING: %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
  printf '%s\n' 'Usage: home_inventory.bash <ORACLE_HOME>' >&2
}

is_true() {
  case "${1:-}" in
    [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Yy] | 1) return 0 ;;
    *) return 1 ;;
  esac
}

# Absolute path with safe characters only, not "/", no ".." component.
is_safe_path() {
  local p=$1
  [[ $p =~ $RE_SAFE_PATH ]] || return 1
  [[ $p =~ ^/+$ ]] && return 1
  case "$p/" in
    */../*) return 1 ;;
  esac
  return 0
}

# Strips trailing slashes.
normalize_path() {
  local p=$1
  while [[ ${#p} -gt 1 && $p == */ ]]; do
    p=${p%/}
  done
  printf '%s\n' "$p"
}

physical_path() {
  (cd -P -- "$1" 2>/dev/null && pwd -P) || true
}

home_matches() {
  local candidate physical
  [[ -n $1 ]] || return 1
  candidate=$(normalize_path "$1")
  if [[ $candidate == "$TARGET_HOME" ]]; then
    return 0
  fi
  if [[ -n $TARGET_HOME_PHYSICAL && -d $candidate ]]; then
    physical=$(physical_path "$candidate")
    [[ -n $physical && $physical == "$TARGET_HOME_PHYSICAL" ]] && return 0
  fi
  return 1
}

# Prints the index of SID in SIDS, adding it when missing.
sid_index() {
  local sid=$1 i
  for ((i = 0; i < ${#SIDS[@]}; i++)); do
    if [[ ${SIDS[i]} == "$sid" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

add_sid() {
  local sid=$1 source=$2 i
  if ! i=$(sid_index "$sid"); then
    i=${#SIDS[@]}
    SIDS[i]=$sid
    FROM_ORATAB[i]=0
    FROM_PMON[i]=0
    FROM_ENVFILE[i]=0
    RUNNING[i]=0
  fi
  case $source in
    oratab) FROM_ORATAB[i]=1 ;;
    pmon) FROM_PMON[i]=1 ;;
    envfile) FROM_ENVFILE[i]=1 ;;
    running) RUNNING[i]=1 ;;
  esac
}

################################################################################
# oratab
################################################################################

collect_oratab() {
  local oratab=${ORA_ORATAB:-/etc/oratab} line sid home rest
  if ! is_safe_path "$oratab"; then
    err "ORA_ORATAB is not a safe absolute path: $oratab"
    return 1
  fi
  if [[ ! -e $oratab ]]; then
    log_warn "oratab not found: $oratab"
    return 0
  fi
  if [[ ! -f $oratab || ! -r $oratab ]]; then
    err "oratab is not a readable file: $oratab"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    IFS=: read -r sid home _ <<<"$line"
    [[ -n $sid && $sid != '*' && -n ${home:-} ]] || continue
    if [[ ! $sid =~ $RE_SID ]]; then
      log_warn "ignoring oratab entry with an unexpected SID: $sid"
      continue
    fi
    if home_matches "$home"; then
      add_sid "$sid" oratab
    fi
  done <"$oratab"
  return 0
}

################################################################################
# Environment files
################################################################################

ENVFILE_SID=""
ENVFILE_HOME=""

# Parses one environment file without executing it; sets ENVFILE_SID and ENVFILE_HOME.
parse_env_file() {
  local file=$1 line segment name value ref pre post found i unresolved
  local -a names=() values=()
  ENVFILE_SID=""
  ENVFILE_HOME=""
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    while IFS= read -r segment; do
      # trim leading and trailing blanks
      segment=${segment#"${segment%%[![:space:]]*}"}
      segment=${segment%"${segment##*[![:space:]]}"}
      [[ $segment =~ $RE_ASSIGNMENT ]] || continue
      name=${BASH_REMATCH[2]}
      value=${BASH_REMATCH[3]}
      case $value in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
      esac
      # Expand references to variables assigned earlier in this file; anything else stays unresolved.
      unresolved=""
      while [[ $value =~ $RE_VAR_REF ]]; do
        ref=${BASH_REMATCH[0]}
        found=""
        for ((i = ${#names[@]} - 1; i >= 0; i--)); do
          if [[ ${names[i]} == "${BASH_REMATCH[1]}" ]]; then
            found=${values[i]}
            break
          fi
        done
        if [[ -z $found ]]; then
          unresolved=$ref
          value=""
          break
        fi
        pre=${value%%"$ref"*}
        post=${value#*"$ref"}
        value=$pre$found$post
      done
      names[${#names[@]}]=$name
      values[${#values[@]}]=$value
      case $name in
        ORACLE_SID) ENVFILE_SID=$value ;;
        ORACLE_HOME)
          ENVFILE_HOME=$value
          if [[ -n $unresolved ]]; then
            log_warn "$file: ORACLE_HOME references $unresolved, which the file does not set; ignored"
          fi
          ;;
      esac
    done < <(printf '%s\n' "$line" | tr ';' '\n')
  done <"$file"
  return 0
}

collect_env_files() {
  local glob=${ORA_ENV_GLOB:-/local/*.env} file sid base
  if [[ ! $glob =~ $RE_SAFE_GLOB ]] || [[ "$glob/" == */../* ]]; then
    err "ORA_ENV_GLOB is not a safe absolute path pattern: $glob"
    return 1
  fi
  while IFS= read -r file; do
    [[ -n $file && -f $file ]] || continue
    if [[ ! -r $file ]]; then
      log_warn "environment file not readable: $file"
      continue
    fi
    parse_env_file "$file"
    if [[ -z $ENVFILE_HOME ]]; then
      continue
    fi
    sid=$ENVFILE_SID
    if [[ -z $sid ]]; then
      base=${file##*/}
      sid=${base%.env}
    fi
    if [[ ! $sid =~ $RE_SID ]]; then
      log_warn "ignoring environment file with an unexpected SID: $file"
      continue
    fi
    if home_matches "$ENVFILE_HOME"; then
      add_sid "$sid" envfile
    fi
  done < <(compgen -G "$glob" || true)
  return 0
}

################################################################################
# Running ora_pmon processes
################################################################################

home_from_proc_exe() {
  local pid=$1 proc=${ORA_PROC_ROOT:-/proc} exe
  [[ -e $proc/$pid/exe || -L $proc/$pid/exe ]] || return 1
  exe=$(readlink "$proc/$pid/exe" 2>/dev/null) || return 1
  exe=${exe% (deleted)}
  case $exe in
    */bin/oracle) printf '%s\n' "${exe%/bin/oracle}" ;;
    *) return 1 ;;
  esac
}

home_from_process_env() {
  local pid=$1 out home
  out=$(ps eww "$pid" 2>/dev/null) || return 1
  home=$(printf '%s\n' "$out" | tr '[:space:]' '\n' | sed -n 's/^ORACLE_HOME=//p' | head -n 1)
  [[ -n $home ]] || return 1
  printf '%s\n' "$home"

}

resolve_process_home() {
  local pid=$1 os=$2
  case $os in
    Linux) home_from_proc_exe "$pid" ;;
    AIX) home_from_process_env "$pid" ;;
    *) home_from_proc_exe "$pid" || home_from_process_env "$pid" ;;
  esac
}

collect_pmon() {
  local os out pid args sid home i
  os=$(uname -s 2>/dev/null) || os=unknown
  if ! out=$(ps -e -o pid,args); then
    err "cannot list processes (ps failed)"
    return 1
  fi
  while read -r pid args; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    args=${args%% *}
    case $args in
      ora_pmon_?*) sid=${args#ora_pmon_} ;;
      *) continue ;;
    esac
    [[ $sid =~ $RE_SID ]] || continue
    if home=$(resolve_process_home "$pid" "$os") && [[ -n $home ]]; then
      if home_matches "$home"; then
        add_sid "$sid" pmon
        add_sid "$sid" running
      fi
      continue
    fi
    if is_true "$STRICT"; then
      err "cannot resolve the ORACLE_HOME of ora_pmon_$sid (pid $pid)"
      return 1
    fi
    if i=$(sid_index "$sid"); then
      log_warn "cannot resolve the ORACLE_HOME of ora_pmon_$sid (pid $pid); counted as running from this home"
      RUNNING[i]=1
    else
      log_warn "cannot resolve the ORACLE_HOME of ora_pmon_$sid (pid $pid); it may use this home"
    fi
  done <<<"$out"
  return 0
}

print_inventory() {
  local i sources state
  for ((i = 0; i < ${#SIDS[@]}; i++)); do
    sources=""
    [[ ${FROM_ORATAB[i]} == 1 ]] && sources="${sources},oratab"
    [[ ${FROM_PMON[i]} == 1 ]] && sources="${sources},pmon"
    [[ ${FROM_ENVFILE[i]} == 1 ]] && sources="${sources},envfile"
    state=stopped
    [[ ${RUNNING[i]} == 1 ]] && state=running
    printf '%s\t%s\t%s\n' "${SIDS[i]}" "$state" "${sources#,}"
  done
}

main() {
  if [[ $# -ne 1 || -z ${1:-} ]]; then
    usage
    return 1
  fi
  if ! is_safe_path "$1"; then
    err "ORACLE_HOME is not a safe absolute path: $1"
    return 1
  fi
  TARGET_HOME=$(normalize_path "$1")
  if [[ -d $TARGET_HOME ]]; then
    TARGET_HOME_PHYSICAL=$(physical_path "$TARGET_HOME")
  fi
  STRICT=${ORA_HOME_INVENTORY_STRICT:-false}

  collect_oratab || return 1
  collect_env_files || return 1
  collect_pmon || return 1
  print_inventory
  return 0
}

main "$@"
exit $?

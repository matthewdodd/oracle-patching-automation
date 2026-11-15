#!/usr/bin/env bash
#
# check_listener_logs.bash - print the error lines of listener logs.
#
# Usage: check_listener_logs.bash <ORACLE_SID> <listener names separated by spaces>
#   The SID and listener names are lower-cased (as before, also for the default environment file name). For
#   each listener the log $ORACLE_BASE/diag/tnslsnr/<host>/<listener>/trace/<listener>.log (or a
#   <listener>.log found under $ORACLE_BASE in a path containing the host name) is checked for "Error" and
#   "ORA-" lines.
#
# Exit codes: 0 every log clean; 4 a log has errors or is missing (any listener, not only the last one as
#             before), $ORACLE_BASE/diag/tnslsnr missing, or invalid arguments.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<sid>.env, lower case)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)

set -u

readonly EX_FAIL=4
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_LISTENER='^[A-Za-z][A-Za-z0-9_#.-]{0,127}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'
readonly LISTENER_PATTERN='Error|ORA-'

ORACLE_SID=""

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

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

to_lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# PATH without empty, "." or other relative entries. An environment file that puts "." (or an empty entry, which means
# the same) in PATH would make every command name resolve against the current directory first; the scripts must only
# run the Oracle and system tools from absolute directories.
safe_path() {
  local entry out=""
  local -a entries=()
  IFS=: read -r -a entries <<<"$1"
  for entry in ${entries[@]+"${entries[@]}"}; do
    [[ $entry == /* ]] || continue
    out=${out:+$out:}$entry
  done
  printf '%s' "$out"
}

source_env_file() {
  local f=$1
  if ! is_safe_path "$f" || [[ ! -f $f ]]; then
    err "Error: environment file not found or not a safe absolute path: $f"
    return 1
  fi
  if [[ -n $(find "$f" -prune -perm -0002 -print 2>/dev/null) ]]; then
    err "Error: environment file is world-writable, refusing to source it: $f"
    return 1
  fi
  if [[ ! -O $f && -z $(find "$f" -prune -user 0 -print 2>/dev/null) ]] && ! is_true "${ORA_ENV_FILE_ALLOW_ANY_OWNER:-false}"; then
    err "Error: environment file is owned by another user (set ORA_ENV_FILE_ALLOW_ANY_OWNER=true to accept): $f"
    return 1
  fi
  # Environment files commonly reference unset variables (LD_LIBRARY_PATH=$LD_LIBRARY_PATH:...).
  set +u
  # shellcheck source=/dev/null  # the database environment file is site-specific and only known at run time
  . "$f"
  set -u
  PATH=$(safe_path "$PATH")
  export PATH
  export ORACLE_SID
  return 0
}

find_listener_log() {
  local name=$1 host=$2 standard
  standard="$ORACLE_BASE/diag/tnslsnr/$host/$name/trace/$name.log"
  if [[ -f $standard ]]; then
    printf '%s\n' "$standard"
  else
    find "$ORACLE_BASE" -type f -name "$name.log" 2>/dev/null | grep -F -e "$host"
  fi
}

# Returns 1 when any listener log has errors or is missing.
check_listener_logs() {
  local host name log_file errors fail=0 found
  host=$(uname -n)
  for name in "$@"; do
    found=0
    while IFS= read -r log_file; do
      [[ -n $log_file ]] || continue
      found=1
      log ""
      log "Checking log: $log_file"
      errors=$(grep -E -e "$LISTENER_PATTERN" -- "$log_file" | uniq)
      if [[ -n $errors ]]; then
        printf '%s\n' "$errors"
        fail=1
      else
        log "This listener log is clean!"
      fi
    done < <(find_listener_log "$name" "$host")
    if [[ $found -eq 0 ]]; then
      log ""
      log "Error: listener log for $name not found"
      fail=1
    fi
  done
  return "$fail"
}

main() {
  local arg
  local -a listeners=()
  if [[ ! ${1:-} =~ $RE_SID ]]; then
    err "Error: invalid ORACLE_SID: '${1:-}'"
    err "Usage: check_listener_logs.bash <ORACLE_SID> <listener names separated by spaces>"
    return "$EX_FAIL"
  fi
  ORACLE_SID=$(to_lower "$1")
  shift
  for arg in "$@"; do
    [[ -n $arg ]] || continue
    if [[ ! $arg =~ $RE_LISTENER ]]; then
      err "Error: invalid listener name: '$arg'"
      return "$EX_FAIL"
    fi
    listeners[${#listeners[@]}]=$(to_lower "$arg")
  done

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"

  if [[ -z ${ORACLE_BASE:-} || ! -d $ORACLE_BASE/diag/tnslsnr/ ]]; then
    log "Error: log directories not mounted: ${ORACLE_BASE:-}/diag/tnslsnr/"
    return "$EX_FAIL"
  fi
  if ! check_listener_logs ${listeners[@]+"${listeners[@]}"}; then
    return "$EX_FAIL"
  fi
  return 0
}

main "$@"
exit $?

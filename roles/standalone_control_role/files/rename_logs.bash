#!/usr/bin/env bash
#
# rename_logs.bash - start a fresh alert log: copy alert_<sid>.log to alert_<sid>.log.<timestamp> and empty it.
#
# Usage: rename_logs.bash <ORACLE_SID> [<listener names>...]
#   The SID is lower-cased (as before, also for the default environment file name). Listener names are
#   accepted for compatibility and ignored: only the alert log is rotated (as before).
#
# Exit codes: 0 success; 4 $ORACLE_BASE/diag/tnslsnr missing, alert log not found or invalid arguments.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<sid>.env, lower case)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)

set -u

readonly EX_FAIL=4
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

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

# Prints the alert log path(s): the standard diag location, else every alert_<sid>.log under ORACLE_BASE.
find_alert_logs() {
  local standard="$ORACLE_BASE/diag/rdbms/$ORACLE_SID/$ORACLE_SID/trace/alert_$ORACLE_SID.log"
  if [[ -f $standard ]]; then
    printf '%s\n' "$standard"
  else
    find "$ORACLE_BASE" -type f -name "alert_$ORACLE_SID.log" 2>/dev/null
  fi
}

rotate_alert_logs() {
  local now log_file found=0 rc=0
  # Rename logs (a fresh log every time the task is rerun).
  now=$(date +"%Y.%m.%d_%I.%M%p")
  while IFS= read -r log_file; do
    [[ -n $log_file ]] || continue
    found=1
    log "alert log        : $log_file"
    # Copy the alert log, then empty it (same as renaming it, without disturbing the open file handle).
    if cp -p -- "$log_file" "$log_file.$now" && echo >"$log_file"; then
      log "alert log renamed: $log_file.$now"
    else
      err "Error: could not rotate $log_file"
      rc=$EX_FAIL
    fi
    log ""
  done < <(find_alert_logs)
  if [[ $found -eq 0 ]]; then
    log "Alert log for $ORACLE_SID not found"
    return "$EX_FAIL"
  fi
  return "$rc"
}

main() {
  if [[ ! ${1:-} =~ $RE_SID ]]; then
    err "Error: invalid ORACLE_SID: '${1:-}'"
    err "Usage: rename_logs.bash <ORACLE_SID> [<listener names>...]"
    return "$EX_FAIL"
  fi
  ORACLE_SID=$(to_lower "$1")

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"
  log ""

  if [[ -z ${ORACLE_BASE:-} || ! -d $ORACLE_BASE/diag/tnslsnr/ ]]; then
    log "Error: log directories not mounted: ${ORACLE_BASE:-}/diag/tnslsnr/"
    return "$EX_FAIL"
  fi
  rotate_alert_logs
}

main "$@"
exit $?

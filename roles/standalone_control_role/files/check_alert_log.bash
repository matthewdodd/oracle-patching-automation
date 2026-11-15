#!/usr/bin/env bash
#
# check_alert_log.bash - print the error and warning lines of the alert log.
#
# Usage: check_alert_log.bash <ORACLE_SID>
#   Prints the unique lines matching "Error", "ORA-" or "Warning", or "Alert log looks clean!". A missing
#   alert log is reported but is not a failure (as before).
#
# Exit codes: 0 checked (or alert log not found); 1 $ORACLE_BASE missing or invalid arguments.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)

set -u

readonly EX_FAIL=1
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'
readonly ALERT_PATTERN='Error|ORA-|Warning'

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
  export ORACLE_SID
  return 0
}

find_alert_logs() {
  local standard="$ORACLE_BASE/diag/rdbms/$ORACLE_SID/$ORACLE_SID/trace/alert_$ORACLE_SID.log"
  if [[ -f $standard ]]; then
    printf '%s\n' "$standard"
  else
    find "$ORACLE_BASE" -type f -name "alert_$ORACLE_SID.log" 2>/dev/null
  fi
}

check_alert_log() {
  local log_file found=0 errors
  while IFS= read -r log_file; do
    [[ -n $log_file ]] || continue
    found=1
    log ""
    log "Checking alert log: $log_file"
    errors=$(grep -E -e "$ALERT_PATTERN" -- "$log_file" | uniq)
    if [[ -n $errors ]]; then
      log "The following Errors/Warnings found in alert log:"
      printf '%s\n' "$errors"
    else
      log "Alert log looks clean!"
    fi
  done < <(find_alert_logs)
  if [[ $found -eq 0 ]]; then
    log "Error: alertLog_$ORACLE_SID not found"
  fi
  return 0
}

main() {
  if [[ ! ${1:-} =~ $RE_SID ]]; then
    err "Error: invalid ORACLE_SID: '${1:-}'"
    err "Usage: check_alert_log.bash <ORACLE_SID>"
    return "$EX_FAIL"
  fi
  ORACLE_SID=$1

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"

  if [[ -z ${ORACLE_BASE:-} || ! -d $ORACLE_BASE ]]; then
    log "Error: log directories not mounted: ${ORACLE_BASE:-}"
    return "$EX_FAIL"
  fi
  check_alert_log
}

main "$@"
exit $?

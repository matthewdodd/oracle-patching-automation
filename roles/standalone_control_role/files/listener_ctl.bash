#!/usr/bin/env bash
#
# listener_ctl.bash - start or stop listeners.
#
# Usage: listener_ctl.bash <start|stop> <ORACLE_SID> <listener names separated by spaces>
#   Listener names are lower-cased (as before). Every listener is processed even when an earlier one fails
#   (the original stopped at the first already-stopped listener).
#
# Exit codes (unchanged meanings):
#   start: 0 all started or already running; 4 a listener failed to start, invalid arguments or ORACLE_HOME
#          missing
#   stop:  0 all stopped; 1 a listener failed to stop; 4 a listener was already stopped (and nothing failed),
#          invalid arguments or ORACLE_HOME missing
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)

set -u

readonly EX_FAIL=4
readonly EX_STOP_FAIL=1
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_LISTENER='^[A-Za-z][A-Za-z0-9_#.-]{0,127}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

ORACLE_SID=""

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  err "Usage: listener_ctl.bash <start|stop> <ORACLE_SID> <listener names separated by spaces>"
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
    err "Failed Error: environment file not found or not a safe absolute path: $f"
    return 1
  fi
  if [[ -n $(find "$f" -prune -perm -0002 -print 2>/dev/null) ]]; then
    err "Failed Error: environment file is world-writable, refusing to source it: $f"
    return 1
  fi
  if [[ ! -O $f && -z $(find "$f" -prune -user 0 -print 2>/dev/null) ]] && ! is_true "${ORA_ENV_FILE_ALLOW_ANY_OWNER:-false}"; then
    err "Failed Error: environment file is owned by another user (set ORA_ENV_FILE_ALLOW_ANY_OWNER=true to accept): $f"
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

listener_processes() {
  ps -e -o pid,args | awk -v b="$ORACLE_HOME/bin/tnslsnr" 'NR > 1 && $2 == b'
}

listener_running() {
  lsnrctl status "$1" >/dev/null 2>&1
}

start_listeners() {
  local name rc=0
  for name in "$@"; do
    if ! listener_running "$name"; then
      log "Starting listener $name ..."
      if lsnrctl start "$name"; then
        log "Listener $name started successfully"
      else
        err "Failed to start listener $name."
        rc=$EX_FAIL
      fi
    else
      log "Looks like listener $name is already started."
      listener_processes
    fi
  done
  return "$rc"
}

stop_listeners() {
  local name failed=0 already_stopped=0
  for name in "$@"; do
    if listener_running "$name"; then
      log "Stopping listener $name ..."
      if lsnrctl stop "$name"; then
        log "Listener $name stopped successfully"
      else
        err "Failed to stop listener $name ."
        failed=1
      fi
    else
      log "Looks like listener $name is already stopped."
      listener_processes
      already_stopped=1
    fi
  done
  if [[ $failed -eq 1 ]]; then
    return "$EX_STOP_FAIL"
  fi
  if [[ $already_stopped -eq 1 ]]; then
    return "$EX_FAIL"
  fi
  return 0
}

main() {
  local action=${1:-} arg name
  local -a listeners=()
  case $action in
    start | stop) ;;
    *)
      usage
      return "$EX_FAIL"
      ;;
  esac
  if [[ ! ${2:-} =~ $RE_SID ]]; then
    err "Failed Error: invalid ORACLE_SID: '${2:-}'"
    return "$EX_FAIL"
  fi
  ORACLE_SID=$2
  shift 2
  for arg in "$@"; do
    [[ -n $arg ]] || continue
    if [[ ! $arg =~ $RE_LISTENER ]]; then
      err "Failed Error: invalid listener name: '$arg'"
      return "$EX_FAIL"
    fi
    name=$(to_lower "$arg")
    listeners[${#listeners[@]}]=$name
  done

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"
  if [[ -z ${ORACLE_HOME:-} || ! -d $ORACLE_HOME ]]; then
    err "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables."
    return "$EX_FAIL"
  fi

  case $action in
    start) start_listeners ${listeners[@]+"${listeners[@]}"} ;;
    stop) stop_listeners ${listeners[@]+"${listeners[@]}"} ;;
  esac
}

main "$@"
exit $?

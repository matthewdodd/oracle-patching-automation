#!/usr/bin/env bash
#
# pdb_ctl.bash - open or close pluggable databases (utility; not called by the playbooks).
#
# Usage: pdb_ctl.bash <start|stop> <ORACLE_SID> [<pdb name>|all]
#   start  starts the container database when it is not running, then opens the PDB (all PDBs for "all" or
#          no name)
#   stop   closes the PDB (all PDBs for "all" or no name) when the container database runs
#
# Exit codes: 0 success, 1 failure or invalid arguments.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)
#   ORA_PS_EXCLUDE_PATTERN       process lines containing this text are ignored (default patrol)

set -u

readonly EX_FAIL=1
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_PDB='^[A-Za-z][A-Za-z0-9_#$]{0,127}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

ORACLE_SID=""
PDB_NAME=""

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  err "Usage: pdb_ctl.bash <start|stop> <ORACLE_SID> [<pdb name>|all]"
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

smon_running() {
  local exclude=${ORA_PS_EXCLUDE_PATTERN-patrol} out
  out=$(ps -e -o pid,args | awk 'NR > 1') || return 1
  if [[ -n $exclude ]]; then
    out=$(printf '%s\n' "$out" | grep -v -F -e "$exclude")
  fi
  printf '%s\n' "$out" | awk -v n="ora_smon_$ORACLE_SID" '$2 == n { found = 1 } END { exit found ? 0 : 1 }'
}

is_all() {
  [[ $PDB_NAME == all || $PDB_NAME == ALL ]]
}

# Prints the PDBs (all non-seed PDBs, or PDB_NAME) whose open mode is not MODE.
pdbs_not_in_mode() {
  local mode=$1 filter
  if is_all; then
    filter="name not like 'PDB%SEED'"
  else
    filter="name = upper('${PDB_NAME}')"
  fi
  printf '%s\n' "SET HEADING OFF FEEDBACK OFF PAGESIZE 0" \
    "select 'PDB_STATE=' || name from v\$pdbs where ${filter} and open_mode != '${mode}';" |
    sqlplus -S / as sysdba | sed -n 's/^[[:space:]]*PDB_STATE=\([A-Za-z0-9_$#][A-Za-z0-9_$#]*\).*$/\1/p'
}

open_pdb() {
  printf '%s\n' "alter pluggable database ${PDB_NAME} open;" | sqlplus / as sysdba
}

start_pdb() {
  if ! smon_running; then
    log "Starting database $ORACLE_SID ..."
    printf '%s\n' 'startup' | sqlplus / as sysdba
    if smon_running; then
      log "Database $ORACLE_SID started successfully"
      log "Starting PDB..."
      open_pdb
    else
      err "Failed to start database $ORACLE_SID."
      return "$EX_FAIL"
    fi
  else
    open_pdb
    if [[ -n $(pdbs_not_in_mode 'READ WRITE') ]]; then
      if is_all; then
        err "Error: Failed to open all PDBs"
      else
        err "Error: Failed to open PDB ${PDB_NAME}"
      fi
      return "$EX_FAIL"
    fi
  fi
  return 0
}

stop_pdb() {
  if smon_running; then
    log "Closing PDB ${PDB_NAME} ..."
    printf '%s\n' "alter pluggable database ${PDB_NAME} close;" | sqlplus / as sysdba
    if [[ -n $(pdbs_not_in_mode 'MOUNTED') ]]; then
      if is_all; then
        err "Error: Failed to close all PDBs"
      else
        err "Error: Failed to close PDB ${PDB_NAME}"
      fi
      return "$EX_FAIL"
    fi
    log "PDB closed"
  else
    log "Looks like database container $ORACLE_SID and PDB is already stopped."
  fi
  return 0
}

main() {
  local action=${1:-}
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
  # No PDB name means all PDBs (the original then issued an invalid "alter pluggable database  open").
  PDB_NAME=${3:-all}
  if [[ ! $PDB_NAME =~ $RE_PDB ]]; then
    err "Failed Error: invalid PDB name: '$PDB_NAME'"
    return "$EX_FAIL"
  fi

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"
  if [[ -z ${ORACLE_HOME:-} || ! -d $ORACLE_HOME ]]; then
    err "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables"
    return "$EX_FAIL"
  fi

  case $action in
    start) start_pdb ;;
    stop) stop_pdb ;;
  esac
}

main "$@"
exit $?

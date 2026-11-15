#!/usr/bin/env bash
#
# database_ctl.bash - start or stop one database.
#
# Usage: database_ctl.bash <start|stop> <ORACLE_SID> [<pdbnames>]
#   start  starts the instance when no ora_smon_<SID> process runs, then, in a container database, opens every
#          PDB (except PDB$SEED) that is not READ WRITE
#   stop   shutdown immediate when ora_smon_<SID> runs
#   pdbnames is accepted for compatibility and not used (all PDBs are opened).
#
# Exit codes: 0 success; 4 start failure, invalid arguments or ORACLE_HOME missing; 1 stop failure.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source  (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                              (default false)
#   ORA_PS_EXCLUDE_PATTERN       process lines containing this text are ignored (default patrol)

set -u

readonly EX_FAIL=4
readonly EX_STOP_FAIL=1
readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

ORACLE_SID=""

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  err "Usage: database_ctl.bash <start|stop> <ORACLE_SID> [<pdbnames>]"
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
  export ORACLE_SID
  return 0
}

# Lines of "ps -e -o pid,args" without the header, minus lines matching ORA_PS_EXCLUDE_PATTERN.
process_list() {
  local exclude=${ORA_PS_EXCLUDE_PATTERN-patrol} out
  out=$(ps -e -o pid,args) || return 1
  if [[ -n $exclude ]]; then
    printf '%s\n' "$out" | awk 'NR > 1' | grep -v -F -e "$exclude"
  else
    printf '%s\n' "$out" | awk 'NR > 1'
  fi
  return 0
}

# ora_smon_<SID> process lines (exact process name: ORCL does not match ORCL2).
smon_processes() {
  local procs
  procs=$(process_list) || return 1
  printf '%s\n' "$procs" | awk -v n="ora_smon_$ORACLE_SID" '$2 == n'
}

smon_running() {
  [[ -n $(smon_processes) ]]
}

sysdba() {
  sqlplus -S / as sysdba
}

# Prints the non-seed PDBs that are not READ WRITE (none on a non-CDB).
pdbs_not_read_write() {
  printf '%s\n' "SET HEADING OFF FEEDBACK OFF PAGESIZE 0" \
    "select 'PDB_NOT_RW=' || name from v\$pdbs where name not like 'PDB%SEED' and open_mode != 'READ WRITE';" |
    sysdba | sed -n 's/^[[:space:]]*PDB_NOT_RW=\([A-Za-z0-9_$#][A-Za-z0-9_$#]*\).*$/\1/p'
}

is_cdb() {
  printf '%s\n' "SET HEADING OFF FEEDBACK OFF PAGESIZE 0" "select 'CDB=' || cdb from v\$database;" |
    sysdba | grep -q '^[[:space:]]*CDB=YES'
}

start_database() {
  if ! smon_running; then
    log "Starting database $ORACLE_SID ..."
    printf '%s\n' 'startup' | sqlplus / as sysdba
    if smon_running; then
      log "Database $ORACLE_SID started successfully"
    else
      err "Failed to start database $ORACLE_SID."
      return "$EX_FAIL"
    fi
  else
    log "Looks like database $ORACLE_SID is already started."
    smon_processes
  fi

  # If the database is a container database, open every PDB that is not open READ WRITE.
  if is_cdb; then
    if [[ -n $(pdbs_not_read_write) ]]; then
      printf '%s\n' 'alter pluggable database all open;' | sqlplus / as sysdba
      if [[ -n $(pdbs_not_read_write) ]]; then
        err "Error: Failed to open PDBs in READ WRITE mode"
        return "$EX_FAIL"
      fi
    fi
  fi
  return 0
}

stop_database() {
  if smon_running; then
    log "Stopping database $ORACLE_SID ..."
    printf '%s\n' 'shutdown immediate' | sqlplus / as sysdba
    if ! smon_running; then
      log "Database $ORACLE_SID stopped successfully"
    else
      err "Failed to stop database $ORACLE_SID."
      return "$EX_STOP_FAIL"
    fi
  else
    log "Looks like database $ORACLE_SID is already stopped."
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

  source_env_file "${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}" || return "$EX_FAIL"
  log "ORACLE_SID is: $ORACLE_SID"
  log "ORACLE_HOME  : ${ORACLE_HOME:-}"
  if [[ -z ${ORACLE_HOME:-} || ! -d $ORACLE_HOME ]]; then
    err "Failed Error: ORACLE_HOME not mounted. Check ORACLE_SID and the set environment variables"
    return "$EX_FAIL"
  fi
  if ! command -v sqlplus >/dev/null 2>&1; then
    err "Failed Error: sqlplus not found in PATH"
    return "$EX_FAIL"
  fi

  case $action in
    start) start_database ;;
    stop) stop_database ;;
  esac
}

main "$@"
exit $?

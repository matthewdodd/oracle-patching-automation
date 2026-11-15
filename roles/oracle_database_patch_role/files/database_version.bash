#!/usr/bin/env bash
#
# database_version.bash - record the version of one database.
#
# Usage: database_version.bash <ORACLE_SID>
#
# Writes to ORA_WORK_DIR:
#   db_version_init.txt  the SQL*Plus spool
#   db_version.txt       v$instance.version only (one line, e.g. 19.0.0.0.0), as before
#   db_version_full.txt  v$instance.version_full (18c and later, e.g. 23.26.0.0.0); empty when not available
#   db_version_info.txt  version=<version> and version_full=<version_full> lines
# and prints the version=/version_full= lines followed by the content of db_version.txt (the original output).
#
# Exit codes: 0 success, 1 error (invalid SID, environment file, work directory, or no version could be read).
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source      (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by another user than the current user
#                                or root                                  (default false)
#   ORA_WORK_DIR                 per-database output directory            (default /tmp/ora_db_patch_<SID>)

set -u

readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'
readonly RE_VERSION='^[0-9]+([.][0-9]+)+$'

ORACLE_SID=""
WORK_DIR=""
ENV_FILE=""

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

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

is_world_writable() {
  [[ -n $(find "$1" -prune -perm -0002 -print 2>/dev/null) ]]
}

is_owned_by_root() {
  [[ -n $(find "$1" -prune -user 0 -print 2>/dev/null) ]]
}

source_env_file() {
  local f=$1
  if ! is_safe_path "$f" || [[ ! -f $f ]]; then
    err "environment file not found or not a safe absolute path: $f"
    return 1
  fi
  if is_world_writable "$f"; then
    err "environment file is world-writable, refusing to source it: $f"
    return 1
  fi
  if [[ ! -O $f ]] && ! is_owned_by_root "$f" && ! is_true "${ORA_ENV_FILE_ALLOW_ANY_OWNER:-false}"; then
    err "environment file is owned by another user (set ORA_ENV_FILE_ALLOW_ANY_OWNER=true to accept): $f"
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

prepare_work_dir() {
  local d=$1
  if ! is_safe_path "$d" || [[ -L $d ]]; then
    err "work directory must be a safe absolute path and not a symbolic link: $d"
    return 1
  fi
  if [[ ! -e $d ]]; then
    if ! mkdir -p -- "$d" || ! chmod 0750 "$d"; then
      err "cannot create work directory: $d"
      return 1
    fi
  fi
  if [[ ! -d $d || ! -O $d ]] || is_world_writable "$d"; then
    err "work directory must be a directory owned by the current user and not world-writable: $d"
    return 1
  fi
  return 0
}

check_database_version() {
  if ! command -v sqlplus >/dev/null 2>&1; then
    err "sqlplus not found in PATH (check ORACLE_HOME and PATH in $ENV_FILE)"
    return 127
  fi
  # version_full exists from 18c on; on 12.1/12.2 the second query fails (ORA-00904) and only version is read.
  sqlplus /nolog <<EOF
connect / as sysdba
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SPOOL ${WORK_DIR}/db_version_init.txt
select 'VERSION=' || version from v\$instance;
select 'VERSION_FULL=' || version_full from v\$instance;
SPOOL OFF
exit
EOF
}

main() {
  local version version_full spool
  if [[ -z ${1:-} ]]; then
    err "first argument must be ORACLE_SID"
    return 1
  fi
  if [[ ! $1 =~ $RE_SID ]]; then
    err "invalid ORACLE_SID: $1"
    return 1
  fi
  ORACLE_SID=$1
  WORK_DIR=${ORA_WORK_DIR:-"/tmp/ora_db_patch_$ORACLE_SID"}
  ENV_FILE=${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}

  prepare_work_dir "$WORK_DIR" || return 1
  source_env_file "$ENV_FILE" || return 1
  log "$ORACLE_SID"
  log "oracle_database_patch_testing_dir is: $WORK_DIR"

  spool="$WORK_DIR/db_version_init.txt"
  rm -f -- "$spool"
  check_database_version || {
    err "sqlplus failed"
    return 1
  }
  version=$(sed -n 's/^[[:space:]]*VERSION=\([0-9][0-9.]*\).*$/\1/p' "$spool" 2>/dev/null | head -n 1)
  version_full=$(sed -n 's/^[[:space:]]*VERSION_FULL=\([0-9][0-9.]*\).*$/\1/p' "$spool" 2>/dev/null | head -n 1)
  if [[ ! $version =~ $RE_VERSION ]]; then
    err "could not read the database version (see $spool)"
    return 1
  fi
  if [[ -n $version_full && ! $version_full =~ $RE_VERSION ]]; then
    version_full=""
  fi

  printf '%s\n' "$version" >"$WORK_DIR/db_version.txt" || return 1
  printf '%s\n' "$version_full" >"$WORK_DIR/db_version_full.txt" || return 1
  printf 'version=%s\nversion_full=%s\n' "$version" "$version_full" >"$WORK_DIR/db_version_info.txt" || return 1

  log "version=$version"
  log "version_full=$version_full"
  cat -- "$WORK_DIR/db_version.txt"
}

main "$@"
exit $?

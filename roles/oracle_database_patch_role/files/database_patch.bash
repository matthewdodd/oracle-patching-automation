#!/usr/bin/env bash
#
# database_patch.bash - check, prerequisite-check and apply an Oracle Database Release Update (and the
# matching OJVM Release Update) for one database.
#
# Usage: database_patch.bash <ORACLE_SID> <mode> <patch_folder>
#
# Modes:
#   test        discover the patch folders with the stricter OJVM README pattern and print them
#   prereq      upgrade OPatch from the bundle when the bundle copy is newer (the previous OPatch is kept as a
#               backup), then run "opatch prereq CheckConflictAgainstOHWithDetail" for the DB RU and the OJVM RU
#   utlrp       run ?/rdbms/admin/utlrp.sql
#   qopiprep    AIX 12.1 fix: make $ORACLE_HOME/QOpatch/qopiprep.bat use /bin/ksh93 and recreate OPATCH_XML_INV
#   status      start the database if it is not OPEN, record the Java components and the SQL patch registry,
#               and report whether the DB RU still has to be applied
#   apply_home  OPatch apply of the DB RU and, when Java is installed, the OJVM RU to ORACLE_HOME only; refuses
#               while the instance (or, when home_inventory.bash is present, any database of the home) runs
#   datapatch   start the instance (upgrade mode by default), run datapatch (re-run once for OJVM errors),
#               recompile new invalid objects with utlrp (up to 2 times), check the registry, shut down
#   apply       apply_home followed by datapatch (the original single-step behaviour)
#
# Exit codes: 0 success (status: proceed with the patch), 2 status only: DB RU already applied,
#             1 error, 64 unknown mode.
#
# Optional environment inputs (the defaults reproduce the original behaviour):
#   ORA_ENV_FILE                 database environment file to source            (default /local/<SID>.env)
#   ORA_ENV_FILE_ALLOW_ANY_OWNER true: accept an environment file owned by a user other than the current
#                                user or root                                   (default false)
#   ORA_WORK_DIR                 per-database output and status directory       (default /tmp/ora_db_patch_<SID>)
#   ORA_DB_RU_PATTERN            README.html grep pattern of the DB RU folder   (default 'Database * Release Update')
#   ORA_JVM_RU_PATTERN           README.html grep pattern of the OJVM RU folder (default '\- Oracle JavaVM Component')
#   ORA_JVM_MIN_MATCHES          README.html lines that must match ORA_JVM_RU_PATTERN (default 2)
#   ORA_DB_PATCH_ID              explicit DB RU patch number (skips README discovery of the DB RU folder)
#   ORA_JVM_PATCH_ID             explicit OJVM RU patch number (skips README discovery of the OJVM folder)
#   ORA_OPATCH_UPGRADE           false: never upgrade OPatch in prereq mode    (default true)
#   ORA_OPATCH_BACKUP_DIR        where the replaced OPatch is moved             (default $ORACLE_HOME/OPatch.bak.<timestamp>)
#   ORA_STATUS_STARTUP           false: status mode fails instead of starting a database that is not OPEN
#                                                                               (default true)
#   ORA_APPLY_JVM                auto (use the Java components recorded by status), true or false (default auto)
#   ORA_APPLY_HOME_CHECK_HOME    false: apply_home does not run home_inventory.bash (default true)
#   ORA_DATAPATCH_STARTUP_MODE   upgrade (startup upgrade, PDBs open upgrade) or normal (default upgrade)
#   ORA_UTLRP_MAX_RETRIES        utlrp runs while datapatch left new invalid objects (default 2)
#   ORA_FAIL_ON_NEW_INVALID_OBJECTS true: new invalid objects left after utlrp fail datapatch (default false: warn)
#   ORA_PS_EXCLUDE_PATTERN       process lines containing this text are ignored (default patrol)
#   ORA_ORATAB, ORA_ENV_GLOB     passed through to home_inventory.bash
#
# Output files in ORA_WORK_DIR: database_state.txt, db_jvm_components.txt, patch_status.txt,
# patch_invalid_objects.txt, utlrp_for_invalid_objects.txt, opatch_prereq_<patch id>.txt,
# opatch_apply_<patch id>.txt, run_datapatch_<patch id>_<run>.txt. opatch_status.txt and run_datapatch.txt are
# copies of the most recent OPatch and datapatch output for operators; the script never reads them back.

set -u

readonly EX_ERROR=1
readonly EX_ALREADY_APPLIED=2
readonly EX_USAGE=64

readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}$'
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'
readonly RE_PATCH_ID='^[0-9]{1,12}$'
readonly RE_UINT='^[0-9]{1,4}$'
readonly RE_VERSION='^[0-9]+([.][0-9]+)*$'
readonly RE_SQL_UNAVAILABLE='ORA-01034|ORACLE not available|ORA-01017|ORA-12547|ORA-12162|SP2-0640'

SCRIPT_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
readonly SCRIPT_DIR

# Globals set by main.
ORACLE_SID=""
MODE=""
PATCH_ROOT=""
WORK_DIR=""
ENV_FILE=""
db_patch_folder=""
jvm_patch_folder=""
db_patch_id=""
jvm_patch_id=""
INVALID_COUNT=""

################################################################################
# Generic helpers
################################################################################

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage: database_patch.bash <ORACLE_SID> <mode> <patch_folder>
  mode: status, prereq, utlrp, qopiprep, apply, apply_home, datapatch or test
  patch_folder: absolute path of the extracted patch bundle, i.e. /u01/oracle/software_dir/19c/jan20
USAGE
}

is_true() {
  case "${1:-}" in
    [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Yy] | 1) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1:-}" in
    [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Nn] | 0) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_sid() { [[ $1 =~ $RE_SID ]]; }

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

timestamp() { date +%Y%m%d%H%M%S; }

# Number of lines of FILE matching the basic regular expression PATTERN. Fails when FILE does not exist (the
# original pipelines counted 0 for a missing file and silently took the wrong branch).
count_matches() {
  local pattern=$1 file=$2 n
  if [[ ! -f $file ]]; then
    err "file not found: $file"
    return 1
  fi
  n=$(grep -c -e "$pattern" -- "$file")
  printf '%s\n' "${n:-0}"
}

is_world_writable() {
  [[ -n $(find "$1" -prune -perm -0002 -print 2>/dev/null) ]]
}

is_owned_by_root() {
  [[ -n $(find "$1" -prune -user 0 -print 2>/dev/null) ]]
}

# Process command lines (pid and args) without the header, minus lines matching ORA_PS_EXCLUDE_PATTERN.
process_list() {
  local exclude=${ORA_PS_EXCLUDE_PATTERN-patrol} out
  out=$(ps -e -o pid,args) || {
    err "cannot list processes (ps failed)"
    return 1
  }
  if [[ -n $exclude ]]; then
    printf '%s\n' "$out" | awk 'NR > 1' | grep -v -F -e "$exclude"
  else
    printf '%s\n' "$out" | awk 'NR > 1'
  fi
  return 0
}

# True when a background process named exactly <prefix><SID> runs (no prefix collision: ORCL vs ORCL2).
instance_process_running() {
  local name="$1$ORACLE_SID" procs
  procs=$(process_list) || return 2
  printf '%s\n' "$procs" | awk -v n="$name" '$2 == n { found = 1 } END { exit found ? 0 : 1 }'
}

################################################################################
# Environment, work directory and arguments
################################################################################

check_env_file() {
  local f=$1
  if ! is_safe_path "$f"; then
    err "environment file path is not a safe absolute path: $f"
    return 1
  fi
  if [[ ! -f $f ]]; then
    err "environment file not found: $f"
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
  return 0
}

source_env_file() {
  local f=$1
  check_env_file "$f" || return 1
  # Environment files commonly reference unset variables (LD_LIBRARY_PATH=$LD_LIBRARY_PATH:...).
  set +u
  # shellcheck source=/dev/null  # the database environment file is site-specific and only known at run time
  . "$f"
  set -u
  export ORACLE_SID
  if [[ -z ${ORACLE_HOME:-} ]] || ! is_safe_path "$ORACLE_HOME" || [[ ! -d $ORACLE_HOME ]]; then
    err "ORACLE_HOME is not set to an existing directory after sourcing $f: '${ORACLE_HOME:-}'"
    return 1
  fi
  export ORACLE_HOME
  return 0
}

prepare_work_dir() {
  local d=$1
  if ! is_safe_path "$d"; then
    err "work directory is not a safe absolute path: $d"
    return 1
  fi
  if [[ -L $d ]]; then
    err "work directory is a symbolic link, refusing it: $d"
    return 1
  fi
  if [[ ! -e $d ]]; then
    if ! mkdir -p -- "$d" || ! chmod 0750 "$d"; then
      err "cannot create work directory: $d"
      return 1
    fi
  fi
  if [[ ! -d $d ]]; then
    err "work directory is not a directory: $d"
    return 1
  fi
  if [[ ! -O $d ]]; then
    err "work directory is not owned by the current user: $d"
    return 1
  fi
  if is_world_writable "$d"; then
    err "work directory is world-writable, refusing it: $d"
    return 1
  fi
  return 0
}

################################################################################
# SQL*Plus
################################################################################

# Runs the SQL read from stdin as SYSDBA. Returns the sqlplus exit status (127 when sqlplus is missing, which
# the original never noticed).
run_sql() {
  if ! command -v sqlplus >/dev/null 2>&1; then
    err "sqlplus not found in PATH (check ORACLE_HOME and PATH in $ENV_FILE)"
    cat >/dev/null
    return 127
  fi
  {
    printf '%s\n' 'connect / as sysdba'
    cat
    printf '%s\n' 'exit'
  } | sqlplus /nolog
}

sql_unavailable() {
  [[ -f $1 ]] && grep -q -E -e "$RE_SQL_UNAVAILABLE" -- "$1"
}

startup_database() {
  printf '%s\n' 'startup;' | run_sql
}

# upgrade: startup upgrade + PDBs open upgrade (the original); normal: startup + PDBs open.
startup_for_datapatch() {
  case "${ORA_DATAPATCH_STARTUP_MODE:-upgrade}" in
    upgrade)
      printf '%s\n' 'startup upgrade;' 'alter pluggable database all open upgrade;' | run_sql
      ;;
    normal)
      printf '%s\n' 'startup;' 'alter pluggable database all open;' | run_sql
      ;;
    *)
      err "ORA_DATAPATCH_STARTUP_MODE must be upgrade or normal: ${ORA_DATAPATCH_STARTUP_MODE}"
      return 1
      ;;
  esac
}

shutdown_database() {
  printf '%s\n' 'shutdown immediate;' | run_sql
}

check_database_state() {
  run_sql <<EOF
SPOOL ${WORK_DIR}/database_state.txt
SELECT INSTANCE_NAME, STATUS, DATABASE_STATUS FROM V\$INSTANCE;
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT 'INSTANCE_STATUS=' || STATUS FROM V\$INSTANCE;
SPOOL OFF
EOF
}

# Prints the instance status (OPEN, MOUNTED, STARTED) or nothing when the instance is down.
# The marker query runs with HEADING OFF, and the pattern is anchored and needs at least one letter, so a
# column heading such as 'INSTANCE_STATUS='||STATUS (SQL*Plus default HEADING ON) can never match.
instance_status() {
  local file="${WORK_DIR}/database_state.txt"
  check_database_state >/dev/null || return 1
  [[ -f $file ]] || return 1
  sed -n 's/^[[:space:]]*INSTANCE_STATUS=\([A-Z][A-Z]*\).*$/\1/p' "$file" | head -n 1
}

check_db_jvm_components() {
  run_sql <<EOF
SPOOL ${WORK_DIR}/db_jvm_components.txt
column COMP_NAME format a35;
column VERSION format a20;
column status format a10;
select COMP_NAME, VERSION, status from dba_registry where upper(COMP_NAME) like '%JAVA%';
SPOOL OFF
EOF
}

# Sets INVALID_COUNT to the number of INVALID objects; fails when the count cannot be read (the original
# compared empty strings and silently skipped the utlrp logic).
count_invalid_objects() {
  local file="${WORK_DIR}/patch_invalid_objects.txt" n
  INVALID_COUNT=""
  run_sql <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SPOOL ${file}
SELECT 'INVALID_COUNT=' || count(*) FROM dba_objects WHERE status = 'INVALID';
SPOOL OFF
EOF
  n=$(sed -n 's/^[[:space:]]*INVALID_COUNT=\([0-9][0-9]*\).*$/\1/p' "$file" 2>/dev/null | head -n 1)
  if [[ ! $n =~ ^[0-9]+$ ]]; then
    err "could not read the number of invalid objects (see $file)"
    return 1
  fi
  INVALID_COUNT=$n
  return 0
}

utlrp_for_invalid_objects() {
  run_sql <<EOF
SPOOL ${WORK_DIR}/utlrp_for_invalid_objects.txt
@?/rdbms/admin/utlrp.sql
SPOOL OFF
EOF
}

check_datapatch_status() {
  run_sql <<EOF
SPOOL ${WORK_DIR}/patch_status.txt
col patch_id format 99999999
col version format a10
col action format a8
col status format a12
col action_time format a26
col description format a55
set linesize 200
set pagesize 30
select patch_id, status, install_id, action, action_time, description
from dba_registry_sqlpatch order by action_time desc;
SPOOL OFF
EOF
}

# First row of patch_status.txt whose patch_id column is exactly ID (the original grep also matched the id as
# a substring of other columns).
patch_status_line() {
  local id=$1 file="${WORK_DIR}/patch_status.txt"
  [[ -n $id && -f $file ]] || return 0
  awk -v id="$id" '$1 == id { print; exit }' "$file"
}

################################################################################
# OPatch
################################################################################

# Checks the last line of an OPatch output file. prereq accepts "OPatch succeeded" only; apply also accepts
# "OPatch completed with warnings" (on every OS: the original treated a clean "OPatch succeeded" on AIX as a
# failure).
check_opatch_output() {
  local file=$1 kind=$2 last
  if [[ ! -f $file ]]; then
    err "OPatch output not found: $file"
    return 1
  fi
  last=$(tail -n 1 -- "$file")
  if [[ -z $last ]]; then
    log "opatch did not succeed"
    return 1
  fi
  if [[ $last == *"OPatch succeeded"* ]]; then
    log "opatch_status=$last, opatch succeeded"
    return 0
  fi
  if [[ $kind == apply && $last == *"OPatch completed with warnings"* ]]; then
    log "opatch_status=$last, opatch succeeded"
    return 0
  fi
  log "opatch_status=$last, opatch did not succeed"
  return 1
}

opatch_prereq() {
  local id=$1 folder=$2 out
  out="${WORK_DIR}/opatch_prereq_${id}.txt"
  (cd -- "$folder" && "$ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph .) 2>&1 | tee -- "$out"
  cp -p -- "$out" "${WORK_DIR}/opatch_status.txt" 2>/dev/null || true
  check_opatch_output "$out" prereq
}

opatch_apply() {
  local id=$1 folder=$2 out
  out="${WORK_DIR}/opatch_apply_${id}.txt"
  "$ORACLE_HOME/OPatch/opatch" apply -silent "$folder" 2>&1 | tee -- "$out"
  cp -p -- "$out" "${WORK_DIR}/opatch_status.txt" 2>/dev/null || true
  check_opatch_output "$out" apply
}

opatch_version_from_file() {
  [[ -f $1 ]] || return 0
  sed -n 's/^OPATCH_VERSION:[[:space:]]*//p' "$1" | head -n 1 | tr -d '[:space:]'
}

# Returns 0 when equal, 1 when $1 > $2, 2 when $1 < $2 (dotted numeric versions).
vercomp() {
  local a=$1 b=$2 i x y
  local IFS=.
  local -a v1 v2
  if [[ $a == "$b" ]]; then
    return 0
  fi
  read -r -a v1 <<<"$a"
  read -r -a v2 <<<"$b"
  for ((i = ${#v1[@]}; i < ${#v2[@]}; i++)); do
    v1[i]=0
  done
  for ((i = 0; i < ${#v1[@]}; i++)); do
    x=${v1[i]}
    y=${v2[i]:-0}
    if ((10#$x > 10#$y)); then
      return 1
    fi
    if ((10#$x < 10#$y)); then
      return 2
    fi
  done
  return 0
}

# Removes the staging copy upgrade_opatch created (and nothing else: the path must be its mktemp name).
remove_opatch_staging() {
  case "$1" in
    "$ORACLE_HOME"/OPatch.new.?*) rm -rf -- "$1" ;;
  esac
}

restore_opatch() {
  local current=$1 backup=$2 failed
  failed="$ORACLE_HOME/OPatch.failed.$(timestamp)"
  if [[ -e $current ]]; then
    mv -- "$current" "$failed" || {
      err "cannot move the new OPatch aside; the previous OPatch is in $backup"
      return 1
    }
    log "the failed OPatch copy was moved to $failed"
  fi
  mv -- "$backup" "$current" || {
    err "cannot restore the previous OPatch from $backup"
    return 1
  }
  log "previous OPatch restored from $backup"
}

# Replaces $ORACLE_HOME/OPatch with the bundle copy when the bundle copy is newer. The previous OPatch is moved
# to ORA_OPATCH_BACKUP_DIR (never deleted) and restored if the new copy does not work.
upgrade_opatch() {
  local new_dir="$PATCH_ROOT/OPatch" current="$ORACLE_HOME/OPatch" old_version new_version rc backup staging
  [[ -d $new_dir ]] || return 0
  if is_false "${ORA_OPATCH_UPGRADE:-true}"; then
    log "OPatch upgrade disabled (ORA_OPATCH_UPGRADE=${ORA_OPATCH_UPGRADE})"
    return 0
  fi
  log "Check if OPatch needs to be updated..."
  old_version=$(opatch_version_from_file "$current/version.txt")
  new_version=$(opatch_version_from_file "$new_dir/version.txt")
  log "old_opatch_version=$old_version"
  log "new_opatch_version=$new_version"
  if [[ ! $old_version =~ $RE_VERSION || ! $new_version =~ $RE_VERSION ]]; then
    err "cannot read OPATCH_VERSION from $current/version.txt and $new_dir/version.txt"
    return 1
  fi
  vercomp "$old_version" "$new_version"
  rc=$?
  if [[ $rc -ne 2 ]]; then
    log "OPatch is up to date"
    return 0
  fi
  log "Update OPatch, new_opatch_version=$new_version is GREATER THAN old_opatch_version=$old_version"
  backup=${ORA_OPATCH_BACKUP_DIR:-"$ORACLE_HOME/OPatch.bak.$(timestamp)"}
  if ! is_safe_path "$backup" || [[ -e $backup ]]; then
    err "OPatch backup directory must be a safe absolute path that does not exist yet: $backup"
    return 1
  fi
  staging=$(mktemp -d "$ORACLE_HOME/OPatch.new.XXXXXX") || {
    err "cannot create a staging directory in $ORACLE_HOME"
    return 1
  }
  if ! cp -pR -- "$new_dir/." "$staging/" || [[ ! -f $staging/opatch ]]; then
    err "cannot copy $new_dir to $staging"
    remove_opatch_staging "$staging"
    return 1
  fi
  if ! mv -- "$current" "$backup"; then
    err "cannot move $current to $backup"
    remove_opatch_staging "$staging"
    return 1
  fi
  if ! mv -- "$staging" "$current"; then
    err "cannot move the new OPatch into place"
    restore_opatch "$current" "$backup"
    return 1
  fi
  if ! "$current/opatch" version; then
    err "the new OPatch does not work"
    restore_opatch "$current" "$backup"
    return 1
  fi
  log "previous OPatch kept in $backup"
  return 0
}

################################################################################
# Patch folder discovery
################################################################################

# Sets db_patch_folder and jvm_patch_folder from the README.html files of the numeric folders under PATCH_ROOT.
# As in the original, the last folder (in find order) whose README matches wins.
discover_patch_folders() {
  local db_pattern=$1 jvm_pattern=$2 jvm_min=$3 line n
  db_patch_folder=""
  jvm_patch_folder=""
  while IFS= read -r line; do
    [[ -n $line && -f $line/README.html ]] || continue
    n=$(count_matches "$db_pattern" "$line/README.html") || return 1
    if [[ $n -gt 0 ]]; then
      db_patch_folder=$line
    fi
    n=$(count_matches "$jvm_pattern" "$line/README.html") || return 1
    if [[ $n -ge $jvm_min ]]; then
      jvm_patch_folder=$line
      log "jvm_patch_folder=$jvm_patch_folder"
    fi
  done < <(find "$PATCH_ROOT" -type d -name '[0-9]*')
  return 0
}

find_patch_folder_by_id() {
  find "$PATCH_ROOT" -type d -name "$1" | head -n 1
}

resolve_patch_folders() {
  local db_pattern=${ORA_DB_RU_PATTERN:-'Database * Release Update'}
  local jvm_pattern=${ORA_JVM_RU_PATTERN:-'\- Oracle JavaVM Component'}
  local jvm_min=${ORA_JVM_MIN_MATCHES:-2}
  local explicit_db=${ORA_DB_PATCH_ID:-} explicit_jvm=${ORA_JVM_PATCH_ID:-}

  if [[ ! $jvm_min =~ $RE_UINT ]] || [[ $jvm_min -lt 1 ]]; then
    err "ORA_JVM_MIN_MATCHES must be a positive integer: $jvm_min"
    return 1
  fi
  discover_patch_folders "$db_pattern" "$jvm_pattern" "$jvm_min" || return 1

  if [[ -n $explicit_db ]]; then
    [[ $explicit_db =~ $RE_PATCH_ID ]] || {
      err "ORA_DB_PATCH_ID must be a patch number: $explicit_db"
      return 1
    }
    db_patch_folder=$(find_patch_folder_by_id "$explicit_db")
  fi
  if [[ -n $explicit_jvm ]]; then
    [[ $explicit_jvm =~ $RE_PATCH_ID ]] || {
      err "ORA_JVM_PATCH_ID must be a patch number: $explicit_jvm"
      return 1
    }
    jvm_patch_folder=$(find_patch_folder_by_id "$explicit_jvm")
    if [[ -z $jvm_patch_folder ]]; then
      err "OJVM patch folder $explicit_jvm not found under $PATCH_ROOT"
      return 1
    fi
  fi
  log "db_patch_folder=$db_patch_folder"
  log "jvm_patch_folder=$jvm_patch_folder"

  if [[ -z $db_patch_folder ]]; then
    log "db_patch_folder not found"
    return 1
  fi
  db_patch_id=$(basename -- "$db_patch_folder")
  log "db_patch_id=$db_patch_id"
  if [[ -z $db_patch_id ]]; then
    log "db_patch_id not found"
    return 1
  fi

  if [[ -n $jvm_patch_folder ]]; then
    jvm_patch_id=$(basename -- "$jvm_patch_folder")
    log "jvm_patch_id=$jvm_patch_id"
    if [[ -z $jvm_patch_id ]]; then
      log "jvm_patch_id not found"
      return 1
    fi
  else
    log "jvm_patch_folder not found, that's okay, not mandatory"
  fi
  return 0
}

################################################################################
# Modes
################################################################################

mode_test() {
  local db_pattern=${ORA_DB_RU_PATTERN:-'Database * Release Update'}
  local jvm_pattern=${ORA_JVM_RU_PATTERN:-'\- Oracle JavaVM Component'}
  local jvm_min=${ORA_JVM_MIN_MATCHES:-2}
  # The stricter OJVM pattern of the original test mode: the OJVM pattern followed by " Release Update".
  discover_patch_folders "$db_pattern" "$jvm_pattern Release Update" "$jvm_min" >/dev/null || return 1
  log "db_patch_folder=$db_patch_folder"
  log "jvm_patch_folder=$jvm_patch_folder"
  return 0
}

mode_prereq() {
  upgrade_opatch || return 1
  opatch_prereq "$db_patch_id" "$db_patch_folder" || return 1
  if [[ -n $jvm_patch_folder ]]; then
    opatch_prereq "$jvm_patch_id" "$jvm_patch_folder" || return 1
  fi
  return 0
}

mode_utlrp() {
  local file="${WORK_DIR}/utlrp_for_invalid_objects.txt"
  rm -f -- "$file"
  utlrp_for_invalid_objects || {
    err "sqlplus failed while running utlrp.sql"
    return 1
  }
  if [[ ! -f $file ]] || sql_unavailable "$file"; then
    log "ORACLE not available, something is wrong"
    return 1
  fi
  return 0
}

# Octal mode (4 digits) of a file, from ls -ld (portable to Linux and AIX, which has no stat command).
file_mode_octal() {
  local perms special=0 u=0 g=0 o=0
  perms=$(ls -ld -- "$1" 2>/dev/null) || return 1
  perms=${perms%% *}
  [[ ${#perms} -ge 10 ]] || return 1
  [[ ${perms:1:1} == r ]] && u=$((u + 4))
  [[ ${perms:2:1} == w ]] && u=$((u + 2))
  case ${perms:3:1} in x) u=$((u + 1)) ;; s) u=$((u + 1)); special=$((special + 4)) ;; S) special=$((special + 4)) ;; esac
  [[ ${perms:4:1} == r ]] && g=$((g + 4))
  [[ ${perms:5:1} == w ]] && g=$((g + 2))
  case ${perms:6:1} in x) g=$((g + 1)) ;; s) g=$((g + 1)); special=$((special + 2)) ;; S) special=$((special + 2)) ;; esac
  [[ ${perms:7:1} == r ]] && o=$((o + 4))
  [[ ${perms:8:1} == w ]] && o=$((o + 2))
  case ${perms:9:1} in x) o=$((o + 1)) ;; t) o=$((o + 1)); special=$((special + 1)) ;; T) special=$((special + 1)) ;; esac
  printf '%d%d%d%d\n' "$special" "$u" "$g" "$o"
}

# Rewrites FILE with CONTENT_FILE in place (same inode, owner and group), adding only owner write while it
# writes, then sets MODE.
rewrite_file_in_place() {
  local file=$1 content=$2 mode=$3 orig_mode=$4
  if [[ ! -w $file ]]; then
    chmod u+w "$file" || return 1
  fi
  if ! cat -- "$content" >"$file"; then
    chmod "$orig_mode" "$file"
    return 1
  fi
  chmod "$mode" "$file"
}

mode_qopiprep() {
  local file="$ORACLE_HOME/QOpatch/qopiprep.bat" prep prep2 orig_mode final_mode backup tmp
  if [[ ! -f $file ]]; then
    err "not found: $file"
    return 1
  fi
  prep=$(head -n 1 -- "$file")
  log "Updating:    $file"
  log "changing 'sh' to 'ksh93'"

  case $prep in
    */bin/sh*)
      orig_mode=$(file_mode_octal "$file") || {
        err "cannot read the mode of $file"
        return 1
      }
      # The original always ended with an owner-executable file (0744); the external table preprocessor
      # needs it, so owner execute is the only bit ever added to the original mode.
      final_mode=$(printf '%04o' "$((8#$orig_mode | 8#0100))")
      backup="$file.bak.$(timestamp)"
      cp -p -- "$file" "$backup" || {
        err "cannot back up $file"
        return 1
      }
      log "backup of the original: $backup"
      tmp=$(mktemp "${WORK_DIR}/qopiprep.bat.XXXXXX") || {
        err "cannot create a temporary file in $WORK_DIR"
        return 1
      }
      if ! sed 's/\/bin\/sh/\/bin\/ksh93/' "$file" >"$tmp" || ! rewrite_file_in_place "$file" "$tmp" "$final_mode" "$orig_mode"; then
        rm -f -- "$tmp"
        err "cannot update $file (original kept in $backup)"
        return 1
      fi
      rm -f -- "$tmp"
      log "attempted to automatically fix the issue"
      ;;
  esac

  prep2=$(head -n 1 -- "$file")
  log "$prep2"
  log "Was that using 'ksh93'?"
  case $prep2 in
    */bin/sh*)
      log "Unsuccessful update to: $file"
      log "This will likely be a problem"
      return 1
      ;;
  esac
  log "Yes, it was using 'ksh93'"

  run_sql <<'EOF'
select dbms_sqlpatch.verify_queryable_inventory from dual;

BEGIN
  EXECUTE IMMEDIATE 'drop table OPATCH_XML_INV';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN
      RAISE;
    END IF;
END;
/

CREATE TABLE opatch_xml_inv
(
  xml_inventory CLOB
)
ORGANIZATION EXTERNAL
(
  TYPE oracle_loader
  DEFAULT DIRECTORY opatch_script_dir
  ACCESS PARAMETERS
  (
  RECORDS DELIMITED BY NEWLINE CHARACTERSET UTF8
  DISABLE_DIRECTORY_LINK_CHECK
  READSIZE 8388608
  preprocessor opatch_script_dir:'qopiprep.bat'
  BADFILE opatch_script_dir:'qopatch_bad.bad'
  LOGFILE opatch_log_dir:'qopatch_log.log'
  FIELDS TERMINATED BY 'UIJSVTBOEIZBEFFQBL'
  MISSING FIELD VALUES ARE NULL
  REJECT ROWS WITH ALL NULL FIELDS
  (
  xml_inventory CHAR(100000000)
  )
  )
  LOCATION(opatch_script_dir:'qopiprep.bat')
)
PARALLEL 1
REJECT LIMIT UNLIMITED;

alter package sys.DBMS_QOPATCH compile body;

select dbms_sqlpatch.verify_queryable_inventory from dual;
EOF
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    err "sqlplus failed while recreating OPATCH_XML_INV (exit $rc)"
    return 1
  fi
  return 0
}

mode_status() {
  local state line status_file="${WORK_DIR}/patch_status.txt"
  state=$(instance_status)
  if [[ $state != OPEN ]]; then
    if is_false "${ORA_STATUS_STARTUP:-true}"; then
      err "database $ORACLE_SID is not OPEN and ORA_STATUS_STARTUP=${ORA_STATUS_STARTUP}"
      return 1
    fi
    log "database $ORACLE_SID is not OPEN (${state:-down}), starting it"
    startup_database
  fi

  rm -f -- "${WORK_DIR}/db_jvm_components.txt" "$status_file"
  check_db_jvm_components
  check_datapatch_status
  if [[ ! -f $status_file ]] || sql_unavailable "$status_file"; then
    log "ORACLE not available, something is wrong"
    return 1
  fi
  if [[ ! -f ${WORK_DIR}/db_jvm_components.txt ]] || sql_unavailable "${WORK_DIR}/db_jvm_components.txt"; then
    log "could not record the Java components, something is wrong"
    return 1
  fi

  line=$(patch_status_line "$db_patch_id")
  if [[ -z $line ]]; then
    log "$db_patch_id not found in database, we can proceed to apply..."
    return 0
  fi
  log "$line"
  # WITH ERRORS is checked first: the original reported an "APPLY ... WITH ERRORS" row as already applied.
  if [[ $line == *"WITH ERRORS"* ]]; then
    log "$db_patch_id is WITH ERRORS, do not proceed..."
    return 1
  fi
  if [[ $line == *"APPLY"* ]]; then
    log "$db_patch_id already applied, nothing to do..."
    return "$EX_ALREADY_APPLIED"
  fi
  log "$db_patch_id not in APPLY state, we can proceed to apply..."
  return 0
}

# Refuses when the instance is OPEN (the original check) or still has background processes (MOUNTED or hung).
refuse_if_instance_running() {
  local state rc
  state=$(instance_status)
  if [[ $state == OPEN ]]; then
    log "Oracle still running, database and listeners must be shutdown"
    return 1
  fi
  instance_process_running ora_pmon_
  rc=$?
  if [[ $rc -eq 0 ]]; then
    log "Oracle still running (ora_pmon_$ORACLE_SID, ${state:-unknown state}), database and listeners must be shutdown"
    return 1
  fi
  if [[ $rc -ne 1 ]]; then
    err "cannot check the processes of $ORACLE_SID"
    return 1
  fi
  return 0
}

# Refuses when any database that uses ORACLE_HOME still runs (shared ORACLE_HOME safety net).
refuse_if_home_in_use() {
  local inventory="$SCRIPT_DIR/home_inventory.bash" out running
  if is_false "${ORA_APPLY_HOME_CHECK_HOME:-true}"; then
    return 0
  fi
  if [[ ! -f $inventory ]]; then
    log "home_inventory.bash not found next to this script, shared ORACLE_HOME check skipped"
    return 0
  fi
  out=$(bash "$inventory" "$ORACLE_HOME") || {
    err "home_inventory.bash failed for $ORACLE_HOME"
    return 1
  }
  running=$(printf '%s\n' "$out" | awk -F '\t' '$2 == "running" { print $1 }')
  if [[ -n $running ]]; then
    log "databases using $ORACLE_HOME are still running: $(printf '%s\n' "$running" | tr '\n' ' ')"
    log "every database using the home must be shut down before the home is patched"
    return 1
  fi
  return 0
}

jvm_patch_required() {
  local components="${WORK_DIR}/db_jvm_components.txt" n
  case "${ORA_APPLY_JVM:-auto}" in
    auto)
      if [[ ! -f $components ]]; then
        err "$components not found: run the status mode first (or set ORA_APPLY_JVM=true|false)"
        return 2
      fi
      n=$(count_matches "Java" "$components") || return 2
      [[ $n -gt 0 ]]
      ;;
    [Tt][Rr][Uu][Ee]) return 0 ;;
    [Ff][Aa][Ll][Ss][Ee]) return 1 ;;
    *)
      err "ORA_APPLY_JVM must be auto, true or false: ${ORA_APPLY_JVM}"
      return 2
      ;;
  esac
}

mode_apply_home() {
  local apply_jvm
  refuse_if_instance_running || return 1
  refuse_if_home_in_use || return 1

  # Decide about the OJVM patch before anything is applied (the original applied the DB RU first and only
  # then found out that the OJVM folder was missing).
  jvm_patch_required
  case $? in
    0)
      apply_jvm=true
      if [[ -z $jvm_patch_folder ]]; then
        log "jvm_patch_folder empty"
        return 1
      fi
      ;;
    1) apply_jvm=false ;;
    *) return 1 ;;
  esac

  opatch_apply "$db_patch_id" "$db_patch_folder" || return 1
  if [[ $apply_jvm == true ]]; then
    opatch_apply "$jvm_patch_id" "$jvm_patch_folder" || return 1
  else
    log "no Java component installed, OJVM patch not applied"
  fi
  return 0
}

# Returns 1 when the OJVM patch row shows WITH ERRORS (the original grepped with an empty id when there was no
# OJVM patch, which matched any row).
check_jvm_patch_status() {
  local line
  if [[ -z $jvm_patch_id ]]; then
    return 0
  fi
  line=$(patch_status_line "$jvm_patch_id")
  if [[ -z $line ]]; then
    log "$jvm_patch_id not found in database"
    return 0
  fi
  if [[ $line == *"WITH ERRORS"* ]]; then
    log "$line"
    log "$jvm_patch_id in WITH ERRORS state, failed"
    return 1
  fi
  log "$jvm_patch_id successfull"
  return 0
}

run_datapatch() {
  local run=$1 out
  out="${WORK_DIR}/run_datapatch_${db_patch_id}_${run}.txt"
  "$ORACLE_HOME/OPatch/datapatch" -verbose 2>&1 | tee -- "$out"
  log "datapatch run $run exit status: ${PIPESTATUS[0]}"
  cp -p -- "$out" "${WORK_DIR}/run_datapatch.txt" 2>/dev/null || true
}

mode_datapatch() {
  local before after retry=0 max_retries=${ORA_UTLRP_MAX_RETRIES:-2} line rc=0 state

  if [[ ! $max_retries =~ $RE_UINT ]]; then
    err "ORA_UTLRP_MAX_RETRIES must be a non-negative integer: $max_retries"
    return 1
  fi
  instance_process_running ora_pmon_
  case $? in
    0)
      log "instance $ORACLE_SID is already running; datapatch mode starts it itself, shut it down first"
      return 1
      ;;
    1) ;;
    *)
      err "cannot check the processes of $ORACLE_SID"
      return 1
      ;;
  esac

  # Be careful about moving the calls below around: they depend on the database being started.
  startup_for_datapatch || return 1
  state=$(instance_status)
  if [[ $state != OPEN ]]; then
    err "database $ORACLE_SID did not open for datapatch (${state:-down})"
    return 1
  fi

  count_invalid_objects || return 1
  before=$INVALID_COUNT

  run_datapatch 1
  # if datapatch shows known OJVM errors, re-run datapatch once
  check_datapatch_status
  if ! check_jvm_patch_status; then
    run_datapatch 2
    check_datapatch_status
    if ! check_jvm_patch_status; then
      log "jvm_patch_id=$jvm_patch_id still failed after running twice"
      return 1
    fi
  fi

  count_invalid_objects || return 1
  after=$INVALID_COUNT

  while [[ $retry -lt $max_retries && $before -lt $after ]]; do
    log "count_invalid_objects_before_upgrade=$before < count_invalid_objects_after_upgrade=$after, invalid objects introduced, running utlrp.sql"
    retry=$((retry + 1))
    utlrp_for_invalid_objects
    count_invalid_objects || return 1
    after=$INVALID_COUNT
  done

  check_datapatch_status
  shutdown_database

  if [[ $before -lt $after ]]; then
    log "count_invalid_objects_before_upgrade=$before < count_invalid_objects_after_upgrade=$after, invalid objects introduced, not resolved, upgrade failed"
    if is_true "${ORA_FAIL_ON_NEW_INVALID_OBJECTS:-false}"; then
      rc=1
    fi
  fi

  line=$(patch_status_line "$db_patch_id")
  if [[ -z $line ]]; then
    log "$db_patch_id not found in database, upgrade failed"
    return 1
  fi
  if [[ $line == *"WITH ERRORS"* || $line != *"APPLY"* ]]; then
    log "$line"
    log "$db_patch_id not in APPLY state, upgrade failed"
    return 1
  fi
  log "$db_patch_id successfully applied"
  return "$rc"
}

mode_apply() {
  mode_apply_home || return 1
  mode_datapatch
}

################################################################################
# Main
################################################################################

main() {
  if [[ -z ${1:-} ]]; then
    log "first argument must be ORACLE_SID"
    usage
    return "$EX_ERROR"
  elif [[ -z ${2:-} ]]; then
    log "second argument must be one of status, prereq, utlrp, qopiprep, apply, apply_home, datapatch or test"
    usage
    return "$EX_ERROR"
  elif [[ -z ${3:-} ]]; then
    log "patch_folder_name parameter required, i.e. /u01/oracle/software_dir/19c/jan20"
    usage
    return "$EX_ERROR"
  fi

  if ! is_valid_sid "$1"; then
    err "invalid ORACLE_SID: $1"
    return "$EX_ERROR"
  fi
  ORACLE_SID=$1
  MODE=$2
  case $MODE in
    test | prereq | utlrp | qopiprep | status | apply | apply_home | datapatch) ;;
    *)
      err "unknown mode: $MODE"
      usage
      return "$EX_USAGE"
      ;;
  esac
  PATCH_ROOT=${3%/}
  if ! is_safe_path "$PATCH_ROOT" || [[ ! -d $PATCH_ROOT ]]; then
    err "patch folder must be an existing directory given as a safe absolute path: $3"
    return "$EX_ERROR"
  fi

  WORK_DIR=${ORA_WORK_DIR:-"/tmp/ora_db_patch_$ORACLE_SID"}
  log "ora_db_patch_dir is: $WORK_DIR"
  prepare_work_dir "$WORK_DIR" || return "$EX_ERROR"

  ENV_FILE=${ORA_ENV_FILE:-"/local/$ORACLE_SID.env"}
  source_env_file "$ENV_FILE" || return "$EX_ERROR"

  resolve_patch_folders || return "$EX_ERROR"

  case $MODE in
    test) mode_test ;;
    prereq) mode_prereq ;;
    utlrp) mode_utlrp ;;
    qopiprep) mode_qopiprep ;;
    status) mode_status ;;
    apply_home) mode_apply_home ;;
    datapatch) mode_datapatch ;;
    apply) mode_apply ;;
  esac
}

main "$@"
exit $?

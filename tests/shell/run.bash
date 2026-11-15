#!/usr/bin/env bash
#
# tests/shell/run.bash - tests of the shell scripts in roles/*/files, with stubbed Oracle tools.
#
# Usage: tests/shell/run.bash [name filter]
#   Runs every test function (t_*) whose name contains the filter (default: all) and exits non-zero when any
#   assertion fails.
#
# Each test gets a fresh case directory under a temporary directory: a fake ORACLE_HOME (OPatch/opatch,
# OPatch/datapatch, bin/sqlplus, bin/lsnrctl stubs, QOpatch/qopiprep.bat), an environment file, a work
# directory (ORA_WORK_DIR), an oratab, a fake /proc and an extracted patch bundle (DB RU 37960098, OJVM RU
# 37847857). tests/shell/stubs/oracle holds the Oracle tool stubs installed into the fake ORACLE_HOME;
# tests/shell/stubs/system (ps, uname, mount, df) is first on PATH. The stubs keep their state in STUB_STATE
# (see each stub's header).
#
# SH_TEST_PATCH_DIR and SH_TEST_CTL_DIR point the tests at other copies of the scripts (mutation testing,
# see tests/shell/mutation.bash).

set -u

TEST_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
REPO_DIR=$(cd -P -- "$TEST_DIR/../.." && pwd -P)
ORACLE_STUBS="$TEST_DIR/stubs/oracle"
SYSTEM_STUBS="$TEST_DIR/stubs/system"
PATCH_DIR=${SH_TEST_PATCH_DIR:-"$REPO_DIR/roles/oracle_database_patch_role/files"}
CTL_DIR=${SH_TEST_CTL_DIR:-"$REPO_DIR/roles/standalone_control_role/files"}
FILTER=${1:-}

readonly DB_ID=37960098
readonly JVM_ID=37847857

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ora_shell_tests.XXXXXX") || exit 1
ROOT=$(cd -P -- "$ROOT" && pwd -P)
trap 'rm -rf -- "$ROOT"' EXIT

PASSES=0
FAILURES=0
CURRENT=""
C=""
H=""
S=""
OUT=""
RC=0

################################################################################
# Assertions
################################################################################

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s: %s\n' "$CURRENT" "$*"
  if [[ -f $OUT ]]; then
    sed 's/^/    | /' "$OUT" | tail -n 25
  fi
}

pass() { PASSES=$((PASSES + 1)); }

assert_rc() {
  if [[ $RC -eq $1 ]]; then pass; else fail "exit status $RC, expected $1"; fi
}

assert_out_contains() {
  if grep -q -F -e "$1" -- "$OUT"; then pass; else fail "output does not contain: $1"; fi
}

assert_out_not_contains() {
  if grep -q -F -e "$1" -- "$OUT"; then fail "output contains: $1"; else pass; fi
}

assert_file_contains() {
  if [[ -f $1 ]] && grep -q -F -e "$2" -- "$1"; then pass; else fail "$1 does not contain: $2"; fi
}

assert_file_not_contains() {
  if [[ -f $1 ]] && grep -q -F -e "$2" -- "$1"; then fail "$1 contains: $2"; else pass; fi
}

assert_exists() {
  if [[ -e $1 ]]; then pass; else fail "missing: $1"; fi
}

assert_not_exists() {
  if [[ -e $1 ]]; then fail "should not exist: $1"; else pass; fi
}

assert_eq() {
  if [[ $1 == "$2" ]]; then pass; else fail "${3:-value}: got '$1', expected '$2'"; fi
}

state() { cat -- "$S/$1" 2>/dev/null; }

count_lines() {
  if [[ -f $1 ]]; then grep -c -F -e "$2" -- "$1"; else echo 0; fi
}

# Octal mode of a file from ls -ld (same approach as the script under test, kept independent of it).
mode_of() {
  local p
  p=$(ls -ld -- "$1")
  p=${p:1:9}
  local i c v=0 out=""
  for i in 0 3 6; do
    v=0
    c=${p:i:1}; [[ $c == r ]] && v=$((v + 4))
    c=${p:i+1:1}; [[ $c == w ]] && v=$((v + 2))
    c=${p:i+2:1}; [[ $c == x || $c == s || $c == t ]] && v=$((v + 1))
    out="$out$v"
  done
  printf '%s\n' "$out"
}

################################################################################
# Fixtures
################################################################################

write_readme() {
  local dir=$1
  shift
  mkdir -p -- "$dir"
  printf '%s\n' "<html><body>" "$@" "</body></html>" >"$dir/README.html"
}

new_case() {
  C="$ROOT/$CURRENT"
  H="$C/base/product/19.0.0/dbhome_1"
  S="$C/state"
  OUT="$C/out"
  mkdir -p -- "$C" "$S" "$H/bin" "$H/OPatch" "$H/QOpatch" "$C/local" "$C/work" "$C/proc" \
    "$C/base/diag/tnslsnr/dbhost01" "$C/patch"
  chmod 0750 "$C/work"
  : >"$H/bin/oracle"
  cp -- "$ORACLE_STUBS/opatch" "$H/OPatch/opatch"
  cp -- "$ORACLE_STUBS/datapatch" "$H/OPatch/datapatch"
  printf 'OPATCH_VERSION:12.2.0.1.40\n' >"$H/OPatch/version.txt"
  cp -- "$ORACLE_STUBS/sqlplus" "$H/bin/sqlplus"
  cp -- "$ORACLE_STUBS/lsnrctl" "$H/bin/lsnrctl"
  printf '#!/bin/sh\necho qopiprep\n' >"$H/QOpatch/qopiprep.bat"
  chmod 0750 "$H/QOpatch/qopiprep.bat"

  echo DOWN >"$S/instance"
  echo ORCL >"$S/sid"
  echo 0 >"$S/invalid_count"
  echo 0 >"$S/invalid_base"
  echo "$JVM_ID" >"$S/jvm_id"
  printf '%s\n' "COMP_NAME VERSION STATUS" "JServer JAVA Virtual Machine 19.0.0.0.0 VALID" \
    "Oracle Database Java Packages 19.0.0.0.0 VALID" >"$S/jvm_components"

  cat >"$C/local/ORCL.env" <<EOF
# test environment file
export ORACLE_SID=ORCL
export ORACLE_BASE=$C/base
export ORACLE_HOME=\$ORACLE_BASE/product/19.0.0/dbhome_1
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\$ORACLE_HOME/lib
: >"\$STUB_STATE/env_sourced"
EOF
  chmod 0640 "$C/local/ORCL.env"
  printf '%s\n' "# oratab" "ORCL:$H:N" >"$C/oratab"
  mkdir -p -- "$C/proc/4242"
  ln -s "$H/bin/oracle" "$C/proc/4242/exe"

  write_readme "$C/patch/$DB_ID" "Oracle Database Release Update 19.27.0.0.250415" \
    "Oracle JavaVM Component is not part of this patch"
  write_readme "$C/patch/$JVM_ID" "Oracle JavaVM Component Release Update 19.27.0.0.250415" \
    "- Oracle JavaVM Component Release Update 19.27.0.0.250415 for Linux" \
    "- Oracle JavaVM Component Release Update 19.27.0.0.250415 for AIX"

  export STUB_STATE="$S"
  export ORA_ENV_FILE="$C/local/ORCL.env"
  export ORA_WORK_DIR="$C/work"
  export ORA_ORATAB="$C/oratab"
  export ORA_ENV_GLOB="$C/local/*.env"
  export ORA_PROC_ROOT="$C/proc"
  export PATH="$SYSTEM_STUBS:$BASE_PATH"
  unset STUB_UNAME_S STUB_UNAME_N
  unset ORA_DB_RU_PATTERN ORA_JVM_RU_PATTERN ORA_JVM_MIN_MATCHES ORA_DB_PATCH_ID ORA_JVM_PATCH_ID \
    ORA_OPATCH_UPGRADE ORA_OPATCH_BACKUP_DIR ORA_STATUS_STARTUP ORA_APPLY_JVM ORA_APPLY_HOME_CHECK_HOME \
    ORA_DATAPATCH_STARTUP_MODE ORA_UTLRP_MAX_RETRIES ORA_FAIL_ON_NEW_INVALID_OBJECTS ORA_PS_EXCLUDE_PATTERN \
    ORA_HOME_INVENTORY_STRICT ORA_ENV_FILE_ALLOW_ANY_OWNER ORA_TIMESTAMP_MAX_MINUTES
}

run() {
  "$@" >"$OUT" 2>&1
  RC=$?
}

patch() { run bash "$PATCH_DIR/database_patch.bash" "$@"; }
inventory() { run bash "$PATCH_DIR/home_inventory.bash" "$@"; }
ctl() {
  local script=$1
  shift
  run bash "$CTL_DIR/$script" "$@"
}

sqlpatch_row() { printf '  %s %s 1 APPLY 01-JAN-26 10.00.00 Patch %s\n' "$1" "$2" "$1" >>"$S/sqlpatch"; }

################################################################################
# database_patch.bash: arguments and environment
################################################################################

t_patch_missing_arguments() {
  patch
  assert_rc 1
  assert_out_contains "first argument must be ORACLE_SID"
  patch ORCL
  assert_rc 1
  patch ORCL status
  assert_rc 1
  assert_out_contains "patch_folder_name parameter required"
  assert_not_exists "$S/env_sourced"
}

t_patch_invalid_sid() {
  local sid
  # shellcheck disable=SC2016  # the literal $(id) is the injection attempt under test
  for sid in "../etc/passwd" "ORCL;id" "1ORCL" "OR CL" 'ORCL$(id)' "$(printf 'ORCL\nX')"; do
    patch "$sid" status "$C/patch"
    assert_rc 1
  done
  assert_not_exists "$S/env_sourced"
}

t_patch_unknown_mode() {
  patch ORCL rollback "$C/patch"
  assert_rc 64
  assert_out_contains "unknown mode: rollback"
  assert_out_contains "apply_home"
  assert_out_not_contains "status, apply, or rollback"
  assert_not_exists "$S/env_sourced"
}

t_patch_invalid_patch_folder() {
  local p
  for p in "patch" "$C/patch/../patch" "$C/patch/.." "$C/missing" "$C/pa tch" "/"; do
    patch ORCL status "$p"
    assert_rc 1
  done
  assert_not_exists "$S/env_sourced"
}

t_patch_invalid_work_dir() {
  ORA_WORK_DIR="$C/work/../work" patch ORCL status "$C/patch"
  assert_rc 1
  ln -s "$C/work" "$C/worklink"
  ORA_WORK_DIR="$C/worklink" patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "symbolic link"
  mkdir -m 0777 "$C/openwork"
  chmod 0777 "$C/openwork"
  ORA_WORK_DIR="$C/openwork" patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "world-writable"
  assert_not_exists "$S/env_sourced"
}

t_patch_creates_work_dir() {
  echo OPEN >"$S/instance"
  ORA_WORK_DIR="$C/newwork" patch ORCL status "$C/patch"
  assert_rc 0
  assert_eq "$(mode_of "$C/newwork")" 750 "work directory mode"
}

t_patch_env_file_checks() {
  chmod 0646 "$C/local/ORCL.env"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "world-writable"
  assert_not_exists "$S/env_sourced"
  chmod 0640 "$C/local/ORCL.env"
  ORA_ENV_FILE="$C/local/MISSING.env" patch ORCL status "$C/patch"
  assert_rc 1
  ORA_ENV_FILE="$C/local/../local/ORCL.env" patch ORCL status "$C/patch"
  assert_rc 1
  assert_not_exists "$S/env_sourced"
}

t_patch_missing_oracle_home() {
  printf 'export ORACLE_HOME=%s/nohome\n' "$C" >"$C/local/ORCL.env"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "ORACLE_HOME is not set to an existing directory"
}

t_patch_db_folder_not_found() {
  write_readme "$C/patch/$DB_ID" "nothing relevant"
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "db_patch_folder not found"
}

################################################################################
# database_patch.bash: status
################################################################################

t_status_proceed() {
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "db_patch_folder=$C/patch/$DB_ID"
  assert_out_contains "jvm_patch_folder=$C/patch/$JVM_ID"
  assert_out_contains "$DB_ID not found in database, we can proceed to apply"
  assert_file_contains "$C/work/db_jvm_components.txt" "Java"
  assert_exists "$C/work/patch_status.txt"
}

t_status_already_applied() {
  echo OPEN >"$S/instance"
  sqlpatch_row "$DB_ID" SUCCESS
  patch ORCL status "$C/patch"
  assert_rc 2
  assert_out_contains "already applied"
}

t_status_rolled_back_proceeds() {
  echo OPEN >"$S/instance"
  printf '  %s SUCCESS 1 ROLLBACK 01-JAN-26 Patch\n' "$DB_ID" >"$S/sqlpatch"
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "not in APPLY state"
}

t_status_with_errors() {
  echo OPEN >"$S/instance"
  sqlpatch_row "$DB_ID" "WITH ERRORS"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "is WITH ERRORS, do not proceed"
}

t_status_exact_patch_id() {
  echo OPEN >"$S/instance"
  sqlpatch_row "1${DB_ID}" SUCCESS
  printf '  999 SUCCESS %s APPLY 01-JAN-26 Patch\n' "$DB_ID" >>"$S/sqlpatch"
  patch ORCL status "$C/patch"
  assert_rc 0
}

t_status_starts_database() {
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_eq "$(state instance)" OPEN "instance state"
  assert_file_contains "$S/sqlplus.log" "startup;"
}

# The instance status must come from the INSTANCE_STATUS= row, never from its SQL*Plus column heading
# 'INSTANCE_STATUS='||STATUS (attempt-1 defect: an open database was reported as down).
t_status_instance_heading() {
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_file_not_contains "$S/sqlplus.log" "startup"
  assert_file_contains "$C/work/database_state.txt" "INSTANCE_STATUS=OPEN"
  assert_file_not_contains "$C/work/database_state.txt" "'INSTANCE_STATUS='||STATUS"
  # Even when a heading does reach the spool file, the anchored pattern skips it.
  : >"$S/force_heading"
  rm -f -- "$S/sqlplus.log"
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_file_contains "$C/work/database_state.txt" "'INSTANCE_STATUS='||STATUS"
  assert_file_not_contains "$S/sqlplus.log" "startup"
  assert_out_not_contains "is not OPEN"
  ORA_STATUS_STARTUP=false patch ORCL status "$C/patch"
  assert_rc 0
}

t_status_no_startup_toggle() {
  ORA_STATUS_STARTUP=false patch ORCL status "$C/patch"
  assert_rc 1
  assert_eq "$(state instance)" DOWN "instance state"
}

t_status_database_unavailable() {
  : >"$S/startup_fail"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "ORACLE not available"
}

t_status_sqlplus_missing() {
  rm -f -- "$H/bin/sqlplus"
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 1
  assert_out_contains "sqlplus not found in PATH"
}

t_status_custom_patterns() {
  echo OPEN >"$S/instance"
  write_readme "$C/patch/$DB_ID" "Oracle AI Database 26ai RU 23.26.0.0.0"
  write_readme "$C/patch/$JVM_ID" "OJVM bundle 23.26" "OJVM bundle 23.26"
  patch ORCL status "$C/patch"
  assert_rc 1
  ORA_DB_RU_PATTERN='Database 26ai RU' ORA_JVM_RU_PATTERN='OJVM bundle' ORA_JVM_MIN_MATCHES=2 \
    patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "jvm_patch_id=$JVM_ID"
  ORA_DB_RU_PATTERN='Database 26ai RU' ORA_JVM_RU_PATTERN='OJVM bundle' ORA_JVM_MIN_MATCHES=3 \
    patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "jvm_patch_folder not found, that's okay"
  ORA_JVM_MIN_MATCHES=x patch ORCL status "$C/patch"
  assert_rc 1
}

t_status_explicit_patch_ids() {
  echo OPEN >"$S/instance"
  write_readme "$C/patch/$DB_ID" "unrecognised wording"
  ORA_DB_PATCH_ID=$DB_ID patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "db_patch_id=$DB_ID"
  ORA_DB_PATCH_ID=$DB_ID ORA_JVM_PATCH_ID=11111111 patch ORCL status "$C/patch"
  assert_rc 1
  ORA_DB_PATCH_ID="1;id" patch ORCL status "$C/patch"
  assert_rc 1
}

t_test_mode() {
  patch ORCL test "$C/patch"
  assert_rc 0
  # the last two lines come from the stricter test-mode discovery
  assert_eq "$(tail -n 2 "$OUT" | tr '\n' ' ')" "db_patch_folder=$C/patch/$DB_ID jvm_patch_folder=$C/patch/$JVM_ID " "test mode"
  write_readme "$C/patch/$JVM_ID" "- Oracle JavaVM Component 19.27" "- Oracle JavaVM Component 19.27"
  patch ORCL test "$C/patch"
  assert_rc 0
  assert_eq "$(tail -n 1 "$OUT")" "jvm_patch_folder=" "test mode with the stricter pattern"
}

################################################################################
# database_patch.bash: prereq and OPatch upgrade
################################################################################

new_bundle_opatch() {
  mkdir -p -- "$C/patch/OPatch"
  cp -- "$ORACLE_STUBS/opatch" "$C/patch/OPatch/opatch"
  printf 'OPATCH_VERSION:%s\n' "$1" >"$C/patch/OPatch/version.txt"
}

t_prereq_ok() {
  patch ORCL prereq "$C/patch"
  assert_rc 0
  assert_file_contains "$C/work/opatch_prereq_${DB_ID}.txt" "OPatch succeeded"
  assert_file_contains "$C/work/opatch_prereq_${JVM_ID}.txt" "OPatch succeeded"
  assert_eq "$(count_lines "$S/opatch.log" "prereq CheckConflictAgainstOHWithDetail -ph .")" 2 "prereq calls"
}

t_prereq_conflict() {
  : >"$S/prereq_fail_$JVM_ID"
  patch ORCL prereq "$C/patch"
  assert_rc 1
  assert_out_contains "opatch did not succeed"
  rm -f -- "$S/prereq_fail_$JVM_ID"
  : >"$S/prereq_fail_$DB_ID"
  patch ORCL prereq "$C/patch"
  assert_rc 1
}

t_prereq_opatch_upgrade() {
  new_bundle_opatch 12.2.0.1.46
  patch ORCL prereq "$C/patch"
  assert_rc 0
  assert_file_contains "$H/OPatch/version.txt" "12.2.0.1.46"
  local backups
  backups=$(find "$C/base/product/19.0.0/dbhome_1" -maxdepth 1 -name 'OPatch.bak.*' | wc -l | tr -d ' ')
  assert_eq "$backups" 1 "OPatch backups"
  assert_file_contains "$(find "$H" -maxdepth 1 -name 'OPatch.bak.*' | head -n 1)/version.txt" "12.2.0.1.40"
  assert_eq "$(find "$H" -maxdepth 1 -name 'OPatch.new.*' | wc -l | tr -d ' ')" 0 "staging leftovers"
}

t_prereq_opatch_backup_dir() {
  new_bundle_opatch 12.2.0.1.46
  ORA_OPATCH_BACKUP_DIR="$C/opatch_backup" patch ORCL prereq "$C/patch"
  assert_rc 0
  assert_file_contains "$C/opatch_backup/version.txt" "12.2.0.1.40"
  ORA_OPATCH_BACKUP_DIR="$C/opatch_backup" patch ORCL prereq "$C/patch"
  assert_rc 0
  new_bundle_opatch 12.2.0.1.50
  ORA_OPATCH_BACKUP_DIR="$C/opatch_backup" patch ORCL prereq "$C/patch"
  assert_rc 1
  assert_out_contains "safe absolute path that does not exist yet"
  assert_file_contains "$H/OPatch/version.txt" "12.2.0.1.46"
  assert_eq "$(find "$H" -maxdepth 1 -name 'OPatch.new.*' | wc -l | tr -d ' ')" 0 "staging leftovers"
}

t_prereq_opatch_not_newer() {
  new_bundle_opatch 12.2.0.1.9
  patch ORCL prereq "$C/patch"
  assert_rc 0
  assert_file_contains "$H/OPatch/version.txt" "12.2.0.1.40"
  assert_eq "$(find "$H" -maxdepth 1 -name 'OPatch.bak.*' | wc -l | tr -d ' ')" 0 "OPatch backups"
}

t_prereq_opatch_upgrade_disabled() {
  new_bundle_opatch 12.2.0.1.46
  ORA_OPATCH_UPGRADE=false patch ORCL prereq "$C/patch"
  assert_rc 0
  assert_file_contains "$H/OPatch/version.txt" "12.2.0.1.40"
}

t_prereq_opatch_broken_restored() {
  new_bundle_opatch 12.2.0.1.46
  : >"$C/patch/OPatch/broken"
  patch ORCL prereq "$C/patch"
  assert_rc 1
  assert_file_contains "$H/OPatch/version.txt" "12.2.0.1.40"
  assert_not_exists "$H/OPatch/broken"
  assert_eq "$(find "$H" -maxdepth 1 -name 'OPatch.failed.*' | wc -l | tr -d ' ')" 1 "failed copy kept"
}

t_prereq_opatch_unreadable_version() {
  new_bundle_opatch ""
  patch ORCL prereq "$C/patch"
  assert_rc 1
  assert_out_contains "cannot read OPATCH_VERSION"
}

################################################################################
# database_patch.bash: utlrp, qopiprep
################################################################################

t_utlrp() {
  echo OPEN >"$S/instance"
  patch ORCL utlrp "$C/patch"
  assert_rc 0
  assert_eq "$(state utlrp_runs)" 1 "utlrp runs"
  echo DOWN >"$S/instance"
  patch ORCL utlrp "$C/patch"
  assert_rc 1
  assert_out_contains "ORACLE not available"
}

t_qopiprep_rewrites_and_keeps_mode() {
  local m
  for m in 750 550 640; do
    rm -f -- "$H/QOpatch/qopiprep.bat"
    printf '#!/bin/sh\necho /bin/sh\n' >"$H/QOpatch/qopiprep.bat"
    chmod "$m" "$H/QOpatch/qopiprep.bat"
    rm -f -- "$H"/QOpatch/qopiprep.bat.bak.*
    patch ORCL qopiprep "$C/patch"
    assert_rc 0
    assert_eq "$(head -n 1 "$H/QOpatch/qopiprep.bat")" "#!/bin/ksh93" "first line ($m)"
    case $m in
      640) assert_eq "$(mode_of "$H/QOpatch/qopiprep.bat")" 740 "mode ($m)" ;;
      *) assert_eq "$(mode_of "$H/QOpatch/qopiprep.bat")" "$m" "mode ($m)" ;;
    esac
    assert_file_contains "$(find "$H/QOpatch" -name 'qopiprep.bat.bak.*' | head -n 1)" "#!/bin/sh"
  done
  assert_file_contains "$S/sqlplus.log" "CREATE TABLE opatch_xml_inv"
  assert_eq "$(find "$C/work" -name 'qopiprep.bat.*' | wc -l | tr -d ' ')" 0 "temporary files"
}

t_qopiprep_already_fixed() {
  printf '#!/bin/ksh93\necho ok\n' >"$H/QOpatch/qopiprep.bat"
  chmod 0750 "$H/QOpatch/qopiprep.bat"
  patch ORCL qopiprep "$C/patch"
  assert_rc 0
  assert_eq "$(find "$H/QOpatch" -name 'qopiprep.bat.bak.*' | wc -l | tr -d ' ')" 0 "backups"
  assert_eq "$(mode_of "$H/QOpatch/qopiprep.bat")" 750 "mode"
}

t_qopiprep_missing_file() {
  rm -f -- "$H/QOpatch/qopiprep.bat"
  patch ORCL qopiprep "$C/patch"
  assert_rc 1
}

################################################################################
# database_patch.bash: apply_home, datapatch, apply
################################################################################

t_apply_home_refuses_open_instance() {
  echo OPEN >"$S/instance"
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_out_contains "Oracle still running"
  assert_file_not_contains "$S/opatch.log" "apply"
}

t_apply_home_refuses_mounted_instance() {
  echo MOUNTED >"$S/instance"
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_out_contains "ora_pmon_ORCL"
  assert_not_exists "$S/home_applied"
}

t_apply_home_refuses_shared_home_running() {
  printf 'OTHER:%s:N\n' "$H" >>"$C/oratab"
  printf ' 5555 ora_pmon_OTHER\n' >"$S/ps_extra"
  mkdir -p -- "$C/proc/5555"
  ln -s "$H/bin/oracle" "$C/proc/5555/exe"
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_out_contains "still running: OTHER"
  assert_not_exists "$S/home_applied"
  ORA_APPLY_HOME_CHECK_HOME=false ORA_APPLY_JVM=false patch ORCL apply_home "$C/patch"
  assert_rc 0
}

t_apply_home_ignores_prefix_sid() {
  printf ' 5555 ora_pmon_ORCL2\n 5556 ora_smon_ORCL2\n' >"$S/ps_extra"
  patch ORCL status "$C/patch" # records the Java components (starts the database)
  echo DOWN >"$S/instance"
  patch ORCL apply_home "$C/patch"
  assert_rc 0
}

t_apply_home_db_and_jvm() {
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  echo DOWN >"$S/instance"
  patch ORCL apply_home "$C/patch"
  assert_rc 0
  assert_eq "$(tr '\n' ' ' <"$S/home_applied")" "$DB_ID $JVM_ID " "applied patches"
  assert_file_contains "$C/work/opatch_apply_${DB_ID}.txt" "OPatch succeeded"
  assert_file_contains "$C/work/opatch_apply_${JVM_ID}.txt" "OPatch succeeded"
  assert_eq "$(state instance)" DOWN "instance state"
}

t_apply_home_without_java() {
  printf 'COMP_NAME VERSION STATUS\nno rows selected\n' >"$C/work/db_jvm_components.txt"
  patch ORCL apply_home "$C/patch"
  assert_rc 0
  assert_eq "$(tr '\n' ' ' <"$S/home_applied")" "$DB_ID " "applied patches"
  ORA_APPLY_JVM=true patch ORCL apply_home "$C/patch"
  assert_rc 0
  assert_file_contains "$S/home_applied" "$JVM_ID"
}

t_apply_home_java_without_jvm_folder() {
  rm -rf -- "${C:?}/patch/$JVM_ID"
  printf 'Oracle Database Java Packages VALID\n' >"$C/work/db_jvm_components.txt"
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_out_contains "jvm_patch_folder empty"
  assert_not_exists "$S/home_applied"
}

t_apply_home_requires_status_first() {
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_out_contains "run the status mode first"
  assert_not_exists "$S/home_applied"
  ORA_APPLY_JVM=false patch ORCL apply_home "$C/patch"
  assert_rc 0
  ORA_APPLY_JVM=maybe patch ORCL apply_home "$C/patch"
  assert_rc 1
}

t_apply_home_opatch_failure() {
  printf 'Oracle Database Java Packages VALID\n' >"$C/work/db_jvm_components.txt"
  : >"$S/apply_fail_$DB_ID"
  patch ORCL apply_home "$C/patch"
  assert_rc 1
  assert_not_exists "$S/home_applied"
  assert_file_not_contains "$S/opatch.log" "$JVM_ID"
}

t_apply_home_warnings_accepted() {
  printf 'no java\n' >"$C/work/db_jvm_components.txt"
  : >"$S/apply_warn"
  patch ORCL apply_home "$C/patch"
  assert_rc 0
}

datapatch_ready() {
  printf '%s\n' "$DB_ID" "$JVM_ID" >"$S/home_applied"
}

t_datapatch_ok() {
  datapatch_ready
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_out_contains "$DB_ID successfully applied"
  assert_file_contains "$S/sqlplus.log" "startup upgrade;"
  assert_file_contains "$S/sqlplus.log" "alter pluggable database all open upgrade;"
  assert_eq "$(state datapatch_runs)" 1 "datapatch runs"
  assert_eq "$(state instance)" DOWN "instance state"
  assert_exists "$C/work/run_datapatch_${DB_ID}_1.txt"
}

# Every spool parser of the datapatch path (instance status, invalid-object count, patch status rows) must ignore
# column headings, even when one reaches the spool file despite HEADING OFF.
t_datapatch_with_headings() {
  datapatch_ready
  : >"$S/force_heading"
  echo 3 >"$S/invalid_count"
  echo 3 >"$S/invalid_base"
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_out_contains "$DB_ID successfully applied"
  assert_out_contains "$JVM_ID successfull"
  assert_eq "$(state instance)" DOWN "instance state"
  assert_file_contains "$C/work/patch_invalid_objects.txt" "'INVALID_COUNT='||COUNT(*)"
}

t_datapatch_normal_startup() {
  datapatch_ready
  ORA_DATAPATCH_STARTUP_MODE=normal patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_eq "$(state open_mode)" normal "startup mode"
  assert_file_not_contains "$S/sqlplus.log" "startup upgrade"
  ORA_DATAPATCH_STARTUP_MODE=bogus patch ORCL datapatch "$C/patch"
  assert_rc 1
}

t_datapatch_jvm_rerun() {
  datapatch_ready
  echo 1 >"$S/jvm_error_runs"
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_eq "$(state datapatch_runs)" 2 "datapatch runs"
}

t_datapatch_jvm_fails_twice() {
  datapatch_ready
  echo 2 >"$S/jvm_error_runs"
  patch ORCL datapatch "$C/patch"
  assert_rc 1
  assert_out_contains "still failed after running twice"
  assert_eq "$(state datapatch_runs)" 2 "datapatch runs"
}

t_datapatch_without_jvm_patch() {
  rm -rf -- "${C:?}/patch/$JVM_ID"
  printf '%s\n' "$DB_ID" >"$S/home_applied"
  # an unrelated row WITH ERRORS must not trigger the OJVM re-run (the original grepped with an empty id)
  printf '  12345 WITH ERRORS 1 APPLY 01-JAN-26 other\n' >"$S/sqlpatch"
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_eq "$(state datapatch_runs)" 1 "datapatch runs"
}

t_datapatch_utlrp_resolves() {
  datapatch_ready
  echo 5 >"$S/datapatch_invalid_delta"
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_eq "$(state utlrp_runs)" 1 "utlrp runs"
  assert_out_not_contains "not resolved"
}

t_datapatch_utlrp_unresolved() {
  datapatch_ready
  echo 5 >"$S/datapatch_invalid_delta"
  : >"$S/utlrp_nofix"
  patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_eq "$(state utlrp_runs)" 2 "utlrp runs"
  assert_out_contains "invalid objects introduced, not resolved"
  echo 0 >"$S/invalid_count"
  rm -f -- "$S/sqlpatch" "$S/utlrp_runs" "$S/datapatch_runs"
  ORA_FAIL_ON_NEW_INVALID_OBJECTS=true patch ORCL datapatch "$C/patch"
  assert_rc 1
  echo 0 >"$S/invalid_count"
  rm -f -- "$S/sqlpatch" "$S/utlrp_runs"
  ORA_UTLRP_MAX_RETRIES=0 patch ORCL datapatch "$C/patch"
  assert_rc 0
  assert_not_exists "$S/utlrp_runs"
}

t_datapatch_not_registered() {
  patch ORCL datapatch "$C/patch"
  assert_rc 1
  assert_out_contains "not found in database, upgrade failed"
}

t_datapatch_db_with_errors() {
  datapatch_ready
  echo "$DB_ID" >"$S/db_error_id"
  patch ORCL datapatch "$C/patch"
  assert_rc 1
  assert_out_contains "not in APPLY state, upgrade failed"
}

t_datapatch_refuses_running_instance() {
  datapatch_ready
  echo OPEN >"$S/instance"
  patch ORCL datapatch "$C/patch"
  assert_rc 1
  assert_not_exists "$S/datapatch_runs"
}

t_datapatch_startup_failure() {
  datapatch_ready
  : >"$S/startup_fail"
  patch ORCL datapatch "$C/patch"
  assert_rc 1
  assert_out_contains "did not open for datapatch"
  assert_not_exists "$S/datapatch_runs"
}

t_apply_full() {
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 0
  echo DOWN >"$S/instance"
  patch ORCL apply "$C/patch"
  assert_rc 0
  assert_eq "$(tr '\n' ' ' <"$S/home_applied")" "$DB_ID $JVM_ID " "applied patches"
  assert_eq "$(state datapatch_runs)" 1 "datapatch runs"
  assert_eq "$(state instance)" DOWN "instance state"
  assert_out_contains "$DB_ID successfully applied"
  echo OPEN >"$S/instance"
  patch ORCL status "$C/patch"
  assert_rc 2
}

t_apply_stops_when_home_fails() {
  printf 'no java\n' >"$C/work/db_jvm_components.txt"
  : >"$S/apply_fail_$DB_ID"
  patch ORCL apply "$C/patch"
  assert_rc 1
  assert_not_exists "$S/datapatch_runs"
}

################################################################################
# database_version.bash
################################################################################

t_version_19c() {
  echo OPEN >"$S/instance"
  echo 19.0.0.0.0 >"$S/version"
  echo 19.27.0.0.0 >"$S/version_full"
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 0
  assert_eq "$(cat "$C/work/db_version.txt")" "19.0.0.0.0" "db_version.txt"
  assert_eq "$(wc -l <"$C/work/db_version.txt" | tr -d ' ')" 1 "db_version.txt lines"
  assert_eq "$(cat "$C/work/db_version_full.txt")" "19.27.0.0.0" "db_version_full.txt"
  assert_file_contains "$C/work/db_version_info.txt" "version_full=19.27.0.0.0"
  assert_eq "$(tail -n 1 "$OUT")" "19.0.0.0.0" "last output line"
}

t_version_12c_without_version_full() {
  echo OPEN >"$S/instance"
  echo 12.1.0.2.0 >"$S/version"
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 0
  assert_eq "$(cat "$C/work/db_version.txt")" "12.1.0.2.0" "db_version.txt"
  assert_eq "$(cat "$C/work/db_version_full.txt")" "" "db_version_full.txt"
  echo 23 >"$S/version_full"
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 0
  assert_eq "$(cat "$C/work/db_version_full.txt")" "" "db_version_full.txt (malformed)"
}

t_version_26ai() {
  echo OPEN >"$S/instance"
  echo 23.0.0.0.0 >"$S/version"
  echo 23.26.0.0.0 >"$S/version_full"
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 0
  assert_out_contains "version_full=23.26.0.0.0"
}

t_version_failures() {
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 1
  assert_out_contains "could not read the database version"
  run bash "$PATCH_DIR/database_version.bash" "../x"
  assert_rc 1
  run bash "$PATCH_DIR/database_version.bash"
  assert_rc 1
}

################################################################################
# home_inventory.bash
################################################################################

t_inventory_sources() {
  local other="$C/other_home"
  mkdir -p -- "$other/bin"
  echo OPEN >"$S/instance"
  cat >"$C/oratab" <<EOF
# comment line
ORCL:$H:N
OTHER:$H/:Y   # trailing slash and comment
DIFF:$other:N
*:$H:N

EOF
  # shellcheck disable=SC2016  # ${ORACLE_BASE} is written literally: the parser under test expands it
  printf 'export ORACLE_BASE=%s/base\nexport ORACLE_HOME=${ORACLE_BASE}/product/19.0.0/dbhome_1; export ORACLE_SID=ENVONLY\n' \
    "$C" >"$C/local/envonly.env"
  printf 'ORACLE_HOME="%s"\n' "$other" >"$C/local/DIFFENV.env"
  printf ' 6000 ora_pmon_OTHER2\n 6001 ora_pmon_PMONLY\n 6002 ora_smon_NOTPMON\n' >"$S/ps_extra"
  mkdir -p -- "$C/proc/6000" "$C/proc/6001"
  ln -s "$other/bin/oracle" "$C/proc/6000/exe"
  ln -s "$H/bin/oracle (deleted)" "$C/proc/6001/exe"
  inventory "$H"
  assert_rc 0
  assert_eq "$(grep -v '^WARNING' "$OUT")" "$(printf 'ORCL\trunning\toratab,pmon,envfile\nOTHER\tstopped\toratab\nENVONLY\tstopped\tenvfile\nPMONLY\trunning\tpmon')" "inventory"
  inventory "$H/"
  assert_rc 0
  assert_out_contains "$(printf 'ORCL\trunning\toratab,pmon,envfile')"
}

t_inventory_missing_home_normalized() {
  printf 'GHOST:/nonexistent/oracle/home/:N\n' >"$C/oratab"
  inventory /nonexistent/oracle/home
  assert_rc 0
  assert_out_contains "$(printf 'GHOST\tstopped\toratab')"
  inventory /nonexistent/oracle/home//
  assert_rc 0
  assert_out_contains "$(printf 'GHOST\tstopped\toratab')"
}

t_inventory_symlinked_home() {
  ln -s "$H" "$C/homelink"
  printf 'LINKED:%s:N\n' "$C/homelink" >"$C/oratab"
  inventory "$H"
  assert_rc 0
  assert_out_contains "$(printf 'LINKED\tstopped\toratab')"
}

t_inventory_empty() {
  mkdir -p -- "$C/unused_home"
  inventory "$C/unused_home"
  assert_rc 0
  assert_eq "$(grep -c . "$OUT")" 0 "output lines"
  rm -f -- "$C/oratab"
  inventory "$H"
  assert_rc 0
  assert_out_contains "oratab not found"
}

t_inventory_unresolved_pmon() {
  echo OPEN >"$S/instance"
  rm -rf -- "${C:?}/proc/4242"
  printf 'export ORACLE_HOME=%s\n' "$H" >"$C/local/ORCL.env"
  inventory "$H"
  assert_rc 0
  assert_out_contains "$(printf 'ORCL\trunning\toratab,envfile')"
  assert_out_contains "cannot resolve the ORACLE_HOME of ora_pmon_ORCL"
  ORA_HOME_INVENTORY_STRICT=true inventory "$H"
  assert_rc 1
}

t_inventory_aix_process_environment() {
  echo OPEN >"$S/instance"
  rm -rf -- "${C:?}/proc/4242"
  printf ' 4242 ora_pmon_ORCL ORACLE_SID=ORCL ORACLE_HOME=%s PATH=/usr/bin\n' "$H" >"$S/psenv_4242"
  STUB_UNAME_S=AIX inventory "$H"
  assert_rc 0
  assert_out_contains "$(printf 'ORCL\trunning\toratab,pmon,envfile')"
  assert_out_not_contains "WARNING"
}

t_inventory_invalid_arguments() {
  inventory
  assert_rc 1
  inventory relative/home
  assert_rc 1
  inventory "$H/../dbhome_1"
  assert_rc 1
  inventory "$H" extra
  assert_rc 1
  ORA_ORATAB="$C/../oratab" inventory "$H"
  assert_rc 1
  # shellcheck disable=SC2016  # the literal $(id) is the injection attempt under test
  ORA_ENV_GLOB='/local/$(id).env' inventory "$H"
  assert_rc 1
  : >"$S/ps_fail"
  inventory "$H"
  assert_rc 1
}

t_inventory_read_only() {
  local before after
  echo OPEN >"$S/instance"
  : >"$OUT"
  before=$(find "$C" -path "$C/out" -prune -o -print | sort | xargs ls -ld 2>/dev/null | cksum)
  inventory "$H"
  assert_rc 0
  after=$(find "$C" -path "$C/out" -prune -o -print | sort | xargs ls -ld 2>/dev/null | cksum)
  assert_eq "$after" "$before" "file tree"
  assert_not_exists "$S/env_sourced"
}

################################################################################
# standalone_control_role scripts
################################################################################

# Security (U3): an environment file that puts "." or an empty entry into PATH must not make the scripts run a program
# from the current directory. plant_tools writes a fake ps and sqlplus into $C/cwd that only record that they ran.
plant_tools() {
  mkdir -p -- "$C/cwd"
  local tool
  for tool in ps sqlplus lsnrctl; do
    # shellcheck disable=SC2016  # $STUB_STATE is expanded by the planted script, not here
    printf '#!/bin/sh\n: >"$STUB_STATE/planted_%s_ran"\nexit 0\n' "$tool" >"$C/cwd/$tool"
    chmod 0750 "$C/cwd/$tool"
  done
  # shellcheck disable=SC2016  # $PATH is expanded when the environment file is sourced
  printf '%s\n' 'export PATH=.:$PATH::' >>"$C/local/ORCL.env"
}

t_env_path_dot_ignored_ctl() {
  plant_tools
  cd -- "$C/cwd" || return
  ctl database_ctl.bash start ORCL
  assert_rc 0
  assert_out_contains "Database ORCL started successfully"
  assert_not_exists "$S/planted_ps_ran"
  assert_not_exists "$S/planted_sqlplus_ran"
  ctl listener_ctl.bash start ORCL LISTENER_ORCL
  assert_not_exists "$S/planted_lsnrctl_ran"
}

t_env_path_dot_ignored_patch() {
  plant_tools
  echo OPEN >"$S/instance"
  cd -- "$C/cwd" || return
  patch ORCL status "$C/patch"
  assert_rc 0
  assert_out_contains "$DB_ID not found in database, we can proceed to apply"
  assert_not_exists "$S/planted_sqlplus_ran"
  assert_not_exists "$S/planted_ps_ran"
  echo 19.0.0.0.0 >"$S/version"
  run bash "$PATCH_DIR/database_version.bash" ORCL
  assert_rc 0
  assert_not_exists "$S/planted_sqlplus_ran"
}

t_database_ctl_start_stop() {
  ctl database_ctl.bash start ORCL
  assert_rc 0
  assert_out_contains "Database ORCL started successfully"
  assert_eq "$(state instance)" OPEN "instance state"
  ctl database_ctl.bash start ORCL
  assert_rc 0
  assert_out_contains "already started"
  ctl database_ctl.bash stop ORCL
  assert_rc 0
  assert_eq "$(state instance)" DOWN "instance state"
  ctl database_ctl.bash stop ORCL
  assert_rc 0
  assert_out_contains "already stopped"
}

t_database_ctl_failures() {
  : >"$S/startup_fail"
  ctl database_ctl.bash start ORCL
  assert_rc 4
  rm -f -- "$S/startup_fail"
  echo OPEN >"$S/instance"
  : >"$S/shutdown_fail"
  ctl database_ctl.bash stop ORCL
  assert_rc 1
  ctl database_ctl.bash restart ORCL
  assert_rc 4
  ctl database_ctl.bash start "ORCL;id"
  assert_rc 4
  printf 'export ORACLE_HOME=\n' >"$C/local/ORCL.env"
  ctl database_ctl.bash start ORCL
  assert_rc 4
  assert_out_contains "ORACLE_HOME not mounted"
}

t_database_ctl_exact_smon_match() {
  printf ' 7000 ora_smon_ORCL2\n' >"$S/ps_extra"
  ctl database_ctl.bash start ORCL
  assert_rc 0
  assert_out_contains "Starting database ORCL"
  printf ' 7001 ora_smon_ORCL\n' >"$S/ps_extra"
  echo DOWN >"$S/instance"
  ORA_PS_EXCLUDE_PATTERN='7001' ctl database_ctl.bash start ORCL
  assert_out_contains "Starting database ORCL"
}

t_database_ctl_opens_pdbs() {
  echo YES >"$S/cdb"
  printf 'PDB1\n' >"$S/pdbs_not_rw"
  ctl database_ctl.bash start ORCL
  assert_rc 0
  assert_file_contains "$S/sqlplus.log" "alter pluggable database all open;"
  echo DOWN >"$S/instance"
  printf 'PDB1\n' >"$S/pdbs_not_rw"
  : >"$S/pdb_open_fail"
  ctl database_ctl.bash start ORCL
  assert_rc 4
  assert_out_contains "Failed to open PDBs"
}

t_listener_ctl() {
  ctl listener_ctl.bash start ORCL LISTENER_A listener_b
  assert_rc 0
  assert_exists "$S/listener_listener_a"
  assert_exists "$S/listener_listener_b"
  rm -f -- "$S/listener_listener_a"
  ctl listener_ctl.bash stop ORCL LISTENER_A LISTENER_B
  assert_rc 4
  assert_out_contains "listener_a is already stopped"
  assert_not_exists "$S/listener_listener_b"
  : >"$S/listener_listener_a"
  : >"$S/listener_stop_fail_listener_a"
  : >"$S/listener_listener_b"
  ctl listener_ctl.bash stop ORCL LISTENER_A LISTENER_B
  assert_rc 1
  assert_not_exists "$S/listener_listener_b"
  : >"$S/listener_start_fail_listener_c"
  ctl listener_ctl.bash start ORCL listener_c listener_d
  assert_rc 4
  assert_exists "$S/listener_listener_d"
  ctl listener_ctl.bash start ORCL 'lsnr;id'
  assert_rc 4
  ctl listener_ctl.bash status ORCL lsnr
  assert_rc 4
}

listener_log() {
  local name=$1
  mkdir -p -- "$C/base/diag/tnslsnr/dbhost01/$name/trace"
  shift
  printf '%s\n' "$@" >"$C/base/diag/tnslsnr/dbhost01/$name/trace/$name.log"
}

t_check_listener_logs() {
  listener_log lsnr_a "TNS-12500 Error something"
  listener_log lsnr_b "clean line"
  ctl check_listener_logs.bash ORCL LSNR_A LSNR_B
  assert_rc 4
  assert_out_contains "This listener log is clean!"
  listener_log lsnr_a "clean"
  ctl check_listener_logs.bash ORCL LSNR_A LSNR_B
  assert_rc 0
  ctl check_listener_logs.bash ORCL LSNR_A LSNR_MISSING
  assert_rc 4
  assert_out_contains "listener log for lsnr_missing not found"
  rm -rf -- "${C:?}/base/diag/tnslsnr"
  ctl check_listener_logs.bash ORCL LSNR_A
  assert_rc 4
}

alert_log() {
  mkdir -p -- "$C/base/diag/rdbms/orcl/orcl/trace"
  printf '%s\n' "$@" >"$C/base/diag/rdbms/orcl/orcl/trace/alert_orcl.log"
}

t_rename_logs() {
  printf 'export ORACLE_SID=orcl ORACLE_BASE=%s/base ORACLE_HOME=%s\n' "$C" "$H" >"$C/local/ORCL.env"
  alert_log "line one" "ORA-00600: internal error"
  ctl rename_logs.bash ORCL LISTENER
  assert_rc 0
  assert_eq "$(find "$C/base/diag/rdbms/orcl/orcl/trace" -name 'alert_orcl.log.*' | wc -l | tr -d ' ')" 1 "rotated copies"
  assert_file_not_contains "$C/base/diag/rdbms/orcl/orcl/trace/alert_orcl.log" "ORA-00600"
  rm -rf -- "${C:?}/base/diag/rdbms"
  ctl rename_logs.bash ORCL
  assert_rc 4
  assert_out_contains "Alert log for orcl not found"
  rm -rf -- "${C:?}/base/diag/tnslsnr"
  ctl rename_logs.bash ORCL
  assert_rc 4
  ctl rename_logs.bash "../x"
  assert_rc 4
}

t_check_alert_log() {
  printf 'export ORACLE_SID=orcl ORACLE_BASE=%s/base ORACLE_HOME=%s\n' "$C" "$H" >"$C/local/ORCL.env"
  alert_log "Warning: something" "ORA-00600: internal error" "fine"
  ctl check_alert_log.bash ORCL
  assert_rc 0
  assert_out_contains "ORA-00600: internal error"
  alert_log "fine"
  ctl check_alert_log.bash ORCL
  assert_rc 0
  assert_out_contains "Alert log looks clean!"
  printf 'export ORACLE_BASE=%s/nobase\n' "$C" >"$C/local/ORCL.env"
  ctl check_alert_log.bash ORCL
  assert_rc 1
}

t_pdb_ctl() {
  echo OPEN >"$S/instance"
  ctl pdb_ctl.bash start ORCL "PDB1 close; drop"
  assert_rc 1
  assert_out_contains "invalid PDB name"
  assert_file_not_contains "$S/sqlplus.log" "drop"
  ctl pdb_ctl.bash start ORCL PDB1
  assert_rc 0
  assert_file_contains "$S/sqlplus.log" "alter pluggable database PDB1 open;"
  ctl pdb_ctl.bash start ORCL
  assert_rc 0
  assert_file_contains "$S/sqlplus.log" "alter pluggable database all open;"
  printf 'PDB1\n' >"$S/pdbs_not_rw"
  : >"$S/pdb_open_fail"
  ctl pdb_ctl.bash start ORCL PDB1
  assert_rc 1
  assert_out_contains "Failed to open PDB PDB1"
  ctl pdb_ctl.bash stop ORCL PDB1
  assert_rc 1
  assert_out_contains "Failed to close PDB PDB1"
}

t_check_mount() {
  printf '/u01\n' >"$S/mounts"
  ctl check_mount.bash ORCL "[u'/u01'," "u'/u02']"
  assert_rc 4
  assert_out_contains "Mount points not mounted:  /u02"
  ctl check_mount.bash ORCL /u01
  assert_rc 0
  assert_out_contains "/u01 ... good"
}

t_check_timestamp() {
  mkdir -p -- "$C/m1" "$C/m2" "$C/m3z"
  : >"$C/m1/recent.log"
  : >"$C/m2/old.log"
  touch -t 200001010000 "$C/m2/old.log"
  ctl check_timestamp.bash ORCL "$C/m1" "$C/m3z"
  assert_rc 0
  ctl check_timestamp.bash ORCL "$C/m1" "$C/m2"
  assert_rc 4
  assert_out_contains "Error $C/m2"
}

################################################################################
# Runner
################################################################################

# Runs one test in a fresh case directory (called in a subshell) and records its counts.
run_one() {
  PASSES=0
  FAILURES=0
  new_case
  "$1"
  echo "$PASSES $FAILURES" >"$ROOT/$1.result"
}

main() {
  local t p f
  BASE_PATH=$PATH
  for t in $(declare -F | awk '{ print $3 }' | grep '^t_'); do
    if [[ -n $FILTER && $t != *"$FILTER"* ]]; then
      continue
    fi
    CURRENT=$t
    (run_one "$t")
    if [[ -f $ROOT/$t.result ]]; then
      read -r p f <"$ROOT/$t.result"
      PASSES=$((PASSES + p))
      FAILURES=$((FAILURES + f))
      if [[ $f -eq 0 ]]; then
        printf 'ok   %s\n' "$t"
      fi
    else
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s: the test aborted\n' "$t"
    fi
  done
  printf '\n%d assertions passed, %d failed\n' "$PASSES" "$FAILURES"
  [[ $FAILURES -eq 0 ]]
}

main

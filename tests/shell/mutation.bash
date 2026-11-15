#!/usr/bin/env bash
#
# tests/shell/mutation.bash - mutation test of tests/shell/run.bash.
#
# Usage: tests/shell/mutation.bash
#   For every mutation below, copies the scripts of roles/*/files to a temporary directory, breaks one thing on
#   purpose (replaces the first occurrence of a literal text) and runs the tests that cover it
#   (run.bash <filter>) against the broken copy. A mutation that the tests do not catch ("SURVIVED") makes this
#   script exit non-zero, and so does a mutation whose text is no longer found in the script.

set -u

TEST_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
REPO_DIR=$(cd -P -- "$TEST_DIR/../.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ora_shell_mutation.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT

KILLED=0
SURVIVED=0
BROKEN=0
NL=$'\n'

P=oracle_database_patch_role/files
K=standalone_control_role/files

# mutate <role/files/script> <test filter> <literal text> <replacement>
mutate() {
  local file=$1 filter=$2 from=$3 to=$4 content pre post
  rm -rf -- "$WORK/roles"
  mkdir -p -- "$WORK/roles"
  cp -R -- "$REPO_DIR/roles/oracle_database_patch_role" "$REPO_DIR/roles/standalone_control_role" "$WORK/roles/"
  content=$(cat -- "$WORK/roles/$file"; printf x)
  content=${content%x}
  case $content in
    *"$from"*) ;;
    *)
      BROKEN=$((BROKEN + 1))
      printf 'NOT FOUND %s: %s\n' "$file" "${from%%"$NL"*}"
      return 0
      ;;
  esac
  pre=${content%%"$from"*}
  post=${content#*"$from"}
  printf '%s' "$pre$to$post" >"$WORK/roles/$file"
  if SH_TEST_PATCH_DIR="$WORK/roles/$P" SH_TEST_CTL_DIR="$WORK/roles/$K" \
    bash "$TEST_DIR/run.bash" "$filter" >"$WORK/last.log" 2>&1; then
    SURVIVED=$((SURVIVED + 1))
    printf 'SURVIVED  %s [%s]: %s\n' "$file" "$filter" "${from%%"$NL"*}"
  else
    KILLED=$((KILLED + 1))
    printf 'killed    %s [%s]: %s\n' "$file" "$filter" "${from%%"$NL"*}"
  fi
}

# The mutation texts are literal script code, so single-quoted "$..." is intended in this function.
# shellcheck disable=SC2016
run_mutations() {
# database_patch.bash
mutate "$P/database_patch.bash" t_patch_unknown 'return "$EX_USAGE"' 'return 0'
mutate "$P/database_patch.bash" t_patch_invalid_sid "readonly RE_SID='^[A-Za-z][A-Za-z0-9_]{0,29}\$'" "readonly RE_SID='.*'"
mutate "$P/database_patch.bash" t_patch_invalid '*/../*) return 1 ;;' '*/../*) return 0 ;;'
mutate "$P/database_patch.bash" t_patch_env_file 'if is_world_writable "$f"; then' 'if false; then'
mutate "$P/database_patch.bash" t_patch_invalid_work 'if is_world_writable "$d"; then' 'if false; then'
mutate "$P/database_patch.bash" t_patch_invalid_work 'if [[ -L $d ]]; then' 'if false; then'
mutate "$P/database_patch.bash" t_status_already 'return "$EX_ALREADY_APPLIED"' 'return 0'
mutate "$P/database_patch.bash" t_status_with_errors 'if [[ $line == *"WITH ERRORS"* ]]; then' 'if false; then'
mutate "$P/database_patch.bash" t_status_exact "awk -v id=\"\$id\" '\$1 == id { print; exit }' \"\$file\"" 'grep -F -e "$id" "$file" | head -n 1'
mutate "$P/database_patch.bash" t_status_no_startup 'if is_false "${ORA_STATUS_STARTUP:-true}"; then' 'if false; then'
mutate "$P/database_patch.bash" t_status_sqlplus_missing '  if ! command -v sqlplus >/dev/null 2>&1; then' '  if false; then'
mutate "$P/database_patch.bash" t_status_explicit 'db_patch_folder=$(find_patch_folder_by_id "$explicit_db")' ':'
mutate "$P/database_patch.bash" t_apply_home_refuses_mounted "  if [[ \$rc -eq 0 ]]; then${NL}    log \"Oracle still running (ora_pmon_" "  if false; then${NL}    log \"Oracle still running (ora_pmon_"
mutate "$P/database_patch.bash" t_apply_home_refuses_shared "\$2 == \"running\"" "\$2 == \"nothing\""
mutate "$P/database_patch.bash" t_apply_home_without_java '      [[ $n -gt 0 ]]' '      [[ $n -ge 0 ]]'
mutate "$P/database_patch.bash" t_apply_home_requires_status "        return 2${NL}      fi${NL}      n=" "        return 1${NL}      fi${NL}      n="
mutate "$P/database_patch.bash" t_apply_home_java_without "        log \"jvm_patch_folder empty\"${NL}        return 1" "        log \"jvm_patch_folder empty\"${NL}        true"
mutate "$P/database_patch.bash" t_apply_home_warnings 'if [[ $kind == apply && $last == *"OPatch completed with warnings"* ]]; then' 'if false; then'
mutate "$P/database_patch.bash" t_apply_home_opatch_failure 'opatch_apply "$db_patch_id" "$db_patch_folder" || return 1' 'opatch_apply "$db_patch_id" "$db_patch_folder"'
mutate "$P/database_patch.bash" t_apply_stops 'mode_apply_home || return 1' 'mode_apply_home'
mutate "$P/database_patch.bash" t_datapatch_ok "printf '%s\\n' 'startup upgrade;' 'alter pluggable database all open upgrade;'" "printf '%s\\n' 'startup;'"
mutate "$P/database_patch.bash" t_datapatch_ok "  check_datapatch_status${NL}  shutdown_database" "  check_datapatch_status"
mutate "$P/database_patch.bash" t_datapatch_jvm_rerun '    run_datapatch 2' '    :'
mutate "$P/database_patch.bash" t_datapatch_jvm_fails "      log \"jvm_patch_id=\$jvm_patch_id still failed after running twice\"${NL}      return 1" "      true"
mutate "$P/database_patch.bash" t_datapatch_without_jvm "  if [[ -z \$jvm_patch_id ]]; then${NL}    return 0${NL}  fi${NL}  line=\$(patch_status_line \"\$jvm_patch_id\")" "  line=\$(awk '/WITH ERRORS/ { print; exit }' \"\$WORK_DIR/patch_status.txt\")"
mutate "$P/database_patch.bash" t_datapatch_utlrp 'while [[ $retry -lt $max_retries && $before -lt $after ]]; do' 'while false; do'
mutate "$P/database_patch.bash" t_datapatch_utlrp_unresolved '      rc=1' '      rc=0'
mutate "$P/database_patch.bash" t_datapatch_db_with_errors 'if [[ $line == *"WITH ERRORS"* || $line != *"APPLY"* ]]; then' 'if [[ $line != *"APPLY"* ]]; then'
mutate "$P/database_patch.bash" t_datapatch_refuses "      log \"instance \$ORACLE_SID is already running; datapatch mode starts it itself, shut it down first\"${NL}      return 1" "      true"
mutate "$P/database_patch.bash" t_datapatch_startup_failure "  if [[ \$state != OPEN ]]; then${NL}    err \"database \$ORACLE_SID did not open" "  if false; then${NL}    err \"database \$ORACLE_SID did not open"
mutate "$P/database_patch.bash" t_prereq_conflict 'opatch_prereq "$jvm_patch_id" "$jvm_patch_folder" || return 1' 'true'
mutate "$P/database_patch.bash" t_prereq_opatch 'if [[ $rc -ne 2 ]]; then' 'if [[ $rc -eq 2 ]]; then'
mutate "$P/database_patch.bash" t_prereq_opatch_upgrade_disabled 'if is_false "${ORA_OPATCH_UPGRADE:-true}"; then' 'if false; then'
mutate "$P/database_patch.bash" t_prereq_opatch_broken 'if ! "$current/opatch" version; then' 'if ! true; then'
mutate "$P/database_patch.bash" t_prereq_opatch_backup_dir 'if ! is_safe_path "$backup" || [[ -e $backup ]]; then' 'if ! is_safe_path "$backup"; then'
mutate "$P/database_patch.bash" t_utlrp 'if [[ ! -f $file ]] || sql_unavailable "$file"; then' 'if false; then'
mutate "$P/database_patch.bash" t_qopiprep "final_mode=\$(printf '%04o' \"\$((8#\$orig_mode | 8#0100))\")" 'final_mode=0744'
mutate "$P/database_patch.bash" t_qopiprep 'cp -p -- "$file" "$backup" || {' 'true || {'
mutate "$P/database_patch.bash" t_test_mode '"$jvm_pattern Release Update" "$jvm_min" >/dev/null' '"no such text" "$jvm_min" >/dev/null'

# database_version.bash
mutate "$P/database_version.bash" t_version_19c "printf '%s\\n' \"\$version\" >\"\$WORK_DIR/db_version.txt\"" "printf '%s\\n%s\\n' \"\$version\" \"\$version_full\" >\"\$WORK_DIR/db_version.txt\""
mutate "$P/database_version.bash" t_version_failures 'if [[ ! $version =~ $RE_VERSION ]]; then' 'if false; then'
mutate "$P/database_version.bash" t_version_12c '    version_full=""' '    version_full="bad"'

# home_inventory.bash
mutate "$P/home_inventory.bash" t_inventory_sources 'exe=${exe% (deleted)}' ':'
mutate "$P/home_inventory.bash" t_inventory_sources '        add_sid "$sid" pmon' '        :'
mutate "$P/home_inventory.bash" t_inventory_missing_home '    p=${p%/}' '    break'
mutate "$P/home_inventory.bash" t_inventory_sources 'value=$pre$found$post' 'value=$pre$post'
mutate "$P/home_inventory.bash" t_inventory_sources "done < <(printf '%s\\n' \"\$line\" | tr ';' '\\n')" "done < <(printf '%s\\n' \"\$line\")"
mutate "$P/home_inventory.bash" t_inventory_symlinked '[[ -n $physical && $physical == "$TARGET_HOME_PHYSICAL" ]] && return 0' ':'
mutate "$P/home_inventory.bash" t_inventory_unresolved 'if is_true "$STRICT"; then' 'if false; then'
mutate "$P/home_inventory.bash" t_inventory_unresolved "counted as running from this home\"${NL}      RUNNING[i]=1" "counted as running from this home\""
mutate "$P/home_inventory.bash" t_inventory_aix '    AIX) home_from_process_env "$pid" ;;' '    AIX) home_from_proc_exe "$pid" ;;'
mutate "$P/home_inventory.bash" t_inventory_invalid "    err \"cannot list processes (ps failed)\"${NL}    return 1" "    return 0"
mutate "$P/home_inventory.bash" t_inventory_invalid 'if [[ $# -ne 1 || -z ${1:-} ]]; then' 'if [[ -z ${1:-} ]]; then'
mutate "$P/home_inventory.bash" t_inventory_empty "    log_warn \"oratab not found: \$oratab\"${NL}    return 0" "    return 1"

# standalone_control_role scripts
mutate "$K/database_ctl.bash" t_database_ctl_exact "awk -v n=\"ora_smon_\$ORACLE_SID\" '\$2 == n'" 'grep -e "ora_smon_$ORACLE_SID"'
mutate "$K/database_ctl.bash" t_database_ctl_failures 'return "$EX_STOP_FAIL"' 'return 4'
mutate "$K/database_ctl.bash" t_database_ctl_opens "        err \"Error: Failed to open PDBs in READ WRITE mode\"${NL}        return \"\$EX_FAIL\"" "        true"
mutate "$K/database_ctl.bash" t_database_ctl_start "  if ! smon_running; then${NL}    log \"Starting" "  if smon_running; then${NL}    log \"Starting"
mutate "$K/listener_ctl.bash" t_listener_ctl '      already_stopped=1' '      return 4'
mutate "$K/listener_ctl.bash" t_listener_ctl 'return "$EX_STOP_FAIL"' 'return 4'
mutate "$K/listener_ctl.bash" t_listener_ctl '        rc=$EX_FAIL' '        return 4'
mutate "$K/listener_ctl.bash" t_listener_ctl "readonly RE_LISTENER='^[A-Za-z][A-Za-z0-9_#.-]{0,127}\$'" "readonly RE_LISTENER='.*'"
mutate "$K/check_listener_logs.bash" t_check_listener_logs "    found=0${NL}    while" "    found=0${NL}    fail=0${NL}    while"
mutate "$K/check_listener_logs.bash" t_check_listener_logs "      log \"Error: listener log for \$name not found\"${NL}      fail=1" "      log \"Error: listener log for \$name not found\""
mutate "$K/rename_logs.bash" t_rename_logs 'echo >"$log_file"' 'true'
mutate "$K/rename_logs.bash" t_rename_logs "    log \"Alert log for \$ORACLE_SID not found\"${NL}    return \"\$EX_FAIL\"" "    return 0"
mutate "$K/check_alert_log.bash" t_check_alert_log 'errors=$(grep -E -e "$ALERT_PATTERN" -- "$log_file" | uniq)' 'errors=""'
mutate "$K/pdb_ctl.bash" t_pdb_ctl "readonly RE_PDB='^[A-Za-z][A-Za-z0-9_#\$]{0,127}\$'" "readonly RE_PDB='.*'"
mutate "$K/pdb_ctl.bash" t_pdb_ctl 'err "Error: Failed to open PDB ${PDB_NAME}"' 'err "Error: Failed to open PDB ${PDBNAME:-}"'
mutate "$K/pdb_ctl.bash" t_pdb_ctl 'PDB_NAME=${3:-all}' 'PDB_NAME=${3:-}'
mutate "$K/check_mount.bash" t_check_mount " -e \"s:'::g\"" ""
mutate "$K/check_mount.bash" t_check_mount '      missing="$missing $mp"' '      :'
mutate "$K/check_timestamp.bash" t_check_timestamp '[[ -n $mp && $mp != *z ]] || continue' '[[ -n $mp ]] || continue'
mutate "$K/check_timestamp.bash" t_check_timestamp '      fail=1' '      :'
}

run_mutations
printf '\n%d mutations killed, %d survived, %d not found\n' "$KILLED" "$SURVIVED" "$BROKEN"
[[ $SURVIVED -eq 0 && $BROKEN -eq 0 ]]

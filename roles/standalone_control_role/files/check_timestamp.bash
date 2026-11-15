#!/usr/bin/env bash
#
# check_timestamp.bash - check that each mount point has a recently modified file (utility; not called by the
# playbooks).
#
# Usage: check_timestamp.bash <ORACLE_SID> <mount point list separated by spaces>
#   Mount point arguments may come from a Python list representation ([u'/u01', u'/u02']): "[", "]", ","
#   and a leading "u" are removed, as before. Mount points ending in "z" (grid mount points) are skipped.
#   The newest file named "*.*" must be younger than ORA_TIMESTAMP_MAX_MINUTES minutes.
#
# Exit codes: 0 every mount point has a recent file; 4 otherwise or an argument is invalid.
#
# Optional environment inputs:
#   ORA_TIMESTAMP_MAX_MINUTES  maximum age in minutes (default 1440 = 1 day, as before)

set -u

readonly EX_FAIL=4
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Strips the Python list decoration of one argument (as the original sed pipeline did).
mount_point_param() {
  printf '%s\n' "$1" | sed -e 's:\[::' -e 's:^u::' -e 's:,::' -e 's:\]::' -e "s:'::g"
}

stamp() { date +"%Y.%m.%d_%I.%M.%S%p"; }

newest_file() {
  local mp=$1 minutes=${2:-}
  if [[ -n $minutes ]]; then
    find "$mp" -name "*.*" -type f -mmin "-$minutes" -exec ls -lt {} + 2>/dev/null | head -n 1
  else
    find "$mp" -name "*.*" -type f -exec ls -lt {} + 2>/dev/null | head -n 1
  fi
}

main() {
  local minutes=${ORA_TIMESTAMP_MAX_MINUTES:-1440} arg mp found fail=0
  if [[ ! $minutes =~ ^[0-9]{1,7}$ ]]; then
    err "Error: ORA_TIMESTAMP_MAX_MINUTES must be a number of minutes: $minutes"
    return "$EX_FAIL"
  fi
  log "Script Begin Date_Time: $(stamp)"
  log "Checks timestamp of the most recently updated file in each mount point:"
  log "(Timestamp must not be older than $minutes minutes ago)"
  log ""

  shift || true
  for arg in "$@"; do
    mp=$(mount_point_param "$arg")
    # skip empty names and grid mount points (ending with z)
    [[ -n $mp && $mp != *z ]] || continue
    if [[ ! $mp =~ $RE_SAFE_PATH ]]; then
      err "Error: invalid mount point: '$mp'"
      return "$EX_FAIL"
    fi
    found=$(newest_file "$mp" "$minutes")
    if [[ -z $found ]]; then
      fail=1
      log "Error ${mp}: No file found or timestamp in files are older than $minutes minutes ago:"
      log "Fail: $(newest_file "$mp")"
      log ""
    fi
  done

  log "Script End Date_Time: $(stamp)"
  if [[ $fail -eq 1 ]]; then
    return "$EX_FAIL"
  fi
  return 0
}

main "$@"
exit $?

#!/usr/bin/env bash
#
# check_mount.bash - check that mount points are mounted (utility; not called by the playbooks).
#
# Usage: check_mount.bash <ORACLE_SID> <mount point list separated by spaces>
#   Mount point arguments may come from a Python list representation ([u'/u01', u'/u02']): "[", "]", ","
#   and a leading "u" are removed, as before. Each mount point is checked with mount and with df.
#
# Exit codes: 0 every mount point is mounted; 4 a mount point is missing or an argument is invalid.

set -u

readonly EX_FAIL=4
readonly RE_SAFE_PATH='^/[A-Za-z0-9._/-]*$'

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Strips the Python list decoration of one argument (as the original sed pipeline did).
mount_point_param() {
  printf '%s\n' "$1" | sed -e 's:\[::' -e 's:^u::' -e 's:,::' -e 's:\]::' -e "s:'::g"
}

is_mounted() {
  local mp=$1
  # check with the mount command
  mount | grep -w -q -F -e "$mp" || return 1
  # check again with the df command
  df -- "$mp" 2>/dev/null | sed 1d | awk '{ print $NF }' | grep -w -q -F -e "$mp"
}

main() {
  local arg mp missing=""
  log "Date_Time: $(date +"%Y.%m.%d_%I.%M%p")"
  shift || true
  for arg in "$@"; do
    mp=$(mount_point_param "$arg")
    [[ -n $mp ]] || continue
    if [[ ! $mp =~ $RE_SAFE_PATH ]]; then
      err "Error: invalid mount point: '$mp'"
      return "$EX_FAIL"
    fi
    if is_mounted "$mp"; then
      log "checking mount point: $mp ... good"
    else
      log "checking mount point: $mp ... ... bad"
      missing="$missing $mp"
    fi
  done

  if [[ -n $missing ]]; then
    log "Error: Mount points not mounted: $missing"
    return "$EX_FAIL"
  fi
  log "Mount points check completed successfully."
  return 0
}

main "$@"
exit $?

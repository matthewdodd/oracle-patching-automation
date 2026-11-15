#!/bin/bash
#
# TEST FIXTURE. Builds the fake patch bundle that the Molecule scenarios serve from their https artifact repository
# (molecule/shared/prepare.yml). Nothing in it is Oracle software: OPatch is the opatch and datapatch stubs.
#
# Usage:
#   build_patch_bundle.bash <stub_dir> <repository_dir> <release_folder> <bundle_file> <ru_id> <ojvm_id> <opatch_version>
#
# Result (the layout <repository URL>/<release folder>/<bundle file> that the playbook downloads):
#   <repository_dir>/<release_folder>/<bundle_file>   tar.gz, extracted into the patch staging directory:
#       OPatch/                       opatch and datapatch stubs, version.txt = <opatch_version> (newer than the homes')
#       p<ru_id>_190000_Linux-x86-64.tar.gz    -> <ru_id>/README.html   ("Database Release Update": the DB RU)
#       p<ojvm_id>_190000_Linux-x86-64.tar.gz  -> <ojvm_id>/README.html ("- Oracle JavaVM Component" twice: the OJVM RU)
#   <repository_dir>/<release_folder>/<bundle_file>.sha256   "<sha256>  <bundle_file>", the checksum file the inventory's
#       oracle_common_patch_checksum (sha256:<https URL>) points to, so the required checksum is really verified.
set -euo pipefail

usage() {
  echo "usage: $0 <stub_dir> <repository_dir> <release_folder> <bundle_file> <ru_id> <ojvm_id> <opatch_version>" >&2
  exit 1
}

readme() {
  local file=$1 title=$2 body=$3
  printf '<html><head><title>%s</title></head>\n<body>\n%s\n</body></html>\n' "$title" "$body" >"$file"
}

build() {
  local stub_dir=$1 out_dir=$2/$3 bundle_file=$4 ru_id=$5 ojvm_id=$6 opatch_version=$7 work bundle
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now: the trap must remove this work directory
  trap "rm -rf -- '$work'" EXIT
  bundle=$work/bundle
  mkdir -p "$out_dir" "$bundle/OPatch" "$work/ru/$ru_id" "$work/ojvm/$ojvm_id"

  install -m 0755 "$stub_dir/opatch" "$bundle/OPatch/opatch"
  install -m 0755 "$stub_dir/datapatch" "$bundle/OPatch/datapatch"
  printf 'OPATCH_VERSION:%s\n' "$opatch_version" >"$bundle/OPatch/version.txt"

  readme "$work/ru/$ru_id/README.html" "Database Release Update $ru_id (test stub)" \
    "<h1>Oracle Database Release Update $ru_id - test stub, not Oracle software</h1>"
  readme "$work/ojvm/$ojvm_id/README.html" "Oracle JavaVM Component Release Update $ojvm_id (test stub)" \
    "<p>Patch $ojvm_id - Oracle JavaVM Component Release Update (test stub)</p>
<p>Applies to - Oracle JavaVM Component of Oracle Database</p>"

  tar -C "$work/ru" -czf "$bundle/p${ru_id}_190000_Linux-x86-64.tar.gz" "$ru_id"
  tar -C "$work/ojvm" -czf "$bundle/p${ojvm_id}_190000_Linux-x86-64.tar.gz" "$ojvm_id"
  tar -C "$bundle" -czf "$out_dir/$bundle_file" .
  (cd "$out_dir" && sha256sum "$bundle_file" >"$bundle_file.sha256")
  ls -l "$out_dir"
}

main() {
  [[ $# -eq 7 ]] || usage
  build "$@"
}

main "$@"

#!/bin/bash
#
# TEST FIXTURE. Creates a throw-away certificate authority and a server certificate for the https artifact repository
# of the Molecule scenarios (molecule/shared/prepare.yml), inside the test container only. prepare.yml adds the CA to
# the container's system trust store, so the playbook downloads with its secure defaults: TLS certificate verified
# (oracle_common_patch_validate_certs true), https only (oracle_common_patch_repo_allow_http false).
#
# Usage: make_test_tls.bash <directory> <host name or IP address of the repository>
# Result in <directory>: ca.crt, ca.key, server.crt, server.key (keys 0600). Valid for 7 days.
set -euo pipefail

make_ca() {
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 \
    -subj "/CN=Molecule test CA (not trusted outside the test container)" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$1/ca.key" -out "$1/ca.crt"
}

make_server_cert() {
  local dir=$1 host=$2 san
  if [[ $host =~ ^[0-9.]+$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
  printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth" "subjectAltName=$san" >"$dir/server.ext"
  openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$host" -keyout "$dir/server.key" -out "$dir/server.csr"
  openssl x509 -req -sha256 -days 7 -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
    -extfile "$dir/server.ext" -out "$dir/server.crt"
}

main() {
  [[ $# -eq 2 ]] || {
    echo "usage: $0 <directory> <repository host>" >&2
    exit 1
  }
  umask 077
  mkdir -p "$1"
  make_ca "$1"
  make_server_cert "$1" "$2"
  chmod 0600 "$1/ca.key" "$1/server.key"
  chmod 0644 "$1/ca.crt" "$1/server.crt"
}

main "$@"

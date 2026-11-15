#!/bin/bash
#
# TEST FIXTURE. Creates a throw-away certificate authority and a server certificate for the https artifact repository
# of the Molecule scenarios (molecule/shared/prepare.yml), inside the test container only. prepare.yml adds the CA to
# the container's system trust store, so the playbook downloads with its secure defaults: TLS certificate verified
# (oracle_common_patch_validate_certs true), https only (oracle_common_patch_repo_allow_http false).
#
# Usage: make_test_tls.bash <directory> <host name or IP address of the repository>
# Result in <directory>: ca.crt, ca.key, server.crt, server.key (keys 0600), plus the request configurations and the
# CSR. Valid for 7 days. The chain is verified with this host's openssl before the script ends.
set -euo pipefail

# OpenSSL configuration of one certificate request (written next to the keys): the subject and, for the CA, its
# extensions. Every certificate is made with -config, so the distribution's openssl.cnf is never read. The default
# openssl.cnf of EL8 (OpenSSL 1.1.1) already gives a self-signed certificate basicConstraints in its v3_ca section, and
# "req -addext" there appends a second copy instead of replacing it (OpenSSL 3 replaces it): a CA with a duplicate
# extension is invalid, so OpenSSL 1.1.1 never accepts it as the issuer ("unable to get local issuer certificate", even
# with the CA in the system trust store).
write_req_config() {
  local file=$1 cn=$2 extensions=${3:-}
  {
    printf '%s\n' "[req]" "prompt = no" "distinguished_name = dn"
    if [[ -n $extensions ]]; then printf '%s\n' "x509_extensions = ext"; fi
    printf '%s\n' "[dn]" "CN = $cn"
    if [[ -n $extensions ]]; then printf '%s\n' "[ext]" "$extensions"; fi
  } >"$file"
}

make_ca() {
  write_req_config "$1/ca.cnf" "Molecule test CA (not trusted outside the test container)" \
    "$(printf '%s\n' "basicConstraints = critical,CA:TRUE" "keyUsage = critical,keyCertSign,cRLSign" \
      "subjectKeyIdentifier = hash" "authorityKeyIdentifier = keyid:always")"
  openssl req -x509 -config "$1/ca.cnf" -newkey rsa:2048 -nodes -sha256 -days 7 -keyout "$1/ca.key" -out "$1/ca.crt"
}

make_server_cert() {
  local dir=$1 host=$2 san
  if [[ $host =~ ^[0-9.]+$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
  # The key identifiers are required by clients that verify strictly (Python 3.13+ sets VERIFY_X509_STRICT, which
  # refuses a certificate without an Authority Key Identifier); tests/download.yml uses this fixture on the controller.
  printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth" "subjectAltName=$san" "subjectKeyIdentifier=hash" \
    "authorityKeyIdentifier=keyid,issuer" >"$dir/server.ext"
  write_req_config "$dir/server.cnf" "$host"
  openssl req -new -config "$dir/server.cnf" -newkey rsa:2048 -nodes -sha256 -keyout "$dir/server.key" -out "$dir/server.csr"
  openssl x509 -req -sha256 -days 7 -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
    -extfile "$dir/server.ext" -out "$dir/server.crt"
}

# Fails (set -e) when the server certificate does not verify against the CA with the openssl of this host, so a CA that
# this host's TLS library rejects is reported here, not as a download that times out later.
check_chain() {
  openssl verify -purpose sslserver -CAfile "$1/ca.crt" "$1/server.crt"
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
  check_chain "$1"
  chmod 0600 "$1/ca.key" "$1/server.key"
  chmod 0644 "$1/ca.crt" "$1/server.crt"
}

main "$@"

"""TEST FIXTURE: the https artifact repository of the Molecule scenarios (molecule/shared/prepare.yml).

Serves a directory read-only over TLS on one address of the test container and appends one line per request to an
access log, which the verify playbooks read to check that both the patch bundle and its checksum file were fetched
over https.

Usage: https_repository.py <directory> <bind address> <port> <certificate> <key> <access log>
"""

import functools
import http.server
import ssl
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    """Static files only, with the access log written to a file."""

    access_log = None

    def log_message(self, format, *args):  # noqa: A002 - signature of the base class
        with open(self.access_log, "a", encoding="utf-8") as log:
            log.write("%s %s\n" % (self.address_string(), format % args))


def main():
    directory, address, port, certificate, key, access_log = sys.argv[1:7]
    Handler.access_log = access_log
    handler = functools.partial(Handler, directory=directory)
    httpd = http.server.ThreadingHTTPServer((address, int(port)), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()

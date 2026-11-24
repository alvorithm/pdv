#!/usr/bin/env python3
"""LSP stdio bridge, run INSIDE the Penpot devenv container.

Spawned once per editor LSP session by `pdv lsp` via
    docker exec -i -u penpot <container> python3 -c "<this source>" \
        <clojure-lsp binary> <host_root>...

Why stdio and not a Unix socket: a socket bound inside the container is not
connectable from the host across the bind mount (container-side connect works,
host-side gets ECONNREFUSED). `docker exec` stdio is the transport that works.

The project is bind-mounted at different absolute paths on each side
(host <host_root>, container /home/penpot/penpot), and the LSP stream is
addressed entirely by file:// URIs / bare paths, so every message body is
rewritten between the two roots (Content-Length recomputed per frame).

clojure-lsp runs as penpot with the full container classpath (.m2, .gitlibs),
so it resolves deps and indexes the whole monorepo; results come back with
container paths, rewritten to host paths the editor can open. One clojure-lsp
per session, reaped when the session ends (no shared long-lived child, no
zombie).
"""
import os
import re
import subprocess
import sys
import threading

CONTAINER_ROOT = "/home/penpot/penpot"

# The binary pdv found, then every host-side spelling of the mount source
# (canonical first, then the docker-inspect form). Server paths translate
# back into the first spelling only.
if len(sys.argv) < 3:
    sys.stderr.write("lsp-bridge: usage: <clojure-lsp binary> <host_root>...\n")
    sys.exit(64)
LSP_BIN = sys.argv[1]
HOST_ROOTS = sys.argv[2:]


def read_message(r):
    """Read one LSP frame from binary stream r; return body bytes or None at EOF."""
    length = None
    while True:
        line = r.readline()
        if line == b"":
            return None
        if line in (b"\r\n", b"\n"):
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            if k.strip().lower() == b"content-length":
                length = int(v.strip())
    if length is None:
        return None
    body = b""
    while len(body) < length:
        chunk = r.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return body


def frame(body):
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def pump(r, w, transform):
    try:
        while True:
            body = read_message(r)
            if body is None:
                break
            w.write(frame(transform(body)))
            w.flush()
    except (OSError, ValueError):
        pass


def main():
    cont_b = CONTAINER_ROOT.encode()
    host_bs = [p.encode() for p in HOST_ROOTS]

    def to_server(b):
        # host paths -> container paths, and null out processId: clojure-lsp
        # monitors the client PID and exits if it's not alive, but the host PID
        # doesn't exist in the container's PID namespace (would exit ~8s after
        # initialize). null disables the parent-liveness check.
        for host_b in host_bs:
            b = b.replace(host_b, cont_b)
        return re.sub(rb'"processId"\s*:\s*(?:\d+|null)', b'"processId":null', b)

    def to_client(b):
        return b.replace(cont_b, host_bs[0])

    try:
        errlog = open("/tmp/penpot-lsp-bridge.log", "ab")
    except OSError:
        errlog = subprocess.DEVNULL
    lsp = subprocess.Popen([LSP_BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=errlog, cwd=CONTAINER_ROOT)
    # editor -> clojure-lsp: host paths -> container paths, processId nulled.
    # The editor closing its end means the session is over, and clojure-lsp
    # would otherwise outlive it inside the container.
    def from_editor():
        pump(sys.stdin.buffer, lsp.stdin, to_server)
        try:
            lsp.terminate()
        except OSError:
            pass

    threading.Thread(target=from_editor, daemon=True).start()
    # clojure-lsp -> editor: container paths -> host paths (blocks until clojure-lsp exits)
    pump(lsp.stdout, sys.stdout.buffer, to_client)
    try:
        lsp.terminate()
    except OSError:
        pass
    # Skip interpreter finalization: the stdin->clojure-lsp daemon thread is
    # blocked on a buffered read, which otherwise triggers a fatal shutdown error.
    os._exit(0)


if __name__ == "__main__":
    main()

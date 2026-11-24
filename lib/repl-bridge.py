#!/usr/bin/env python3
"""Host->container nREPL bridge for the Penpot devenv.

Listens on 127.0.0.1:<listen-port> on the host and pipes each accepted
connection to a TCP port inside the devenv container via `docker exec ...
python3`.  Lets host-side editors (Emacs/CIDER, Zed's clojure-repl tasks)
reach the container's nREPL without publishing a port or recreating the
container (the host cannot route to the container IP: ip_forward=0).

    host client -> 127.0.0.1:6064  (this script)
                -> docker exec -i <container> python3 -c <stdio<->tcp pipe>
                -> 127.0.0.1:6064  inside the container (nREPL)

nREPL is a bencode/TCP protocol carrying code and data -- no file:// URIs --
so, unlike the LSP bridge, this is a raw byte pipe with no path translation.

Stdlib only, both sides.  The container needs only python3 (already in the
devenv image), so there is nothing to install and it survives recreation.

`pdv repl` runs it in the foreground, one bridge per instance:
    repl-bridge.py --container C --listen-port 6064 --target-port 6066
"""
import argparse
import os
import signal
import socket
import subprocess
import sys
import threading

# Runs inside the container: bridges its own stdin/stdout to a TCP socket.
INNER = r"""
import socket, sys, os, threading
s = socket.create_connection((sys.argv[1], int(sys.argv[2])))
def sock_to_stdout():
    try:
        while True:
            d = s.recv(65536)
            if not d:
                break
            os.write(1, d)
    except Exception:
        pass
    finally:
        os._exit(0)
threading.Thread(target=sock_to_stdout, daemon=True).start()
try:
    while True:
        d = os.read(0, 65536)
        if not d:
            break
        s.sendall(d)
except Exception:
    pass
"""


def handle(client, container, target_host, target_port):
    proc = subprocess.Popen(
        ["docker", "exec", "-i", container,
         "python3", "-c", INNER, target_host, str(target_port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )

    def client_to_proc():
        try:
            while True:
                data = client.recv(65536)
                if not data:
                    break
                proc.stdin.write(data)
                proc.stdin.flush()
        except OSError:
            pass
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass

    def proc_to_client():
        try:
            while True:
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    break
                client.sendall(data)
        except OSError:
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass

    t1 = threading.Thread(target=client_to_proc, daemon=True)
    t2 = threading.Thread(target=proc_to_client, daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    try:
        proc.terminate()
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="Host->container nREPL bridge")
    ap.add_argument("--container", default="penpot-devenv-ws0-main")
    ap.add_argument("--listen-host", default="127.0.0.1")
    ap.add_argument("--listen-port", type=int, default=6064)
    ap.add_argument("--target-host", default="127.0.0.1")
    ap.add_argument("--target-port", type=int, default=6064)
    args = ap.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.listen_host, args.listen_port))
    server.listen(8)
    print(f"[repl-bridge] {args.listen_host}:{args.listen_port} -> "
          f"{args.container}:{args.target_port}", file=sys.stderr, flush=True)

    signal.signal(signal.SIGINT, lambda *_: (server.close(), sys.exit(0)))
    try:
        while True:
            client, _ = server.accept()
            threading.Thread(
                target=handle,
                args=(client, args.container, args.target_host,
                      args.target_port),
                daemon=True,
            ).start()
    except OSError:
        pass


if __name__ == "__main__":
    main()

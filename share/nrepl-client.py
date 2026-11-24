#!/usr/bin/env python3
"""nrepl-client.py: evaluate Clojure code over nREPL from inside the devenv.

Runs inside the devenv container, where the nREPL servers listen: the test
JVM's on 127.0.0.1:6065, the backend's on 6064. `pdv testjvm` and `pdv
eval` pass this file's source as `python3 -S -c "$src"` through `docker
exec`, because pdv's checkout is not mounted there; stdin stays
free for the code.

  nrepl-client.py [--port P] [--ns NS] [--timeout S] [--exit-value]
                  [--pre FORM] (CODE | - | --load-file PATH --file-name NAME)

CODE is evaluated; `-` reads it from stdin. --load-file sends the nREPL
load-file op with the content from stdin and PATH as the file's path, so
errors cite PATH and its lines even when PATH exists only on the host.
--pre evaluates FORM first on the same connection; it must return an
integer, and anything but 0 ends the call with that exit status (the
test-JVM guards: a reload, a staleness check).

Everything runs in a cloned session, so the deadline can interrupt it:
--timeout bounds the whole call, and when it passes the client sends
`interrupt` and exits 4. Output and errors stream as the JVM prints them,
and each top-level form's value prints as it arrives, cut by the server at
16000 characters. With --exit-value the process exits with the last value
instead, which must be an integer.

Exit status: 0 evaluated, 1 the code threw, 3 nothing listens on the port
or the connection closed before the evaluation finished, 4 deadline
passed, 6 harness error (a --pre or --exit-value form threw or returned no
integer), 64 bad usage; with --exit-value, the value. Standard library
only: bencode is a dozen lines.
"""
import argparse
import os
import socket
import sys
import time

QUOTA = 16000
TRUNCATED = "nrepl.middleware.print/truncated"


def bencode(obj):
    if isinstance(obj, int):
        return b"i%de" % obj
    if isinstance(obj, str):
        obj = obj.encode()
    if isinstance(obj, bytes):
        return b"%d:%s" % (len(obj), obj)
    if isinstance(obj, list):
        return b"l" + b"".join(bencode(x) for x in obj) + b"e"
    if isinstance(obj, dict):
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in sorted(obj.items())) + b"e"
    raise TypeError(type(obj))


def read_exactly(stream, n):
    data = stream.read(n)
    if len(data) < n:
        raise EOFError
    return data


def bdecode(stream, head=None):
    """Read one value from a binary file-like object. EOFError at end of
    stream, also between messages: the caller decides whether that was
    expected."""
    head = head or read_exactly(stream, 1)
    if head == b"i":
        digits = b""
        while (c := read_exactly(stream, 1)) != b"e":
            digits += c
        return int(digits)
    if head in (b"l", b"d"):
        items = []
        while (c := read_exactly(stream, 1)) != b"e":
            items.append(bdecode(stream, c))
        if head == b"l":
            return items
        return {items[i].decode(): items[i + 1] for i in range(0, len(items), 2)}
    digits = head
    while (c := read_exactly(stream, 1)) != b":":
        digits += c
    return read_exactly(stream, int(digits))


def text(value):
    return value.decode(errors="replace") if isinstance(value, bytes) else str(value)


class Deadline(Exception):
    pass


class Connection:
    def __init__(self, port, deadline):
        self.deadline = deadline
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=min(10, self.remaining()))
        self.stream = self.sock.makefile("rb")
        self.next_id = 0

    def remaining(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Deadline
        return left

    def send(self, msg):
        self.next_id += 1
        msg["id"] = "%d-%d" % (os.getpid(), self.next_id)
        self.sock.settimeout(self.remaining())
        try:
            self.sock.sendall(bencode(msg))
        except socket.timeout:
            raise Deadline
        return msg["id"]

    def recv(self):
        self.sock.settimeout(self.remaining())
        try:
            return bdecode(self.stream)
        except socket.timeout:
            raise Deadline


class Result:
    def __init__(self):
        self.value = None
        self.failed = False
        self.interrupted = False
        self.truncated = False


def run_request(conn, msg, print_values):
    """Send one request and stream its output until `done`."""
    msg_id = conn.send(msg)
    res, at_line_start = Result(), True
    while True:
        reply = conn.recv()
        if text(reply.get("id", b"")) != msg_id:
            continue
        if "out" in reply:
            out = text(reply["out"])
            sys.stdout.write(out)
            sys.stdout.flush()
            at_line_start = out.endswith("\n") or (at_line_start and not out)
        if "err" in reply:
            sys.stderr.write(text(reply["err"]))
            sys.stderr.flush()
        if "value" in reply:
            res.value = text(reply["value"])
            if print_values:
                print(res.value if at_line_start else "\n" + res.value, flush=True)
                at_line_start = True
        if "ex" in reply:
            res.failed = True
        status = [text(s) for s in reply.get("status", [])]
        if TRUNCATED in status:
            res.truncated = True
        if "interrupted" in status:
            res.interrupted = True
        # nREPL reports namespace-not-found as an :error status with no
        # :ex, so a typo in --ns would otherwise exit 0 having evaluated
        # nothing.
        if "error" in status:
            res.failed = True
            if "namespace-not-found" in status:
                print(f"[nrepl] namespace not found: {text(reply.get('ns', b''))}", file=sys.stderr)
        if "done" in status:
            return res


def close_session(conn, session):
    """Drop the cloned session; the JVM keeps it otherwise. Waits for the
    answer: a socket closed before it makes nREPL log a 30-line
    SocketException. Best effort, at most 2 s."""
    try:
        conn.deadline = time.monotonic() + 2
        close_id = conn.send({"op": "close", "session": session})
        while text(conn.recv().get("id", b"")) != close_id:
            pass
        conn.sock.close()
    except (Deadline, EOFError, OSError):
        pass


def interrupt(port, session):
    """Interrupt whatever `session` evaluates, over a fresh connection (the
    timed-out one's buffered reader is unusable), then close the session.
    nREPL interrupts the evaluating thread and, when the JVM allows
    attaching to itself, stops it after 5 s."""
    try:
        conn = Connection(port, time.monotonic() + 5)
        conn.send({"op": "interrupt", "session": session})
        conn.recv()
        close_session(conn, session)
    except (Deadline, EOFError, OSError):
        pass


def integer(res, what):
    """The integer value of a guard or --exit-value form, or None after
    printing the harness error."""
    if res.failed:
        print(f"[nrepl] harness error: the {what} threw; the exception is above", file=sys.stderr)
        return None
    try:
        return int(res.value)
    except (TypeError, ValueError):
        print(f"[nrepl] harness error: the {what} returned {res.value!r}, not an integer exit status",
              file=sys.stderr)
        return None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"nrepl-client.py: {message}", file=sys.stderr)
        sys.exit(64)


def positive(value):
    seconds = float(value)
    if not seconds > 0:
        raise argparse.ArgumentTypeError("must be more than 0")
    return seconds


def main():
    ap = Parser(prog="nrepl-client.py")
    ap.add_argument("--port", type=int, default=6065)
    ap.add_argument("--ns", help="namespace to evaluate in (default user)")
    ap.add_argument("--timeout", type=positive, default=1800.0)
    ap.add_argument("--exit-value", action="store_true")
    ap.add_argument("--pre", help="guard form evaluated first; a non-zero integer ends the call")
    ap.add_argument("--load-file", metavar="PATH", help="load stdin as the file PATH")
    ap.add_argument("--file-name", metavar="NAME")
    ap.add_argument("code", nargs="?", help="code to evaluate, or - for stdin")
    args = ap.parse_args()
    if (args.code is None) == (args.load_file is None):
        ap.error("give CODE, -, or --load-file PATH")
    if args.load_file and not args.file_name:
        ap.error("--load-file needs --file-name")

    if args.load_file:
        main_msg = {"op": "load-file", "file": sys.stdin.read(),
                    "file-path": args.load_file, "file-name": args.file_name}
    else:
        main_msg = {"op": "eval", "code": sys.stdin.read() if args.code == "-" else args.code}
    main_msg["nrepl.middleware.print/quota"] = QUOTA
    if args.ns:
        main_msg["ns"] = args.ns

    deadline = time.monotonic() + args.timeout
    try:
        conn = Connection(args.port, deadline)
    except (Deadline, OSError) as e:
        print(f"[nrepl] nothing listens on 127.0.0.1:{args.port} ({e or 'timed out'})", file=sys.stderr)
        return 3

    session = None
    try:
        conn.send({"op": "clone"})
        while session is None:
            session = conn.recv().get("new-session")
        session = text(session)
        if args.pre:
            res = run_request(conn, {"op": "eval", "code": args.pre, "session": session}, False)
            status = 4 if res.interrupted else integer(res, "--pre guard")
            if status != 0:
                close_session(conn, session)
                return 6 if status is None else status
        main_msg["session"] = session
        res = run_request(conn, main_msg, not args.exit_value)
    except Deadline:
        if session:
            interrupt(args.port, session)
        print(f"[nrepl] no answer within {args.timeout:.0f} s; interrupted", file=sys.stderr)
        return 4
    except (EOFError, OSError):
        print("[nrepl] connection closed before the evaluation finished; the JVM likely died",
              file=sys.stderr)
        return 3
    close_session(conn, session)

    if res.interrupted:
        print("[nrepl] the evaluation was interrupted", file=sys.stderr)
        return 4
    if res.truncated:
        print(f"[nrepl] the value was cut at {QUOTA} characters", file=sys.stderr)
    if args.exit_value:
        status = integer(res, "form")
        return 6 if status is None else status
    return 1 if res.failed else 0


if __name__ == "__main__":
    sys.exit(main())

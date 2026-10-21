#!/usr/bin/env python3
"""Test every binary of a build directory against SPEC.md and write results.tsv next to them.

Usage: scripts/check.py <dir>    e.g. scripts/check.py out/linux-amd64/c

Binaries are named <program>-<variant> (hello-default, tcp-extreme, ...).
Exit status is 1 if any binary fails.
"""
import os
import socket
import struct
import subprocess
import sys
import threading
import time

HELLO = b"Hello, World!\n"
REQUEST = b"hello\n"
PAYLOAD = b"got: hello\n" + b"".join(b"%05d abcdefghijklmnopqrstuvwxyz\n" % i for i in range(300))
# Sent in pieces with pauses: a client that reads only once gets the first 11 bytes.
CHUNKS = [PAYLOAD[:11], PAYLOAD[11:4000], PAYLOAD[4000:]]


def handle(conn, reset):
    with conn:
        conn.settimeout(5)
        data = b""
        try:
            while not data.endswith(b"\n") and len(data) < 64:
                b = conn.recv(64)
                if not b:
                    break
                data += b
        except OSError:
            pass
        if data != REQUEST:
            conn.sendall(b"bad request: %r\n" % data)
            return
        if reset:  # first chunk, then a RST instead of a clean close
            conn.sendall(CHUNKS[0])
            time.sleep(0.1)
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            return
        for c in CHUNKS:
            conn.sendall(c)
            time.sleep(0.05)


def serve(host, reset=False):
    """Start a server on host, return its port, or None if host can't be bound.
    With reset, it sends the first chunk and then resets the connection."""
    s = socket.socket()
    try:
        s.bind((host, 0))
    except OSError:
        s.close()
        return None
    s.listen(16)

    def loop():
        while True:
            c, _ = s.accept()
            threading.Thread(target=handle, args=(c, reset), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


def other_address():
    """A local IPv4 address other than 127.0.0.1, to catch clients that ignore argv."""
    port = serve("127.1.2.3")  # works on Linux, the whole 127/8 is on lo
    if port:
        return "127.1.2.3", port
    try:  # no packet is sent, this only picks the outgoing interface
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.connect(("192.0.2.1", 9))
        ip = u.getsockname()[0]
        u.close()
        port = None if ip.startswith("127.") else serve(ip)
        if port:
            return ip, port
    except OSError:
        pass
    return None


def dead_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run(args, timeout=10):
    try:
        p = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return "timeout", b""
    except OSError as e:
        return "exec error: %s" % e, b""


def is_error_exit(rc):
    return isinstance(rc, int) and 1 <= rc <= 125


def check_hello(path):
    rc, out = run([path], timeout=5)
    if rc != 0:
        return "exit %s" % rc
    if out != HELLO:
        return "stdout %r" % out[:40]
    return None


def check_tcp(path, servers, reset_port):
    for host, port in servers:
        rc, out = run([path, host, str(port)])
        if rc != 0:
            return "%s:%d exit %s" % (host, port, rc)
        if out != PAYLOAD:
            return "%s:%d got %d bytes, want %d (%r)" % (host, port, len(out), len(PAYLOAD), out[:30])
    live = str(servers[0][1])
    for args, what in (([], "no args"), (["127.0.0.1"], "one arg"), ([live], "one arg (port)"),
                       ([live + ".127.0.0.1"], "one arg (port.ip)"), (["1.2.3"], "one arg (1.2.3)"),
                       (["127.0.0.1", str(dead_port())], "refused"),
                       (["127.0.0.1", str(reset_port)], "reset mid-reply")):
        rc, _ = run([path] + args)
        if not is_error_exit(rc):
            return "%s: exit %s, want 1-125" % (what, rc)
    return None


def main():
    d = sys.argv[1]
    servers = [("127.0.0.1", serve("127.0.0.1"))]
    reset_port = serve("127.0.0.1", reset=True)
    alt = other_address()
    if alt:
        servers.append(alt)
    names = sorted(n for n in os.listdir(d)
                   if (n.startswith("hello-") or n.startswith("tcp-")) and "." not in n)
    rows, failed = [], 0
    for n in names:
        path = os.path.join(d, n)
        err = check_hello(path) if n.startswith("hello-") else check_tcp(path, servers, reset_port)
        size = os.path.getsize(path)
        status = "FAIL" if err else "PASS"
        failed += bool(err)
        rows.append((n, size, status, err or ""))
        print("%-4s %8d  %s/%s  %s" % (status, size, d, n, err or ""))
    with open(os.path.join(d, "results.tsv"), "w") as f:
        for r in rows:
            f.write("%s\t%d\t%s\t%s\n" % r)
    if not alt:
        print("note: no second local address, tcp tested on 127.0.0.1 only")
    sys.exit(1 if failed or not names else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Clever Cloud health-check proxy for xray.

Listens on $PORT (platform-injected, default 8080 for Clever Cloud Docker).
Returns HTTP 200 for GET /healthz (and GET /) when xray is reachable,
otherwise 503. All other traffic is proxied as raw TCP to xray on
127.0.0.1:10000 (WebSocket handshake included).

xray itself returns 404 on GET /, which fails a readiness probe
that polls / and requires 2xx.
"""
import os
import socket
import threading

PORT = int(os.environ.get("PORT", "8080"))
XRAY_HOST = "127.0.0.1"
XRAY_PORT = 10000


def xray_up():
    try:
        s = socket.create_connection((XRAY_HOST, XRAY_PORT), timeout=2)
        s.close()
        return True
    except OSError:
        return False


def relay(src, dst, closer):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        closer()


def handle(client):
    upstream = None
    try:
        buf = b""
        client.settimeout(5)
        while b"\r\n\r\n" not in buf and len(buf) < 65536:
            chunk = client.recv(65536 - len(buf))
            if not chunk:
                break
            buf += chunk
        if not buf:
            return
        first_line = buf.split(b"\r\n", 1)[0].decode("latin-1", "ignore")
        parts = first_line.split(" ")
        method = parts[0] if parts else ""
        path = parts[1].split("?", 1)[0] if len(parts) > 1 else ""
        if method in ("GET", "HEAD") and path in ("/healthz", "/"):
            ok = xray_up()
            body = b"ok" if ok else b"down"
            status = b"200 OK" if ok else b"503 Service Unavailable"
            resp = (
                b"HTTP/1.1 " + status + b"\r\nContent-Type: text/plain\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                b"Connection: close\r\n\r\n"
            )
            if method == "GET":
                resp += body
            client.sendall(resp)
            return
        upstream = socket.create_connection((XRAY_HOST, XRAY_PORT), timeout=5)
        upstream.sendall(buf)
        client.settimeout(None)
        upstream.settimeout(None)
        closed = threading.Event()

        def close_both():
            if not closed.is_set():
                closed.set()
                for s in (client, upstream):
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    try:
                        s.close()
                    except OSError:
                        pass

        t1 = threading.Thread(target=relay, args=(client, upstream, close_both), daemon=True)
        t2 = threading.Thread(target=relay, args=(upstream, client, close_both), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError:
        pass
    finally:
        for s in (client, upstream):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(128)
    print("proxy: listening on %d, xray at %s:%d" % (PORT, XRAY_HOST, XRAY_PORT), flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Stand-in for QUAD's GET /program.mjpeg (PLAN_quad_virtual_camera.md, phase 0).

QUAD itself serves /program.mjpeg since phase 1 (desktop/.../QuadProgram.kt, same port);
use this only to test the extension with no console running.

Pulls ONE camera's MJPEG (the Sony `/mjpeg` server push, 1280x720) and re-serves it as
the program stream the ARC QUAD camera extension reads. This is the wire contract QUAD
will serve in phase 1, so the extension is built against the real format:

    multipart/x-mixed-replace; boundary=arcquad
    --arcquad\r\n
    Content-Type: image/jpeg\r\n
    Content-Length: <n>\r\n
    \r\n
    <n bytes of JPEG>\r\n

One upstream connection no matter how many clients (each camera has few client slots).
Camera credentials come from ~/.arc-ptz-quad.properties at run time, never from here.

    python3 program_relay.py [--room 1] [--port 8779]
"""
import argparse
import http.server
import socketserver
import subprocess
import threading
import time
from pathlib import Path

BOUNDARY = b"arcquad"


def props():
    out = {}
    for line in (Path.home() / ".arc-ptz-quad.properties").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


class Latest:
    """The newest frame and a condition clients wait on."""

    def __init__(self):
        self.cond = threading.Condition()
        self.frame = None
        self.seq = 0

    def put(self, jpeg):
        with self.cond:
            self.frame, self.seq = jpeg, self.seq + 1
            self.cond.notify_all()


def pull(host, user, password, latest):
    """Read the camera's stream forever. The camera's parts carry `DataLength:`."""
    backoff = 1.5
    while True:
        # curl owns the digest handshake: ONE handshake per connection, Referer always
        # (without it the camera answers 403 with no challenge; CameraSession.kt).
        p = subprocess.Popen(
            ["curl", "-sN", "--digest", "-u", f"{user}:{password}",
             "-H", f"Referer: http://{host}/", f"http://{host}/mjpeg"],
            stdout=subprocess.PIPE)
        frames = 0
        try:
            f = p.stdout
            while True:
                length = None
                while True:
                    line = f.readline()
                    if not line:
                        raise EOFError
                    s = line.strip()
                    if s.lower().startswith(b"datalength:") or s.lower().startswith(b"content-length:"):
                        length = int(s.split(b":", 1)[1])
                    elif not s and length is not None:
                        break
                data = f.read(length)
                if len(data) != length:
                    raise EOFError
                latest.put(data)
                frames += 1
                backoff = 1.5
        except EOFError:
            pass
        finally:
            p.kill()
        print(f"upstream closed after {frames} frames; reconnecting in {backoff:.1f}s", flush=True)
        time.sleep(backoff)
        backoff = min(backoff * 2, 10)


def handler_for(latest):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.split("?")[0] != "/program.mjpeg":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=arcquad")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            print(f"client {self.client_address[0]} connected", flush=True)
            seen = 0
            try:
                while True:
                    with latest.cond:
                        latest.cond.wait_for(lambda: latest.seq != seen, timeout=5)
                        frame, seen = latest.frame, latest.seq
                    if frame is None:
                        continue
                    self.wfile.write(b"--" + BOUNDARY + b"\r\nContent-Type: image/jpeg\r\n"
                                     + f"Content-Length: {len(frame)}\r\n\r\n".encode()
                                     + frame + b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                print(f"client {self.client_address[0]} left", flush=True)
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--room", type=int, default=1)
    ap.add_argument("--port", type=int, default=8779)
    a = ap.parse_args()
    p = props()
    host = p[f"room{a.room}.host"]
    latest = Latest()
    threading.Thread(target=pull, args=(host, p.get(f"room{a.room}.user", "admin"),
                                        p[f"room{a.room}.password"], latest), daemon=True).start()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer(("0.0.0.0", a.port), handler_for(latest))
    srv.daemon_threads = True
    print(f"program relay: room{a.room} {host} -> http://0.0.0.0:{a.port}/program.mjpeg", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

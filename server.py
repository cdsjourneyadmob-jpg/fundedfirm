#!/usr/bin/env python3
"""
Tiny HTTP server so this can run as a Render FREE *web service*
(background workers are not available on the free plan).

- Binds to $PORT (Render requirement for web services).
- Launches run_loop.sh as a background subprocess.
- Serves a small status page + reads accounts count from accounts.txt.
"""
import os
import time
import subprocess
import threading
import urllib.request
import http.server
import socketserver

PORT = int(os.environ.get("PORT", "10000"))
# Render injects the public URL of this service; used for self-ping keep-alive.
SELF_URL = os.environ.get("RENDER_EXTERNAL_URL", "")
# How often to self-ping (seconds). Must be < Render's ~15min idle window.
KEEPALIVE_SECS = int(os.environ.get("KEEPALIVE_SECS", "600"))
WORK = os.environ.get("REPO_DIR", os.path.dirname(os.path.abspath(__file__)))
ACCOUNTS = os.path.join(os.environ.get("DATA_DIR", WORK), "accounts.txt")

_loop_started = False
_lock = threading.Lock()


def start_loop_once():
    global _loop_started
    with _lock:
        if _loop_started:
            return
        _loop_started = True
    # Launch the loop; inherit env (BASE_DELAY, JITTER, GITHUB_TOKEN, etc.)
    subprocess.Popen(
        ["bash", os.path.join(WORK, "run_loop.sh")],
        cwd=WORK,
    )
    print(f"[server] launched run_loop.sh in {WORK}", flush=True)


def keepalive_loop():
    """Ping our own public URL periodically so Render's free web service
    doesn't spin down for inactivity (replaces an external uptime pinger)."""
    if not SELF_URL:
        print("[keepalive] RENDER_EXTERNAL_URL not set; self-ping disabled", flush=True)
        return
    url = SELF_URL.rstrip("/") + "/healthz"
    # small initial delay so the server is listening first
    time.sleep(15)
    while True:
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                r.read()
            print(f"[keepalive] pinged {url} ({KEEPALIVE_SECS}s interval)", flush=True)
        except Exception as e:
            print(f"[keepalive] ping failed: {e}", flush=True)
        time.sleep(KEEPALIVE_SECS)


def account_count():
    try:
        with open(ACCOUNTS) as f:
            return sum(1 for ln in f if ln.strip() and not ln.startswith("#"))
    except FileNotFoundError:
        return 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = (
            "fundedfirm account loop running\n"
            f"accounts created (this checkout): {account_count()}\n"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # quiet


if __name__ == "__main__":
    start_loop_once()
    # Self-ping keep-alive thread (no external uptime service needed)
    threading.Thread(target=keepalive_loop, daemon=True).start()
    with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"[server] listening on :{PORT}", flush=True)
        httpd.serve_forever()

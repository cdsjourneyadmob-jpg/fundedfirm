#!/usr/bin/env python3
"""
Tiny HTTP server so this can run as a Render FREE *web service*
(background workers are not available on the free plan).

- Binds to $PORT (Render requirement for web services).
- Launches run_loop.sh as a background subprocess.
- Serves a small status page + reads accounts count from accounts.txt.
"""
import os
import subprocess
import threading
import http.server
import socketserver

PORT = int(os.environ.get("PORT", "10000"))
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


def account_count():
    try:
        with open(ACCOUNTS) as f:
            return sum(1 for ln in f if ln.strip() and not ln.startswith("#"))
    except FileNotFoundError:
        return 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
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
    with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"[server] listening on :{PORT}", flush=True)
        httpd.serve_forever()

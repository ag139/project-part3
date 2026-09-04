import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Info, generate_latest

HEARTBEAT_FILE = "/tmp/healthy"  # nosec B108  # noqa: S108
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))

worker_iterations_total = Counter(
    "worker_iterations_total",
    "Completed iterations of the background loop.",
)

worker_heartbeat_timestamp_seconds = Gauge(
    "worker_heartbeat_timestamp_seconds",
    "Unix time of the last completed iteration.",
)

worker_up = Gauge(
    "worker_up",
    "1 while the background loop is running.",
)

app_info = Info("app", "Build and release identity of the running instance.")
app_info.info(
    {
        "version": os.environ.get("APP_VERSION", "unknown"),
        "git_sha": os.environ.get("GIT_SHA", "unknown"),
        "release": os.environ.get("RELEASE", "unknown"),
        "component": "worker",
    }
)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = generate_latest()
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE_LATEST)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def serve_metrics():
    HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler).serve_forever()  # nosec B104  # noqa: S104


threading.Thread(target=serve_metrics, daemon=True).start()
worker_up.set(1)

while True:
    print("Worker running", flush=True)
    now = time.time()
    with open(HEARTBEAT_FILE, "w") as f:
        f.write(str(now))
    worker_iterations_total.inc()
    worker_heartbeat_timestamp_seconds.set(now)
    time.sleep(10)

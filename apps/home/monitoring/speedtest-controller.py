import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
UPSTREAM_METRICS_URL = os.environ.get(
    "UPSTREAM_METRICS_URL",
    "http://speedtest-exporter.monitoring.svc:9798/metrics",
)
REQUEST_TIMEOUT_SECONDS = int(os.environ.get("REQUEST_TIMEOUT_SECONDS", "180"))
SCHEDULE_INTERVAL_SECONDS = int(os.environ.get("SCHEDULE_INTERVAL_SECONDS", "1800"))

METRIC_RE = re.compile(r"^(speedtest_[a-z_]+)\s+([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)$")
HELP_TEXT = {
    "speedtest_server_id": "Speedtest server ID used to test",
    "speedtest_jitter_latency_milliseconds": "Speedtest current jitter in ms",
    "speedtest_ping_latency_milliseconds": "Speedtest current ping in ms",
    "speedtest_download_bits_per_second": "Speedtest current download speed in bit/s",
    "speedtest_upload_bits_per_second": "Speedtest current upload speed in bit/s",
    "speedtest_up": "Speedtest status whether the scrape worked",
    "speedtest_last_run_timestamp_seconds": "Unix timestamp of the last completed speedtest run",
    "speedtest_run_in_progress": "Whether a speedtest run is currently in progress",
    "speedtest_last_run_status": "Whether the last completed speedtest run succeeded",
    "speedtest_manual_runs_total": "Total number of accepted manual run requests",
    "speedtest_scheduled_runs_total": "Total number of scheduled speedtest runs",
}

state_lock = threading.Lock()
run_lock = threading.Lock()
state = {
    "metrics": {},
    "running": False,
    "last_run_timestamp": 0.0,
    "last_run_status": 0.0,
    "last_error": "",
    "last_trigger": "startup",
    "manual_runs_total": 0.0,
    "scheduled_runs_total": 0.0,
}


def fetch_metrics():
    request = urllib.request.Request(
        UPSTREAM_METRICS_URL,
        headers={"User-Agent": "speedtest-controller/1.0"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        return response.read().decode("utf-8")


def parse_metrics(payload):
    metrics = {}
    for line in payload.splitlines():
        match = METRIC_RE.match(line.strip())
        if not match:
            continue
        metrics[match.group(1)] = float(match.group(2))
    required = [
        "speedtest_server_id",
        "speedtest_jitter_latency_milliseconds",
        "speedtest_ping_latency_milliseconds",
        "speedtest_download_bits_per_second",
        "speedtest_upload_bits_per_second",
        "speedtest_up",
    ]
    missing = [metric for metric in required if metric not in metrics]
    if missing:
        raise ValueError("Missing upstream metrics: " + ", ".join(missing))
    return metrics


def finish_speedtest(trigger):
    with state_lock:
        if trigger == "manual":
            state["manual_runs_total"] += 1
        elif trigger == "scheduled":
            state["scheduled_runs_total"] += 1
    try:
        payload = fetch_metrics()
        metrics = parse_metrics(payload)
        now = time.time()
        with state_lock:
            state["metrics"] = metrics
            state["last_run_timestamp"] = now
            state["last_run_status"] = 1.0
            state["last_error"] = ""
            state["last_trigger"] = trigger
    except Exception as exc:
        with state_lock:
            state["last_run_timestamp"] = time.time()
            state["last_run_status"] = 0.0
            state["last_error"] = str(exc)
            state["last_trigger"] = trigger
    finally:
        with state_lock:
            state["running"] = False
        run_lock.release()


def start_speedtest(trigger):
    if not run_lock.acquire(blocking=False):
        return False
    with state_lock:
        state["running"] = True
        state["last_trigger"] = trigger
    thread = threading.Thread(target=finish_speedtest, args=(trigger,), daemon=True)
    thread.start()
    return True


def schedule_loop():
    start_speedtest("startup")
    while True:
        time.sleep(SCHEDULE_INTERVAL_SECONDS)
        start_speedtest("scheduled")


def render_metrics():
    with state_lock:
        snapshot = {
            "metrics": dict(state["metrics"]),
            "running": state["running"],
            "last_run_timestamp": state["last_run_timestamp"],
            "last_run_status": state["last_run_status"],
            "manual_runs_total": state["manual_runs_total"],
            "scheduled_runs_total": state["scheduled_runs_total"],
        }

    metrics = dict(snapshot["metrics"])
    metrics["speedtest_last_run_timestamp_seconds"] = snapshot["last_run_timestamp"]
    metrics["speedtest_run_in_progress"] = 1.0 if snapshot["running"] else 0.0
    metrics["speedtest_last_run_status"] = snapshot["last_run_status"]
    metrics["speedtest_manual_runs_total"] = snapshot["manual_runs_total"]
    metrics["speedtest_scheduled_runs_total"] = snapshot["scheduled_runs_total"]

    lines = []
    for name, help_text in HELP_TEXT.items():
        metric_type = "counter" if name.endswith("_total") else "gauge"
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {metric_type}")
        value = metrics.get(name)
        if value is not None:
            lines.append(f"{name} {value}")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, payload, status=HTTPStatus.OK):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, payload, content_type="text/plain; version=0.0.4; charset=utf-8"):
        body = payload.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send_json({"ok": True})
            return
        if self.path == "/metrics":
            self._send_text(render_metrics())
            return
        if self.path == "/status":
            with state_lock:
                payload = {
                    "running": state["running"],
                    "last_run_timestamp": state["last_run_timestamp"],
                    "last_run_status": state["last_run_status"],
                    "last_error": state["last_error"],
                    "last_trigger": state["last_trigger"],
                    "metrics": state["metrics"],
                }
            self._send_json(payload)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if self.path != "/run":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        started = start_speedtest("manual")
        if started:
            self._send_json({"accepted": True, "running": True}, status=HTTPStatus.ACCEPTED)
            return
        self._send_json({"accepted": False, "running": True}, status=HTTPStatus.CONFLICT)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    threading.Thread(target=schedule_loop, daemon=True).start()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()

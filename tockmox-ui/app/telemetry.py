# SPDX-License-Identifier: Apache-2.0
"""What the UI says about its own failures: a log line and a counter for each (TM-1013).

Until 0.8.0-rc1 every caught failure on the sign-in path rendered a friendly page and said
nothing else: on the homelab (2026-10-11) /login answered 503 "The identity provider did not
answer" while the pod log held only the access line, and the cause (the pod's connection to the
issuer refused by NetworkPolicy) took an exec into the pod to find. Now each one is:

  - LOGGED at WARNING on logger "tockmox_ui": the stage, the exception class and its message.
    Exception text from httpx/PyJWT names URLs and reasons, never tokens or secrets; nothing
    else from the request (no codes, no cookies, no claims) is logged.
  - COUNTED in tockmox_ui_oidc_failures_total{stage}, and source failures in
    tockmox_ui_source_failures_total{source}, served in Prometheus text format on a
    SEPARATE port (TOCKMOX_UI_METRICS_PORT; the chart sets 9464). Not on the app port: the
    Ingress routes every path of the app port to the world-facing host, and /metrics there
    would be readable without signing in.

EVERY SERIES EXISTS AT 0 BEFORE ITS FIRST FAILURE. increase() cannot see a counter's first
sample, so a series created BY the first failure reads as 0 and an alert on it misses exactly
that failure (the same reason tockmox_hook.py pre-creates tockmox_gate_served_total). So the
labels are a closed set: the two sign-in stages, declared here, and each source's name,
declared when the source is built. The error class is in the log line, not a label: it is an
open set, and a label nobody could pre-create would bring the blind first failure back.

Stdlib only: the counters are a dict under a lock, the server is http.server in a daemon
thread. No metrics port set means no server (the tests, a laptop run).
"""
from __future__ import annotations

import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("tockmox_ui")

HELP = {
    "tockmox_ui_oidc_failures_total": "Sign-in steps that failed, by stage (discovery, token).",
    "tockmox_ui_source_failures_total": "Status-source reads that failed, by source.",
}
OIDC_STAGES = ("discovery", "token")

_lock = threading.Lock()
_counters: dict[tuple[str, tuple[tuple[str, str], ...]], float] = {}
_server = None


def setup_logging() -> None:
    """Make WARNING from logger tockmox_ui reach stderr under uvicorn, without reconfiguring
    anything a caller already configured."""
    if not log.handlers:
        h = logging.StreamHandler()
        h.setFormatter(logging.Formatter("%(levelname)s:     %(name)s %(message)s"))
        log.addHandler(h)
        log.setLevel(logging.INFO)
        log.propagate = False


def _key(name: str, labels: dict) -> tuple[str, tuple[tuple[str, str], ...]]:
    return (name, tuple(sorted((k, str(v)) for k, v in labels.items())))


def declare(name: str, **labels: str) -> None:
    """Create the series at 0 if it does not exist yet (see the module note)."""
    with _lock:
        _counters.setdefault(_key(name, labels), 0.0)


def inc(name: str, **labels: str) -> None:
    key = _key(name, labels)
    with _lock:
        _counters[key] = _counters.get(key, 0.0) + 1.0


def _declare_stages() -> None:
    for st in OIDC_STAGES:
        declare("tockmox_ui_oidc_failures_total", stage=st)


def oidc_failure(stage: str, e: BaseException) -> None:
    log.warning("sign-in %s failed: %s: %s", stage, type(e).__name__, e)
    inc("tockmox_ui_oidc_failures_total", stage=stage)


def source_failure(source: str, e: BaseException) -> None:
    log.warning("source %s failed: %s: %s", source, type(e).__name__, e)
    inc("tockmox_ui_source_failures_total", source=source)


def _esc(v: str) -> str:
    return v.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render() -> str:
    with _lock:
        items = sorted(_counters.items())
    out = []
    for name in sorted(HELP):
        out.append(f"# HELP {name} {HELP[name]}")
        out.append(f"# TYPE {name} counter")
        for (n, labels), v in items:
            if n != name:
                continue
            lab = ",".join(f'{k}="{_esc(val)}"' for k, val in labels)
            out.append(f"{n}{{{lab}}} {v:g}" if lab else f"{n} {v:g}")
    return "\n".join(out) + "\n"


def reset() -> None:
    """Tests only: back to the state at import (the stages at 0, no sources)."""
    with _lock:
        _counters.clear()
    _declare_stages()


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_error(404)
            return
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # scrapes every 30s would drown the app log
        pass


def serve_from_env() -> None:
    """Start the metrics server once per process when TOCKMOX_UI_METRICS_PORT names a port."""
    global _server
    port = os.environ.get("TOCKMOX_UI_METRICS_PORT", "").strip()
    if not port or _server is not None:
        return
    _server = ThreadingHTTPServer(("0.0.0.0", int(port)), _Handler)
    threading.Thread(target=_server.serve_forever, name="tockmox-ui-metrics", daemon=True).start()
    log.info("metrics on :%s/metrics", port)


_declare_stages()

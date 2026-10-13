# SPDX-License-Identifier: Apache-2.0
"""TM-1013: a failed sign-in step is logged and counted, not only rendered.

Found on the homelab 2026-10-11: /login answered 503 "The identity provider did not answer" with
nothing in the pod log, and the cause (a NetworkPolicy refusing the pod's connection to the issuer)
needed an exec into the pod. Run from tockmox-ui/: python -m pytest tests
"""
import logging
import socket
import sys
import urllib.request
from pathlib import Path

import httpx
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import telemetry  # noqa: E402


def client(tmp_path, oidc_handler):
    from fastapi.testclient import TestClient
    from app import config
    from app.main import Transports, create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["sources"]["timeoutSeconds"] = 1
    s = config.parse(doc)
    app = create_app(s, Transports(oidc=httpx.MockTransport(oidc_handler)), notes_path=str(tmp_path / "none.md"))
    return TestClient(app, follow_redirects=False)


def refused(req):
    raise httpx.ConnectError("[Errno 111] Connection refused", request=req)


def test_refused_issuer_is_logged_and_counted(tmp_path, caplog):
    telemetry.reset()
    c = client(tmp_path, refused)
    with caplog.at_level(logging.WARNING, logger="tockmox_ui"):
        caplog.handler.setLevel(logging.WARNING)
        logging.getLogger("tockmox_ui").addHandler(caplog.handler)
        r = c.get("/login")
    assert r.status_code == 503
    assert "did not answer" in r.text
    lines = [m for m in caplog.messages if "sign-in discovery failed" in m]
    assert lines and "ConnectError" in lines[0] and "Connection refused" in lines[0]
    out = telemetry.render()
    assert 'tockmox_ui_oidc_failures_total{stage="discovery"} 1' in out
    assert 'tockmox_ui_oidc_failures_total{stage="token"} 0' in out


def test_counter_accumulates_and_is_in_exposition_format(tmp_path):
    telemetry.reset()
    c = client(tmp_path, refused)
    c.get("/login")
    c.get("/login")
    out = telemetry.render()
    assert "# TYPE tockmox_ui_oidc_failures_total counter" in out
    assert "# TYPE tockmox_ui_source_failures_total counter" in out
    assert 'tockmox_ui_oidc_failures_total{stage="discovery"} 2' in out


def test_every_series_exists_at_zero_before_its_first_failure(tmp_path):
    # increase() cannot see a counter's first sample: a series born at 1 hides the first failure.
    telemetry.reset()
    client(tmp_path, refused)          # builds the app and its sources; no request made
    out = telemetry.render()
    assert 'tockmox_ui_oidc_failures_total{stage="discovery"} 0' in out
    assert 'tockmox_ui_oidc_failures_total{stage="token"} 0' in out
    assert 'tockmox_ui_source_failures_total{source="Prometheus"} 0' in out


def test_a_failed_source_read_is_counted_under_its_declared_series():
    from app import sources
    telemetry.reset()

    class Broken(sources.Source):
        name = "Broken"

        def fetch(self):
            raise httpx.ConnectError("refused")

    b = Broken()
    assert 'tockmox_ui_source_failures_total{source="Broken"} 0' in telemetry.render()
    b.read()
    assert 'tockmox_ui_source_failures_total{source="Broken"} 1' in telemetry.render()


def test_label_values_are_escaped():
    telemetry.reset()
    telemetry.inc("tockmox_ui_source_failures_total", source='a"b\\c\nd')
    assert 'source="a\\"b\\\\c\\nd"' in telemetry.render()


def test_no_metrics_port_means_no_server(monkeypatch):
    monkeypatch.delenv("TOCKMOX_UI_METRICS_PORT", raising=False)
    monkeypatch.setattr(telemetry, "_server", None)
    telemetry.serve_from_env()
    assert telemetry._server is None


def test_metrics_server_serves_metrics_only(monkeypatch):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    monkeypatch.setenv("TOCKMOX_UI_METRICS_PORT", str(port))
    monkeypatch.setattr(telemetry, "_server", None)
    telemetry.reset()
    telemetry.inc("tockmox_ui_oidc_failures_total", stage="token")
    telemetry.serve_from_env()
    try:
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read().decode()
        assert 'stage="token"' in body
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5)
            raise AssertionError("/ must be 404")
        except urllib.error.HTTPError as e:
            assert e.code == 404
    finally:
        telemetry._server.shutdown()
        monkeypatch.setattr(telemetry, "_server", None)

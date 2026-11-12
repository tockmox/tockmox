# SPDX-License-Identifier: Apache-2.0
"""Run the identity layer's open-applications script (charts/tockmox-identity/files/open-applications.py) on
stand-ins: Authentik's two models as in-memory rows, and the Kubernetes API as a loopback HTTP server that keeps one
ConfigMap and applies the script's merge PATCH to it, the way the API server does.

    python3 tests/identity-open-applications/standin.py --write   regenerate the console's fixtures from the script
    python3 tests/identity-open-applications/standin.py --check   exit 1 when a committed fixture is not what it writes

The console's tests (tockmox-ui/tests/test_open_applications.py) read those fixtures, so what the Status page is
tested against is what the job writes, not a shape written by hand.
"""
from __future__ import annotations

import copy
import datetime
import importlib.util
import json
import os
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(ROOT, "charts", "tockmox-identity", "files", "open-applications.py")
FIXTURES = os.path.join(ROOT, "tockmox-ui", "tests", "fixtures", "open_applications")
NS, CM = "tockmox-authentik", "tockmox-identity-open-applications"
NOW = datetime.datetime(2026, 11, 12, 9, 30, 0, tzinfo=datetime.timezone.utc)


def load():
    spec = importlib.util.spec_from_file_location("tockmox_open_applications", SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def values(self, *fields):
        return [{f: r.get(f) for f in fields} for r in self.rows]


def install_models(apps, bindings):
    """authentik.core.models.Application and authentik.policies.models.PolicyBinding, as the script calls them."""
    pkg = types.ModuleType("authentik")
    core, pol = types.ModuleType("authentik.core"), types.ModuleType("authentik.policies")
    core_m, pol_m = types.ModuleType("authentik.core.models"), types.ModuleType("authentik.policies.models")
    core_m.Application = type("Application", (), {"objects": _Rows(apps)})
    pol_m.PolicyBinding = type("PolicyBinding", (), {"objects": _Rows(bindings)})
    sys.modules.update({"authentik": pkg, "authentik.core": core, "authentik.policies": pol,
                        "authentik.core.models": core_m, "authentik.policies.models": pol_m})


class FakeApi:
    """One ConfigMap, as the chart renders it (no data), behind GET and merge PATCH. Records every request."""

    def __init__(self, status=200, exists=True):
        self.requests, self.status = [], status
        self.cm = {"apiVersion": "v1", "kind": "ConfigMap",
                   "metadata": {"name": CM, "namespace": NS,
                                "labels": {"tockmox.com/managed-by": "tockmox"}}} if exists else None
        api = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, doc):
                b = json.dumps(doc).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_PATCH(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                api.requests.append({"method": "PATCH", "path": self.path, "headers": dict(self.headers),
                                     "body": json.loads(body)})
                if self.path != f"/api/v1/namespaces/{NS}/configmaps/{CM}" or api.cm is None:
                    return self._send(404, {"kind": "Status", "code": 404})
                if api.status != 200:
                    return self._send(api.status, {"kind": "Status", "code": api.status})
                patch = json.loads(body)
                for k, v in patch.items():           # RFC 7386, two levels deep is all a ConfigMap patch needs
                    if isinstance(v, dict):
                        api.cm.setdefault(k, {}).update(v)
                    else:
                        api.cm[k] = v
                return self._send(200, api.cm)

        self.server = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class _FixedClock(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW if tz else NOW.replace(tzinfo=None)


def run(apps, bindings, everyone=(), api: FakeApi | None = None):
    """Run the script's main() as the CronJob does. Returns (api, module); the caller closes the api."""
    m = load()
    install_models(apps, bindings)
    api = api or FakeApi()
    with tempfile.TemporaryDirectory() as sa:
        with open(os.path.join(sa, "token"), "w") as fh:
            fh.write("stand-in-token\n")
        env = {"TOCKMOX_KUBE_URL": api.url, "TOCKMOX_SA_DIR": sa, "TOCKMOX_REPORT_NAMESPACE": NS,
               "TOCKMOX_REPORT_CONFIGMAP": CM, "TOCKMOX_OPEN_TO_EVERYONE": json.dumps(list(everyone))}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        m.datetime = types.SimpleNamespace(datetime=_FixedClock, timezone=datetime.timezone)
        try:
            m.main()
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
    return api, m


# ------------------------------------------------------------------------------------------- the scenarios
# pk values are UUID strings, as Django gives them for PolicyBindingModel.pbm_uuid.
GRAFANA = {"pk": "8f0c1d2e-0000-4000-8000-000000000001", "slug": "tockmox-grafana", "name": "Grafana", "group": "Observability"}
ARGOCD = {"pk": "8f0c1d2e-0000-4000-8000-000000000002", "slug": "argocd", "name": "Argo CD", "group": "Infrastructure"}
HANDBOOK = {"pk": "8f0c1d2e-0000-4000-8000-000000000003", "slug": "handbook", "name": "Staff handbook", "group": ""}
ADMIN_GROUP, USER_GROUP = "5a5a0000-0000-4000-8000-0000000000a1", "5a5a0000-0000-4000-8000-0000000000a2"


def bind(app, group=None, user=None, enabled=True, negate=False):
    return {"target_id": app["pk"], "group_id": group, "user_id": user, "enabled": enabled, "negate": negate}


SHIPPED = [bind(GRAFANA, ADMIN_GROUP), bind(GRAFANA, USER_GROUP)]
SCENARIOS = {
    # Argo CD made by hand from the docs' prose, with no binding; a handbook the site declared open.
    "unbound": ([GRAFANA, ARGOCD, HANDBOOK], SHIPPED, ["handbook"]),
    # The same, after Argo CD is bound to the admin group.
    "bound": ([GRAFANA, ARGOCD, HANDBOOK], SHIPPED + [bind(ARGOCD, ADMIN_GROUP)], ["handbook"]),
    # Every application bound, nothing declared.
    "all-bound": ([GRAFANA, ARGOCD], SHIPPED + [bind(ARGOCD, ADMIN_GROUP)], []),
}


def fixture(name):
    apps, bindings, everyone = SCENARIOS[name]
    api, _ = run(apps, bindings, everyone)
    try:
        return copy.deepcopy(api.cm)
    finally:
        api.close()


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--check"
    bad = 0
    for name in SCENARIOS:
        path = os.path.join(FIXTURES, f"{name}.json")
        text = json.dumps(fixture(name), indent=2, sort_keys=True) + "\n"
        if mode == "--write":
            os.makedirs(FIXTURES, exist_ok=True)
            with open(path, "w") as fh:
                fh.write(text)
            print(f"wrote {os.path.relpath(path, ROOT)}")
        else:
            cur = open(path).read() if os.path.exists(path) else ""
            if cur != text:
                print(f"STALE: {os.path.relpath(path, ROOT)} is not what the job writes; run {argv[0]} --write")
                bad = 1
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv))

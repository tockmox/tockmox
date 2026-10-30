# SPDX-License-Identifier: Apache-2.0
"""Shared fixtures for the model-lifecycle tests: a two-node inventory, a catalog, verdict records and a
logged-in client through the real app. Generic names and documentation addresses only (the site-specifics
gate scans tests/ too).

Not a test module: pytest does not collect it. Import it as `from tests.models_support import ...`.
"""
import hashlib
import json
import sys
from pathlib import Path

import httpx
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import models as ml  # noqa: E402
from app import nodes as nm  # noqa: E402

SHA_A = "1" * 40
SHA_B = "2" * 40
SHA_C = "3" * 40
OLLAMA_DIGEST = "sha256:" + "a" * 64

ALPHA, BETA = "192.0.2.10", "192.0.2.11"


def inventory_doc(probe=False):
    """alpha: the new node (M5 Ultra preset, 256 GiB). beta: the node today's aliases live on (64 GiB)."""
    def eps(host):
        return [{"id": "mlx-lm-8080", "engine": "mlx-lm", "url": f"http://{host}:8080"},
                {"id": "mlx-lm-8082", "engine": "mlx-lm", "url": f"http://{host}:8082"},
                {"id": "llama-8081", "engine": "llama-server", "url": f"http://{host}:8081"},
                {"id": "ollama-11434", "engine": "ollama", "url": f"http://{host}:11434"}]
    hw = lambda chip, mem: {"chip": {"value": chip, "source": "preset"}, "memory_gib": {"value": mem, "source": "preset"}}  # noqa: E731
    d = {"nodes": [
        {"id": "alpha", "name": "Alpha", "type": "apple-silicon-mac", "address": ALPHA, "endpoints": eps(ALPHA),
         "hardware": hw("Apple M5 Ultra", 256)},
        {"id": "beta", "name": "Beta", "type": "apple-silicon-mac", "address": BETA, "endpoints": eps(BETA),
         "hardware": hw("Apple M4 Max", 64)}],
        "routes": [
            {"alias": "local-medium", "model": "example-org/Example-27B-4bit", "node": "beta", "endpoint": "mlx-lm-8080",
             "sizeGiB": 15.0, "modelInfo": {"max_input_tokens": 32768}},
            {"alias": "local-embed", "model": "example-embed-4b-q8", "node": "beta", "endpoint": "llama-8081", "kind": "embedding",
             "sizeGiB": 4.0},
        ]}
    if probe:
        d["probe"] = {"allowedCidrs": ["192.0.2.0/24"], "timeoutSeconds": 1}
    return d


def lifecycle_doc(**extra):
    d = {"catalog": [
        {"id": "example-27b-4bit", "model": "example-org/Example-27B-4bit", "family": "example", "baseModel": "example-org/Example-27B",
         "quant": "4bit", "sizeGiB": 15.0, "adopted": "2026-10-07",
         "source": {"kind": "huggingface", "ref": "example-org/Example-27B-4bit", "revision": SHA_A},
         "track": ["revision", "quants"]},
        {"id": "example-embed", "model": "example-embed-4b-q8", "sizeGiB": 4.0, "adopted": "2026-10-07",
         "source": {"kind": "huggingface", "ref": "example-org/Example-Embedding-4B-GGUF", "revision": SHA_B}},
    ], "promotion": {"requiredPasses": 3}}
    d.update(extra)
    return d


def verdict_record(model, alias, verdict="pass", run="r1", date="2026-10-07", klass="chat", incumbent="", revision="",
                   eval_version="v1", grader="rule", results=None, criterion=None, placement=None, sampling=None,
                   extras=None):
    """A REQ-0045 comparative verdict record (AC-45.9) as the eval runner writes it. Each run gets its own sampling
    seed unless `sampling` is given, so separate runs are separate evidence (TM-1248); pass the same `sampling` to
    two runs to model a rerun of the same thing."""
    d = {"schema": "comparative-verdict/1", "run_id": run, "date": date, "class": klass, "alias": alias,
         "candidate": {"model": model, **({"revision": revision} if revision else {})},
         "eval_set": {"id": f"{klass}-set", "version": eval_version}, "grader": grader,
         "criterion": criterion or ("absolute-bars/" + klass if not incumbent else "design-6/" + klass), "verdict": verdict,
         "results": [] if results is None else results, "methodology": "evals/results/m.md"}
    if incumbent:
        d["incumbent"] = {"model": incumbent}
    if placement:
        d["placement"] = placement
    d["sampling"] = sampling if sampling is not None else {"seed": run}
    d.update(extras or {})
    return json.dumps(d)


def verdicts(*records):
    return [ml.parse_verdict(t, f"evals/verdicts/{i}.json") for i, t in enumerate(records)]


def sha(b):
    return hashlib.sha256(b if isinstance(b, bytes) else b.encode("utf-8")).hexdigest()


def world():
    lc = ml.parse(lifecycle_doc())
    inv = nm.parse_inventory(inventory_doc())
    return lc, inv


def apply_change(lc, inv, add_lc, add_inv):
    """What committing a propose-style change does to the values."""
    new_lc = ml.merge(lc, add_lc)
    new_inv = nm.merge(inv, add_inv) if add_inv.routes else inv
    return new_lc, new_inv


def models_client(tmp_path, lifecycle=None, inventory=None, groups=None, extra=None, probe_transport=None, prometheus=None):
    """A logged-in admin client through the real app. Returns (client, user). `prometheus` is a handler(request) -> Response for
    the Prometheus the app reads (demand, spend); without it the app would try the real network and read Unknown."""
    from fastapi.testclient import TestClient

    from app import config
    from app.auth import Sessions
    from app.main import Transports, create_app
    doc = yaml.safe_load((Path(__file__).resolve().parent.parent / "config.example.yaml").read_text())
    (tmp_path / "cs").write_text("x")
    (tmp_path / "ss").write_text("s" * 40)
    doc["oidc"]["clientSecretFile"] = str(tmp_path / "cs")
    doc["session"]["secretFile"] = str(tmp_path / "ss")
    doc["session"]["secureCookies"] = False
    doc["inferenceNodes"] = inventory or inventory_doc()
    doc["modelLifecycle"] = lifecycle or lifecycle_doc()
    if extra:
        extra(doc)
    s = config.parse(doc)
    tp = Transports(probe=httpx.MockTransport(probe_transport) if probe_transport else None,
                    prometheus=httpx.MockTransport(prometheus) if prometheus else None)
    app = create_app(s, tp, notes_path=str(tmp_path / "none.md"))
    c = TestClient(app, follow_redirects=False)
    sess = Sessions(s.session_secret, 3600, s.admin_group, False)
    c.cookies.set(sess.session_cookie, sess.issue("a", "Admin", groups if groups is not None else [s.admin_group]))
    return c, sess.read(c.cookies.get(sess.session_cookie))


def result_doc(**over):
    """A valid capability-result/1 as a dict (a perf leg for the catalog's 27B model on beta)."""
    d = {"schema": "capability-result/1", "kind": "perf", "date": "2026-10-20", "node": "beta", "model": "example-org/Example-27B-4bit",
         "revision": SHA_A, "quant": "4bit", "engine": {"id": "mlx-lm", "version": "0.32.2"}, "plane": "engine",
         "class": "chat",
         "metrics": [{"name": "decode_tps_stream_p50", "value": 31.2, "unit": "tok/s", "n": 120, "concurrency": 1},
                     {"name": "ttft_p95", "value": 1.8, "unit": "s", "n": 120, "concurrency": 4}],
         "memory": {"peak_resident_gib": 21.4, "predicted_gib": 20.1, "context_tokens": 32768, "parallel_slots": 3},
         "power": {"tokens_per_joule": 0.42, "watts_mean": 71.0},
         "environment": {"macos": "26.2", "chip": "Apple M4 Max", "memory_gib": 64, "wired_limit_mb": 49152},
         "methodology": "evals/results/beta/method.md"}
    d.update(over)
    return d


def result_text(**over):
    return json.dumps(result_doc(**over), indent=2) + "\n"

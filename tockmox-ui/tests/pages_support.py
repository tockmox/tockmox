# SPDX-License-Identifier: Apache-2.0
"""Fixtures for the Models inbox, candidate and budget pages: a watcher report, run-status/1 files, a prometheus that answers
the demand and spend queries, and a logged-in admin client. Documentation names and addresses only. Not a test module."""
import datetime
import json

import httpx

from app import fit as fx
from tests.models_support import SHA_A, SHA_B, SHA_C, inventory_doc, lifecycle_doc, models_client

REPO = "example-org/Example-27B-4bit"
NEW_Q = "example-org/Example-27B-8bit"
SUCC = "example-org/Example-30B-4bit"
HOSTED_NEW = "anthropic/example-model-9"
HOSTED_OLD = "anthropic/example-old-3"
REV = "4" * 40
GIB = 1 << 30


def iso(delta_days=0, delta_s=0):
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=delta_days, seconds=delta_s)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def day(delta_days):
    return (datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=delta_days)).isoformat()


def cand(kind, model, subject="example-27b-4bit", ref=None, revision="", detail="", when="", **extra):
    src_kind = "hosted" if kind in ("frontier", "deprecation") else "huggingface"
    c = {"id": f"{kind}:{model}" + (f"@{revision[:12]}" if revision else ""), "kind": kind, "subject": subject, "model": model,
         "source": {"kind": src_kind, "ref": ref or model, **({"revision": revision} if revision else {})},
         "detail": detail or f"{kind} {model}", "when": when}
    c.update(extra)
    return c


CANDIDATES = {
    "revision": cand("revision", REPO, revision=SHA_C, detail="the repo has a new commit"),
    "quant": cand("quant", NEW_Q, detail="another quantisation of example-org/Example-27B"),
    "successor": cand("successor", SUCC, detail="a newer example family"),
    "frontier": cand("frontier", HOSTED_NEW, subject="anthropic", detail="anthropic lists example-model-9, which the gateway does not route"),
    "deprecation": cand("deprecation", HOSTED_OLD, subject="anthropic", detail="anthropic retires example-old-3", when=day(12),
                        replacement=HOSTED_NEW),
}


def size_rec(ref, gib=17.0, lic="apache-2.0", fmt="mlx", evals=(), revision=REV):
    return fx.SizeRecord(ref, revision, int(gib * GIB), 3, 64 * 1024, 12, 48, None, None, None, 27.0, None, False, lic, "text-generation",
                         fmt, False, tuple(evals), (), "2026-10-29T00:00:00Z").as_dict()


def write_report(tmp_path, candidates, *, generated=None, sources=None, sizes=None, gaps=()):
    p = tmp_path / "report.json"
    p.write_text(json.dumps({"schema": 1, "generatedAt": generated or iso(),
                             "sources": sources if sources is not None else {"huggingface": {"ok": True}, "anthropic": {"ok": True}},
                             "candidates": list(candidates), "gaps": list(gaps), "sizes": sizes or {}}))
    return str(p)


def status(run_id="local-medium-chat-1", alias="local-medium", state="running", legs=None, **over):
    names = ["control", "smoke", "perf", "quality"]
    legs = legs if legs is not None else [{"name": n, "state": "queued", "started": None, "finished": None, "summary": ""} for n in names]
    d = {"schema": "run-status/1", "run_id": run_id, "alias": alias, "class": "chat",
         "candidate": {"model": SUCC, "revision": REV}, "incumbent": {"model": REPO, "revision": SHA_A},
         "node": "alpha", "engine": {"id": "mlx-lm", "version": "0.32.2"}, "set": {"id": "chat", "version": "v1", "sha256": "e" * 64},
         "trigger": "admitted", "state": state, "reason": "",
         "plan": {"legs": names, "estimated_seconds": 7800, "disk_gib": None, "window": "next quiet window"},
         "legs": legs, "created": iso(delta_s=-600), "updated": iso(delta_s=-30), "verdict_path": None, "label": None, "evidence_pr": None}
    d.update(over)
    return d


def write_status(directory, doc):
    runs = directory / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    (runs / f"{doc['run_id']}.json").write_text(json.dumps(doc))
    return str(directory)


def prom(demand=None, spend=None, fail=False):
    """A prometheus handler. demand / spend: {label value: number}, answered for the demand query (model_group) and the
    spend query. fail=True answers 500 to everything."""
    def h(req: httpx.Request):
        if fail:
            return httpx.Response(500)
        q = req.url.params.get("query", "")
        src = spend if "spend" in q else demand
        res = [{"metric": {"model_group": k}, "value": [0, str(v)]} for k, v in (src or {}).items()]
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": res}})
    return h


def page_client(tmp_path, *, candidates=None, report=None, lifecycle=None, inventory=None, gateway=None, status_dir=None,
                prometheus=None, groups=None, sizes=None, generated=None, sources=None, **lc_extra):
    """An admin client with a watcher report (when `candidates` is given), run statuses and a Prometheus. Returns (client, user)."""
    inv = inventory or inventory_doc()
    if gateway:
        inv = {**inv, "gateway": {"modelList": gateway}}
    lcd = dict(lifecycle or lifecycle_doc())
    if candidates is not None:
        lcd["reportFile"] = report or write_report(tmp_path, candidates, sizes=sizes, generated=generated, sources=sources)
    if status_dir:
        lcd["statusDir"] = str(status_dir)
    lcd.update(lc_extra)
    return models_client(tmp_path, lifecycle=lcd, inventory=inv, groups=groups, prometheus=prometheus)


HOSTED_GATEWAY = [{"model_name": "big-hosted-chat", "litellm_params": {"model": "anthropic/example-old-3", "api_key": "os.environ/K"},
                   "model_info": {"endpoint_tier": "external"}}]


def with_next(inv=None, model=SUCC, node="alpha", endpoint="mlx-lm-8080", alias="local-medium-next"):
    """The inventory with a `-next` route on the eval gateway (a candidate under evaluation)."""
    inv = dict(inv or inventory_doc())
    inv["routes"] = list(inv["routes"]) + [{"alias": alias, "model": model, "node": node, "endpoint": endpoint, "sizeGiB": 17.0}]
    return inv


def leg(name, state, summary="", metrics=None):
    return {"name": name, "state": state, "started": iso(delta_s=-300) if state != "queued" else None,
            "finished": iso(delta_s=-60) if state in ("done", "failed") else None, "summary": summary, **({"metrics": metrics} if metrics else {})}

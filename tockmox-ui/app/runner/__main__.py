# SPDX-License-Identifier: Apache-2.0
"""python -m app.runner run REQUEST.yaml --set DIR --gateway URL --key-env VAR --node ID --engine ID
--engine-version V --out SITE_ROOT [--steps 1,2] [--perf-requests 20] [--workers 2] [--seed 1] [--health-url URL]"""
from __future__ import annotations

import argparse
import json
import os
import sys

import httpx

from . import evalset
from . import legs
from .run import RunError, load_request, run


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.runner")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run one evaluation request")
    r.add_argument("request")
    r.add_argument("--set", required=True, help="the eval-set/1 directory")
    r.add_argument("--gateway", required=True, help="the eval gateway base URL")
    r.add_argument("--key-env", default="EVAL_GATEWAY_KEY", help="environment variable holding the eval gateway key")
    r.add_argument("--node", required=True)
    r.add_argument("--engine", required=True)
    r.add_argument("--engine-version", required=True)
    r.add_argument("--quant", default="")
    r.add_argument("--out", required=True, help="the site repository root the evidence is written under")
    r.add_argument("--steps", default="1,2")
    r.add_argument("--perf-requests", type=int, default=20)
    r.add_argument("--workers", type=int, default=2)
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--health-url", action="append", default=[], help="GET that must answer 2xx before each leg")
    a = p.parse_args(argv)
    key = os.environ.get(a.key_env, "")
    if not key:
        print(f"runner: {a.key_env} is empty", file=sys.stderr)
        return 2

    def health():
        for u in a.health_url:
            try:
                ok = httpx.get(u, timeout=10, follow_redirects=False).status_code < 300
            except httpx.HTTPError:
                ok = False
            if not ok:
                raise legs.Aborted(f"{u} is not healthy: the node is not fit to measure, so the run stops")
    try:
        req = load_request(a.request)
        es = evalset.load(a.set)
        res = run(req, es, gateway=a.gateway, key=key, node=a.node, engine=a.engine, engine_version=a.engine_version,
                  out=a.out, steps=tuple(int(x) for x in a.steps.split(",")), perf_requests=a.perf_requests,
                  workers=a.workers, seed=a.seed, health=health if a.health_url else None, quant=a.quant)
    except (RunError, evalset.SetError, legs.Aborted) as e:
        print(f"runner: {e}", file=sys.stderr)
        return 1
    d = res["decision"]
    print(json.dumps({"verdict": res["verdict"], "label": res["label"], "n": d["n"], "wins": d.get("wins"),
                      "losses": d.get("losses"), "ties": d.get("ties"), "interval": d["interval"],
                      "screening": d["screening"], "control": res["control"], "verdict_path": res["verdict_path"],
                      "twins": [p for p, _ in res["twins"]]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

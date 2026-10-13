# SPDX-License-Identifier: Apache-2.0
"""Tockmox policy gate for the model gateway (TM-0383; REQ-0002, REQ-0003).

Ported from the reference site's hook, which has run since 2026-06-05, and
shipped here in ENFORCE mode. Rendered into the `tockmox-litellm-hooks`
ConfigMap by charts/tockmox-ai when modelGateway.policyGate.enabled is true,
and registered as `hooks.tockmox_gate.tockmox_gate`.

A generic engine: ALL policy data lives in tockmox_policy.yaml (rendered from
modelGateway.policyGate) and in each model_list entry's tags and
model_info.endpoint_tier. Adding a class or changing a tier must never need an
edit here.

Fail-closed throughout:
  - an unknown or missing endpoint_tier is treated as external
  - an alias with no route posture gets default_class (restricted)
  - an unreadable policy file is a controlled 500 in both modes, because the
    enforcement mode itself lives in the file that could not be read
  - an audit line that cannot be written never fails the request, and counts
    tockmox_audit_emit_failures_total instead

What it does NOT enforce, stated so nobody infers it: traffic that does not
pass through the gateway (a client calling a model host directly, a tool or
web search an application makes on its own), and anything a model does with
an answer after the gateway returns it. docs/usage/ai-plane.md says the same.
"""

import json
import os
import time
from datetime import datetime, timezone

import yaml
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

try:  # the proxy image ships prometheus_client; a bare test harness may not
    from prometheus_client import Counter, Histogram
except Exception:  # pragma: no cover
    Counter = Histogram = None

POLICY_PATH = os.environ.get(
    "TOCKMOX_POLICY_PATH", "/etc/litellm/hooks/tockmox_policy.yaml")

# restricted > internal > open (tighten-only ordering)
CLASS_RANK = {"open": 0, "internal": 1, "restricted": 2}


def _metric(kind, *args, **kw):
    if kind is None:
        return None
    try:
        return kind(*args, **kw)
    except Exception:  # already registered on a module reload
        return None


ROUTING_OVERHEAD = _metric(
    Histogram, "tockmox_routing_overhead_seconds",
    "Tockmox policy-gate pre-call overhead per request (AC-3.3)",
    buckets=(0.001, 0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0))
GATE_DECISIONS = _metric(
    Counter, "tockmox_gate_decisions_total", "Tockmox policy-gate decisions",
    ["decision", "request_class", "enforcement"])
AUDIT_EMIT_FAILURES = _metric(
    Counter, "tockmox_audit_emit_failures_total",
    "Audit lines that failed to emit (silent audit loss indicator)")

_policy_cache = {"mtime": None, "policy": None}


def _load_policy():
    """Load the policy, cached on mtime. Raises on unreadable or invalid."""
    mtime = os.path.getmtime(POLICY_PATH)
    if _policy_cache["mtime"] != mtime:
        with open(POLICY_PATH) as f:
            pol = yaml.safe_load(f)
        assert pol["default_class"] in CLASS_RANK
        assert pol["enforcement"] in ("shadow", "enforce")
        for cls, spec in pol["classes"].items():
            assert cls in CLASS_RANK
            assert set(spec["allowed_tiers"]) <= {"local", "external"}
        _policy_cache["mtime"] = mtime
        _policy_cache["policy"] = pol
    return _policy_cache["policy"]


def _metadata_key(data):
    return "litellm_metadata" if "litellm_metadata" in data else "metadata"


def _router_models(**kw):
    try:
        from litellm.proxy.proxy_server import llm_router
        return llm_router.get_model_list(**kw) or []
    except Exception:
        return []


def _alias_tiers(alias):
    """Endpoint tiers reachable through this alias, from the live router.
    A missing tier reads as 'external' (fail closed). An unknown alias gives
    an empty set: the router answers 404, and restricted/internal refuse
    first."""
    return {((d.get("model_info") or {}).get("endpoint_tier") or "external")
            for d in _router_models(model_name=alias)}


def _norm(url):
    return (url or "").rstrip("/")


def _tier_for_served(kwargs):
    """The tier of the deployment that actually served, for the audit line.
    Unknown reads as 'external', so a resolution bug is visible rather than
    masking a violation.

    The deployment's own model_info is read first when LiteLLM passes it.
    Matching on api_base is the fallback, and it compares with any trailing
    slash removed: LiteLLM 1.100.1 hands the hook `.../v1/` for a deployment
    configured as `.../v1`, so an exact comparison never matched and every
    LOCAL request was audited as endpoint_tier=external, routing_decision=
    escalate (found by the CI test, 2026-10-06)."""
    lp = kwargs.get("litellm_params") or {}
    api_base = lp.get("api_base")
    info = lp.get("model_info") or kwargs.get("model_info") or {}
    if info.get("endpoint_tier") in ("local", "external"):
        return info["endpoint_tier"], (api_base or info.get("id"))
    for dep in _router_models():
        dlp = dep.get("litellm_params") or {}
        if api_base and _norm(dlp.get("api_base")) == _norm(api_base):
            return ((dep.get("model_info") or {}).get("endpoint_tier")
                    or "external"), api_base
    model = lp.get("model") or kwargs.get("model") or ""
    provider = model.split("/")[0] if "/" in model else "unknown"
    return "external", (api_base or provider)


def _inc(metric, *labels):
    try:
        if metric is not None:
            (metric.labels(*labels) if labels else metric).inc()
    except Exception:
        pass


def _emit(line):
    """One audit line to stdout, where the cluster's log pipeline collects it.
    Never raises."""
    try:
        base = {"tockmox_audit": 1, "audit_schema": "v0",
                "ts": datetime.now(timezone.utc).isoformat()}
        base.update(line)
        print(json.dumps(base, default=str), flush=True)
    except Exception:
        _inc(AUDIT_EMIT_FAILURES)


class TockmoxPolicyGate(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data,
                                  call_type):
        t0 = time.perf_counter()
        mkey = _metadata_key(data)
        try:
            try:
                pol = _load_policy()
            except Exception as exc:
                _emit({"event": "request", "status": "error",
                       "refusal_reason": "policy_load_failure",
                       "detail": str(exc)})
                raise HTTPException(status_code=500, detail={
                    "error": "tockmox: policy unavailable, failing closed"})

            md = data.get(mkey)
            if not isinstance(md, dict):
                md = {}
            data[mkey] = md
            enforce = pol["enforcement"] == "enforce"

            # 1. Strip client routing overrides (REQ-0002 AC-2.3), in both
            #    modes: LiteLLM honours body fallbacks and lifts client tags
            #    into metadata with no opt-in.
            stripped = [k for k in ("fallbacks", "context_window_fallbacks")
                        if data.pop(k, None) is not None]
            if md.pop("tags", None):
                stripped.append("metadata.tags")
            if data.pop("tags", None) is not None:
                stripped.append("tags")

            # 2. Resolve the class, server side. The route posture of the
            #    alias is the deterministic escalation grant (config, never a
            #    model); an unlisted alias gets default_class.
            alias = data.get("model")
            posture = pol.get("route_posture") or {}
            if posture.get(alias) in CLASS_RANK:
                resolved, class_source = posture[alias], "route_posture"
            else:
                resolved, class_source = pol["default_class"], "default"
            if pol.get("platform_mode") == "dark_site":
                resolved, class_source = "restricted", "dark_site"

            # 2b. A client may tighten its class, never loosen it.
            client_class = md.get("tockmox_class")
            client_class_rejected = None
            if client_class in CLASS_RANK:
                if CLASS_RANK[client_class] > CLASS_RANK[resolved]:
                    resolved, class_source = client_class, "client_tightened"
                elif CLASS_RANK[client_class] < CLASS_RANK[resolved]:
                    client_class_rejected = client_class

            # 3. Gate: the alias's tiers against the class's allowed tiers.
            allowed = set(pol["classes"][resolved]["allowed_tiers"])
            tiers = _alias_tiers(alias)
            would_refuse = bool(tiers) and not (tiers & allowed)

            tock = {"class": resolved, "class_source": class_source,
                    "policy": pol["policy_id"],
                    "mode": pol.get("platform_mode", "normal"),
                    "enforcement": pol["enforcement"],
                    "requested_model": alias, "stripped": stripped}
            if client_class_rejected:
                tock["client_class_rejected"] = client_class_rejected
            if would_refuse and not enforce:
                tock["shadow_would_refuse"] = True
            md["tockmox"] = tock

            if would_refuse and enforce:
                # Marked so the failure logger below does not write a SECOND
                # line for this request. LiteLLM 1.100.1 does call
                # async_log_failure_event for a request this hook refused, and
                # that line resolved no endpoint, so it read `endpoint_tier:
                # external`, `routing_decision: escalate` for a request that
                # never left the gateway (found by the CI test, 2026-10-06).
                tock["refused"] = True
                _inc(GATE_DECISIONS, "refuse", resolved, pol["enforcement"])
                ms = round((time.perf_counter() - t0) * 1000, 2)
                line = {"event": "request", "class": resolved,
                        "class_source": class_source,
                        "requested_model": alias, "routing_decision": "refuse",
                        "policy": pol["policy_id"],
                        "mode": pol.get("platform_mode", "normal"),
                        "status": "refused",
                        "refusal_reason": "class_forbids_endpoint_tier",
                        "latency_ms": ms, "routing_overhead_ms": ms}
                if client_class_rejected:
                    line["client_class_rejected"] = client_class_rejected
                _emit(line)
                raise HTTPException(status_code=403, detail={
                    "error": (f"tockmox policy gate: class '{resolved}' may "
                              f"not use '{alias}' (allowed tiers: "
                              f"{sorted(allowed)})"),
                    "refusal_reason": "class_forbids_endpoint_tier"})

            # 4. Authoritative tags, enforce only. Shadow leaves the request
            #    untagged, which is the router's ordinary behaviour.
            if enforce:
                md["tags"] = [resolved]
            _inc(GATE_DECISIONS, "allow", resolved, pol["enforcement"])
            return data
        finally:
            dt = time.perf_counter() - t0
            try:
                if ROUTING_OVERHEAD is not None:
                    ROUTING_OVERHEAD.observe(dt)
                data[mkey]["tockmox"]["overhead_ms"] = round(dt * 1000, 2)
            except Exception:
                pass

    def _request_line(self, kwargs, status, start_time, end_time):
        lp = kwargs.get("litellm_params") or {}
        md = lp.get("metadata") or {}
        tock = md.get("tockmox") or {}
        if tock.get("refused") or not tock:
            # Refused by the gate, or failed before the gate decided anything
            # (an unreadable policy): the pre-call hook already wrote this
            # request's line, and a second one here could only guess at an
            # endpoint, which it reported as external.
            return
        tier, endpoint = _tier_for_served(kwargs)
        try:
            latency_ms = round(
                (end_time - start_time).total_seconds() * 1000, 2)
        except Exception:
            latency_ms = None
        line = {"event": "request",
                "request_id": kwargs.get("litellm_call_id"),
                "class": tock.get("class"),
                "class_source": tock.get("class_source"),
                "requested_model": tock.get("requested_model")
                or kwargs.get("model"),
                "serving_model": lp.get("model") or kwargs.get("model"),
                "endpoint": endpoint, "endpoint_tier": tier,
                "routing_decision": "local" if tier == "local" else "escalate",
                "policy": tock.get("policy"), "mode": tock.get("mode"),
                "status": status, "latency_ms": latency_ms,
                "routing_overhead_ms": tock.get("overhead_ms")}
        for extra in ("client_class_rejected", "shadow_would_refuse",
                      "enforcement"):
            if tock.get(extra) is not None:
                line[extra] = tock[extra]
        _emit(line)

    async def async_log_success_event(self, kwargs, response_obj, start_time,
                                      end_time):
        self._request_line(kwargs, "ok", start_time, end_time)

    async def async_log_failure_event(self, kwargs, response_obj, start_time,
                                      end_time):
        self._request_line(kwargs, "error", start_time, end_time)


tockmox_gate = TockmoxPolicyGate()

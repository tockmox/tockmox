# SPDX-License-Identifier: Apache-2.0
"""The /models area (REQ-0048, as revised 2026-10-07). Admin only. Writes nothing: every action ends in a
change to commit, and the two that matter are the two approvals Jeff ruled on: admitting a candidate to the
eval gateway, and promoting it to the production gateway after enough passing comparisons.

  GET  /models                      the catalog, the watcher's candidates, comparisons in progress, the gate
  POST /models/propose              admit a candidate: catalog entry at stage candidate + <alias>-next (eval gateway)
  GET  /models/evaluate             start an evaluation: the request the REQ-0045 runner picks up
  POST /models/evaluate
  GET  /models/promote?alias=       what the verdicts say for a -next route, and the promotion when there are enough
  POST /models/promote
  GET  /models/promote-hosted?entry=  the same for a hosted candidate, choosing its alias and data-class tags
  POST /models/promote-hosted
  GET  /models/profiles             workload profiles -> a residency plan per node, and the engine configs
  POST /models/builds               read which build each node holds for the pinned models it serves (TM-0934),
                                    through the probe's fences; the result lives in memory and goes stale
"""
from __future__ import annotations

import datetime

import yaml
from fastapi import Form, Request
from fastapi.responses import PlainTextResponse, RedirectResponse, Response

from . import models as ml
from . import nodes as nm
from .probe import Refused

# A build check is a reading like any other: an old one does not vouch for today (AC-48.4's rule).
BUILD_CHECK_MAX_AGE_S = 3600


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def register(app, s, render, user_of, need_login, forbidden, csrf_ok, src_report, src_demand, app_version, src_verdicts=None,
             prober=None):
    L = s.lifecycle
    inv = s.nodes.inventory
    builds = {"at": None, "readings": {}}       # the last build check, in memory only (the UI writes nothing)

    def admin(request):
        u = user_of(request)
        if not u:
            return None, need_login(request)
        if not u.is_admin:
            return None, forbidden(request, u)
        return u, None

    def bad(request, u, msg, code=400):
        return render(request, "error.html", u, status_code=code, title="That did not work", message=msg)

    def verdicts():
        if src_verdicts is None or not src_verdicts.configured():
            return None, []
        r = src_verdicts.read()
        return r, (r.data or {}).get("verdicts", []) if r.data else []

    def gateway_names():
        return {str(m.get("model_name", "")) for m in s.nodes.gateway_model_list if isinstance(m, dict)}

    def rows():
        out = []
        by_model = {}
        for r in inv.routes:
            by_model.setdefault(r.model, []).append(r)
        for e in L.lifecycle.catalog:
            out.append({"entry": e, "routes": by_model.pop(e.model, [])})
        uncatalogued = [(m, rs) for m, rs in by_model.items()]
        return out, uncatalogued

    def progress(alias, model, revision="", incumbent=None, vs=()):
        counted, notes = ml.count_passes(vs, alias, model, revision, incumbent)
        klass = counted[-1].klass if counted else ""
        req = L.lifecycle.required_for(klass) if klass else L.lifecycle.required_passes
        return {"counted": counted, "notes": notes, "klass": klass, "required": req, "ready": bool(counted) and len(counted) >= req}

    def next_rows(vs):
        out = []
        for r in inv.routes:
            if not r.alias.endswith(ml.NEXT):
                continue
            alias = r.alias[: -len(ml.NEXT)]
            live = next((x for x in inv.routes if x.alias == alias), None)
            e = L.lifecycle.by_model(r.model)
            out.append({"route": r, "alias": alias, "live": live, "entry": e,
                        **progress(alias, r.model, e.source.revision if e else "", live.model if live else "", vs)})
        return out

    def probe_on():
        return prober is not None and prober.enabled

    def drift_rows():
        if not probe_on():
            return ml.build_drift(L.lifecycle, inv, {}, "probing is off: set inferenceNodes.probe.allowedCidrs to read the nodes")
        at = builds["at"]
        if at is None:
            return ml.build_drift(L.lifecycle, inv, {}, "not checked yet")
        age = (_now() - at).total_seconds()
        if age > BUILD_CHECK_MAX_AGE_S or age < -60:
            return ml.build_drift(L.lifecycle, inv, {}, f"last checked over {BUILD_CHECK_MAX_AGE_S // 60} minutes ago: check again")
        return ml.build_drift(L.lifecycle, inv, builds["readings"])

    @app.post("/models/builds")
    def models_builds(request: Request, csrf: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if probe_on():
            readings = {}
            for _e, r in ml.drift_targets(L.lifecycle, inv):
                key = (r.node, r.endpoint)
                n = inv.node(r.node)
                ep = n.endpoint(r.endpoint) if n else None
                if key in readings or ep is None:
                    continue
                try:
                    readings[key] = prober.read_builds(ep.url, ep.engine)
                except Refused as ex:
                    readings[key] = str(ex)
            builds["readings"], builds["at"] = readings, _now()
        return RedirectResponse("/models#builds-h", status_code=303)

    @app.get("/models")
    def models_index(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        rep = src_report.read()
        vr, vs = verdicts()
        cat, unc = rows()
        cands = rep.data.candidates if rep.data else []
        groups = {k: [c for c in cands if c.kind == k] for k in ("revision", "digest", "quant", "successor", "frontier", "deprecation")}
        hosted = [e for e in L.lifecycle.catalog if e.source.kind == "hosted" and e.stage == "candidate"]
        drift = drift_rows()
        return render(request, "models.html", u, catalog=cat, uncatalogued=unc, reading=rep, groups=groups,
                      watch_on=L.watch_enabled, gate=ml.check_promotions(L.lifecycle, inv),
                      gate_notes=ml.promotion_notes(L.lifecycle), nexts=next_rows(vs), hosted=hosted,
                      verdict_reading=vr, lc=L.lifecycle, drift=drift, drift_findings=ml.drift_findings(drift),
                      probe_on=probe_on(), checked_at=builds["at"])

    def _change(request, u, new_lc, new_inv, notes, title, fmt, form_fields, path):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        header = (f"Generated by Tockmox UI {app_version} for {u.name} at {stamp}.\n"
                  f"Replaces the modelLifecycle and inferenceNodes blocks in {s.nodes.values_file}. Review, then commit.")
        problems = ml.check_promotions(new_lc, new_inv)
        if problems:
            return bad(request, u, "This change would fail the promotion gate: " + "; ".join(problems))
        # carry every key the operator set (reportFile, watch, demandQuery ...; probe, gateway ...): review finding
        doc = ml.change_doc(L.raw, s.nodes.raw, new_lc, new_inv)
        text = "".join(f"# {h}\n" for h in header.splitlines()) + yaml.dump(doc, Dumper=nm._Dumper, sort_keys=False, width=120)
        if fmt == "yaml":
            return Response(text, media_type="application/yaml",
                            headers={"Content-Disposition": 'attachment; filename="model-lifecycle.values.yaml"'})
        dump = lambda entries: yaml.dump({"model_list": entries}, Dumper=nm._Dumper, sort_keys=False) if entries else ""
        changed = {r.alias for r in new_inv.routes} ^ {r.alias for r in inv.routes} | {
            r.alias for r in new_inv.routes if any(x.alias == r.alias and x.model != r.model for x in inv.routes)}
        bases = {a[: -len(ml.NEXT)] for a in changed if a.endswith(ml.NEXT)}
        derived = nm.Inventory(new_inv.nodes, [r for r in new_inv.routes if r.alias in changed or r.alias in bases])
        return render(request, "models_change.html", u, title=title, notes=notes, text=text,
                      eval_hosted=dump(new_lc.eval_gateway_entries), prod_hosted=dump(new_lc.production_gateway_entries),
                      model_list=nm.model_list_yaml(derived) if [r for r in nm.gateway_routes(derived) if r.alias in changed] else "",
                      eval_list=nm.model_list_yaml(derived, "eval") if nm.gateway_routes(derived, "eval") else "",
                      form_fields=form_fields, values_file=s.nodes.values_file)

    @app.post("/models/propose")
    def models_propose(request: Request, csrf: str = Form(""), cid: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        rep = src_report.read()
        cand = next((c for c in (rep.data.candidates if rep.data else []) if c.id == cid), None)
        if cand is None:
            return bad(request, u, "That candidate is not in the watcher's current report.", 404)
        try:
            add_lc, add_inv, notes = ml.propose(cand, L.lifecycle, inv, taken=gateway_names())
            new_lc = ml.merge(L.lifecycle, add_lc)
            new_inv = nm.merge(inv, add_inv) if add_inv.routes else inv
        except (ml.LifecycleError, nm.NodeError, ValueError) as e:
            return bad(request, u, str(e))
        return _change(request, u, new_lc, new_inv, notes, f"Admit {cand.model} for evaluation", fmt, {"cid": cid},
                       "/models/propose")

    # ------------------------------------------------------------ start an evaluation (AC-48.13)

    def _eval_target(alias_next="", entry="", alias=""):
        """(alias, candidate {model, revision}, incumbent {model, revision}) or a reason it cannot be evaluated."""
        if alias_next:
            r = next((x for x in inv.routes if x.alias == alias_next and alias_next.endswith(ml.NEXT)), None)
            if r is None:
                return None, "There is no such -next route."
            base = alias_next[: -len(ml.NEXT)]
            live = next((x for x in inv.routes if x.alias == base), None)
            e, le = L.lifecycle.by_model(r.model), L.lifecycle.by_model(live.model) if live else None
            return (base, {"model": r.model, "revision": e.source.revision if e else ""},
                    {"model": live.model, "revision": le.source.revision if le else ""} if live else {}), ""
        e = L.lifecycle.entry(entry)
        if e is None or e.source.kind != "hosted" or e.stage != "candidate":
            return None, "That is not a hosted candidate in the catalog."
        if not alias:
            return ("", {"model": e.model}, {}), ""
        live = next((x for x in inv.routes if x.alias == alias), None)
        gw = next((m for m in s.nodes.gateway_model_list if isinstance(m, dict) and m.get("model_name") == alias), None)
        inc = {"model": live.model} if live else ({"model": str((gw.get("litellm_params") or {}).get("model", ""))} if gw else {})
        return (alias, {"model": e.model}, inc), ""

    def _classes():
        names = {c.name for p in L.lifecycle.profiles for c in p.classes} | set(L.lifecycle.required_by_class)
        return sorted(n for n in names if ml.CLASS_RE.match(n))

    @app.get("/models/evaluate")
    def models_evaluate_form(request: Request, alias: str = "", entry: str = "", target: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        t, why = _eval_target(alias, entry, target)
        if t is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message=why)
        return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2],
                      classes=_classes(), lc=L.lifecycle, error=None, request_text="", commit_path="")

    @app.post("/models/evaluate")
    def models_evaluate(request: Request, csrf: str = Form(""), alias: str = Form(""), entry: str = Form(""),
                        target: str = Form(""), klass: str = Form(""), runs: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        t, why = _eval_target(alias, entry, target)
        if t is None:
            return bad(request, u, why, 404)
        now = datetime.datetime.now(datetime.timezone.utc)
        try:
            n = int(runs) if runs.strip() else L.lifecycle.required_for(klass) if ml.CLASS_RE.match(klass or "") else 0
            req = ml.eval_request(t[0], klass, n, t[1], t[2], u.name, now.strftime("%Y-%m-%dT%H:%M:%SZ"))
        except (ValueError, ml.LifecycleError) as e:
            return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2],
                          classes=_classes(), lc=L.lifecycle, error=str(e), request_text="", commit_path="", status_code=400)
        text = yaml.dump(req, Dumper=nm._Dumper, sort_keys=False)
        path = f"{s.lifecycle.requests_repo_path}/{now.strftime('%Y-%m-%d')}-{ml._slug(t[0])}.yaml"
        if fmt == "yaml":
            return Response(text, media_type="application/yaml",
                            headers={"Content-Disposition": 'attachment; filename="eval-request.yaml"'})
        return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2],
                      classes=_classes(), lc=L.lifecycle, error=None, request_text=text, commit_path=path,
                      form_fields={"alias": alias, "entry": entry, "target": target, "klass": klass, "runs": str(n)})

    # ------------------------------------------------------------ promote (the second approval)

    @app.get("/models/promote")
    def models_promote_form(request: Request, alias: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        row = next((x for x in next_rows(verdicts()[1]) if x["route"].alias == alias), None)
        if row is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such -next route.")
        return render(request, "models_promote.html", u, row=row, error=None, verdict_reading=verdicts()[0])

    @app.post("/models/promote")
    def models_promote(request: Request, csrf: str = Form(""), alias: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        vr, vs = verdicts()
        row = next((x for x in next_rows(vs) if x["route"].alias == alias), None)
        if row is None:
            return bad(request, u, "There is no such -next route.", 404)
        if vr is not None and vr.state != "ok":
            # a verdict file that could not be read might be the fail that resets the count
            return render(request, "models_promote.html", u, row=row, verdict_reading=vr, status_code=400,
                          error=f"Not every verdict file could be read ({vr.reason}), so the count cannot be trusted.")
        try:
            new_lc, new_inv, notes = ml.promote(alias, vs, L.lifecycle, inv)
        except (ml.LifecycleError, nm.NodeError) as e:
            return render(request, "models_promote.html", u, row=row, error=str(e), verdict_reading=vr, status_code=400)
        return _change(request, u, new_lc, new_inv, notes, f"Promote {row['alias']} to {row['route'].model}", fmt,
                       {"alias": alias}, "/models/promote")

    @app.get("/models/promote-hosted")
    def models_promote_hosted_form(request: Request, entry: str = "", target: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        e = L.lifecycle.entry(entry)
        if e is None or e.source.kind != "hosted" or e.stage != "candidate":
            return render(request, "error.html", u, status_code=404, title="Not found", message="That is not a hosted candidate.")
        vr, vs = verdicts()
        prog = progress(target, e.model, vs=vs) if target and nm.ALIAS_RE.match(target) else None
        return render(request, "models_promote_hosted.html", u, e=e, target=target, prog=prog, error=None, verdict_reading=vr)

    @app.post("/models/promote-hosted")
    def models_promote_hosted(request: Request, csrf: str = Form(""), entry: str = Form(""), target: str = Form(""),
                              tags: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        e = L.lifecycle.entry(entry)
        if e is None or e.source.kind != "hosted":
            return bad(request, u, "That is not a hosted model in the catalog.", 404)
        vr, vs = verdicts()
        prog = progress(target, e.model, vs=vs) if target and nm.ALIAS_RE.match(target) else None
        if vr is not None and vr.state != "ok":
            return render(request, "models_promote_hosted.html", u, e=e, target=target, prog=prog, verdict_reading=vr, status_code=400,
                          error=f"Not every verdict file could be read ({vr.reason}), so the count cannot be trusted.")
        try:
            new_lc, notes = ml.promote_hosted(entry, target, [t.strip() for t in tags.split(",")], vs, L.lifecycle, gateway_names())
        except ml.LifecycleError as ex:
            return render(request, "models_promote_hosted.html", u, e=e, target=target, prog=prog, error=str(ex),
                          verdict_reading=vr, status_code=400)
        return _change(request, u, new_lc, inv, notes, f"Promote {e.model} as {target}", fmt,
                       {"entry": entry, "target": target, "tags": tags}, "/models/promote-hosted")

    @app.get("/models/m/{eid}")
    def models_model(request: Request, eid: str):
        """One model: where it comes from (links built from the catalog, never fetched), the links the operator
        added, which routes serve it on which gateway, and its promotion record (TM-0938)."""
        u, deny = admin(request)
        if deny:
            return deny
        e = L.lifecycle.entry(eid)
        if e is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such model in the catalog.")
        routes = [{"route": r, "gateway": "eval" if r.alias.endswith(ml.NEXT) else "production"} for r in inv.routes if r.model == e.model]
        rep = src_report.read()
        cands = [c for c in (rep.data.candidates if rep.data else []) if c.subject == e.id]
        return render(request, "models_model.html", u, e=e, src_links=ml.source_links(e, s.lifecycle.provider_pages, s.lifecycle.modelkit_registries),
                      routes=routes, cands=cands, reading=rep, required=L.lifecycle.required_passes)

    @app.get("/models/profiles")
    def models_profiles(request: Request, profile: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        lc = L.lifecycle
        prof = lc.profile(profile) or lc.profile(lc.active_profile) or (lc.profiles[0] if lc.profiles else None)
        plans = []
        for n in inv.nodes:
            plan = ml.plan_residency(n, inv.routes_on(n.id), prof)
            swap = ml.render_llama_swap(plan)
            oll = ml.render_ollama(plan)
            plans.append({"node": n, "plan": plan,
                          "swap": yaml.dump(swap, Dumper=nm._Dumper, sort_keys=False) if swap["models"] else "",
                          "ollama": yaml.dump(oll, Dumper=nm._Dumper, sort_keys=False) if oll["routeParams"] else ""})
        demand = src_demand.read()
        return render(request, "models_profiles.html", u, profiles=lc.profiles, prof=prof, plans=plans, demand=demand)

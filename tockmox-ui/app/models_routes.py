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
  GET  /models/v/<runId>            one comparison: the label, the numbers, how it was run, what it cites, whether it counted
  GET  /models/a/<alias>            one live alias: what it serves, its promotion record, and the revert
  POST /models/a/<alias>/revert     the revert change (alias back to promotion.previous), for a person to review and commit
  GET  /models/promote-hosted?entry=  the same for a hosted candidate, choosing its alias and data-class tags
  POST /models/promote-hosted
  GET  /models/recommend?node=<id>  per alias class, a shortlist for one node (AC-48.14). A hypothesis list: it admits nothing
  POST /models/recommend/admit      the same change as /models/propose, for one row of that list ("Admit for evaluation")
  GET  /models/inbox                what the watcher found, as cards: reason, fit per node, licence, a model card's own results
                                    as a labelled hint, and Evaluate / Snooze 30 days / Dismiss (TM-1258, TM-1265)
  POST /models/inbox/snooze         the values change that snoozes one candidate (modelLifecycle.inbox.snoozed); writes nothing
  POST /models/inbox/dismiss        the same for modelLifecycle.inbox.dismissed
  GET  /models/c/<alias>            the candidate for an alias: the plan, and a strip of its runs from run-status/1 files
  POST /models/c/<alias>/rerun      the values change that lists a finished run in modelLifecycle.runner.rerun (TM-1301); writes nothing
  GET  /models/budget               requests and estimated cost per alias, and the local share of traffic; Unknown where nothing says
  POST /models/v/<runId>/reject     the reject change for a fail, worse or tradeoff comparison (reason required); writes nothing
  GET  /models/profiles             workload profiles -> a residency plan per node, and the engine configs
  POST /models/builds               read which build each node holds for the pinned models it serves (TM-0934),
                                    through the probe's fences; the result lives in memory and goes stale
"""
from __future__ import annotations

import copy
import datetime

import yaml
from fastapi import Form, Request
from fastapi.responses import PlainTextResponse, RedirectResponse, Response

from . import budget as bg
from . import candidate as cd
from . import fit as fx
from . import inbox as ib
from . import models as ml
from . import nodes as nm
from . import recommend as rc
from . import results as rs
from . import verdict_stats as vst
from .probe import Refused

# A build check is a reading like any other: an old one does not vouch for today (AC-48.4's rule).
BUILD_CHECK_MAX_AGE_S = 3600


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def register(app, s, render, user_of, need_login, forbidden, csrf_ok, src_report, src_demand, app_version, src_verdicts=None,
             prober=None, node_facts=None):
    """node_facts(node_id) -> {"wired_limit_mib": float} from the node's live metrics, or {}. Optional. Without it the wired
    limit is read from the newest capability-result/1 that recorded one, and failing that the node's planning fraction is used."""
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

    def gateway_list():
        return [m for m in s.nodes.gateway_model_list if isinstance(m, dict)]

    def gateway_names():
        return {str(m.get("model_name", "")) for m in gateway_list()}

    def rows():
        out = []
        by_model = {}
        for r in inv.routes:
            by_model.setdefault(r.model, []).append(r)
        for e in L.lifecycle.catalog:
            out.append({"entry": e, "routes": by_model.pop(e.model, [])})
        uncatalogued = [(m, rs) for m, rs in by_model.items()]
        return out, uncatalogued

    def progress(alias, model, revision="", incumbent=None, vs=(), move=None):
        """What the verdicts say about moving `alias` to `model`. `move` ({from_node, to_node}) is set for a re-placement
        (the same model on another node): only class perf records that name that move count."""
        counted, notes = ml.count_passes(vs, alias, model, revision, incumbent, move)
        klass = counted[-1].klass if counted else ""
        req = L.lifecycle.required_for(klass, move is not None) if klass else L.lifecycle.required_for(ml.PERF, True) if move else L.lifecycle.required_passes
        return {"counted": counted, "notes": notes, "klass": klass, "required": req, "ready": bool(counted) and len(counted) >= req,
                "move": move}

    def next_rows(vs):
        out = []
        for r in inv.routes:
            if not r.alias.endswith(ml.NEXT):
                continue
            alias = r.alias[: -len(ml.NEXT)]
            live = next((x for x in inv.routes if x.alias == alias), None)
            e = L.lifecycle.by_model(r.model)
            move = {"from_node": live.node, "to_node": r.node} if ml.is_replacement(live, r) else None
            out.append({"route": r, "alias": alias, "live": live, "entry": e, "replacement": move is not None,
                        **progress(alias, r.model, e.source.revision if e else "", live.model if live else "", vs, move)})
        return out

    def probe_on():
        return prober is not None and prober.enabled

    def today():
        return _now().date()

    def inbox_cfg():
        """(Inbox, "") or (empty Inbox, why): a malformed modelLifecycle.inbox is shown on the page, not hidden."""
        try:
            return ib.parse((L.raw or {}).get("inbox")), ""
        except ml.LifecycleError as e:
            return ib.Inbox(), str(e)

    def retire_note(when):
        """The countdown for a deprecation's date, with its badge state: ("retires in 12 days (2026-11-10)", "warning")."""
        r = ib.retirement(when, today())
        return {**r, "badge": ib.retire_state(r)}

    hosted_by_model = {}                 # "provider/model" -> [gateway aliases that route it to the provider]
    for m_ in gateway_list():
        h_ = bg.hosted_model(m_)
        if h_ and m_.get("model_name"):
            hosted_by_model.setdefault(h_, []).append(str(m_["model_name"]))

    budget_cfg, budget_problems = bg.parse_budget((L.raw or {}).get("budget"))
    # the spend source rides the demand source's URL, timeout and transport: one Prometheus, one set of fences
    spend_src = (bg.SpendSource(src_demand.url, budget_cfg["spendQuery"], src_demand.timeout, src_demand.transport)
                 if budget_cfg["spendQuery"] and hasattr(src_demand, "url") else None)

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
        inbox, inbox_why = inbox_cfg()
        cands, snoozed, dismissed = ib.split(rep.data.candidates if rep.data else [], inbox, today())
        groups = {k: [c for c in cands if c.kind == k] for k in ("revision", "digest", "quant", "successor", "frontier", "deprecation")}
        rmap = ib.retire_map(rep.data, today())
        for row in cat:
            row["retire"] = ib.retire_for(rmap, row["entry"].model, row["entry"].source.ref)
            if row["retire"]:
                row["retire"] = {**row["retire"], "badge": ib.retire_state(row["retire"])}
            row["hosted_aliases"] = hosted_by_model.get(row["entry"].source.ref, []) if row["entry"].source.kind == "hosted" else []
        hosted = [e for e in L.lifecycle.catalog if e.source.kind == "hosted" and e.stage == "candidate"]
        drift = drift_rows()
        return render(request, "models.html", u, catalog=cat, uncatalogued=unc, reading=rep, groups=groups,
                      watch_on=L.watch_enabled, gate=ml.check_promotions(L.lifecycle, inv),
                      gate_notes=ml.promotion_notes(L.lifecycle), nexts=next_rows(vs), hosted=hosted,
                      verdict_reading=vr, lc=L.lifecycle, drift=drift, drift_findings=ml.drift_findings(drift),
                      probe_on=probe_on(), checked_at=builds["at"], nodes=inv.nodes, inbox_count=len(cands), hidden_count=len(snoozed) + len(dismissed),
                      inbox_why=inbox_why, retire_note=retire_note)

    def _change(request, u, new_lc, new_inv, notes, title, fmt, form_fields, path, raw=None):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        header = (f"Generated by Tockmox UI {app_version} for {u.name} at {stamp}.\n"
                  f"Replaces the modelLifecycle and inferenceNodes blocks in {s.nodes.values_file}. Review, then commit.")
        problems = ml.check_promotions(new_lc, new_inv)
        if problems:
            return bad(request, u, "This change would fail the promotion gate: " + "; ".join(problems))
        # carry every key the operator set (reportFile, watch, demandQuery ...; probe, gateway ...): review finding
        doc = ml.change_doc(L.raw if raw is None else raw, s.nodes.raw, new_lc, new_inv)
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
                      form_fields=form_fields, values_file=s.nodes.values_file, path=path)

    def replacement_candidate(dep, report):
        """(hosted Candidate, "") for the replacement a deprecation names, or (None, why). The report's own frontier candidate for it
        is used when there is one; otherwise one is built from the name, so a replacement the provider's list does not show yet can
        still be admitted for evaluation."""
        if not dep.replacement:
            return None, (f"The report names no replacement for {dep.model}. Name one under "
                          f"modelLifecycle.watch.providers.{dep.subject}.replacements, or admit a hosted model from the list by hand.")
        known = next((c for c in (report.candidates if report else []) if c.kind == "frontier" and c.model == dep.replacement), None)
        if known is not None:
            return known, ""
        e = L.lifecycle.by_model(dep.replacement)
        if e is not None:
            return None, f"{dep.replacement} is already in the catalog (stage {e.stage}): start its evaluation from the Models page."
        return ml.Candidate(f"frontier:{dep.replacement}", "frontier", dep.subject, dep.replacement, ml.Source("hosted", dep.replacement, ""),
                            f"{dep.replacement} replaces {dep.model}, which {dep.subject} retires ({dep.when or 'date not given'})"), ""

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
        if cand.kind == "deprecation":
            # a retiring hosted model: what is offered is the replacement the report names, as a hosted candidate (TM-1265)
            cand, why = replacement_candidate(cand, rep.data)
            if cand is None:
                return bad(request, u, why)
        try:
            add_lc, add_inv, notes = ml.propose(cand, L.lifecycle, inv, taken=gateway_names(), gateway=gateway_list())
            new_lc = ml.merge(L.lifecycle, add_lc)
            new_inv = nm.merge(inv, add_inv) if add_inv.routes else inv
        except (ml.LifecycleError, nm.NodeError, ValueError) as e:
            return bad(request, u, str(e))
        return _change(request, u, new_lc, new_inv, notes, f"Admit {cand.model} for evaluation", fmt, {"cid": cid},
                       "/models/propose")

    # ------------------------------------------------------------ recommend for a node (AC-48.14)

    def rec_config():
        """(Config, "") or (None, why). Read per request: the values file is the one source."""
        try:
            return rc.parse_config((L.raw or {}).get("recommend")), ""
        except ml.LifecycleError as e:
            return None, str(e)

    def load_results():
        """capability-result/1 twins from modelLifecycle.resultsDir (a mount of the site's evals/results), or ([], [])."""
        d = str((L.raw or {}).get("resultsDir", "") or "")
        if not d:
            return [], []
        return rs.load_dir(d, "", prefix=str((L.raw or {}).get("resultsRepoPath", "evals/results") or "evals/results"))

    def facts_for(node_id):
        if node_facts is None:
            return {}
        try:
            f = node_facts(node_id)
        except Exception:  # noqa: BLE001  a metrics read must not take the page down
            return {}
        return f if isinstance(f, dict) else {}

    def recommend_for(node_id):
        cfg, why = rec_config()
        if cfg is None:
            return None, None, why
        rep = src_report.read()
        results, bad = load_results()
        rec = rc.recommend(node_id, L.lifecycle, inv, rep.data, cfg, results, facts_for(node_id))
        if bad:
            rec.notes.append(f"{len(bad)} measured-result file(s) could not be read and were ignored: " + "; ".join(bad[:3]))
        return rec, cfg, ""

    @app.get("/models/recommend")
    def models_recommend(request: Request, node: str = ""):
        """A shortlist per alias class for one node. Read only: it admits nothing and writes nothing. The buttons POST to
        /models/recommend/admit, which renders the same change /models/propose does, for a person to review and commit."""
        u, deny = admin(request)
        if deny:
            return deny
        if not node:
            first = inv.nodes[0].id if inv.nodes else ""
            if not first:
                return render(request, "error.html", u, status_code=404, title="No nodes", message="There are no inference nodes in the inventory to recommend for.")
            return RedirectResponse(f"/models/recommend?node={first}", status_code=303)
        if inv.node(node) is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such node.")
        rec, cfg, why = recommend_for(node)
        if rec is None:
            return bad(request, u, "modelLifecycle.recommend is not valid: " + why)
        rep = src_report.read()
        return render(request, "models_recommend.html", u, rec=rec, cfg=cfg, nodes=inv.nodes, reading=rep, node=inv.node(node),
                      facts_on=node_facts is not None)

    @app.post("/models/recommend/admit")
    def models_recommend_admit(request: Request, csrf: str = Form(""), node: str = Form(""), cls: str = Form(""),
                               model: str = Form(""), endpoint: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if inv.node(node) is None:
            return bad(request, u, "There is no such node.", 404)
        rec, cfg, why = recommend_for(node)
        if rec is None:
            return bad(request, u, "modelLifecycle.recommend is not valid: " + why)
        # Never trust the form for what to do: find the row again and take the action from it. A row that is no longer
        # on the list (the report changed, an alias was taken) is refused rather than guessed at.
        cr = next((c for c in rec.classes if c.spec.name == cls), None)
        row = next((r for r in cr.rows if r.option.model == model), None) if cr else None
        if row is None:
            return bad(request, u, "That model is no longer on this node's list for that class. Open the list again.", 404)
        if not row.admissible:
            return bad(request, u, f"{model} cannot be admitted for {row.alias}: {row.why_not}")
        eps = {e: g for e, g in row.endpoints}
        ep = endpoint or (row.endpoints[0][0] if row.endpoints else "")
        if ep not in eps:
            return bad(request, u, f"{node} has no endpoint {ep!r} that can serve {model}.")
        try:
            add_lc, add_inv, notes = rc.build_change(row.action, row.alias, row.option, node, ep, cr.spec, L.lifecycle, inv,
                                                     gateway_names())
            ml.stamp_next_routes(add_inv, inv, gateway_list())          # TM-1119: tier and tags, as propose() writes them
            new_lc = ml.merge(L.lifecycle, add_lc)
            new_inv = nm.merge(inv, add_inv) if add_inv.routes else inv
        except (ml.LifecycleError, nm.NodeError, ValueError) as e:
            return bad(request, u, str(e))
        notes = notes + ["this came from the Recommend list, which is a set of hypotheses: the evaluation decides, and promotion is a "
                         "second approval"]
        return _change(request, u, new_lc, new_inv, notes, f"Admit {model} for evaluation as {row.alias}{ml.NEXT}", fmt,
                       {"node": node, "cls": cls, "model": model, "endpoint": ep}, "/models/recommend/admit")

    # ------------------------------------------------------------ the inbox (TM-1258, TM-1265)

    FIT_BADGE = {"fits": "ok", "tight": "warning", "over": "critical", "unknown": "unknown"}
    INBOX_RANK = {"deprecation": 0, "revision": 1, "digest": 1, "successor": 2, "quant": 3, "frontier": 4}
    HOSTED_HELD = ("Hosted candidates are admitted to the eval gateway tagged open: the eval runner sends them public eval sets "
                   "only, and the eval gateway refuses them anything tagged above open (the data-class rails, TM-1249).")

    def fit_chips(c, rep, results):
        """One chip per node for a local candidate, from fit v2 (fit_compat): {node, state, text}. A candidate with no size is Unknown."""
        if c.source.kind not in ("huggingface", "ollama"):
            return []
        rec = (rep.sizes if rep else {}).get(c.source.ref) if c.source.kind == "huggingface" else None
        entry = L.lifecycle.entry(c.subject)
        # c.size_gib is the watcher's own (the incumbent's for a new revision of the same bytes); the incumbent's size is NOT a quant's
        est = c.size_gib or nm.estimate_size_gib(c.model)
        opt = rc.Option(c.model, c.source, "watcher", None, rec, c.detail)
        kind = rc._kind_of(opt)
        live = next((r for r in inv.routes if entry and r.model == entry.model and not r.alias.endswith(ml.NEXT)), None)
        need = fx.route_need(live) if live else fx.Need()
        cfg, _why = rec_config()
        sizes = rc.sizes_by_model(L.lifecycle, rep)
        out = []
        for n in inv.nodes:
            eps = rc._compatible(n, opt, kind)
            if not eps:
                out.append({"node": n, "state": "unknown", "text": f"no endpoint on {n.name} can serve this build"})
                continue
            facts = dict(facts_for(n.id))
            if not facts.get("wired_limit_mib"):
                facts.update(rc.facts_from_results(results, n.id))
            op = ((cfg.nodes.get(n.id) or {}).get("wiredLimitGiB") if cfg else None)
            if op:
                facts["operator_usable_gib"] = op
            f = fx.fit_compat(n, inv.routes_on(n.id), est, eps[0][1], sizes=sizes, facts=facts, need=need, new_record=rec)
            if f.state == "unknown" or f.new_gib is None or f.usable_gib is None:
                why = "its size is not known" if f.new_gib is None else "the node's memory is not known"
                out.append({"node": n, "state": "unknown", "text": f"{n.name}: Unknown, {why}"})
            else:
                out.append({"node": n, "state": FIT_BADGE[f.state], "text": f"{n.name}: {f.state}, {f.total:.0f} of {f.usable_gib:.0f} GiB planned"})
        return out

    def licence_chip(c, rep):
        cfg, why = rec_config()
        if cfg is None:
            return {"state": "unknown", "word": "Licence: Unknown", "text": "modelLifecycle.recommend is not valid, so the allow list cannot be read: " + why}
        rec = (rep.sizes if rep else {}).get(c.source.ref) if c.source.kind == "huggingface" else None
        lic, text = rc.licence_state(rc.Option(c.model, c.source, "watcher", None, rec, c.detail), cfg)
        name = (rec.license if rec and rec.license else "") or "unknown"
        return {"state": {"allowed": "ok", "exception": "warning", "outside": "critical"}.get(lic, "unknown"),
                "word": f"Licence: {name}", "text": "" if lic == "allowed" else text}

    def inbox_cards(rep, shown):
        results = load_results()[0]
        cards = []
        for c in shown:
            hosted = c.source.kind == "hosted"
            card = {"c": c, "reason": ib.REASONS[c.kind][0], "reason_why": ib.REASONS[c.kind][1], "hosted": hosted,
                    "fits": [] if hosted else fit_chips(c, rep, results), "licence": None if hosted else licence_chip(c, rep),
                    "hint": None, "retire": None, "replacement": None}
            rec = (rep.sizes if rep else {}).get(c.source.ref) if c.source.kind == "huggingface" else None
            if rec and rec.eval_results:
                card["hint"] = "; ".join(f"{x['name'] or 'metric'} {x['value']}" + (f" on {x['dataset']}" if x['dataset'] else "") for x in rec.eval_results[:4])
            if c.kind == "deprecation":
                card["retire"] = retire_note(c.when)
                if c.replacement:
                    e = L.lifecycle.by_model(c.replacement)
                    card["replacement"] = {"model": c.replacement, "entry": e}
            cards.append(card)
        cards.sort(key=lambda k: (INBOX_RANK[k["c"].kind], (k["retire"] or {}).get("date") or "9999", k["c"].model))
        return cards

    @app.get("/models/inbox")
    def models_inbox(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        rep = src_report.read()
        inbox, inbox_why = inbox_cfg()
        cands, snoozed, dismissed = ib.split(rep.data.candidates if rep.data else [], inbox, today())
        return render(request, "models_inbox.html", u, reading=rep, cards=inbox_cards(rep.data, cands), snoozed=snoozed, dismissed=dismissed,
                      inbox_why=inbox_why, held=HOSTED_HELD, days=ib.SNOOZE_DAYS, watch_on=L.watch_enabled)

    def inbox_change(request, u, kind, cid, fmt):
        rep = src_report.read()
        cand = next((c for c in (rep.data.candidates if rep.data else []) if c.id == cid), None)
        if cand is None:
            return bad(request, u, "That candidate is not in the watcher's current report.", 404)
        inbox, inbox_why = inbox_cfg()
        if inbox_why:
            return bad(request, u, "modelLifecycle.inbox is not valid, so it cannot be extended: " + inbox_why)
        raw_inbox = (L.raw or {}).get("inbox")
        if kind == "snooze":
            new_inbox = ib.with_snooze(raw_inbox, cid, today())
            until = next(x["until"] for x in new_inbox["snoozed"] if x["id"] == cid)
            title = f"Snooze {cand.model} for {ib.SNOOZE_DAYS} days"
            notes = [f"{cid} is hidden until {until}: the watcher leaves it out of its report, and the Models pages hide it",
                     "it comes back on its own after that date; the entry is a date, not a decision"]
        else:
            new_inbox = ib.with_dismiss(raw_inbox, cid, today())
            title = f"Dismiss {cand.model}"
            notes = [f"{cid} is hidden for good: the watcher leaves it out of its report",
                     "a NEW candidate for the same model (another revision, say) has another id and is offered again",
                     "to bring this one back, delete its line from modelLifecycle.inbox.dismissed"]
        new_raw = copy.deepcopy(L.raw or {})
        new_raw["inbox"] = new_inbox
        notes.append("this changes only modelLifecycle.inbox: no route, no catalog entry and no gateway entry")
        return _change(request, u, L.lifecycle, inv, notes, title, fmt, {"cid": cid}, f"/models/inbox/{kind}", raw=new_raw)

    @app.post("/models/inbox/snooze")
    def models_inbox_snooze(request: Request, csrf: str = Form(""), cid: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        return inbox_change(request, u, "snooze", cid, fmt)

    @app.post("/models/inbox/dismiss")
    def models_inbox_dismiss(request: Request, csrf: str = Form(""), cid: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        return inbox_change(request, u, "dismiss", cid, fmt)

    # ------------------------------------------------------------ the candidate for an alias: plan and run strip (TM-1258)

    @app.get("/models/c/{alias}")
    def models_candidate(request: Request, alias: str):
        u, deny = admin(request)
        if deny:
            return deny
        base = alias[: -len(ml.NEXT)] if alias.endswith(ml.NEXT) else alias
        nxt = next((r for r in inv.routes if r.alias == base + ml.NEXT), None)
        live = next((r for r in inv.routes if r.alias == base), None)
        runs, problem = cd.read_runs(cd.status_dir(L.raw))
        mine = cd.runs_for(runs, base)
        if nxt is None and not mine:
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message=f"{base} has no candidate: there is no {base}{ml.NEXT} route and no run on record for it.")
        now = _now()
        strips = [cd.strip(r, now) for r in mine]
        latest = strips[0] if strips else None
        ce = L.lifecycle.by_model(nxt.model) if nxt else None
        le = L.lifecycle.by_model(live.model) if live else None
        move = {"from_node": live.node, "to_node": nxt.node} if nxt and ml.is_replacement(live, nxt) else None
        node = inv.node(nxt.node) if nxt else None
        ep = node.endpoint(nxt.endpoint) if node else None
        vr, vs = verdicts()
        have = {v.run_id for v in vs}
        seen_legs = [l["name"] for l in (latest or {}).get("legs") or []]
        plan = {"legs": seen_legs or list(cd.DEFAULT_LEGS), "from_status": bool(seen_legs), "estimated": (latest or {}).get("estimated", ""),
                "window": (latest or {}).get("window", ""), "disk_gib": (latest or {}).get("disk_gib"), "quiet": cd.quiet_window(L.raw)}
        return render(request, "models_candidate.html", u, alias=base, nxt=nxt, live=live, ce=ce, le=le, move=move, engine=ep.engine if ep else "",
                      plan=plan, words=cd.LEG_WORDS, latest=latest, earlier=strips[1:6], problem=problem, status_dir=cd.status_dir(L.raw),
                      have_verdicts=have, verdict_reading=vr, rerun=cd.rerun_offer(latest, cd.rerun_ids(L.raw)))

    @app.post("/models/c/{alias}/rerun")
    def models_candidate_rerun(request: Request, alias: str, csrf: str = Form(""), run_id: str = Form(""), fmt: str = Form("")):
        """TM-1301: measure a finished run again. The change lists its run id in modelLifecycle.runner.rerun (appended to what the
        site already lists); the runner's next pass queues a new run for the same combination. A change to review and commit."""
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        base = alias[: -len(ml.NEXT)] if alias.endswith(ml.NEXT) else alias
        runs, _problem = cd.read_runs(cd.status_dir(L.raw))
        run = next((r for r in cd.runs_for(runs, base) if str(r.get("run_id", "")) == run_id), None)
        if run is None:
            return bad(request, u, f"There is no run {run_id or '(none given)'} on record for {base}.", 404)
        if run.get("state") not in cd.FINISHED:
            return bad(request, u, f"Run {run_id} is {run.get('state')}: only a run that is done or failed can be run again.")
        listed = cd.rerun_ids(L.raw)
        new_raw = copy.deepcopy(L.raw or {})
        cur = new_raw.get("runner")
        runner = dict(cur) if isinstance(cur, dict) else {}
        runner["rerun"] = listed if run_id in listed else listed + [run_id]
        new_raw["runner"] = runner
        notes = [f"run {run_id} is listed in modelLifecycle.runner.rerun" + (" (it already was; nothing else changes)" if run_id in listed else ""),
                 "the runner's next scheduled pass queues a new run for the same candidate, eval set, engine, node and route, under a new run id",
                 "a listed id whose combination already has a newer finished run is left alone, so the line can stay until you tidy it",
                 "a rerun of one frozen set counts once toward promotion: it is more evidence about the same thing, not another vote",
                 "this changes only modelLifecycle.runner: no route, no catalog entry and no gateway entry"]
        if not runner.get("enabled"):
            notes.insert(1, "modelLifecycle.runner.enabled is off here, so nothing measures it until the runner is turned on")
        return _change(request, u, L.lifecycle, inv, notes, f"Run {run_id} again", fmt, {"run_id": run_id}, f"/models/c/{alias}/rerun", raw=new_raw)

    # ------------------------------------------------------------ the budget (TM-1258)

    @app.get("/models/budget")
    def models_budget(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        demand = src_demand.read()
        spend = spend_src.read() if spend_src is not None else None
        data = bg.build(demand, spend, inv, gateway_list(), budget_cfg)
        return render(request, "models_budget.html", u, b=data, demand=demand, spend=spend, window=bg.window_of(s.lifecycle.demand_query),
                      problems=budget_problems, demand_query=s.lifecycle.demand_query, spend_query=budget_cfg["spendQuery"])

    # ------------------------------------------------------------ start an evaluation (AC-48.13)

    def _eval_target(alias_next="", entry="", alias=""):
        """((alias, candidate {model, revision}, incumbent {model, revision}, move), "") or (None, reason). `move` is
        {from_node, to_node} for a re-placement (the same model on another node), else None."""
        if alias_next:
            r = next((x for x in inv.routes if x.alias == alias_next and alias_next.endswith(ml.NEXT)), None)
            if r is None:
                return None, "There is no such -next route."
            base = alias_next[: -len(ml.NEXT)]
            live = next((x for x in inv.routes if x.alias == base), None)
            e, le = L.lifecycle.by_model(r.model), L.lifecycle.by_model(live.model) if live else None
            move = {"from_node": live.node, "to_node": r.node} if ml.is_replacement(live, r) else None
            return (base, {"model": r.model, "revision": e.source.revision if e else ""},
                    {"model": live.model, "revision": le.source.revision if le else ""} if live else {}, move), ""
        e = L.lifecycle.entry(entry)
        if e is None or e.source.kind != "hosted" or e.stage != "candidate":
            return None, "That is not a hosted candidate in the catalog."
        if not alias:
            return ("", {"model": e.model}, {}, None), ""
        live = next((x for x in inv.routes if x.alias == alias), None)
        gw = next((m for m in s.nodes.gateway_model_list if isinstance(m, dict) and m.get("model_name") == alias), None)
        inc = {"model": live.model} if live else ({"model": str((gw.get("litellm_params") or {}).get("model", ""))} if gw else {})
        return (alias, {"model": e.model}, inc, None), ""

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
        return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2], move=t[3],
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
            n = int(runs) if runs.strip() else L.lifecycle.required_for(klass, t[3] is not None) if ml.CLASS_RE.match(klass or "") else 0
            req = ml.eval_request(t[0], klass, n, t[1], t[2], u.name, now.strftime("%Y-%m-%dT%H:%M:%SZ"), t[3])
        except (ValueError, ml.LifecycleError) as e:
            return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2], move=t[3],
                          classes=_classes(), lc=L.lifecycle, error=str(e), request_text="", commit_path="", status_code=400)
        text = yaml.dump(req, Dumper=nm._Dumper, sort_keys=False)
        path = f"{s.lifecycle.requests_repo_path}/{now.strftime('%Y-%m-%d')}-{ml._slug(t[0])}.yaml"
        if fmt == "yaml":
            return Response(text, media_type="application/yaml",
                            headers={"Content-Disposition": 'attachment; filename="eval-request.yaml"'})
        return render(request, "models_evaluate.html", u, alias_next=alias, entry=entry, target=t[0], cand=t[1], inc=t[2], move=t[3],
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

    # ------------------------------------------------------------ one comparison, and one alias (revert)

    def _pct(x):
        return f"{x:+.3f}"

    def compare_view(v, vs):
        """Everything the Compare page shows for one verdict, as plain values. A field an older producer did not write is
        None, and the template says "not recorded"."""
        ex = v.extras
        label = ex.get("label") or v.verdict
        # an older runner wrote pass / fail; the label set is better / same / worse / inconclusive, and a tradeoff (TM-1269) is neither
        # a win nor a loss. A label this page does not know reads as a warning, never as a crash and never as OK.
        state = {"better": "ok", "same": "ok", "worse": "critical", "inconclusive": "warning", "tradeoff": "warning", "pass": "ok",
                 "fail": "critical"}.get(label, "warning")
        dc = ex.get("discordant")
        n = ex.get("n")
        wins, losses = (dc["b"], dc["c"]) if dc else (None, None)
        ties = n - wins - losses if (n is not None and dc and n >= wins + losses) else None
        iv = ex.get("interval")
        method = ex.get("method")
        pval = None
        if dc and method in (None, "sign-test+bootstrap"):
            pval = f"{vst.sign_test(wins, losses):.4g} (exact sign test on the {wins + losses} discordant pair(s), worked out here)"
        if iv:
            wil = method == "wilson"
            fmt_ = (lambda x: f"{x:.3f}") if wil else _pct
            what = "pass rate, 95% Wilson interval" if wil else "difference in pass rate, candidate minus incumbent, 95% interval"
            interval = f"{fmt_(iv[0])} to {fmt_(iv[1])} ({what})"
        else:
            interval = None
        if "bar" in ex:
            threshold = f"bar {ex['bar']:.3f}: the interval's lower end must reach it"
        elif "margin" in ex or "min_effect" in ex:
            threshold = ", ".join(x for x in (f"margin {ex['margin']:.3f}" if "margin" in ex else "",
                                              f"min effect {ex['min_effect']:.3f}" if "min_effect" in ex else "") if x)
        else:
            threshold = None
        ctl = ex.get("control")
        samp = ex.get("sampling")
        eng = ex.get("engine")
        # did it count: ask count_passes the way the promote page does, for the alias as it stands now
        e = L.lifecycle.by_model(v.candidate.get("model", ""))
        live = next((x for x in inv.routes if x.alias == v.alias), None)
        counted, notes = ml.count_passes(vs, v.alias, v.candidate.get("model", ""), e.source.revision if e else "",
                                         live.model if live else "", v.placement or None)
        did = any(c is v for c in counted)
        mine = [x for x in notes if x.startswith(v.run_id + " ")]
        if did:
            why = ""
        elif mine:
            why = "; ".join(mine)
            why = why[0].upper() + why[1:]
        else:
            why = ("It is not among the passes that count now: a later fail reset the count, or a newer version of the eval set, "
                   "another class or another build took over")
        return {"label": label, "state": state, "word": label.capitalize(), "n": n, "wins": wins, "losses": losses, "ties": ties,
                "method": method, "interval": interval, "threshold": threshold, "pvalue": pval,
                "control": ctl, "sampling": ", ".join(f"{k} {val}" for k, val in sorted(samp.items())) if samp else None,
                "engine": (f"{eng['id']} {eng['version']}".strip() + (f" ({eng['flags']})" if eng["flags"] else "")) if eng else None,
                "node": ex.get("node"), "set_sha": ex.get("set_sha256"), "judge": ex.get("judge"), "screening": bool(ex.get("screening")),
                "counted": did, "why_not": why, "move_text": (f"{v.placement['from_node']} to {v.placement['to_node']}" if v.placement else "")}

    def reject_view(v, label):
        """What the Reject button on the Compare page does. It is shown for a fail, worse or tradeoff comparison; it is offered when
        `<alias>-next` still routes the candidate and models.reject would accept it, and otherwise says why not (its own words)."""
        if not (v.verdict == "fail" or label in ("worse", "tradeoff")):
            return {"show": False}
        nxt = next((r for r in inv.routes if r.alias == v.alias + ml.NEXT), None)
        if nxt is None or nxt.model != v.candidate.get("model"):
            return {"show": True, "offered": False, "why": f"{v.alias}{ml.NEXT} does not route {v.candidate.get('model')} now: it was already "
                                                           "rejected or promoted, or the route was replaced"}
        try:
            ml.reject(nxt.alias, "check", today().isoformat(), L.lifecycle, inv)
        except (ml.LifecycleError, nm.NodeError) as ex:
            return {"show": True, "offered": False, "why": str(ex)}
        return {"show": True, "offered": True, "alias_next": nxt.alias, "model": nxt.model}

    def compare_page(request, u, run_id, error=None, reason="", status_code=200):
        vr, vs = verdicts()
        v = next((x for x in vs if x.run_id == run_id), None)
        if v is None:
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="There is no comparison with that run id in the verdict records this page reads.")
        c = compare_view(v, vs)
        return render(request, "models_compare.html", u, v=v, c=c, verdict_reading=vr, rj=reject_view(v, c["label"]), error=error,
                      reason=reason, status_code=status_code)

    @app.get("/models/v/{run_id}")
    def models_verdict(request: Request, run_id: str):
        """The Compare page: one comparative verdict, answer first, then the numbers, how it was run, and what it cites."""
        u, deny = admin(request)
        if deny:
            return deny
        return compare_page(request, u, run_id)

    @app.post("/models/v/{run_id}/reject")
    def models_reject(request: Request, run_id: str, csrf: str = Form(""), reason: str = Form(""), fmt: str = Form("")):
        """The reject change for the candidate a comparison judged: `<alias>-next` leaves the eval gateway and its entry becomes
        rejected, with the reason. A change to review and commit; nothing is written here."""
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        vr, vs = verdicts()
        v = next((x for x in vs if x.run_id == run_id), None)
        if v is None:
            return bad(request, u, "There is no comparison with that run id in the verdict records this page reads.", 404)
        rj = reject_view(v, compare_view(v, vs)["label"])
        if not rj["show"]:
            return bad(request, u, "Only a comparison that failed, came out worse or was a tradeoff can be rejected from here.")
        if not rj["offered"]:
            return compare_page(request, u, run_id, error=rj["why"], reason=reason, status_code=400)
        try:
            new_lc, new_inv, notes = ml.reject(rj["alias_next"], reason, today().isoformat(), L.lifecycle, inv)
        except (ml.LifecycleError, nm.NodeError) as ex:
            return compare_page(request, u, run_id, error=str(ex), reason=reason, status_code=400)
        notes = notes + [f"this follows comparison {run_id}; its record stays where it is, as the evidence for the rejection"]
        return _change(request, u, new_lc, new_inv, notes, f"Reject {rj['model']} on {rj['alias_next']}", fmt, {"reason": reason},
                       f"/models/v/{run_id}/reject")

    def hosted_alias(alias):
        """{model, entry} for an alias the gateway routes to a hosted provider, else None (TM-1265: its page carries the countdown)."""
        m = next((g for g in gateway_list() if g.get("model_name") == alias and not alias.endswith(ml.NEXT)), None)
        h = bg.hosted_model(m) if m else ""
        if not h:
            return None
        return {"model": h, "entry": L.lifecycle.by_model(h) or next((e for e in L.lifecycle.catalog if e.source.ref == h), None)}

    def alias_view(alias):
        """(live route, entry, revert) for a live alias, or None. `revert` is {"ok": True} or {"ok": False, "why": text}: the
        LifecycleError revert() raises, asked with a placeholder reason so the reason itself is not what refuses it."""
        live = next((r for r in inv.routes if r.alias == alias and not alias.endswith(ml.NEXT)), None)
        if live is None:
            return None
        try:
            ml.revert(alias, "check", _now().strftime("%Y-%m-%d"), L.lifecycle, inv)
            rv = {"ok": True, "why": ""}
        except (ml.LifecycleError, nm.NodeError) as ex:
            rv = {"ok": False, "why": str(ex)}
        return live, L.lifecycle.by_model(live.model), rv

    def alias_page(request, u, alias, error=None, reason="", status_code=200):
        av = alias_view(alias)
        if av is None:
            h = hosted_alias(alias)
            if h is None:
                return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such live alias.")
            rep = src_report.read()
            r = ib.retire_for(ib.retire_map(rep.data, today()), h["model"], h["entry"].model if h["entry"] else "")
            return render(request, "models_alias.html", u, alias=alias, live=None, e=h["entry"], promo={}, prev=None, revert={"ok": False, "why": ""},
                          error=None, reason="", hosted=h, retire=({**r, "badge": ib.retire_state(r)} if r else None), reading=rep,
                          status_code=status_code)
        live, e, rv = av
        promo = (e.promotion if e else {}) or {}
        return render(request, "models_alias.html", u, alias=alias, live=live, e=e, promo=promo, prev=promo.get("previous"),
                      revert=rv, error=error, reason=reason, status_code=status_code, hosted=None, retire=None, reading=None)

    @app.get("/models/a/{alias}")
    def models_alias(request: Request, alias: str):
        u, deny = admin(request)
        if deny:
            return deny
        return alias_page(request, u, alias)

    @app.post("/models/a/{alias}/revert")
    def models_revert(request: Request, alias: str, csrf: str = Form(""), reason: str = Form(""), fmt: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if alias_view(alias) is None:
            return bad(request, u, "There is no such live alias.", 404)
        try:
            new_lc, new_inv, notes = ml.revert(alias, reason, _now().strftime("%Y-%m-%d"), L.lifecycle, inv)
        except (ml.LifecycleError, nm.NodeError) as ex:
            return alias_page(request, u, alias, error=str(ex), reason=reason, status_code=400)
        return _change(request, u, new_lc, new_inv, notes, f"Revert {alias}", fmt, {"reason": reason}, f"/models/a/{alias}/revert")

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

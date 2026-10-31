# SPDX-License-Identifier: Apache-2.0
"""The /nodes area (REQ-0047). Admin only. Writes nothing: every flow ends at /nodes/change,
which shows the site-values change for the admin to commit (AC-47.8).

  GET  /nodes                 inventory: each node, its health and memory, its routes
  GET  /nodes/add             the node-type catalog
  GET  /nodes/add/<type>      onboarding steps for that type, then a probe or a manual endpoint. For a Mac: enrol it for
                              GitOps (a console checklist, the bootstrap one-liner, then a change) or manage it yourself
  POST /nodes/probe           probe a named host (bounded: app/probe.py), propose endpoints and routes
  GET  /nodes/import          import from the gateway's route list (no network)
  POST /nodes/import          the same, from a pasted model_list
  GET  /nodes/<id>            one node: the models it serves per endpoint with their tunings, planned memory and a memory bar
                              (TM-1299), the builds it holds against the ones the catalog pins and the check that reads them
                              (TM-1296); `?model=&endpoint=&alias=` previews a placement and its fit
  POST /nodes/change          the generated change (also format=yaml as a download); a newly enrolled node's
                              ai-nodes/<id>/ai-node.yaml skeleton comes with it (format=ai-node&ai_node=<id>)
"""
from __future__ import annotations

import datetime
import json
import re

import yaml
from fastapi import Form, Request
from fastapi.responses import PlainTextResponse, Response

from . import deployments as dp
from . import models as mdl
from . import nodes as nm
from .build_checks import BuildChecks
from .probe import Prober, Refused

MAX_DRAFT = 256 * 1024
MAX_PASTE = 256 * 1024


def register(app, s, render, user_of, need_login, forbidden, csrf_ok, src_nodes, prober: Prober, app_version, src_report=None,
             build_checks=None):
    ns = s.nodes
    checks = build_checks if build_checks is not None else BuildChecks(prober)

    def admin(request):
        u = user_of(request)
        if not u:
            return None, need_login(request)
        if not u.is_admin:
            return None, forbidden(request, u)
        return u, None

    def bad(request, u, msg, code=400):
        return render(request, "error.html", u, status_code=code, title="That did not work", message=msg)

    def health_by_id():
        r = src_nodes.read()
        if not r.data:
            return r, {}
        if r.fetched_at is None:
            # Prometheus did not answer THIS time: what `data` holds is the last good answer. Its
            # per-node states must not be shown as current (lab finding D3, 2026-10-07: a node read
            # Healthy for as long as Prometheus stayed down).
            stale = f"no current reading ({r.reason}); last answered {r.age_text()}"
            return r, {x["id"]: dict(x, state="unknown", why=stale,
                                     # a last-good Healthy convergence is as stale as the node's own state
                                     convergence=({"state": "unknown", "why": stale, "interval_s": x["convergence"].get("interval_s")}
                                                  if x.get("convergence") else None),
                                     readiness=({"state": "unknown", "why": stale, "items": []} if x.get("readiness") else None))
                       for x in r.data}
        return r, {x["id"]: x for x in r.data}

    # ------------------------------------------------------------ inventory

    @app.get("/nodes")
    def nodes_index(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        reading, health = health_by_id()
        inv = ns.inventory
        rows = []
        for n in inv.nodes:
            rows.append({"node": n, "health": health.get(n.id), "routes": inv.routes_on(n.id),
                         "fit": nm.fit(n, inv.routes_on(n.id), 0.0)})
        return render(request, "nodes.html", u, rows=rows, reading=reading, probe_on=prober.enabled,
                      catalog=nm.CATALOG)

    @app.get("/nodes/add")
    def nodes_add(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        return render(request, "nodes_add.html", u, catalog=nm.CATALOG, engines=nm.ENGINES)

    @app.get("/nodes/add/{ntype}")
    def nodes_add_type(request: Request, ntype: str, engine: str = "", model: str = "", node_id: str = "", host: str = "",
                       name: str = "", preset: str = "", admin_user: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        kind = nm.CATALOG.get(ntype)
        if kind is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such node type.")
        if engine not in kind["engines"]:
            engine = kind["engines"][0]
        # a model id to fill into the commands; shown as text, and restricted to the
        # characters model ids use so a crafted link cannot plant shell syntax in a step
        model = model if re.match(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$", model or "") else ""
        enroll = _enroll_context(ntype, kind, engine, node_id, host, name, preset, admin_user) if kind["onboarding"] == "mac" else None
        return render(request, "nodes_add_type.html", u, ntype=ntype, kind=kind, engine=engine,
                      eng=nm.ENGINES[engine], engines=nm.ENGINES, probe_on=prober.enabled,
                      sources=list(ns.gateway_sources), src=list(ns.gateway_sources) or ["GATEWAY_SOURCE_CIDR"],
                      allowed=list(ns.probe_allowed), model=model, enroll=enroll)

    def _enroll_context(ntype, kind, engine, node_id, host, name, preset, admin_user):
        """What the "Enroll for GitOps" section shows. The one-liner is built by nm.enroll_command, which refuses (and never
        echoes) a value that could carry shell syntax; the site repository and toolkit ref come from site values only."""
        ai = ns.inventory.ai
        cmd = nm.enroll_command(node_id, host, ai.site_repo, ai.toolkit_ref, admin_user)
        draft, error = "", ""
        if cmd.complete:
            try:
                inv = nm.enroll_inventory(node_id.strip(), host.strip(), name, preset if any(p["id"] == preset for p in kind["presets"]) else "", engine)
                draft = json.dumps(nm.inventory_to_doc(inv))
            except nm.NodeError as e:
                error = str(e)
        return {"cmd": cmd, "draft": draft, "error": error, "converged": engine in nm.CONVERGED_ENGINES,
                "converged_list": ", ".join(nm.ENGINES[e]["name"] for e in nm.CONVERGED_ENGINES),
                "ref_known": bool(ai.toolkit_ref), "repo_known": bool(ai.site_repo),
                "form": {"node_id": node_id[:40], "host": host[:253], "name": name[:80], "preset": preset[:40], "admin_user": admin_user[:32]}}

    # ------------------------------------------------------------ probe (the only outbound request)

    @app.post("/nodes/probe")
    def nodes_probe(request: Request, csrf: str = Form(""), ntype: str = Form("openai-compatible"),
                    host: str = Form(""), name: str = Form(""), node_id: str = Form(""),
                    preset: str = Form(""), memory_gib: str = Form(""), ports: str = Form(""),
                    token: str = Form(""), scheme: str = Form("http")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if ntype not in nm.CATALOG:
            return bad(request, u, "Unknown node type.")
        try:
            extra = [int(p) for p in re.split(r"[,\s]+", ports.strip()) if p] if ports.strip() else []
        except ValueError:
            return bad(request, u, "Ports must be numbers, separated by commas.")
        try:
            result = prober.probe(host, ntype, extra, token=token, scheme=scheme)
        except Refused as e:
            return render(request, "nodes_probe.html", u, refused=str(e), result=None, draft=None,
                          ntype=ntype, host=host[:253])
        try:
            draft = _draft_from_probe(result, ntype, name, node_id, preset, memory_gib)
        except nm.NodeError as e:
            return bad(request, u, str(e))
        n = draft.nodes[0]
        return render(request, "nodes_probe.html", u, refused=None, result=result, ntype=ntype, host=result.host,
                      node=n, draft=json.dumps(nm.inventory_to_doc(draft)), engines=nm.ENGINES,
                      draft_routes=nm.inventory_to_doc(draft)["routes"],
                      size_src={m.id: m.size_source for f in result.found for m in f.models},
                      existing=ns.inventory.aliases(), auth_hint=bool(token))

    # ------------------------------------------------------------ import from the gateway (offline)

    @app.get("/nodes/import")
    def nodes_import(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        if ns.gateway_model_list:
            return _import_page(request, u, list(ns.gateway_model_list), "the gateway route list this UI was configured with")
        return render(request, "nodes_import.html", u, proposal=None, error=None)

    @app.post("/nodes/import")
    def nodes_import_paste(request: Request, csrf: str = Form(""), pasted: str = Form("")):
        u, deny = admin(request)
        if deny:
            return deny
        if not csrf_ok(u, csrf):
            return PlainTextResponse("bad request", status_code=400)
        if len(pasted) > MAX_PASTE:
            return render(request, "nodes_import.html", u, proposal=None, error="That is larger than 256 KB; paste only the model_list.")
        try:
            doc = yaml.safe_load(pasted)
        except (yaml.YAMLError, ValueError):
            return render(request, "nodes_import.html", u, proposal=None, error="That is not valid YAML.")
        ml = _find_model_list(doc)
        if ml is None:
            return render(request, "nodes_import.html", u, proposal=None,
                          error="No model_list found. Paste the gateway's config.yaml, its ConfigMap, or the model_list itself.")
        return _import_page(request, u, ml, "the list you pasted")

    def _import_page(request, u, ml, origin):
        try:
            res = nm.import_model_list(ml)
        except (nm.NodeError, ValueError, TypeError, AttributeError) as e:
            return render(request, "nodes_import.html", u, proposal=None, error=str(e))
        known = {n.address: n.id for n in ns.inventory.nodes}
        names = {n.address: n.name for n in ns.inventory.nodes}
        return render(request, "nodes_import.html", u, proposal=res, origin=origin, error=None,
                      draft=json.dumps(nm.inventory_to_doc(res.inventory)), catalog=nm.CATALOG,
                      engines=nm.ENGINES, known=known, names=names, existing=ns.inventory.aliases())

    # ------------------------------------------------------------ one node, and placing a model on it

    @app.get("/nodes/{nid}")
    def node_detail(request: Request, nid: str, model: str = "", endpoint: str = "", alias: str = "",
                    kind: str = "chat", size: str = ""):
        u, deny = admin(request)
        if deny:
            return deny
        inv = ns.inventory
        n = inv.node(nid)
        if n is None:
            return render(request, "error.html", u, status_code=404, title="Not found", message="There is no such node.")
        reading, health = health_by_id()
        preview = None
        if model or alias:
            preview = _placement_preview(n, inv, model, endpoint, alias, kind, size)
        return render(request, "node_detail.html", u, node=n, kind_=n.kind, health=health.get(n.id), reading=reading,
                      routes=inv.routes_on(n.id), fit=nm.fit(n, inv.routes_on(n.id), 0.0), preview=preview,
                      models=_models_on(n, inv, health.get(n.id)), builds=_builds_on(n, inv),
                      engines=nm.ENGINES, form={"model": model, "endpoint": endpoint, "alias": alias, "kind": kind, "size": size})

    def _models_on(n, inv, node_health):
        """Per endpoint, the deployments it serves, and the node's memory bar (TM-1299). The memory arithmetic is fit v2's,
        with the inputs the Recommend page gives it, so this page and the fit pages agree."""
        rep = src_report.read().data if src_report is not None else None
        fi = dp.fit_inputs_for(s.lifecycle, rep)
        deps = dp.deployment_rows(inv, s.lifecycle.lifecycle, fi, node=n.id)
        usable = dp.usable_for_node(n, fi)
        states = {c["what"]: c for c in (node_health or {}).get("checks", [])}
        groups = []
        for e in n.endpoints:
            c = states.get(f"{e.engine} on :{e.port}")
            groups.append({"endpoint": e, "engine": nm.ENGINES.get(e.engine, {}).get("name", e.engine),
                           "state": c["state"] if c else "unknown", "why": c["why"] if c else "no reading",
                           "deployments": [d for d in deps if d.endpoint.id == e.id]})
        mem = (node_health or {}).get("memory")
        return {"groups": groups, "deployments": deps, "bar": dp.memory_bar(n, deps, usable), "notes": fi["notes"],
                "in_use_gib": mem["used_gib"] if mem and mem.get("used_gib") is not None else None}

    def _builds_on(n, inv):
        """The build check for this node's pinned routes (TM-0934, moved here from /models by TM-1296): pinned against the build
        the node holds, per route, the findings, and when it was last read."""
        rows = [x for x in checks.rows(s.lifecycle.lifecycle, inv) if x.node == n.id]
        return {"rows": rows, "findings": mdl.drift_findings(rows), "probe_on": checks.probe_on, "checked_at": checks.at}

    def _placement_preview(n, inv, model, endpoint, alias, kind, size):
        errors = []
        ep = n.endpoint(endpoint)
        if ep is None:
            errors.append("Choose one of this node's endpoints.")
        if not nm.ALIAS_RE.match(alias or ""):
            errors.append("The alias must start with a letter or digit and use only letters, digits and . _ : / -")
        elif alias in inv.aliases():
            errors.append(f"The gateway already has a route called {alias}. Pick another alias, or edit that route in values.")
        if kind not in nm.KINDS:
            errors.append("Choose chat, embedding or rerank.")
        if not model or len(model) > 200 or any(c.isspace() for c in model):
            errors.append("Enter the model id the engine knows (no spaces).")
        if ep is not None and kind in nm.KINDS:
            try:
                nm.provider_for(ep.engine, kind)
            except nm.NodeError as e:
                errors.append(str(e))
        size_gib, size_src = None, ""
        if size.strip():
            try:
                size_gib, size_src = nm.planning_size(nm._pos(size, "size")), "you entered it"
            except nm.NodeError:
                errors.append("Size must be a positive number of GiB.")
        elif model:
            size_gib = nm.estimate_size_gib(model)
            size_src = "estimated from the model's name" if size_gib else ""
        f = nm.fit(n, inv.routes_on(n.id), size_gib, ep.engine if ep else "")
        draft = None
        entry = None
        if not errors:
            add = nm.Inventory([n], [nm.Route(alias, n.id, ep.id, model, kind, "", nm.default_params(ep.engine), {}, size_gib)])
            draft = json.dumps(nm.inventory_to_doc(add))
            entry = nm.render_model_list(add, "all")[0]
        return {"errors": errors, "fit": f, "size_src": size_src, "draft": draft,
                "entry": yaml.safe_dump(entry, sort_keys=False) if entry else ""}

    # ------------------------------------------------------------ the change

    @app.post("/nodes/change")
    async def nodes_change(request: Request):
        u, deny = admin(request)
        if deny:
            return deny
        form = await request.form()
        if not csrf_ok(u, str(form.get("csrf", ""))):
            return PlainTextResponse("bad request", status_code=400)
        raw = str(form.get("draft", ""))
        if not raw or len(raw) > MAX_DRAFT:
            return bad(request, u, "Nothing to change.")
        try:
            add_doc = json.loads(raw)
            if not isinstance(add_doc, dict) or not isinstance(add_doc.get("nodes", []), list) \
                    or not isinstance(add_doc.get("routes", []), list):
                raise nm.NodeError("not a draft")
            _apply_edits(add_doc, form)
            add = nm.parse_inventory(add_doc)
            # An alias may be re-stated unchanged (a re-import). Pointing an existing alias at another node or
            # another model is a clash: that is a promotion, and it goes through /models (review finding).
            base = {x.alias: x for x in ns.inventory.routes}
            clashes = sorted(r.alias for r in add.routes if r.alias in base
                             and (base[r.alias].node != r.node or base[r.alias].model != r.model))
            if clashes:
                raise nm.NodeError("these aliases already route somewhere else, or to another model: " + ", ".join(clashes))
            merged = nm.merge(ns.inventory, add)
            from . import models as ml
            gate = ml.check_promotions(s.lifecycle.lifecycle, merged) if s.lifecycle else []
            if gate:
                raise nm.NodeError("it would fail the promotion gate: " + "; ".join(gate))
        except (ValueError, TypeError, KeyError, AttributeError, nm.NodeError) as e:
            return bad(request, u, f"The change is not valid: {e}")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        header = (f"Generated by Tockmox UI {app_version} for {u.name} at {stamp}.\n"
                  f"Replaces the whole inferenceNodes block in {ns.values_file}. Review it, then commit it to the site repo.")
        text = nm.change_yaml(merged, header, ns.raw)
        if form.get("format") == "yaml":
            return Response(text, media_type="application/yaml",
                            headers={"Content-Disposition": 'attachment; filename="inference-nodes.values.yaml"'})
        # A node enrolled by THIS change gets an ai-nodes/<id>/ai-node.yaml skeleton beside the values. One already
        # enrolled does not: that file exists in the site repo, hand-edited, and a regenerated skeleton would invite
        # overwriting it.
        enrolled_now = [n for n in add.nodes if n.enrolled and not (ns.inventory.node(n.id) and ns.inventory.node(n.id).enrolled)]
        ai_files, ai_missing = _ai_node_files(enrolled_now, merged)
        if form.get("format") == "ai-node":
            f = next((x for x in ai_files if x["id"] == str(form.get("ai_node", ""))), None)
            if f is None:
                return bad(request, u, "That change enrols no such node, so there is no ai-node.yaml for it.")
            return Response(f["text"], media_type="application/yaml",
                            headers={"Content-Disposition": f'attachment; filename="ai-node.{f["id"]}.yaml"'})
        before = {n.id for n in ns.inventory.nodes}
        before_r = {r.alias for r in ns.inventory.routes}
        summary = {"new_nodes": [n for n in add.nodes if n.id not in before],
                   "enrolled": enrolled_now,
                   "changed_nodes": [n for n in add.nodes if n.id in before],
                   "new_routes": [r for r in add.routes if r.alias not in before_r],
                   "changed_routes": [r for r in add.routes if r.alias in before_r]}
        derived = nm.Inventory(merged.nodes, [r for r in merged.routes if r.alias in {x.alias for x in add.routes}])
        return render(request, "nodes_change.html", u, text=text, summary=summary,
                      model_list=nm.model_list_yaml(derived) if nm.gateway_routes(derived) else "",
                      eval_list=nm.model_list_yaml(derived, "eval") if nm.gateway_routes(derived, "eval") else "",
                      draft=json.dumps(nm.inventory_to_doc(add)), values_file=ns.values_file,
                      secrets=sorted({e.auth_secret for n in add.nodes for e in n.endpoints if e.auth_secret}),
                      ai_files=ai_files, ai_missing=ai_missing, ai_admin_cidrs_unset=not ns.inventory.ai.admin_cidrs)

    def _ai_node_files(enrolled, merged):
        """[{id, path, text, command}] for each node enrolled by the change. The skeleton comes from app/ai_nodes.py (the
        renderer); the second return is True when that module is not part of this build."""
        if not enrolled:
            return [], False
        try:
            from .ai_nodes import skeleton_ai_node_yaml
        except ImportError:
            return [], True
        ai = ns.inventory.ai
        out = []
        for n in enrolled:
            node = merged.node(n.id) or n
            text = skeleton_ai_node_yaml(node.id, node.type, node.memory_gib(), list(ai.admin_cidrs))
            out.append({"id": node.id, "path": f"ai-nodes/{node.id}/ai-node.yaml", "text": text,
                        "command": nm.enroll_command(node.id, node.address, ai.site_repo, ai.toolkit_ref).text})
        return out, False


# ---------------------------------------------------------------- helpers (pure)

def _find_model_list(doc):
    if isinstance(doc, list):
        return doc
    if not isinstance(doc, dict):
        return None
    if isinstance(doc.get("model_list"), list):
        return doc["model_list"]
    if doc.get("kind") == "ConfigMap":
        data = doc.get("data")
        for v in (data.values() if isinstance(data, dict) else []):
            if not isinstance(v, str):
                continue
            try:
                inner = yaml.safe_load(v)
            except (yaml.YAMLError, ValueError):
                continue
            found = _find_model_list(inner)
            if found is not None:
                return found
    return None


def _draft_from_probe(result, ntype, name, node_id, preset, memory_gib):
    kind = nm.CATALOG[ntype]
    host = result.host
    nid = node_id.strip() or nm._slug(name or host)
    if not nm.ID_RE.match(nid) or nid in nm.RESERVED_NODE_IDS:
        raise nm.NodeError(f"node id {nid!r}: lowercase letters, digits and dashes, not one of {sorted(nm.RESERVED_NODE_IDS)}")
    hw = {}
    p = next((x for x in kind["presets"] if x["id"] == preset), None)
    if p:
        hw["chip"] = nm.Fact(p["chip"], "preset")
        hw["memory_gib"] = nm.Fact(p["memory_gib"], "preset")
    if memory_gib.strip():
        hw["memory_gib"] = nm.Fact(nm._pos(memory_gib, "memory"), "operator")
    n = nm.Node(nid, (name.strip() or host)[:80], ntype, host, [], hw, dict(kind["metrics"]))
    routes = []
    used = set()
    for f in result.found:
        eid = f"{f.engine}-{f.port}"
        n.endpoints.append(nm.Endpoint(eid, f.suggested or f.engine, f.url))
        for m in f.models:
            alias = _suggest_alias(m.id, used)
            used.add(alias)
            kind_ = "embedding" if "embed" in m.id.lower() else ("rerank" if "rerank" in m.id.lower() else "chat")
            try:
                nm.provider_for(f.engine, kind_)
            except nm.NodeError:
                kind_ = "chat"
            routes.append(nm.Route(alias, nid, eid, m.id, kind_, "", nm.default_params(f.engine), {}, m.size_gib))
    return nm.Inventory([n], routes)


def _suggest_alias(model_id: str, used: set) -> str:
    base = re.sub(r"\.gguf$", "", model_id.split("/")[-1].split(":")[0].lower())
    tag = model_id.split(":")[1].lower() if ":" in model_id.split("/")[-1] else ""
    a = re.sub(r"[^a-z0-9.-]+", "-", ("local-" + base + ("-" + tag if tag and tag != "latest" else ""))).strip("-")[:60]
    out, i = a, 2
    while out in used:
        out, i = f"{a}-{i}", i + 1
    return out


def _apply_edits(doc: dict, form):
    """Apply the admin's choices on a proposal page to the draft before it is validated."""
    for i, n in enumerate(doc.get("nodes") or []):
        old = n["id"]
        for key, field in (("name", "name"), ("type", "type"), ("id", "id")):
            v = form.get(f"node.{i}.{field}")
            if v is not None and str(v).strip():
                n[key] = str(v).strip()
        if n["id"] != old:
            for r in doc.get("routes") or []:
                if r.get("node") == old:
                    r["node"] = n["id"]
        if n.get("type") in nm.CATALOG and not n.get("metrics") and form.get(f"node.{i}.metrics") == "default":
            n["metrics"] = dict(nm.CATALOG[n["type"]]["metrics"])
        if form.get(f"node.{i}.metrics.present"):
            # the admin says which exporters the node actually runs; an expected exporter that is not
            # there reads Unknown for ever (lab finding: DCGM on a CPU-only Linux node)
            n["metrics"] = {k: v for k, v in (n.get("metrics") or {}).items() if form.get(f"node.{i}.metric.{k}")}
        for j, e in enumerate(n.get("endpoints") or []):
            eng = form.get(f"node.{i}.ep.{j}.engine")
            if eng and str(eng) in nm.ENGINES:
                e["engine"] = str(eng)
            sec = str(form.get(f"node.{i}.ep.{j}.secret", "") or "").strip()
            if sec:
                e["auth"] = {"secretRef": sec}
    keep = []
    for k, r in enumerate(doc.get("routes") or []):
        if form.get(f"route.{k}.present") and not form.get(f"route.{k}.include"):
            continue
        a = form.get(f"route.{k}.alias")
        if a is not None and str(a).strip():
            r["alias"] = str(a).strip()
        kd = form.get(f"route.{k}.kind")
        if kd and str(kd) in nm.KINDS:
            r["kind"] = str(kd)
        keep.append(r)
    doc["routes"] = keep


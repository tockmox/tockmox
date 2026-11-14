#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generates the Tockmox / Overview board (uid tockmox-overview): the L0 NOC page.

AI first (Jeff, 2026-11-13), then capacity, then whether the platform is working; no variables beyond the
data source. Every tile follows
the house rule from the Tockmox UI: ABSENCE IS NOT GREEN. A query that can return nothing is
written to return -1 instead (or carries a null mapping), and -1/null renders grey with a word.

Generated, not hand-edited (Grafana's own "high maturity" guidance): change this file, run it,
commit both.

    python3 tools/gen-dashboard-overview.py            write charts/tockmox-observability/dashboards/overview.json
    python3 tools/gen-dashboard-overview.py --check    exit 1 if the committed JSON is not what this file generates

Every query on this board reads a metric family a stock install emits once the component it watches
has done anything (the AI row stays grey until the first gated request: "no gated traffic", never 0).
Site-only signals (a vulnerability scanner, a site's model-port rules) belong on a site board.
"""
import json
import os
import sys

DS = {"type": "prometheus", "uid": "${datasource}"}
GREY, GREEN, AMBER, RED, BLUE = "#808080", "green", "orange", "red", "#6FB3DD"
_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def t(expr, legend="", ref="A", instant=True):
    d = {"datasource": DS, "expr": expr, "refId": ref, "legendFormat": legend}
    if instant:
        d["instant"] = True
        d["range"] = False
    return d


def steps(*pairs):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in pairs]}


def unknown_map(text="no data", minus_one=True):
    m = [{"type": "special", "options": {"match": "null", "result": {"text": text, "color": GREY, "index": 0}}},
         {"type": "special", "options": {"match": "nan", "result": {"text": text, "color": GREY, "index": 2}}}]
    if minus_one:
        m.append({"type": "value", "options": {"-1": {"text": text, "color": GREY, "index": 1}}})
    return m


def stat(title, targets, x, y, w=3, h=4, unit="none", thr=None, mappings=None, desc="", decimals=None,
         link=None, text_mode="value", color_mode="background", graph="none"):
    p = {"id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS,
         "gridPos": {"x": x, "y": y, "w": w, "h": h}, "targets": targets,
         "fieldConfig": {"defaults": {"unit": unit, "thresholds": thr or steps((None, GREY)),
                                      "mappings": mappings or [], "color": {"mode": "thresholds"},
                                      "noValue": "no data"}, "overrides": []},
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": color_mode, "graphMode": graph, "textMode": text_mode,
                     "justifyMode": "center", "orientation": "auto", "wideLayout": True}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    if link:
        p["links"] = [{"title": link[0], "url": f"/d/{link[1]}?${{__url_time_range}}"}]
    return p


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


panels = []
y = 0
HERE = os.path.dirname(os.path.abspath(__file__))
DASH = os.path.join(HERE, "..", "charts", "tockmox-observability", "dashboards")
# The brand header every product board carries (REQ-0006), taken from a sibling board so there is
# one copy of it, not two that drift.
with open(os.path.join(DASH, "traefik.json"), encoding="utf-8") as fh:
    header = json.load(fh)["panels"][0]
assert header.get("type") == "text" and "tockmox-logo" in header["options"]["content"], "traefik.json no longer opens with the brand header"
panels.append({"id": nid(), "type": "text", "title": "", "gridPos": {"x": 0, "y": y, "w": 24, "h": 2},
               "options": dict(header["options"]), "transparent": header.get("transparent", False)})
y += 2
panels.append({"id": nid(), "type": "text", "title": "", "gridPos": {"x": 0, "y": y, "w": 24, "h": 2}, "transparent": True,
               "options": {"mode": "markdown", "content":
                           "**The platform at a glance, AI first.** Grey means *no data*, which is never healthy: the source did not answer or is not installed. "
                           "A tile with a link icon opens the board that explains it."}})
y += 2

# Absence is not green: these alert counts exist only while Alertmanager's always-firing Watchdog does,
# so a dead alert pipeline reads grey, never a green zero.
HEARTBEAT = 'count(ALERTS{alertname="Watchdog",alertstate="firing"})'
CRIT = 'count(ALERTS{alertstate="firing",severity="critical"})'
WARN = 'count(ALERTS{alertstate="firing",severity="warning"})'

# ---------------------------------------------------------------- AI (leads: it is what a user opens Tockmox for)
panels.append(row("AI: can it serve, where did it run, what did it cost", y)); y += 1
# Top row: "can I use it right now", plus the two control checks, plus one Platform tile so a platform
# problem is visible without scrolling.
panels.append(stat("Platform", [t(f'(((({CRIT} > 0) + 1000) or ({WARN} or on() vector(0))) and on() ({HEARTBEAT} > 0)) or on() vector(-1)')],
                   0, y, w=4, h=5, thr=steps((None, GREY), (0, GREEN), (1, AMBER), (1000, RED)),
                   mappings=[{"type": "value", "options": {"-1": {"text": "UNKNOWN: alert pipeline silent", "color": GREY, "index": 0},
                                                           "0": {"text": "OK", "color": GREEN, "index": 1}}},
                             {"type": "range", "options": {"from": 1, "to": 999, "result": {"text": "warnings: ${__value.raw}", "color": AMBER, "index": 2}}},
                             {"type": "range", "options": {"from": 1000, "to": 1e9, "result": {"text": "CRITICAL firing", "color": RED, "index": 3}}}],
                   desc="The platform verdict. OK needs two facts: no critical or warning alert firing AND Alertmanager's always-firing Watchdog present. "
                        "Without the heartbeat an empty alert list proves nothing, so the tile reads UNKNOWN. The detail is in Is it working? below.",
                   link=("Alert delivery", "tockmox-alert-delivery")))
panels.append(stat("Local engines down", [t("count(tockmox_ai_node_engine_healthy == 0) or (count(tockmox_ai_node_engine_healthy) * 0)")],
                   4, y, w=3, h=5, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no AI nodes enrolled", minus_one=False),
                   desc="Inference engines on enrolled AI nodes that report unhealthy. Shows local capacity being down before a request fails on it. Grey: no AI node is enrolled."))
panels.append(stat("Gate errors (24h)", [t('sum(increase(tockmox_gate_served_total{status="error"}[24h])) / sum(increase(tockmox_gate_served_total[24h]))')],
                   7, y, w=3, h=5, unit="percentunit", decimals=1, thr=steps((None, GREEN), (0.02, AMBER), (0.1, RED)),
                   mappings=unknown_map("no gated traffic", minus_one=False),
                   desc="Share of requests the policy gate could not serve, local and frontier together. The gate sees failures LiteLLM's own counter does not."))
panels.append(stat("Gateway errors (24h)", [t('(sum(increase(litellm_proxy_total_requests_metric_total{status_code!~"2.."}[24h])) or on() vector(0)) / sum(increase(litellm_proxy_total_requests_metric_total[24h]))')],
                   10, y, w=3, h=5, unit="percentunit", decimals=1, thr=steps((None, GREEN), (0.02, AMBER), (0.1, RED)),
                   mappings=unknown_map("no traffic", minus_one=False),
                   desc="Non-2xx share of LiteLLM requests over a day. A day, not 15 minutes: a site with a few requests an hour would otherwise read 'no traffic' most of the time."))
panels.append(stat("Gateway p95 (24h)", [t("histogram_quantile(0.95, sum by (le) (rate(litellm_request_total_latency_metric_bucket[24h])))")],
                   13, y, w=3, h=5, unit="s", decimals=1, thr=steps((None, GREEN), (120, AMBER), (300, RED)), mappings=unknown_map("no traffic", minus_one=False),
                   desc="95th percentile of a whole request through the gateway over a day, long generations included, which is why the bands are minutes, not seconds."))
panels.append(stat("Restricted served off-site (24h)", [t('sum(increase(tockmox_gate_served_total{request_class="restricted",endpoint_tier="external",status="ok"}[24h])) or (count(tockmox_gate_served_total) * 0)')],
                   16, y, w=4, h=5, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no gated traffic", minus_one=False),
                   desc="Requests the gate classed restricted that were served by a frontier model. The policy says this is zero; anything else is a control that failed."))
panels.append(stat("AI nodes unverified", [t("count(tockmox_ai_node_converge_signature_ok == 0) or (count(tockmox_ai_node_converge_signature_ok) * 0)")],
                   20, y, w=4, h=5, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no AI nodes enrolled", minus_one=False),
                   desc="Enrolled inference nodes whose last converge ran a commit whose signature did not verify. Grey: no AI node is enrolled."))
y += 5
LOCAL = 'sum(increase(tockmox_gate_served_total{endpoint_tier="local",status="ok"}[24h])) / sum(increase(tockmox_gate_served_total{endpoint_tier=~"local|external",status="ok"}[24h]))'
panels.append(stat("Served locally, last 24h", [t(LOCAL)], 0, y, w=4, h=6, unit="percentunit", decimals=0, color_mode="value",
                   thr=steps((None, BLUE)), mappings=unknown_map("no gated traffic", minus_one=False),
                   desc="Share of AI requests the policy gate served from a local model (tockmox_gate_served_total, endpoint_tier). The gate's tier is the authority: LiteLLM's api_provider says 'openai' for a local OpenAI-compatible server, so it cannot tell local from frontier. No threshold: the right share is a site decision."))
panels.append({"id": nid(), "type": "timeseries", "title": "AI requests served, by tier", "datasource": DS,
               "gridPos": {"x": 4, "y": y, "w": 6, "h": 6},
               "targets": [{"datasource": DS, "expr": 'sum by (endpoint_tier) (increase(tockmox_gate_served_total{endpoint_tier=~"local|external",status="ok"}[1h]))',
                            "legendFormat": "{{endpoint_tier}}", "refId": "A", "interval": "1h"}],
               "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "bars", "stacking": {"mode": "normal"}, "fillOpacity": 70, "barAlignment": 0}},
                               "overrides": [{"matcher": {"id": "byName", "options": "local"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "green"}}, {"id": "displayName", "value": "local"}]},
                                             {"matcher": {"id": "byName", "options": "external"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}, {"id": "displayName", "value": "frontier"}]}]},
               "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}})
panels.append(stat("Frontier spend", [t("sum(increase(litellm_spend_metric_total[24h]))", "last 24h", "A"),
                                      t("sum(increase(litellm_spend_metric_total[30d]))", "last 30 days", "B")],
                   10, y, w=4, h=6, unit="currencyUSD", decimals=2, color_mode="value", thr=steps((None, BLUE)),
                   mappings=unknown_map("no gateway spend metric", minus_one=False), text_mode="value_and_name",
                   desc="LiteLLM's computed cost (USD by its price map; not an invoice). Counts what went through the gateway only: a subscription used directly is not here. Local models cost 0 here unless a notional price is set."))
panels.append({"id": nid(), "type": "bargauge", "title": "Frontier spend by model, last 7 days", "datasource": DS,
               "gridPos": {"x": 14, "y": y, "w": 6, "h": 6},
               "targets": [t('sort_desc(sum by (model) (increase(litellm_spend_metric_total[7d])) > 0)', "{{model}}")],
               "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "color": {"mode": "fixed", "fixedColor": "orange"}, "min": 0}},
               "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True, "reduceOptions": {"calcs": ["lastNotNull"], "values": True}}})
panels.append(stat("Least budget left on a key", [t("min(litellm_remaining_api_key_budget_metric / litellm_api_key_max_budget_metric)")],
                   20, y, w=4, h=6, unit="percentunit", decimals=0, thr=steps((None, RED), (0.05, AMBER), (0.2, GREEN)), mappings=unknown_map("no key budgets set", minus_one=False),
                   desc="The tightest key's remaining budget. LiteLLM reports a key only while it holds it in memory, so a key that has been idle since a restart is not counted here."))
y += 6

# ---------------------------------------------------------------- capacity
panels.append(row("Capacity", y)); y += 1
cap = [
    ("Busiest node, memory", "max(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)", (0.8, 0.9), None),
    ("Busiest node, CPU (1h)", 'max(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1h])))', (0.8, 0.95), None),
    ("Fullest volume", "max(1 - kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes)", (0.8, 0.9), ("Storage contract", "tockmox-storage-contract")),
    ("Longhorn storage used", "sum(longhorn_node_storage_usage_bytes) / sum(longhorn_node_storage_capacity_bytes)", (0.7, 0.85), ("Storage contract", "tockmox-storage-contract")),
]
x = 0
for title, q, (w_, c_), link in cap:
    panels.append(stat(title, [t(q)], x, y, w=6, unit="percentunit", decimals=0, color_mode="value", graph="area",
                       thr=steps((None, GREEN), (w_, AMBER), (c_, RED)), mappings=unknown_map(minus_one=False), link=link))
    x += 6
y += 4

# ---------------------------------------------------------------- is it working
panels.append(row("Is it working?", y)); y += 1
panels.append(stat("Alerts firing", [t(f"{CRIT} or ({HEARTBEAT} * 0)", "critical", "A"),
                                     t(f"{WARN} or ({HEARTBEAT} * 0)", "warning", "B")],
                   0, y, thr=steps((None, GREEN), (1, AMBER)), mappings=unknown_map("alert pipeline silent", minus_one=False),
                   text_mode="value_and_name",
                   desc="Critical and warning alerts. Zero is shown only while Alertmanager's Watchdog fires; without it the tile is grey, because an empty list proves nothing.",
                   link=("Alert delivery", "tockmox-alert-delivery")))
panels.append(stat("GitOps not synced",
                   [t('count(argocd_app_info unless argocd_app_info{sync_status="Synced",health_status="Healthy"}) or (count(argocd_app_info) * 0) or on() vector(-1)')],
                   3, y, thr=steps((None, GREY), (0, GREEN), (1, AMBER)), mappings=unknown_map("no Argo CD metrics"),
                   desc="Argo CD applications that are out of sync or not healthy. Grey: Argo CD metrics are not scraped (apps.argocdMonitoring), which is not the same as all synced.",
                   link=("Argo CD", "tockmox-argocd")))
panels.append(stat("Targets down", [t("count(up == 0) or (count(up) * 0)")], 6, y,
                   thr=steps((None, GREY), (0, GREEN), (1, RED)), mappings=unknown_map(),
                   desc="Prometheus targets that stopped answering. A target that was never configured is not counted; this is the 'it was there and went away' signal."))
panels.append(stat("Endpoints up", [t("sum(probe_success) / count(probe_success)")], 9, y, unit="percentunit",
                   thr=steps((None, RED), (0.9, AMBER), (0.999, GREEN)), mappings=unknown_map("no probes"), decimals=0,
                   desc="Blackbox probes of every console: the user's view of 'is it up'. Grey: no probes configured.",
                   link=("Traefik", "tockmox-traefik")))
panels.append(stat("Nodes not Ready", [t('count(kube_node_status_condition{condition="Ready",status="true"} == 0) or (count(kube_node_info) * 0) or on() vector(-1)')],
                   12, y, thr=steps((None, GREY), (0, GREEN), (1, RED)), mappings=unknown_map("no node metrics"),
                   desc="Kubernetes nodes whose Ready condition is false."))
# The STALEST drill, not the newest: one fresh drill must not hide another that stopped passing.
# Drill CronJobs are named *-drill or *-drill-<suffix>; a rehearsal is not a drill.
DRILL = 'kube_cronjob_status_last_successful_time{cronjob=~".*-drill(-[a-z0-9]+)?",cronjob!~".*rehearsal.*"}'
panels.append(stat("Stalest restore drill", [t(f"(time() - min({DRILL})) / 86400")],
                   15, y, unit="d", decimals=1, thr=steps((None, GREEN), (8, AMBER), (15, RED)), mappings=unknown_map("no drill has passed"),
                   desc="Backups are only proven by a restore. Days since the drill that passed LONGEST ago (CronJobs named *-drill). "
                        "Not seen here: a drill that has never passed, and drills run as Argo CronWorkflows until they emit a success metric.",
                   link=("Backup and restore proof", "tockmox-backup-proof")))
panels.append(stat("Next cert expiry", [t("(min(certmanager_certificate_expiration_timestamp_seconds) - time()) / 86400")],
                   18, y, unit="d", decimals=0, thr=steps((None, RED), (7, AMBER), (21, GREEN)),
                   mappings=unknown_map("no certificates", minus_one=False), link=("cert-manager", "tockmox-cert-manager"),
                   desc="Days until the soonest cert-manager certificate expires."))
panels.append(stat("Certs not ready", [t('count(certmanager_certificate_ready_status{condition="True"} == 0) or (count(certmanager_certificate_ready_status) * 0)')],
                   21, y, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no certificates", minus_one=False),
                   desc="cert-manager Certificates whose Ready condition is false: the TLS a console is about to serve wrong or not at all.",
                   link=("cert-manager", "tockmox-cert-manager")))
y += 4

# ---------------------------------------------------------------- active alerts
# Fixed columns, whatever labels a rule carries: severity, alert, namespace, and how long it has fired
# (ALERTS_FOR_STATE's value is the time it went active). Info and none severities stay off, as on the counts.
panels.append({"id": nid(), "type": "table", "title": "Active alerts", "datasource": DS,
               "gridPos": {"x": 0, "y": y, "w": 24, "h": 6},
               "targets": [{"datasource": DS, "refId": "A", "instant": True, "format": "table",
                            "expr": '1000 * (ALERTS_FOR_STATE{alertname!~"Watchdog|InfoInhibitor",severity=~"critical|warning"} '
                                    'and ignoring(alertstate) ALERTS{alertstate="firing"})'}],
               "transformations": [{"id": "filterFieldsByName", "options": {"include": {"names": ["severity", "alertname", "namespace", "Value"]}}},
                                   {"id": "organize", "options": {"excludeByName": {},
                                                                  "indexByName": {"severity": 0, "alertname": 1, "namespace": 2, "Value": 3},
                                                                  "renameByName": {"alertname": "alert", "Value": "firing since"}}},
                                   {"id": "sortBy", "options": {"sort": [{"field": "firing since", "desc": False}]}}],
               "fieldConfig": {"defaults": {"custom": {"align": "auto"}},
                               "overrides": [{"matcher": {"id": "byName", "options": "firing since"},
                                              "properties": [{"id": "unit", "value": "dateTimeFromNow"}, {"id": "custom.width", "value": 180}]},
                                             {"matcher": {"id": "byName", "options": "severity"}, "properties": [{"id": "custom.width", "value": 110}]}]},
               "options": {"showHeader": True, "footer": {"show": False}}})

board = {
    "uid": "tockmox-overview", "title": "Tockmox / Overview",
    "description": "L0: the platform at a glance, AI first: can the AI serve, where it ran and what it cost, then capacity, then whether the platform is working. A tile with a link icon opens its board.",
    "tags": ["tockmox", "product", "tier-l0", "noc"],
    "editable": False, "graphTooltip": 1, "refresh": "1m", "schemaVersion": 39,
    "time": {"from": "now-24h", "to": "now"},
    "links": [{"asDropdown": True, "icon": "external link", "includeVars": False, "keepTime": True, "tags": ["tockmox"],
               "targetBlank": False, "title": "Tockmox dashboards", "type": "dashboards"},
              {"asDropdown": True, "icon": "external link", "includeVars": False, "keepTime": True, "tags": ["site"],
               "targetBlank": False, "title": "Site dashboards", "type": "dashboards"}],
    "templating": {"list": [{"current": {"text": "Prometheus", "value": "Prometheus"}, "hide": 0, "label": "Data source",
                             "name": "datasource", "query": "prometheus", "type": "datasource"}]},
    "panels": panels,
}
OUT = os.path.join(DASH, "overview.json")
text = json.dumps(board, indent=2) + "\n"
if "--check" in sys.argv:
    with open(OUT, encoding="utf-8") as fh:
        same = fh.read() == text
    print("overview.json is " + ("current" if same else "STALE: run tools/gen-dashboard-overview.py"))
    sys.exit(0 if same else 1)
with open(OUT, "w", encoding="utf-8") as fh:
    fh.write(text)
print("wrote", os.path.relpath(OUT))

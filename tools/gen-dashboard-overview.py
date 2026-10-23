#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generates the Tockmox / Overview board (uid tockmox-overview): the L0 NOC page.

One screen, no scroll on a 1080p kiosk, no variables beyond the data source. Every tile follows
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
         link=None, text_mode="value_and_name", color_mode="background", graph="none"):
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
panels.append({"id": nid(), "type": "text", "title": "", "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "transparent": True,
               "options": {"mode": "markdown", "content":
                           "**The platform at a glance.** Grey means *no data*, which is never healthy: the source did not answer or is not installed. Each tile links to its board."}})
y += 1

# ---------------------------------------------------------------- is it working
panels.append(row("Is it working?", y)); y += 1
panels.append(stat("Platform verdict", [t('((count(ALERTS{alertstate="firing",severity="critical"}) or on() vector(0)) '
                                          'and on() (count(ALERTS{alertname="Watchdog",alertstate="firing"}) > 0)) or on() vector(-1)')],
                   0, y, w=4, h=5, thr=steps((None, GREY), (0, GREEN), (1, RED)),
                   mappings=[{"type": "value", "options": {"-1": {"text": "UNKNOWN: alert pipeline silent", "color": GREY, "index": 0},
                                                           "0": {"text": "OK", "color": GREEN, "index": 1}}},
                             {"type": "range", "options": {"from": 1, "to": 1e9, "result": {"text": "${__value.raw} critical", "color": RED, "index": 2}}}],
                   desc="OK needs two facts: no critical alert firing AND the always-firing Watchdog present. Without the heartbeat, an empty alert list proves nothing, so the tile reads UNKNOWN.",
                   text_mode="value", link=("Alert delivery", "tockmox-alert-delivery")))
panels.append(stat("Alerts firing", [t('count(ALERTS{alertstate="firing",severity="critical"}) or on() vector(0)', "critical", "A"),
                                     t('count(ALERTS{alertstate="firing",severity="warning"}) or on() vector(0)', "warning", "B")],
                   4, y, w=4, h=5, thr=steps((None, GREEN), (1, AMBER)),
                   desc="Excludes Watchdog and InfoInhibitor by severity. Read with the verdict: zero here is only good news while the heartbeat is present.",
                   link=("Alert delivery", "tockmox-alert-delivery")))
panels.append(stat("GitOps layers not Synced + Healthy",
                   [t('count(argocd_app_info unless argocd_app_info{sync_status="Synced",health_status="Healthy"}) or (count(argocd_app_info) * 0) or on() vector(-1)')],
                   8, y, thr=steps((None, GREY), (0, GREEN), (1, AMBER)), mappings=unknown_map("no Argo CD metrics"),
                   desc="Argo CD applications that are out of sync or not healthy. Grey: Argo CD metrics are not scraped (apps.argocdMonitoring), which is not the same as all synced.",
                   link=("Argo CD", "tockmox-argocd")))
panels.append(stat("Scrape targets down", [t("count(up == 0) or (count(up) * 0)")], 11, y,
                   thr=steps((None, GREY), (0, GREEN), (1, RED)), mappings=unknown_map(),
                   desc="Prometheus targets that stopped answering. A target that was never configured is not counted; this is the 'it was there and went away' signal."))
panels.append(stat("Endpoints answering", [t("sum(probe_success) / count(probe_success)")], 14, y, unit="percentunit",
                   thr=steps((None, RED), (0.9, AMBER), (0.999, GREEN)), mappings=unknown_map("no probes"), decimals=0,
                   desc="Blackbox probes of every console: the user's view of 'is it up'. Grey: no probes configured.",
                   link=("Traefik", "tockmox-traefik")))
panels.append(stat("Nodes not Ready", [t('count(kube_node_status_condition{condition="Ready",status="true"} == 0) or (count(kube_node_info) * 0) or on() vector(-1)')],
                   17, y, thr=steps((None, GREY), (0, GREEN), (1, RED)), mappings=unknown_map("no node metrics")))
panels.append(stat("Days since a restore drill passed", [t('(time() - max(kube_cronjob_status_last_successful_time{cronjob=~".*drill.*"})) / 86400')],
                   20, y, w=4, unit="d", decimals=1, thr=steps((None, GREEN), (8, AMBER), (15, RED)), mappings=unknown_map("no drill has passed"),
                   desc="Backups are only proven by a restore. The newest successful restore-drill CronJob; drills run as Argo CronWorkflows are not seen here until they emit a success metric (see the design doc).",
                   link=("Backup and restore proof", "tockmox-backup-proof")))
y += 5

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
    panels.append(stat(title, [t(q)], x, y, w=4, unit="percentunit", decimals=0, color_mode="value", graph="area",
                       thr=steps((None, GREEN), (w_, AMBER), (c_, RED)), mappings=unknown_map(minus_one=False), link=link))
    x += 4
panels.append(stat("Next certificate expiry", [t("(min(certmanager_certificate_expiration_timestamp_seconds) - time()) / 86400")],
                   16, y, w=4, unit="d", decimals=0, thr=steps((None, RED), (7, AMBER), (21, GREEN)),
                   mappings=unknown_map("no certificates", minus_one=False), link=("cert-manager", "tockmox-cert-manager")))
panels.append(stat("Certificates not ready", [t('count(certmanager_certificate_ready_status{condition="True"} == 0) or (count(certmanager_certificate_ready_status) * 0)')],
                   20, y, w=4, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no certificates", minus_one=False),
                   desc="cert-manager Certificates whose Ready condition is false: the TLS a console is about to serve wrong or not at all.",
                   link=("cert-manager", "tockmox-cert-manager")))
y += 4

# ---------------------------------------------------------------- AI
panels.append(row("AI: local versus frontier, and spend", y)); y += 1
LOCAL = 'sum(increase(tockmox_gate_served_total{endpoint_tier="local",status="ok"}[24h])) / sum(increase(tockmox_gate_served_total{endpoint_tier=~"local|external",status="ok"}[24h]))'
panels.append(stat("Served locally, last 24h", [t(LOCAL)], 0, y, w=4, h=6, unit="percentunit", decimals=0, color_mode="value",
                   thr=steps((None, BLUE)), mappings=unknown_map("no gated traffic", minus_one=False),
                   desc="Share of AI requests the policy gate served from a local model (tockmox_gate_served_total, endpoint_tier). The gate's tier is the authority: LiteLLM's api_provider says 'openai' for a local OpenAI-compatible server, so it cannot tell local from frontier. No threshold: the right share is a site decision."))
panels.append({"id": nid(), "type": "timeseries", "title": "AI requests served, by tier", "datasource": DS,
               "gridPos": {"x": 4, "y": y, "w": 8, "h": 6},
               "targets": [{"datasource": DS, "expr": 'sum by (endpoint_tier) (increase(tockmox_gate_served_total{endpoint_tier=~"local|external",status="ok"}[1h]))',
                            "legendFormat": "{{endpoint_tier}}", "refId": "A", "interval": "1h"}],
               "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "bars", "stacking": {"mode": "normal"}, "fillOpacity": 70, "barAlignment": 0}},
                               "overrides": [{"matcher": {"id": "byName", "options": "local"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "green"}}, {"id": "displayName", "value": "local"}]},
                                             {"matcher": {"id": "byName", "options": "external"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}, {"id": "displayName", "value": "frontier"}]}]},
               "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}})
panels.append(stat("Frontier spend", [t("sum(increase(litellm_spend_metric_total[24h]))", "last 24h", "A"),
                                      t("sum(increase(litellm_spend_metric_total[30d]))", "last 30 days", "B")],
                   12, y, w=4, h=6, unit="currencyUSD", decimals=2, color_mode="value", thr=steps((None, BLUE)),
                   mappings=unknown_map("no gateway spend metric", minus_one=False),
                   desc="LiteLLM's computed cost (USD by its price map; not an invoice). Counts what went through the gateway only: a subscription used directly is not here. Local models cost 0 here unless a notional price is set."))
panels.append({"id": nid(), "type": "bargauge", "title": "Frontier spend by model, last 7 days", "datasource": DS,
               "gridPos": {"x": 16, "y": y, "w": 8, "h": 6},
               "targets": [t('sort_desc(sum by (model) (increase(litellm_spend_metric_total[7d])) > 0)', "{{model}}")],
               "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 2, "color": {"mode": "fixed", "fixedColor": "orange"}, "min": 0}},
               "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True, "reduceOptions": {"calcs": ["lastNotNull"], "values": True}}})
y += 6
panels.append(stat("Gateway errors (15m)", [t('sum(rate(litellm_proxy_total_requests_metric_total{status_code!~"2.."}[15m])) / sum(rate(litellm_proxy_total_requests_metric_total[15m]))')],
                   0, y, w=4, unit="percentunit", decimals=1, thr=steps((None, GREEN), (0.02, AMBER), (0.1, RED)), mappings=unknown_map("no traffic", minus_one=False)))
panels.append(stat("Gateway latency p95 (15m)", [t("histogram_quantile(0.95, sum by (le) (rate(litellm_request_total_latency_metric_bucket[15m])))")],
                   4, y, w=4, unit="s", decimals=1, thr=steps((None, GREEN), (20, AMBER), (60, RED)), mappings=unknown_map("no traffic", minus_one=False)))
panels.append(stat("Least budget left on a gateway key", [t("min(litellm_remaining_api_key_budget_metric / litellm_api_key_max_budget_metric)")],
                   8, y, w=4, unit="percentunit", decimals=0, thr=steps((None, RED), (0.05, AMBER), (0.2, GREEN)), mappings=unknown_map("no key budgets set", minus_one=False)))
panels.append(stat("AI nodes on an unverified configuration", [t("count(tockmox_ai_node_converge_signature_ok == 0) or (count(tockmox_ai_node_converge_signature_ok) * 0)")],
                   12, y, w=4, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no AI nodes enrolled", minus_one=False),
                   desc="Enrolled inference nodes whose last converge ran a commit whose signature did not verify. Grey: no AI node is enrolled."))
panels.append(stat("Restricted traffic served off-site (24h)", [t('sum(increase(tockmox_gate_served_total{request_class="restricted",endpoint_tier="external",status="ok"}[24h])) or (count(tockmox_gate_served_total) * 0)')],
                   16, y, w=8, thr=steps((None, GREEN), (1, RED)), mappings=unknown_map("no gated traffic", minus_one=False),
                   desc="Requests the gate classed restricted that were served by a frontier model. The policy says this is zero; anything else is a control that failed."))
y += 4

# ---------------------------------------------------------------- active alerts
panels.append({"id": nid(), "type": "table", "title": "Active alerts", "datasource": DS,
               "gridPos": {"x": 0, "y": y, "w": 24, "h": 6},
               "targets": [{"datasource": DS, "expr": 'ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"}', "refId": "A", "instant": True, "format": "table"}],
               "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True, "__name__": True, "alertstate": True, "container": True, "endpoint": True, "instance": True, "job": True, "pod": True, "service": True, "prometheus": True},
                                                                  "indexByName": {"severity": 0, "alertname": 1, "namespace": 2}}}],
               "options": {"showHeader": True, "footer": {"show": False}}})

board = {
    "uid": "tockmox-overview", "title": "Tockmox / Overview",
    "description": "L0: the platform at a glance. Component health, capacity, AI routing and spend. Every tile links down to its L1 board.",
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

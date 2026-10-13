# SPDX-License-Identifier: Apache-2.0
"""What each Tockmox capability is set to, and what is actually deployed for it (TM-1017).

Two facts per capability, kept apart on purpose, because they disagree in exactly the cases
worth seeing:

  configured  the capability's switch as the AI layer resolved it from site values (the chart
              renders it into this UI's config). Every layer reads the same `capabilities` map,
              but a site can set it in one layer's values file only, so this is the AI layer's
              view, and the page says so.
  deployed    whether Argo CD reports the capability's marker workload in the layer that owns
              it, from the Applications' status.resources. No Kubernetes permission beyond the
              Applications the UI already reads.

A capability whose owning layer is missing, never reconciled or stale reads `unknown`, never
`off`: absence of evidence is not "turned off" (the UI's standing rule, ABSENCE IS NOT GREEN).
"""
from __future__ import annotations

import re
from dataclasses import dataclass

ON, OFF, UNKNOWN = "on", "off", "unknown"


@dataclass(frozen=True)
class Capability:
    key: str
    name: str
    what: str
    layer: str                      # the layer chart that deploys the marker: charts/tockmox-<layer>
    markers: tuple                  # ((kind, name regex), ...): ANY present means deployed
    components: str


# The marker is the one workload without which the capability is not there. Names are the
# rendered ones (release tockmox-<layer>); a regex so a site's release prefix does not matter.
CATALOG = (
    Capability("identity", "Single sign-on", "One sign-in across every console (Authentik).",
               "identity", (("Deployment", r"authentik-server$"),), "Authentik, its database and backup"),
    Capability("observability", "Metrics, logs and alerts", "What the platform is doing right now.",
               "observability", (("Prometheus", r"prometheus$"),), "Prometheus, Alertmanager, Grafana, Loki, Alloy"),
    Capability("notifications", "Alerts that reach a person", "The phone path for alerts, and its heartbeat.",
               "observability", (("Deployment", r"(^|-)ntfy$"), ("Deployment", r"alert-bridge$")),
               "ntfy (or Apprise), the alert bridge"),
    Capability("aiPlane", "Private AI", "A chat console and the model gateway in front of it.",
               "ai", (("StatefulSet", r"open-webui$"), ("Deployment", r"open-webui$"), ("Deployment", r"litellm$")),
               "Open WebUI, LiteLLM"),
    Capability("dataProtection", "Backups and restores", "Backups that go somewhere, and restores that are exercised.",
               "platform", (("StatefulSet", r"garage$"),), "Garage, the CNPG backup plugin, snapshot controller"),
    Capability("hardwareTelemetry", "Hardware telemetry", "Disk SMART and SNMP from physical hardware.",
               "exporters", (("DaemonSet", r"smartctl-exporter"), ("Deployment", r"snmp-exporter$")),
               "smartctl and SNMP exporters"),
    Capability("workflowAutomation", "Workflow automation", "Jobs on a schedule or an event, with a console.",
               "devops", (("Deployment", r"workflow-controller$"),), "Argo Workflows"),
    Capability("networkPolicy", "Network isolation", "Default-deny between namespaces.",
               "policy", (("NetworkPolicy", r".+"),), "the policy layer's NetworkPolicies"),
)

LAYER_PATH = re.compile(r"^charts/tockmox-([a-z]+)$")


def _layer_of(app: dict) -> str | None:
    m = LAYER_PATH.match(str(app.get("path", "")).strip("/"))
    return m.group(1) if m else None


def evaluate(configured: dict, apps: list | None, stale_names: set) -> list[dict]:
    """One row per capability in CATALOG order. `apps` is ApplicationsSource data (None when
    Argo CD did not answer); `stale_names` the applications too old to trust."""
    layers = {}
    for a in apps or []:
        layer = _layer_of(a)
        if layer:
            layers[layer] = a
    rows = []
    for c in CATALOG:
        conf = configured.get(c.key)
        app = layers.get(c.layer)
        if apps is None:
            dep, why = UNKNOWN, "Argo CD could not be read just now"
        elif app is None:
            dep, why = UNKNOWN, f"no Argo CD application deploys charts/tockmox-{c.layer}"
        elif app["name"] in stale_names:
            dep, why = UNKNOWN, f"{app['name']} has not been reconciled recently"
        else:
            hit = [n for k, n in (app.get("resources") or ())
                   if any(k == mk and re.search(rx, n) for mk, rx in c.markers)]
            dep = ON if hit else OFF
            why = f"{app['name']}: {hit[0]}" if hit else f"{app['name']} deploys none of its workloads"
        agree = conf is None or dep == UNKNOWN or (conf is True) == (dep == ON)
        rows.append({"key": c.key, "name": c.name, "what": c.what, "components": c.components,
                     "configured": None if conf is None else (ON if conf else OFF),
                     "deployed": dep, "evidence": why, "agree": agree})
    return rows

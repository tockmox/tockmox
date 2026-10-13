#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# The scanning half of tools/check-cloud-egress.sh (TM-0671). Reads rendered
# layers from a directory (<layer>.yaml and <layer>.allon.yaml, as the shell
# half writes them) and answers two questions about what the tree can REACH.
#
#   1. URLS. Every URL in a config position of a rendered object (env values,
#      args, ConfigMap data, Secret data and stringData, spec fields) whose host
#      is not inside the cluster or a placeholder domain must be in ALLOW below,
#      with a reason. Anything else is a new outbound destination nobody wrote
#      down.
#   2. SWITCHES. A phone-home whose hostname lives in the BINARY is invisible to
#      a URL scan: Grafana's update check and Open WebUI's version check are a
#      boolean in a values file and the address is in the image. So SWITCHES
#      names each one audited so far and asserts what the render says about it:
#      OFF (the off-switch must be present) or KNOWN_ON (the off-switch must be
#      ABSENT, and the reason it is still on is written down). Both directions
#      are checked: a KNOWN_ON entry whose switch has appeared fails until it is
#      promoted to OFF, so the list cannot go stale in the comfortable direction.
#
# WHAT THIS DOES NOT PROVE. SWITCHES is a list of what has been audited, not of
# everything that could phone home. Components not in it, and in NOT_AUDITED, are
# unexamined, not clean. And no render says whether a call SUCCEEDS or whether
# the network would stop it: the platform ships no egress NetworkPolicy for the
# monitoring namespace.
import base64, os, re, sys
import yaml

# --------------------------------------------------------------------------
# 1. URLS
# --------------------------------------------------------------------------
# host -> (kind, reason). `call` means a pod or a browser really contacts it;
# `identifier` means the string is an XML namespace or similar and is never
# fetched. Every entry must be SEEN in a render, or the gate fails it as stale.
ALLOW = {
    "www.w3.org": ("identifier",
        "xmlns / xlink namespace URIs inside the brand SVGs (tockmox-brand-assets). "
        "An identifier, never fetched."),
    "c2pa.org": ("identifier",
        "xmlns:c2pa namespace URI on the brand SVGs, which carry a C2PA content-credentials "
        "manifest (provenance for AI-assisted art). An identifier, never fetched."),
}

SCHEMES = r"(?:https?|wss?|redis|rediss|postgres(?:ql)?|ssh|git|oci|ldaps?|smtps?|amqp|nats|tcp|grpc)"
# s3:// is deliberately absent: its authority is a bucket name, not a host.
URL = re.compile(r"\b" + SCHEMES + r"://[^\s\"'<>\\),;`\]}]+")
SKIPKEYS = {"annotations", "labels", "description", "summary", "runbook_url", "status"}
PLACEHOLDER = re.compile(r"(^|\.)example\.(com|org|net)$")
INTERNAL = re.compile(r"(\.svc(\.cluster\.local)?|\.cluster\.local|\.default|\.kube-system|\.tockmox-[a-z-]+)$")

def internal(host):
    return (not host or "." not in host or host in ("localhost", "127.0.0.1", "::1")
            or any(c in host for c in "${[(")          # unresolved shell or template text
            or PLACEHOLDER.search(host) or INTERNAL.search(host))

def host_of(url):
    h = re.sub(r"^[a-z0-9+]+://([^/@]*@)?", "", url)
    return re.split(r"[/:?]", h)[0]

def objects(path):
    """Yield (object, decoded-text) per document. CRDs and PrometheusRules are
    skipped: their text is API documentation and runbook links, not config.
    A document that does not parse is an ERROR, never silently skipped."""
    for raw in open(path).read().split("\n---"):
        if re.search(r"^kind: (CustomResourceDefinition|PrometheusRule)$", raw, re.M):
            continue
        try:
            d = yaml.safe_load(raw)
        except yaml.YAMLError as e:
            sys.exit(f"egress_scan: {path}: a document does not parse: {e}")
        if isinstance(d, dict) and d.get("kind"):
            if d["kind"] == "ConfigMap" and "grafana_dashboard" in ((d.get("metadata") or {}).get("labels") or {}):
                continue
            if d["kind"] == "Secret":
                dec = {}
                for k, v in (d.get("data") or {}).items():
                    try: dec[k] = base64.b64decode(v).decode("utf-8", "replace")
                    except Exception: pass
                d = dict(d); d["stringData"] = {**(d.get("stringData") or {}), **dec}; d.pop("data", None)
            yield d

def strings(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in SKIPKEYS: continue
            strings(v, path + [str(k)], out)
    elif isinstance(o, list):
        for i, v in enumerate(o): strings(v, path + [str(i)], out)
    elif isinstance(o, str):
        out.append((".".join(path), o))

def scan_urls(files):
    found = {}                                  # host -> sorted list of "Kind/name path"
    for f in files:
        for d in objects(f):
            out = []; strings(d, [], out)
            for p, s in out:
                text = "\n".join(l for l in s.split("\n") if not l.lstrip().startswith("#"))
                for u in URL.findall(text):
                    h = host_of(u)
                    if not internal(h):
                        found.setdefault(h, set()).add(f"{d['kind']}/{(d.get('metadata') or {}).get('name')} {p[:60]}")
    return found

# --------------------------------------------------------------------------
# 2. SWITCHES   (layer, regex over the rendered text with Secret data decoded)
# --------------------------------------------------------------------------
# state OFF       the off-switch regex MUST match: it is off at its source.
# state KNOWN_ON  the off-switch regex must NOT match: it is on, and `why` says so
#                 plainly. Turning it off is a values change; when it lands the
#                 gate fails here until the entry moves to OFF. EMPTY since 0.7.1
#                 (TM-0671 turned the last four off) and kept as the place the
#                 next audited-but-still-on phone-home goes; `--selftest` proves
#                 the mechanism with a synthetic entry.
# `dest` is the host the call goes to, as upstream documents it.
SWITCHES = [
  # name, layer, state, off-switch regex, dest, note
  ("Grafana update check", "observability", "OFF",
   r"(?m)^\s*check_for_updates\s*=\s*false\s*$", "grafana.com",
   "[analytics] check_for_updates, shipped off in 0.6.0 (TM-0671)."),
  ("Grafana usage reporting", "observability", "OFF",
   r"(?m)^\s*reporting_enabled\s*=\s*false\s*$", "stats.grafana.org",
   "[analytics] reporting_enabled, shipped off in 0.6.0 (TM-0671)."),
  ("Grafana news feed", "observability", "OFF",
   r"(?m)^\s*news_feed_enabled\s*=\s*false\s*$", "grafana.com, a-us.storyblok.com (the operator's BROWSER fetches)",
   "[news] news_feed_enabled, shipped off in 0.6.0 (TM-0671)."),
  ("Open WebUI version check", "ai", "OFF",
   r"name: ENABLE_VERSION_UPDATE_CHECK\s*\n\s*value: ['\"]?False", "github.com (upstream release check)",
   "tockmox-ai values.yaml, with the measurement."),
  ("Traefik new-version check", "platform", "OFF",
   r"--global\.checkNewVersion=false", "update.traefik.io (upstream)",
   "TM-0785."),
  ("authentik error reporting", "identity", "OFF",
   r"AUTHENTIK_ERROR_REPORTING__ENABLED: ['\"]?false", "sentry.io",
   "subchart default is also false; asserted so it cannot flip unseen."),
  ("Loki anonymous usage reporting", "observability", "OFF",
   r"(?m)^\s*analytics:\s*\n\s+reporting_enabled:\s*false\s*$", "stats.grafana.org",
   "loki.loki.analytics.reporting_enabled: false; the default is true (TM-0671)."),
  ("Alloy usage reporting", "observability", "OFF",
   r"--disable-reporting(=true)?(\s|$)", "stats.grafana.org",
   "alloy.alloy.enableReporting: false renders `--disable-reporting`; the default is on (TM-0671)."),
  ("Longhorn upgrade checker", "platform", "OFF",
   r"(?m)^\s*upgrade-checker:\s*\"?false\"?\s*$", "longhorn-upgrade-responder.rancher.io",
   "longhorn.defaultSettings.upgradeChecker: false; the default is on (TM-0671)."),
  ("authentik update check", "identity", "OFF",
   r"AUTHENTIK_DISABLE_UPDATE_CHECK: ['\"]?true", "authentik's version endpoint (host not stated in its docs)",
   "authentik.authentik.disable_update_check: true (TM-0671)."),
  ("authentik startup analytics", "identity", "OFF",
   r"AUTHENTIK_DISABLE_STARTUP_ANALYTICS: ['\"]?true", "authentik's analytics endpoint (host not stated in its docs)",
   "authentik.authentik.disable_startup_analytics: true (TM-0671)."),
]

# Named so nobody reads the list above as complete. Not examined, not clean.
NOT_AUDITED = [
  "LiteLLM telemetry and its callbacks", "Open WebUI beyond the version check (analytics, Scarf, tracking env)",
  "Grafana plugin installs and Gravatar", "kube-prometheus-stack components", "cert-manager and MetalLB",
  "CloudNativePG operator", "ntfy and Apprise (ntfy's upstreamBaseURL is empty unless set)",
  "Argo Workflows", "what a site's own applications do",
]

def render_text(layer_files):
    parts = []
    for f in layer_files:
        for d in objects(f):
            out = []; strings(d, [], out)
            parts += [s for _, s in out]
            # The structure too: an env entry is two strings (name, value) and
            # the switch is the pair, so the dumped YAML is searched as well.
            parts.append(yaml.safe_dump(d, sort_keys=False, width=10**6))
    return "\n".join(parts)

def main(dirpath, mode):
    files = [os.path.join(dirpath, f) for f in sorted(os.listdir(dirpath)) if f.endswith(".yaml")]
    rc = 0
    print("=== 1. URLs in rendered config: external hosts ===")
    found = scan_urls(files)
    for h in sorted(found):
        if h in ALLOW:
            kind, why = ALLOW[h]
            print(f"  allowed  {h}  [{kind}]  {why}")
        else:
            print(f"  FAIL  {h} is not inside the cluster and is not in ALLOW (tools/lib/egress_scan.py):")
            for w in sorted(found[h])[:4]: print(f"          {w}")
            rc = 1
    for h in sorted(ALLOW):
        if h not in found:
            print(f"  FAIL  ALLOW lists {h} but no render contains it: a stale entry hides the next one. Remove it.")
            rc = 1
    if not found and not ALLOW:
        pass
    print()
    print("=== 2. phone-home switches audited so far ===")
    # Per render, not per layer: the default render and the all-on render must
    # each satisfy an entry, so a regression on the default path is not masked by
    # the other render still carrying the switch.
    texts = {os.path.basename(f): render_text([f]) for f in files}
    for name, layer, state, rx, dest, note in SWITCHES:
        mine = {k: v for k, v in texts.items() if re.sub(r"(\.allon)?\.yaml$", "", k) == layer}
        if not mine or not any(mine.values()):
            print(f"  FAIL  {name}: layer {layer} did not render, nothing was checked"); rc = 1; continue
        hits = {k: re.search(rx, v) is not None for k, v in mine.items()}
        if state == "OFF":
            missing = [k for k, h in hits.items() if not h]
            if not missing: print(f"  off      {name} -> {dest}")
            else:
                print(f"  FAIL  {name}: expected OFF at its source ({dest}) but the off-switch is not in {', '.join(missing)}"); rc = 1
        else:
            on = [k for k, h in hits.items() if h]
            if on:
                print(f"  FAIL  {name}: listed KNOWN_ON but the off-switch is now in {', '.join(on)}; move it to OFF"); rc = 1
            else:
                print(f"  KNOWN ON {name} -> {dest}\n             {note}")
    print()
    print("  not audited (unexamined, not clean): " + "; ".join(NOT_AUDITED))
    return rc

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))

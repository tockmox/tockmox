# SPDX-License-Identifier: Apache-2.0
# THE APPLICATIONS OPEN TO EVERY SIGNED-IN USER (templates/open-applications.yaml runs this with `ak shell -c`).
#
# In Authentik an application with no policy binding is authorized for anyone who can sign in: it shows on their
# dashboard and they can authorize to it. Its `group` field is only a launcher heading. This lists every application
# with no enabled, non-negated binding to a group or a user, marks the ones the site declared open on purpose
# (sso.access.everyone), and writes the list to one ConfigMap, which the console's Status page reads.
#
# It reads Authentik's database and changes nothing in it. Its only Kubernetes call is one merge PATCH of the
# ConfigMap's `data`, which the chart renders empty; its Role allows exactly that (patch on that one name).
# Any failure exits non-zero and leaves the last list in place with its old `generatedAt`, so the console reads it
# as stale rather than as current.
#
# Kept to the standard library: the server image's Python is the only one here.
import datetime
import json
import os
import ssl
import urllib.request

REPORT_KEY = "report.json"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def restricting_targets(bindings):
    """The binding targets with at least one enabled, non-negated binding to a group or a user. A binding to a
    policy alone does not count: this asks whether anyone is named, and an expression policy can pass everyone."""
    out = set()
    for b in bindings:
        if not b.get("enabled") or b.get("negate"):
            continue
        if b.get("group_id") is None and b.get("user_id") is None:
            continue
        out.add(str(b.get("target_id")))
    return out


def listing(apps, bindings, everyone, generated_at):
    """The report: every application no group or user binding restricts, each marked whether the site declared it
    open on purpose. Pure, so the unit tests drive it without Authentik."""
    everyone = sorted({str(s) for s in everyone})
    bound = restricting_targets(bindings)
    slugs = {str(a.get("slug")) for a in apps}
    open_apps = []
    for a in sorted(apps, key=lambda x: str(x.get("slug"))):
        if str(a.get("pk")) in bound:
            continue
        slug = str(a.get("slug"))
        open_apps.append({"slug": slug, "name": str(a.get("name") or ""), "group": str(a.get("group") or ""),
                          "everyone": slug in everyone})
    return {
        "version": 1,
        "generatedAt": generated_at,
        "applications": len(apps),
        "open": open_apps,
        # declared open but not found: a typo in sso.access.everyone, or an application since removed
        "everyoneNotFound": [s for s in everyone if s not in slugs],
    }


def publish(report, namespace, name):
    """One merge PATCH of the ConfigMap's data. No proxy: the API server is in-cluster."""
    base = os.environ.get("TOCKMOX_KUBE_URL", "")
    if not base:
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        if ":" in host:
            host = "[%s]" % host
        base = "https://%s:%s" % (host, os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
    sa_dir = os.environ.get("TOCKMOX_SA_DIR", SA_DIR)
    with open(os.path.join(sa_dir, "token"), encoding="utf-8") as fh:
        token = fh.read().strip()
    handlers = [urllib.request.ProxyHandler({})]
    if base.startswith("https://"):
        ctx = ssl.create_default_context(cafile=os.path.join(sa_dir, "ca.crt"))
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    body = json.dumps({"data": {REPORT_KEY: json.dumps(report, sort_keys=True, indent=1)}}).encode()
    req = urllib.request.Request("%s/api/v1/namespaces/%s/configmaps/%s" % (base.rstrip("/"), namespace, name),
                                 data=body, method="PATCH",
                                 headers={"Authorization": "Bearer " + token,
                                          "Content-Type": "application/merge-patch+json"})
    with urllib.request.build_opener(*handlers).open(req, timeout=30) as r:
        r.read()


def main():
    from authentik.core.models import Application
    from authentik.policies.models import PolicyBinding

    everyone = json.loads(os.environ.get("TOCKMOX_OPEN_TO_EVERYONE") or "[]")
    apps = list(Application.objects.values("pk", "slug", "name", "group"))
    # The default manager leaves expired bindings out (authentik.lib.models.ExpiringModel), as the engine does.
    bindings = list(PolicyBinding.objects.values("target_id", "group_id", "user_id", "enabled", "negate"))
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    report = listing(apps, bindings, everyone, now)
    publish(report, os.environ["TOCKMOX_REPORT_NAMESPACE"], os.environ["TOCKMOX_REPORT_CONFIGMAP"])
    flagged = [a["slug"] for a in report["open"] if not a["everyone"]]
    print("open applications: %d of %d have no group or user binding; %d not declared open: %s"
          % (len(report["open"]), report["applications"], len(flagged), ", ".join(flagged) or "none"))
    if report["everyoneNotFound"]:
        print("declared open but not found: %s" % ", ".join(report["everyoneNotFound"]))


# `ak shell -c` runs this with Django's shell module as __name__; the unit tests load it under the name below and
# call main() themselves, with stand-ins for Authentik's models and the API server.
if __name__ != "tockmox_open_applications":
    main()

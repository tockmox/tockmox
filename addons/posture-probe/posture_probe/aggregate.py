# SPDX-License-Identifier: Apache-2.0
"""Security Posture Probe ... the in-cluster differential Job.

Runs in the add-on's own namespace under the posture-probe ServiceAccount. In
order, and stopping at the first step that fails:

  1. PROVE ITS OWN IDENTITY IS WRITE-LESS. Asks the authorization oracle whether
     it may create, update, patch or delete the kinds that matter, in every
     declared namespace and cluster-wide. Any "yes" ends the run with exit 1: the
     safety contract is the role, and a role that has grown a write verb is a
     broken contract even if this code never uses it.
  2. COLLECT. Waits for this run's collector pods (one per declared namespace,
     one per identity vantage, created by their CronJobs at the same schedule)
     and reads each one's report from its termination message in pod status.
     Nothing is exec'd and no log is read.
  3. READ DECLARED STATE. Namespaces (labels), NetworkPolicies and running pods
     (name, labels and IP only) in the declared namespaces.
  4. DIFFERENTIAL. intent x config x observed, via differential.build.
  5. VALIDATE against the published schema, then STORE in the report volume.
     The report never goes to stdout: what is reachable from where is sensitive
     (threat model s5). The log line carries counts only.

Exit code is the gate contract: 0 clean, 1 could not run, 2 drift.
"""
import datetime, hashlib, json, os, sys, time, urllib.parse

from . import blackbox, differential, schema

CONF = os.environ.get("POSTURE_CONFIG_DIR", "/etc/posture-probe")
STORE = os.environ.get("POSTURE_REPORT_DIR", "/reports")
RUN_PREFIX = "posture-probe-differential-"
COLLECT_PREFIX, IDENT_PREFIX = "posture-probe-collect-", "posture-probe-identity-"

WRITE_VERBS = ["create", "update", "patch", "delete", "deletecollection"]
# (group, resource) pairs the write check asks about. Not exhaustive by design:
# these are the kinds whose mutation would change posture or reach a secret.
WRITE_KINDS = [("", "pods"), ("", "secrets"), ("", "configmaps"), ("", "services"),
               ("", "serviceaccounts"), ("", "namespaces"), ("networking.k8s.io", "networkpolicies"),
               ("rbac.authorization.k8s.io", "roles"), ("rbac.authorization.k8s.io", "rolebindings"),
               ("rbac.authorization.k8s.io", "clusterroles"), ("rbac.authorization.k8s.io", "clusterrolebindings"),
               ("apps", "deployments"), ("batch", "jobs"), ("batch", "cronjobs")]
# Verbs that are never reads, on the subresources and kinds where they bite.
NEVER = [("create", "", "pods", "exec"), ("create", "", "pods", "attach"), ("get", "", "pods", "log"),
         ("impersonate", "", "serviceaccounts", ""), ("impersonate", "", "users", ""),
         ("escalate", "rbac.authorization.k8s.io", "clusterroles", ""),
         ("bind", "rbac.authorization.k8s.io", "clusterroles", ""),
         ("get", "", "secrets", ""), ("list", "", "secrets", "")]


def log(msg):
    print("posture-probe differential: " + msg)
    sys.stdout.flush()


class Cluster:
    """The few reads the differential needs, over an Api-like object with .call()."""

    def __init__(self, api):
        self.api = api

    def can(self, verb, group, resource, namespace="", subresource=""):
        attrs = {"verb": verb, "group": group, "resource": resource}
        if namespace:
            attrs["namespace"] = namespace
        if subresource:
            attrs["subresource"] = subresource
        st, r = self.api.call("POST", "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
                              {"apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                               "spec": {"resourceAttributes": attrs}})
        if st != 201 and st != 200:
            raise RuntimeError("the authorization oracle did not answer (%s)" % st)
        return bool((r or {}).get("status", {}).get("allowed"))

    def get(self, path):
        st, body = self.api.call("GET", path)
        if st != 200:
            raise RuntimeError("GET %s -> %s" % (path, st))
        return body

    def pods(self, ns, selector=None):
        q = "?labelSelector=" + urllib.parse.quote(selector) if selector else ""
        return self.get("/api/v1/namespaces/%s/pods%s" % (ns, q)).get("items", [])


def write_violations(cl, namespaces):
    """Every write the oracle says this identity holds. Empty is the only pass."""
    bad = []
    scopes = [""] + list(namespaces)
    for ns in scopes:
        for group, res in WRITE_KINDS:
            for verb in WRITE_VERBS:
                if cl.can(verb, group, res, ns):
                    bad.append("%s %s%s @%s" % (verb, group + "/" if group else "", res, ns or "*"))
        for verb, group, res, sub in NEVER:
            if cl.can(verb, group, res, ns, sub):
                bad.append("%s %s%s%s @%s" % (verb, group + "/" if group else "", res,
                                               "/" + sub if sub else "", ns or "*"))
    return bad


def collect(cl, expected, deadline, poll=5, sleep=time.sleep, now=time.monotonic):
    """expected: [(namespace, job-name)]. Returns ({key: doc}, {key: why-missing}, {"ns/job": settle reason})."""
    docs, missing, unsettled = {}, {}, {}
    pending = list(expected)
    while pending:
        still = []
        for ns, job in pending:
            pods = cl.pods(ns, "job-name=%s" % job)
            done = [p for p in pods if p.get("status", {}).get("phase") in ("Succeeded", "Failed")]
            if not done:
                still.append((ns, job))
                continue
            p = sorted(done, key=lambda x: x["metadata"].get("creationTimestamp", ""))[-1]
            msg = None
            for c in p.get("status", {}).get("containerStatuses", []):
                term = (c.get("state") or {}).get("terminated") or {}
                if c.get("name") == "probe":
                    msg = term.get("message")
            try:
                d = blackbox.decode_termination(msg)
                st = (d.get("namespace") or {}).get("settle") or {}
                if st and not st.get("settled"):
                    # The collector never saw a policed pod: nothing it read counts.
                    # The log says only that; WHICH control read WHAT is a finding and goes to the report.
                    missing[(ns, job)] = "collector did not settle in %ss" % st.get("seconds")
                    unsettled["%s/%s" % (ns, job)] = st.get("reason", "")
                else:
                    docs[(ns, job)] = d
            except Exception as e:
                missing[(ns, job)] = "pod %s ended %s with no readable report (%s)" % (
                    p["metadata"]["name"], p["status"].get("phase"), (msg or "")[:40] or type(e).__name__)
        pending = still
        if pending and now() >= deadline:
            for k in pending:
                missing[k] = "no finished collector pod for job %s by the deadline" % k[1]
            break
        if pending:
            sleep(poll)
    return docs, missing, unsettled


def declared_state(cl, namespaces):
    names = set(namespaces)
    nss = [n for n in cl.get("/api/v1/namespaces").get("items", []) if n["metadata"]["name"] in names]
    pols, pods = [], []
    for ns in namespaces:
        pols += cl.get("/apis/networking.k8s.io/v1/namespaces/%s/networkpolicies" % ns).get("items", [])
        for p in cl.pods(ns):
            if p.get("status", {}).get("phase") == "Running":
                # Minimised: the evaluator needs nothing else, and nothing else is kept.
                pods.append({"name": p["metadata"]["name"], "namespace": ns,
                             "labels": p["metadata"].get("labels") or {}, "ip": p["status"].get("podIP")})
    return {"namespaces": [{"metadata": {"name": n["metadata"]["name"], "labels": n["metadata"].get("labels") or {}}}
                           for n in nss],
            "networkpolicies": pols, "pods": pods}


def store(report, run_id, keep, out_dir=STORE):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "report-%s.json" % run_id)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    os.replace(tmp, path)
    with open(os.path.join(out_dir, "latest"), "w") as f:
        f.write(os.path.basename(path) + "\n")
    reports = sorted((p for p in os.listdir(out_dir) if p.startswith("report-") and p.endswith(".json")),
                     key=lambda p: os.path.getmtime(os.path.join(out_dir, p)))
    for old in reports[:-max(1, keep)]:
        os.remove(os.path.join(out_dir, old))
    return path


def run(cl, conf, intents, targets_doc, run_id, deadline, out_dir=STORE, sleep=time.sleep, now=time.monotonic):
    namespaces = conf["namespaces"]
    bad = write_violations(cl, namespaces)
    if bad:
        log("REFUSING: this identity holds %d write permission(s), first: %s. The probe's safety is its "
            "read-only role; fix the RBAC before trusting any result." % (len(bad), bad[0]))
        return differential.GATE_ERROR, None
    log("identity checked: no write verb on %d kinds in %d scopes" % (len(WRITE_KINDS), len(namespaces) + 1))
    if conf.get("presetRowsDropped"):
        log("intent: %d rows; %d preset rows dropped because they name a namespace, target or identity "
            "this release does not measure" % (len(intents), conf["presetRowsDropped"]))

    expected = [(ns, COLLECT_PREFIX + run_id) for ns in namespaces]
    expected += [(v["namespace"], IDENT_PREFIX + run_id) for v in conf.get("identityVantages", [])]
    docs, missing, unsettled = collect(cl, expected, deadline, sleep=sleep, now=now)
    for (ns, job), why in sorted(missing.items()):
        log("not observed: %s (%s)" % (ns, why))   # names a namespace and a job, never a result

    observed = {"runId": run_id, "clusterIdentifier": conf.get("clusterIdentifier", "unknown"),
                "namespaces": [], "observations": []}
    for d in docs.values():
        observed["observations"] += d.get("observations", [])
        if d.get("namespace", {}).get("reachability") is not None or d.get("namespace", {}).get("podIP"):
            nsd = d["namespace"]
            # The white-box evaluates the pod the black-box connected from: keep its IP.
            if "reachability" not in nsd:
                nsd["reachability"] = [{}] if any("->" in o["subject"] for o in d.get("observations", [])) else []
            observed["namespaces"].append(nsd)

    declared = differential.Declared(declared_state(cl, namespaces))
    report, gate = differential.build(observed, intents, declared, targets_doc.get("targets"),
                                      targets_doc.get("probeLabels"))
    report["run"]["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["run"]["intentFileDigest"] = conf.get("intentDigest", "")
    report["run"]["presetRowsDropped"] = int(conf.get("presetRowsDropped", 0))
    if missing:
        report["run"]["notObserved"] = sorted("%s/%s" % k for k in missing)
    if unsettled:
        report["run"]["notSettled"] = unsettled
    errs = schema.validate(report)
    if errs:
        log("REFUSING to store a report its own schema rejects: %s" % errs[0])
        return differential.GATE_ERROR, None
    path = store(report, run_id, int(conf.get("keep", 1)), out_dir)
    s = report["summary"]
    log("run=%s drift=%d enforcement-drift=%d unintended-deny=%d unknown=%d confirmed-safe=%d gate=%d stored=%s"
        % (run_id, s["driftCount"], s["enforcementDriftCount"], s["unintendedDenyCount"], s["unknownCount"],
           s["confirmedSafeCount"], gate, os.path.basename(path)))
    return gate, report


def main():
    job = os.environ.get("POSTURE_RUN_JOB", "")
    run_id = os.environ.get("POSTURE_RUN_ID") or (job[len(RUN_PREFIX):] if job.startswith(RUN_PREFIX) else "")
    if not run_id:
        log("REFUSING: cannot tell which run this is. The Job must be named %s<run-id> (the CronJob does "
            "this; by hand use kubectl create job --from=cronjob/posture-probe-differential %s<run-id>)"
            % (RUN_PREFIX, RUN_PREFIX))
        return differential.GATE_ERROR
    try:
        conf = json.load(open(os.path.join(CONF, "config.json")))
        raw = open(os.path.join(CONF, "intent.json"), "rb").read()
        intents = json.loads(raw)["intents"]
        conf["intentDigest"] = "sha256:" + hashlib.sha256(raw).hexdigest()
        targets_doc = json.load(open(os.path.join(CONF, "targets.json")))
        cl = Cluster(blackbox.Api(float(conf.get("apiTimeoutSeconds", 10))))
        gate, _ = run(cl, conf, intents, targets_doc, run_id,
                      time.monotonic() + float(conf.get("collectSeconds", 240)))
        return gate
    except Exception as e:  # any failure to run is COULD-NOT-RUN, never clean
        log("could not run: %s: %s" % (type(e).__name__, e))
        return differential.GATE_ERROR


if __name__ == "__main__":
    sys.exit(main())

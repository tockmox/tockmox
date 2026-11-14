# SPDX-License-Identifier: Apache-2.0
"""Platform › Schedule: how each Argo CronWorkflow's newest run ended (read from the Workflow it made), jobs named by
what they protect, deployed jobs that are a planned task, and the site applications' own scheduled work."""
import os
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from tests.proto_support import ROOT, login_as, World  # noqa: F401
from tests.proto_support import _secret, world  # noqa: F401  (fixtures)
from tests.test_platform import add_cronjob, doc_with_platform, healthy_signals, item
from app import config as cfgmod
from app import platform as pm
from app.cronexpr import Cron
from app.main import Transports, create_app

NOW = time.time()
DAILY = "15 2 * * *"


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def cronworkflow(name, ns="drills", last=None, protects=None, schedule=DAILY):
    md = {"name": name, "namespace": ns}
    if protects:
        md["annotations"] = {"tockmox.com/protects": protects}
    return {"metadata": md, "spec": {"schedules": [schedule], "timezone": "UTC"},
            "status": {"lastScheduledTime": iso(last)} if last else {}}


def workflow(cron, ns="drills", scheduled=None, phase="Succeeded", started=None, finished=None, n=1):
    md = {"name": f"{cron}-{n}", "namespace": ns, "labels": {"workflows.argoproj.io/cron-workflow": cron},
          "annotations": {"workflows.argoproj.io/scheduled-time": iso(scheduled)} if scheduled else {}}
    st = {"phase": phase, "startedAt": iso(started or scheduled)}
    if finished:
        st["finishedAt"] = iso(finished)
    return {"metadata": md, "status": st}


def client(world, doc, cronworkflows=(), workflows=None):
    """The Kubernetes API answers cronworkflows, and workflows when given (else it refuses them with 403)."""
    s = cfgmod.parse(doc)
    kube_h = world.handler("kube")

    def kube(req):
        if req.url.path.endswith("/cronworkflows"):
            return httpx.Response(200, json={"items": list(cronworkflows)})
        if req.url.path.endswith("/workflows") and workflows is not None:
            assert req.url.params.get("labelSelector") == "workflows.argoproj.io/cron-workflow"
            return httpx.Response(200, json={"items": list(workflows)})
        return kube_h(req)
    tp = Transports(kube=httpx.MockTransport(kube), prometheus=httpx.MockTransport(world.handler("prometheus")),
                    alertmanager=httpx.MockTransport(world.handler("alertmanager")))
    app = create_app(s, tp, notes_path=os.path.join(ROOT, "tests", "fixtures", "none.md"))
    c = TestClient(app, follow_redirects=False)
    login_as(c, s, ["tockmox-admins"])
    return c


def row_of(page, name):
    """The schedule table row holding a job's name."""
    i = page.index(name)
    return page[page.rfind("<tr>", 0, i):page.index("</tr>", i)]


# ---------------------------------------------------------------- outcomes

def test_each_cronworkflow_shows_how_its_newest_run_ended_with_its_time(world):
    healthy_signals(world)
    prev = Cron(DAILY).prev_before(NOW)
    cws = [cronworkflow("restore-drill-good", last=prev), cronworkflow("restore-drill-bad", last=prev),
           cronworkflow("restore-drill-going", last=prev)]
    wfs = [workflow("restore-drill-good", scheduled=prev, finished=prev + 300),
           workflow("restore-drill-good", scheduled=prev - 86400, phase="Failed", finished=prev - 86000, n=0),
           workflow("restore-drill-bad", scheduled=prev, phase="Failed", finished=prev + 420),
           workflow("restore-drill-going", scheduled=prev, phase="Running")]
    t = client(world, doc_with_platform(), cws, wfs).get("/platform/schedule").text
    good, bad, going = row_of(t, "restore-drill-good"), row_of(t, "restore-drill-bad"), row_of(t, "restore-drill-going")
    # an older failed run does not count against a newer success
    assert "On schedule" in good and "Newest run: Succeeded, finished" in good and f'datetime="{iso(prev + 300)}"' in good
    # a failed run reads Failed, in the critical colour, with the time it ended
    assert "st-critical" in bad and "Last run failed" in bad
    assert "Newest run: Failed, finished" in bad and f'datetime="{iso(prev + 420)}"' in bad
    assert "Running" in going and "Newest run: Running, started" in going
    assert "outcome is not visible" not in t


def test_a_newest_run_whose_record_is_gone_is_unknown_not_failed(world):
    # Argo deleted the newest run's Workflow; the one left is yesterday's success. That is not the newest run's outcome.
    healthy_signals(world)
    prev = Cron(DAILY).prev_before(NOW)
    t = client(world, doc_with_platform(), [cronworkflow("restore-drill-gone", last=prev)],
               [workflow("restore-drill-gone", scheduled=prev - 86400, finished=prev - 86000)]).get("/platform/schedule").text
    r = row_of(t, "restore-drill-gone")
    assert "Unknown" in r and "Argo keeps no record of its newest run" in r and "Last run failed" not in r


def test_a_success_metric_still_counts_when_the_run_record_is_gone(world):
    healthy_signals(world)
    prev = Cron(DAILY).prev_before(NOW)
    q = "tockmox_test_cronworkflow_last_success"
    world.series[q] = [({"namespace": "drills", "cronworkflow": "restore-drill-gone"}, prev + 200)]
    t = client(world, doc_with_platform(workflowSuccessQuery=q), [cronworkflow("restore-drill-gone", last=prev)],
               []).get("/platform/schedule").text
    assert "On schedule" in row_of(t, "restore-drill-gone")


# ---------------------------------------------------------------- what a job protects

DRILLS = {"restore-drill-identity": "Sign-in database", "restore-drill-chats": "Chat history",
          "restore-drill-documents": "Scanned documents", "restore-drill-registry": "Image registry",
          "restore-drill-forge": "Source repositories", "restore-drill-etcd": "Cluster state",
          "restore-drill-gateway": "Model gateway keys and spend", "restore-drill-objects": "Object store metadata"}


def test_drills_are_named_by_what_they_protect_with_the_job_name_second(world):
    healthy_signals(world)
    prev = Cron(DAILY).prev_before(NOW)
    names = list(DRILLS)
    # four say so on the workload, four through features.platform.protects; the annotation wins over the map
    cws = [cronworkflow(n, last=prev, protects=DRILLS[n] if i < 4 else None) for i, n in enumerate(names)]
    wfs = [workflow(n, scheduled=prev, finished=prev + 60) for n in names]
    protects = {n: DRILLS[n] for n in names[4:]}
    protects[names[0]] = "not this one"
    prev_cj = Cron("0 4 * * *").prev_before(NOW)
    add_cronjob(world, "db", "db-drill", "0 4 * * *", last_run=prev_cj, last_ok=prev_cj + 60, nxt=prev_cj + 86400)
    protects["db-drill"] = "Notes database"
    c = client(world, doc_with_platform(protects=protects), cws, wfs)
    t = c.get("/platform/schedule").text
    for n in names:
        r = row_of(t, f">{DRILLS[n]}<")
        assert f'<span class="ref">{n} · CronWorkflow in drills' in r and "On schedule" in r and "Newest run: Succeeded" in r
    assert "not this one" not in t
    assert '>Notes database<span class="ref">db-drill · CronJob in db' in t
    # the role's own page and the week's run list use the same words
    a = c.get("/platform/agents/continuity").text
    assert ">Sign-in database<span" in a and "Notes database" in a


# ---------------------------------------------------------------- owners

def test_a_deployed_job_linked_to_a_planned_task_is_that_task(world):
    healthy_signals(world)
    prev = Cron("30 3 * * *").prev_before(NOW)
    add_cronjob(world, "agents", "orchestrator-standup", "30 3 * * *", last_run=prev, last_ok=prev + 90, nxt=prev + 86400)
    add_cronjob(world, "agents", "orchestrator-retro", "0 19 * * 0", last_run=prev, last_ok=prev + 90)
    doc = doc_with_platform(plannedTasks={"orchestrator-standup": "daily-standup", "orchestrator-retro": "no-such-task"})
    c = client(world, doc)
    a = c.get("/platform/agents/scrum-master").text
    r = row_of(a, "orchestrator-standup")
    assert "the planned task daily-standup" in r and "On schedule" in r
    assert ">daily-standup<" not in a, "the task's Planned row gives way to the job that is it"
    assert ">review-and-retro<" in a, "the other planned tasks stay planned"
    o = c.get("/platform").text
    assert "Scheduled work with no owner" in o and "agents/orchestrator-retro" in o, "a link to no task is passed over"
    assert "agents/orchestrator-standup" not in o


def test_owner_order_is_label_then_task_then_assign_then_pattern():
    cat = pm.load_catalog()
    tasks, given = {"nightly-backup": "release-readiness"}, {"nightly-backup": "security"}
    assert pm.owner_of(item(name="nightly-backup"), cat, given, tasks) == "release"
    assert pm.owner_of(item(name="nightly-backup", practice="incident"), cat, given, tasks) == "incident"
    assert pm.owner_of(item(name="nightly-backup"), cat, given, {"nightly-backup": "ghost"}) == "security"


@pytest.mark.parametrize("name,role", [
    ("tockmox-health-watch", "incident"), ("gitops-github-minter", "change"), ("gitops-github-minter-x", "change"),
    ("tockmox-gate-freshness", "release"), ("improvement-fetcher", "improvement-manager"),
])
def test_the_default_catalog_owns_the_platforms_own_scheduled_jobs(name, role):
    assert pm.owner_of(item(name=name), pm.load_catalog()) == role


def test_site_applications_work_is_its_own_group_not_no_owner(world):
    healthy_signals(world)
    prev = Cron("0 6 * * 1").prev_before(NOW)
    add_cronjob(world, "notes-app", "notes-weekly-digest", "0 6 * * 1", last_run=prev, last_ok=prev + 30)
    add_cronjob(world, "notes-app", "notes-backup", "0 6 * * 1", last_run=prev, last_ok=prev + 30)
    add_cronjob(world, "elsewhere", "mystery-thing", "0 6 * * 1", last_run=prev, last_ok=prev + 30)
    c = client(world, doc_with_platform(siteNamespaces=["notes-app"]))
    o = c.get("/platform").text
    site = o[o.index("Scheduled work of site applications"):]
    nobody = o[o.index("Scheduled work with no owner"):o.index("Scheduled work of site applications")]
    assert "notes-app/notes-weekly-digest" in site and "notes-app/notes-weekly-digest" not in nobody
    assert "elsewhere/mystery-thing" in nobody
    assert "notes-backup" in c.get("/platform/agents/continuity").text, "a role's pattern still wins in a site namespace"
    assert "Site application" in row_of(c.get("/platform/schedule").text, "notes-weekly-digest")


def test_planned_task_names_are_unique_across_the_catalog(tmp_path):
    bad = tmp_path / "catalog.yaml"
    bad.write_text("version: 2\nteams:\n  - id: run\n    lead: {id: lead, schedules: {planned: [{name: p, cron: '0 1 * * *'}]}}\n"
                   "    members: [{id: m, schedules: {planned: [{name: p, cron: '0 2 * * *'}]}}]\n")
    with pytest.raises(pm.CatalogError, match="planned task names must be unique.*: p"):
        pm.load_catalog(str(bad))

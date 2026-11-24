# SPDX-License-Identifier: Apache-2.0
"""A cluster that does not serve Argo's CronWorkflow API is a cluster with no scheduled workflows, not a failure.

What it fixes: when the Kubernetes API answers 404 to the cluster-wide cronworkflows list (Argo Workflows is not
installed, its CRDs are absent, or the served API version is not argoproj.io/v1alpha1), the 'Scheduled workflows
(Argo)' source raised, counted a source failure and read Unknown with 'HTTP 404', so the Platform pages said every
role's scheduled work could not be read. A 404 on that list now reads as an empty section with the reason named.
Any other error on the list (403, 429 after its retries, 5xx, a timeout) is still a failure, read Unknown as before.
"""
import httpx
import pytest

from app import platform as pm
from app import sources
from app.sources import OK, UNKNOWN, KubeClient

LIST = "/apis/argoproj.io/v1alpha1/cronworkflows"
CW = {"items": [{"metadata": {"name": "nightly-backup", "namespace": "site-backup"},
                 "spec": {"schedule": "0 2 * * *"}, "status": {}}]}
NOT_FOUND = {"kind": "Status", "apiVersion": "v1", "status": "Failure", "message": "the server could not find the "
             "requested resource", "reason": "NotFound", "details": {}, "code": 404}


class Kube:
    """The cronworkflows list answers `code`; the workflows list (the runs) answers `runs_code`. Paths are recorded."""

    def __init__(self, code, runs_code=None):
        self.code, self.runs_code, self.paths = code, code if runs_code is None else runs_code, []

    def handler(self, req):
        self.paths.append(req.url.path)
        code = self.runs_code if req.url.path.endswith("/workflows") else self.code
        if code == 200:
            return httpx.Response(200, json=CW if req.url.path.endswith("/cronworkflows") else {"items": []})
        return httpx.Response(code, json=dict(NOT_FOUND, code=code))


def source(kube):
    kc = KubeClient("https://kube.test", "/nonexistent/token", "/nonexistent/ca", 4.0,
                    httpx.MockTransport(kube.handler), sleep=lambda s: None)
    return pm.CronWorkflowsSource(kc, "", 4.0)


def test_the_404_is_on_the_cluster_wide_cronworkflows_list():
    kube = Kube(404)
    source(kube).read(now=lambda: 1_800_000_000.0)
    assert kube.paths[0] == LIST                       # the one GET this source makes first: the cluster-wide list


def test_a_404_on_the_list_is_an_empty_section_with_its_reason_not_a_failure(monkeypatch):
    seen = []
    monkeypatch.setattr(sources.telemetry, "source_failure", lambda name, e: seen.append((name, e)))
    r = source(Kube(404)).read(now=lambda: 1_800_000_000.0)
    assert r.state == OK
    assert r.data == []
    assert r.fetched_at is not None                    # a real answer, not last-good data kept on screen
    assert "HTTP 404" not in r.reason
    assert r.reason == pm.CronWorkflowsSource.NOT_SERVED and "does not serve" in r.reason
    assert seen == []                                  # no source failure counted


def test_a_404_on_the_list_does_not_read_the_runs():
    kube = Kube(404)
    source(kube).read(now=lambda: 1_800_000_000.0)
    assert not any(p.endswith("/workflows") for p in kube.paths)


def test_the_list_served_with_no_runs_api_still_shows_the_schedules():
    r = source(Kube(200, runs_code=404)).read(now=lambda: 1_800_000_000.0)
    assert [x["name"] for x in r.data] == ["nightly-backup"]
    assert r.state != UNKNOWN


@pytest.mark.parametrize("code", [403, 500, 503])
def test_any_other_error_on_the_list_is_still_unknown(code):
    r = source(Kube(code)).read(now=lambda: 1_800_000_000.0)
    assert r.state == UNKNOWN and r.reason == f"HTTP {code}"


def test_after_a_404_the_api_appearing_is_read_again():
    kube = Kube(404)
    src = source(kube)
    t0 = 1_800_000_000.0
    assert src.read(now=lambda: t0).data == []
    kube.code = kube.runs_code = 200
    r = src.read(now=lambda: t0 + 3600)                # past the cache
    assert r.state == OK and [x["name"] for x in r.data] == ["nightly-backup"]

# SPDX-License-Identifier: Apache-2.0
"""The open-applications job's listing and publishing (charts/tockmox-identity/files/open-applications.py), run on
stand-ins for Authentik's models and the Kubernetes API (standin.py). The render and the RBAC are test_render.py."""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import standin  # noqa: E402
from standin import ADMIN_GROUP, ARGOCD, GRAFANA, HANDBOOK, USER_GROUP, bind  # noqa: E402

T = "2026-11-12T09:30:00Z"


@pytest.fixture(scope="module")
def m():
    return standin.load()


def slugs(report, everyone=None):
    return [a["slug"] for a in report["open"] if everyone is None or a["everyone"] is everyone]


def test_an_application_with_no_binding_is_listed_and_a_bound_one_is_not(m):
    r = m.listing([GRAFANA, ARGOCD], [bind(GRAFANA, ADMIN_GROUP)], [], T)
    assert slugs(r) == ["argocd"]
    assert r["applications"] == 2 and r["generatedAt"] == T and r["version"] == 1


def test_a_user_binding_restricts_as_a_group_binding_does(m):
    r = m.listing([GRAFANA, ARGOCD], [bind(GRAFANA, ADMIN_GROUP), bind(ARGOCD, user=7)], [], T)
    assert slugs(r) == []


@pytest.mark.parametrize("b", [
    bind(ARGOCD, ADMIN_GROUP, enabled=False),       # a disabled binding is not evaluated
    bind(ARGOCD, ADMIN_GROUP, negate=True),         # "everyone except the group" names nobody who may
    {"target_id": ARGOCD["pk"], "group_id": None, "user_id": None, "enabled": True, "negate": False},  # policy only
])
def test_a_binding_that_names_nobody_does_not_count(m, b):
    r = m.listing([ARGOCD], [b], [], T)
    assert slugs(r) == ["argocd"]


def test_a_binding_on_another_application_does_not_cover_this_one(m):
    r = m.listing([GRAFANA, ARGOCD], [bind(GRAFANA, ADMIN_GROUP), bind(GRAFANA, USER_GROUP)], [], T)
    assert slugs(r) == ["argocd"]


def test_an_application_the_site_declared_open_is_listed_as_intended(m):
    r = m.listing([ARGOCD, HANDBOOK], [], ["handbook"], T)
    assert slugs(r, everyone=True) == ["handbook"] and slugs(r, everyone=False) == ["argocd"]


def test_a_declared_slug_that_matches_nothing_is_reported(m):
    r = m.listing([ARGOCD], [], ["handbok", "argocd"], T)
    assert r["everyoneNotFound"] == ["handbok"]
    assert slugs(r, everyone=True) == ["argocd"]


def test_uuid_and_string_keys_compare_equal(m):
    import uuid
    app = dict(ARGOCD, pk=uuid.UUID(ARGOCD["pk"]))
    r = m.listing([app], [bind(ARGOCD, ADMIN_GROUP)], [], T)
    assert slugs(r) == []


def test_the_list_is_sorted_by_slug(m):
    r = m.listing([HANDBOOK, GRAFANA, ARGOCD], [], [], T)
    assert slugs(r) == ["argocd", "handbook", "tockmox-grafana"]


def test_the_job_patches_one_configmap_with_the_report():
    apps, bindings, everyone = standin.SCENARIOS["unbound"]
    api, m = standin.run(apps, bindings, everyone)
    try:
        assert len(api.requests) == 1
        rq = api.requests[0]
        assert rq["method"] == "PATCH"
        assert rq["path"] == "/api/v1/namespaces/tockmox-authentik/configmaps/tockmox-identity-open-applications"
        assert rq["headers"]["Content-Type"] == "application/merge-patch+json"
        assert rq["headers"]["Authorization"] == "Bearer stand-in-token"
        assert list(rq["body"]) == ["data"] and list(rq["body"]["data"]) == ["report.json"]
        rep = json.loads(api.cm["data"]["report.json"])
        assert rep == m.listing(apps, bindings, everyone, T)
        assert api.cm["metadata"]["labels"] == {"tockmox.com/managed-by": "tockmox"}     # nothing else touched
    finally:
        api.close()


def test_the_job_fails_when_the_configmap_is_missing():
    apps, bindings, everyone = standin.SCENARIOS["unbound"]
    api = standin.FakeApi(exists=False)
    try:
        with pytest.raises(Exception, match="404"):
            standin.run(apps, bindings, everyone, api=api)
    finally:
        api.close()


def test_the_job_fails_when_the_patch_is_refused():
    apps, bindings, everyone = standin.SCENARIOS["unbound"]
    api = standin.FakeApi(status=403)
    try:
        with pytest.raises(Exception, match="403"):
            standin.run(apps, bindings, everyone, api=api)
    finally:
        api.close()


def test_the_consoles_fixtures_are_what_the_job_writes():
    assert standin.main(["standin.py", "--check"]) == 0

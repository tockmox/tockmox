# SPDX-License-Identifier: Apache-2.0
"""The API server's 429 (priority and fairness, a full queue for a moment) is retried, and a 429 that outlasts the
retries keeps the last good answer with its age, read as Unknown.

What it fixes: an isolated 429 on the cluster-wide cronworkflows list made the Platform pages show
'Scheduled workflows (Argo): HTTP 429' for that page view, so every role's scheduled work read Unknown.
"""
import httpx
import pytest

from app import platform as pm
from app.sources import UNKNOWN, OK, KubeClient, retry_wait

CW = {"items": [{"metadata": {"name": "nightly-backup", "namespace": "site-backup"},
                 "spec": {"schedule": "0 2 * * *"}, "status": {}}]}


class Kube:
    """Answers each GET with the next status in `script`; the last one repeats."""

    def __init__(self, *script, retry_after="1"):
        self.script, self.retry_after, self.seen = list(script), retry_after, 0

    def handler(self, req):
        code = self.script[min(self.seen, len(self.script) - 1)]
        self.seen += 1
        if code == 429:
            h = {} if self.retry_after is None else {"Retry-After": self.retry_after}
            return httpx.Response(429, headers=h, json={"kind": "Status", "code": 429, "reason": "TooManyRequests"})
        if code == 200:
            return httpx.Response(200, json=CW)
        return httpx.Response(code, json={"kind": "Status", "code": code})


def client(kube, waits, timeout=4.0):
    return KubeClient("https://kube.test", "/nonexistent/token", "/nonexistent/ca", timeout,
                      httpx.MockTransport(kube.handler), sleep=waits.append)


def test_one_429_is_retried_and_the_answer_is_the_retry():
    kube, waits = Kube(429, 200), []
    assert client(kube, waits).get("/apis/argoproj.io/v1alpha1/cronworkflows") == CW
    assert kube.seen == 2 and waits == [1.0]


def test_two_429s_running_are_still_answered():
    kube, waits = Kube(429, 429, 200), []
    assert client(kube, waits).get("/x") == CW
    assert kube.seen == 3 and waits == [1.0, 1.0]


def test_a_third_429_is_the_answer():
    kube, waits = Kube(429), []
    with pytest.raises(httpx.HTTPStatusError) as e:
        client(kube, waits).get("/x")
    assert e.value.response.status_code == 429
    assert kube.seen == 3 and len(waits) == 2          # three tries, two waits, never a fourth


@pytest.mark.parametrize("code", [403, 404, 500, 503])
def test_nothing_but_429_is_retried(code):
    kube, waits = Kube(code, 200), []
    with pytest.raises(httpx.HTTPStatusError):
        client(kube, waits).get("/x")
    assert kube.seen == 1 and waits == []


@pytest.mark.parametrize("header, cap, want", [
    ("1", 2.0, 1.0),
    ("0", 2.0, 0.0),
    ("120", 2.0, 2.0),                                  # never longer than the cap
    ("1", 0.5, 0.5),                                    # nor the source timeout, when that is shorter
    ("-5", 2.0, 0.0),
    ("Wed, 21 Oct 2026 07:28:00 GMT", 2.0, 1.0),        # an HTTP-date reads as the default
    ("nan", 2.0, 1.0),
    (None, 2.0, 1.0),                                   # no Retry-After at all
])
def test_the_wait_is_what_the_server_asks_within_the_cap(header, cap, want):
    h = {} if header is None else {"Retry-After": header}
    assert retry_wait(httpx.Response(429, headers=h), cap) == want


def test_the_wait_never_exceeds_the_source_timeout():
    kube, waits = Kube(429, 200, retry_after="30"), []
    client(kube, waits, timeout=0.8).get("/x")
    assert waits == [0.8]


def test_a_planted_429_keeps_the_last_good_answer_with_its_age():
    kube, waits = Kube(200, 429), []
    src = pm.CronWorkflowsSource(client(kube, waits), "", 4.0)
    t0 = 1_800_000_000.0
    good = src.read(now=lambda: t0)
    assert good.state == OK and [x["name"] for x in good.data] == ["nightly-backup"]
    bad = src.read(now=lambda: t0 + 3600)               # past the cache: three 429s running
    assert bad.state == UNKNOWN and bad.reason == "HTTP 429"
    assert [x["name"] for x in bad.data] == ["nightly-backup"]   # the last good answer stays on the page
    assert bad.last_ok_at == t0 and bad.age_text(now=t0 + 3600) == "1h ago"
    assert bad.fetched_at is None                       # and it is not presented as a new answer

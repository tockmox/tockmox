# SPDX-License-Identifier: Apache-2.0
"""The enrol flow, the change page, the node page panels and the shell-safety of the one-liner."""
import html
import json
import re
import shlex
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from _ainode_helpers import (FakeProm, SHA, converge_rows, csrf, draft_of, flap_rows, info_row, mac, make_app,  # noqa: E402
                             readiness_rows, row)
from app import nodes as nm  # noqa: E402

AI = {"siteRepo": "git@git.example.com:team/site.git", "toolkitRef": "v0.1.0", "signingMode": "warn",
      "adminCidrs": ["192.0.2.0/24"]}
UP = [row("up", 1, instance="10.0.0.5:9100")]


def block(*nodes, ai=AI):
    d = {"nodes": list(nodes), "routes": []}
    if ai is not None:
        d["aiNodes"] = ai
    return d


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path, block(mac("studio", enrolled=False)))


def shape(cmd):
    """The command as a shell tokenises it: the operators in order, and the number of words between them."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = False
    toks = list(lex)
    ops = [t for t in toks if set(t) <= set("();<>|&")]
    words = [t for t in toks if t not in ops and not t.startswith("#")]
    return ops, len(words), sum(1 for w in words if w.startswith("bash /tmp/bootstrap-node.sh"))


def panel_state(page, heading="conv-h"):
    """The state badge class (st-ok, st-unknown ...) of the first badge after a panel heading."""
    m = re.search(r'class="badge st-(\w+)"', page.split(f'id="{heading}"', 1)[1])
    return m.group(1) if m else None


def oneliner(page):
    m = re.search(r"<pre[^>]*><code>(.*?)</code></pre>", page, re.S)
    return html.unescape(m.group(1)) if m else ""


# ---- the enrol section

def test_the_enroll_path_sits_beside_the_manual_one(app):
    t = app.get("/nodes/add/apple-silicon-mac").text
    assert "Enroll for GitOps (recommended)" in t and "Manage it yourself" in t
    assert t.index("Enroll for GitOps") < t.index("Manage it yourself")


def test_the_one_liner_carries_the_real_values_and_site_settings(app):
    t = app.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio-2", "host": "192.0.2.30"}).text
    cmd = oneliner(t)
    assert "scp ai-node/bootstrap-node.sh admin@192.0.2.30:/tmp/" in cmd
    assert "--ai-node-id studio-2" in cmd and "--site-repo git@git.example.com:team/site.git" in cmd.replace("'", "") \
        and "--toolkit-ref v0.1.0" in cmd
    assert "ssh -t admin@192.0.2.30" in cmd


def test_without_input_the_command_is_placeholders(app):
    cmd = oneliner(app.get("/nodes/add/apple-silicon-mac").text)
    for ph in ("NODE_ID", "HOST"):
        assert ph in cmd


CRAFTED = ["x; rm -rf /", "$(id)", "`id`", "a b", "a&b", "a|b", "a\nb", "a'b", "a\"b", "-oProxyCommand=id", "--x", "../../etc",
           "a;b", "host>out", "h$IFS", "a" * 300]


@pytest.mark.parametrize("bad", CRAFTED)
@pytest.mark.parametrize("field", ["node_id", "host", "admin_user"])
def test_a_crafted_link_cannot_plant_shell_in_the_one_liner(app, bad, field):
    params = {"node_id": "studio-2", "host": "192.0.2.30", "admin_user": "admin"}
    params[field] = bad
    t = app.get("/nodes/add/apple-silicon-mac", params=params).text
    cmd = oneliner(t)
    assert cmd, "the page rendered no command block"
    # the rejected value is not in the command or the notes, and the only place the page repeats it is the form field
    # the admin typed it in, where autoescaping keeps a quote or an angle bracket from leaving the attribute
    assert bad not in cmd
    outside = re.sub(r"<input[^>]*>", "", t)
    assert bad not in outside, "the crafted value is echoed outside its form field"
    if re.search(r"[<>\"]", bad):
        assert bad not in t, "an angle bracket or quote came through unescaped"
    # whatever the command is, a shell reads the same structure as for an honest link: same operators, same words
    # outside the quoted argument, and the remote command is ONE word
    clean = oneliner(app.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio-2", "host": "192.0.2.30"}).text)
    assert shape(cmd) == shape(clean)


def test_a_crafted_value_is_never_planted_in_the_generated_draft(app):
    t = app.get("/nodes/add/apple-silicon-mac", params={"node_id": "x; rm -rf /", "host": "192.0.2.30"}).text
    assert draft_of(t) is None


def test_site_repo_and_toolkit_ref_cannot_be_set_from_the_link(app):
    t = app.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio-2", "host": "192.0.2.30",
                                                      "site_repo": "git@evil.example:x/y.git", "toolkit_ref": "evil"}).text
    cmd = oneliner(t)
    assert "evil" not in cmd and "evil" not in t
    assert "git.example.com:team/site.git" in cmd.replace("'", "")


def test_unset_site_values_leave_placeholders_and_say_where_they_come_from(tmp_path):
    c = make_app(tmp_path, block(mac("studio", enrolled=False), ai=None))
    t = c.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio-2", "host": "192.0.2.30"}).text
    cmd = oneliner(t)
    assert "SITE_REPO" in cmd and "TOOLKIT_REF" in cmd and "inferenceNodes.aiNodes" in t


def test_the_firewall_step_comes_before_any_engine_serves(app):
    for eng in ("mlx-lm", "omlx", "vllm-mlx", "vllm", "ollama", "llama-server", "lm-studio"):
        t = app.get("/nodes/add/apple-silicon-mac", params={"engine": eng}).text
        manual = t[t.index("Manage it yourself"):]
        fw = manual.find("pfctl")
        assert fw >= 0, f"{eng}: no firewall step in the manual path"
        serve = [manual.find(s) for s in ("mlx_lm.server", "mlx_lm server", "brew services", "ollama serve", "llama-server ", "--host")
                 if manual.find(s) >= 0]
        assert not serve or fw < min(serve), f"{eng}: something serves before the firewall is on"


def test_a_converged_engine_has_no_warning_and_another_has(app):
    ok = app.get("/nodes/add/apple-silicon-mac", params={"engine": "mlx-lm"}).text
    other = app.get("/nodes/add/apple-silicon-mac", params={"engine": "omlx"}).text
    assert "The converger handles" not in ok and "The converger handles" in other


# ---- the change

def enroll_post(c, **over):
    t = c.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio-2", "host": "192.0.2.30", "engine": "mlx-lm", **over}).text
    d = draft_of(t)
    assert d, "no draft on the enrol page"
    return t, d


def test_the_enrol_draft_enrolls_the_node(app):
    _, d = enroll_post(app)
    doc = json.loads(d)
    n = doc["nodes"][0]
    assert n["id"] == "studio-2" and n["management"] == {"enrolled": True} and n["type"] == "apple-silicon-mac"
    assert n["endpoints"] and n["endpoints"][0]["engine"] == "mlx-lm"
    nm.parse_inventory(doc)


@pytest.fixture
def generator(monkeypatch):
    """A stand-in for app/ai_nodes.py (the renderer's module), so these tests hold with or without the real one.
    It records how the UI calls skeleton_ai_node_yaml(ai_node_id, node_type, memory_gib, admin_cidrs)."""
    import types
    calls = []
    mod = types.ModuleType("app.ai_nodes")

    def skeleton_ai_node_yaml(ai_node_id, node_type, memory_gib, admin_cidrs):
        calls.append((ai_node_id, node_type, memory_gib, list(admin_cidrs)))
        return f"schema: tockmox.ai-node/v1\naiNodeId: {ai_node_id}\n"
    mod.skeleton_ai_node_yaml = skeleton_ai_node_yaml
    monkeypatch.setitem(sys.modules, "app.ai_nodes", mod)
    monkeypatch.setattr("app.ai_nodes", mod, raising=False)
    return calls


def test_the_change_page_offers_the_node_file_beside_the_values_change(tmp_path, generator):
    c = make_app(tmp_path, block(mac("studio", enrolled=False)))
    _, d = enroll_post(c)
    r = c.post("/nodes/change", data={"csrf": csrf(c), "draft": d})
    assert r.status_code == 200, r.text[:300]
    page = html.unescape(r.text)
    assert "Enrolls" in page and "studio-2" in page
    assert "ai-nodes/studio-2/ai-node.yaml" in page and "aiNodeId: studio-2" in page
    assert "management" in page
    assert generator == [("studio-2", "apple-silicon-mac", generator[0][2], ["192.0.2.0/24"])]


def test_the_node_file_downloads_as_yaml(tmp_path, generator):
    c = make_app(tmp_path, block(mac("studio", enrolled=False)))
    _, d = enroll_post(c)
    r = c.post("/nodes/change", data={"csrf": csrf(c), "draft": d, "format": "ai-node", "ai_node": "studio-2"})
    assert r.status_code == 200
    assert "ai-node.studio-2.yaml" in r.headers.get("content-disposition", "")
    assert r.text.startswith("schema: tockmox.ai-node/v1")


def test_the_node_file_download_refuses_an_id_that_is_not_in_the_draft(tmp_path, generator):
    c = make_app(tmp_path, block(mac("studio", enrolled=False)))
    _, d = enroll_post(c)
    r = c.post("/nodes/change", data={"csrf": csrf(c), "draft": d, "format": "ai-node", "ai_node": "someone-else"})
    assert r.status_code == 400 and "aiNodeId" not in r.text


def test_a_build_without_the_generator_still_enrolls_and_says_what_is_missing(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, "app.ai_nodes", None)              # `import` of it now raises ImportError
    c = make_app(tmp_path, block(mac("studio", enrolled=False)))
    _, d = enroll_post(c)
    r = c.post("/nodes/change", data={"csrf": csrf(c), "draft": d})
    assert r.status_code == 200
    page = html.unescape(r.text)
    assert "Enrolls" in page and "no ai-node.yaml generator" in page


def test_the_admin_cidrs_warning_shows_when_the_site_names_none(tmp_path, generator):
    c = make_app(tmp_path, block(mac("studio", enrolled=False), ai={k: v for k, v in AI.items() if k != "adminCidrs"}))
    _, d = enroll_post(c)
    page = html.unescape(c.post("/nodes/change", data={"csrf": csrf(c), "draft": d}).text)
    assert "adminCidrs" in page and "empty" in page and generator[0][3] == []


def test_an_already_enrolled_node_gets_no_second_skeleton(tmp_path, generator):
    c = make_app(tmp_path, block(mac("studio", enrolled=True)))
    t = c.get("/nodes/add/apple-silicon-mac", params={"node_id": "studio", "host": "10.0.0.5"}).text
    d = draft_of(t)
    if d:
        page = html.unescape(c.post("/nodes/change", data={"csrf": csrf(c), "draft": d}).text)
        assert "ai-nodes/studio/ai-node.yaml" not in page
    assert generator == []


def test_the_change_is_refused_without_a_csrf_token(app):
    _, d = enroll_post(app)
    assert app.post("/nodes/change", data={"csrf": "nope", "draft": d}).status_code == 400


# ---- the node page

def page_of(tmp_path, nodes, ai_rows, flap=None, nid="studio", ai=AI):
    prom = FakeProm(ai=ai_rows, up=UP, flap=flap or {})
    c = make_app(tmp_path, block(*nodes, ai=ai), prom)
    return c.get(f"/nodes/{nid}").text


def test_an_enrolled_node_shows_convergence_and_readiness(tmp_path):
    t = page_of(tmp_path, [mac()], converge_rows() + readiness_rows() + [info_row()], flap_rows(changed=0))
    assert 'id="conv-h"' in t and 'id="ready-h"' in t
    assert SHA[:8] in t and "v0.9.0" in t and "warn" in t
    assert "measured" in t


def test_an_enrolled_node_that_has_not_reported_says_so_and_is_not_green(tmp_path):
    t = page_of(tmp_path, [mac()], [])
    assert 'id="conv-h"' in t and "this node has not reported a converge" in t
    assert panel_state(t) == "unknown"


def test_a_failing_converge_names_its_phase_on_the_page(tmp_path):
    t = page_of(tmp_path, [mac()], converge_rows(exit_code=2, phase="verify") + readiness_rows())
    assert "verify" in t.split('id="conv-h"')[1]


def test_an_unenrolled_node_has_no_convergence_or_readiness_panel(tmp_path):
    t = page_of(tmp_path, [mac(enrolled=False)], [])
    assert 'id="conv-h"' not in t and 'id="ready-h"' not in t
    assert "onvergence" not in t


def test_an_unenrolled_node_that_reports_is_told_to_enroll_not_judged(tmp_path):
    t = page_of(tmp_path, [mac(enrolled=False)], converge_rows() + readiness_rows())
    assert 'id="conv-h"' not in t and "enroll" in t.lower()


def test_values_from_prometheus_are_escaped(tmp_path):
    evil = '<script>alert(1)</script>'
    rows = converge_rows(commit="a" * 40, ref=evil, mode=evil)
    t = page_of(tmp_path, [mac()], rows + readiness_rows())
    assert evil not in t and "&lt;script&gt;" in t


def test_prometheus_down_shows_unknown_not_the_last_good_convergence(tmp_path):
    prom = FakeProm(ai=converge_rows() + readiness_rows(), up=UP, flap=flap_rows(changed=0))
    c = make_app(tmp_path, block(mac()), prom)
    assert panel_state(c.get("/nodes/studio").text) == "ok"
    prom.fail = True
    r = c.get("/nodes/studio")
    assert r.status_code == 200          # a stale reading once crashed the page: the override dropped interval_s
    assert panel_state(r.text) == "unknown" and panel_state(r.text, "ready-h") == "unknown"
    assert c.get("/nodes").status_code == 200


def test_the_nodes_list_badges_convergence_only_for_enrolled_nodes(tmp_path):
    prom = FakeProm(ai=converge_rows("a") + readiness_rows("a"), up=UP, flap=flap_rows("a", changed=0))
    c = make_app(tmp_path, block(mac("a"), mac("b", enrolled=False, address="10.0.0.6")), prom)
    t = c.get("/nodes").text
    assert t.count("Convergence") == 1


# ---- parsing

def test_management_validation_and_merge_keep_enrolment():
    base = nm.parse_inventory({"nodes": [mac("a")]})
    assert base.nodes[0].enrolled
    for bad in ({"enrolled": "yes"}, {"enrolled": 1}, {"other": True}, True, "x"):
        n = mac("a"); n["management"] = bad
        with pytest.raises(nm.NodeError):
            nm.parse_inventory({"nodes": [n]})
    again = nm.parse_inventory({"nodes": [mac("a", enrolled=False)]})
    assert not again.nodes[0].enrolled
    merged = nm.merge(base, again)                      # an import of the same node must not drop an enrolment
    assert merged.nodes[0].enrolled
    assert nm.inventory_to_doc(merged)["nodes"][0]["management"] == {"enrolled": True}
    assert "management" not in nm.inventory_to_doc(again)["nodes"][0]


def test_ai_settings_validation():
    s = nm.parse_ai_settings({"siteRepo": "git@git.example.com:t/s.git", "toolkitRef": "v1.2.3", "signingMode": "enforce",
                              "convergeIntervalSeconds": 300, "adminCidrs": ["192.0.2.0/24"]})
    assert s.converge_interval_s == 300 and s.signing_mode == "enforce" and s.admin_cidrs == ("192.0.2.0/24",)
    assert nm.parse_ai_settings(None).converge_interval_s == 900
    for bad in ({"convergeIntervalSeconds": 59}, {"convergeIntervalSeconds": 86401}, {"convergeIntervalSeconds": "x"},
                {"signingMode": "off"}, {"siteRepo": "a b; c"}, {"toolkitRef": "$(x)"}, {"nope": 1}, {"adminCidrs": ["nope"]}):
        with pytest.raises(nm.NodeError):
            nm.parse_ai_settings(bad)


def test_the_enrol_command_helper_directly():
    c = nm.enroll_command("studio-2", "192.0.2.30", AI["siteRepo"], AI["toolkitRef"])
    assert c.complete and "studio-2" in c.text
    assert not nm.enroll_command("bad id", "192.0.2.30", "", "").complete
    assert not nm.enroll_command("studio-2", "x;y", "", "").complete
    for bad in ("x; id", "$(id)", "a b"):
        assert bad not in nm.enroll_command(bad, "192.0.2.30", "", "").text
        assert all(bad not in n for n in nm.enroll_command(bad, "192.0.2.30", "", "").notes)

# SPDX-License-Identifier: Apache-2.0
"""TM-1299: the node page lists the models it serves per endpoint, with tunings, planned memory and a memory bar, and
the Models page links every local deployment to its node. Run from tockmox-ui/: python -m pytest tests"""
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tests.models_support import inventory_doc, models_client  # noqa: E402


def inventory(extra_routes=()):
    """alpha (256 GiB, M5 Ultra preset): local-medium live on mlx-lm :8080, local-medium-next beside it on :8082."""
    d = inventory_doc()
    d["routes"] = [
        {"alias": "local-medium", "model": "example-org/Example-27B-4bit", "node": "alpha", "endpoint": "mlx-lm-8080", "sizeGiB": 15.0,
         "modelInfo": {"max_input_tokens": 32768},
         "params": {"max_tokens": 8192, "temperature": 0.2, "extra_body": {"chat_template_kwargs": {"enable_thinking": False}}}},
        {"alias": "local-medium-next", "model": "example-org/Example-2-27B-4bit", "node": "alpha", "endpoint": "mlx-lm-8082",
         "sizeGiB": 30.0},
        {"alias": "local-embed", "model": "example-embed-4b-q8", "node": "beta", "endpoint": "llama-8081", "kind": "embedding", "sizeGiB": 4.0},
        *extra_routes]
    return d


def page(tmp_path, nid="alpha", **kw):
    c, _ = models_client(tmp_path, inventory=inventory(kw.pop("extra_routes", ())), **kw)
    r = c.get(f"/nodes/{nid}")
    assert r.status_code == 200
    return r.text, c


def text_of(t):
    return html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", t)))


def section(t):
    return t.split('id="models-h"', 1)[1].split('id="hw-h"', 1)[0]


def test_a_node_with_two_endpoints_and_a_candidate_renders_both_groups_the_rows_the_bar_totals_and_both_links(tmp_path):
    t, _ = page(tmp_path)
    s = section(t)
    flat = text_of(s)
    # one group per endpoint that serves something, then the idle ones
    assert "mlx-lm server :8080" in flat and "mlx-lm server :8082" in flat
    tbl = text_of(s.split("<table", 1)[1])
    assert tbl.index("mlx-lm server :8080") < tbl.index("local-medium ") < tbl.index("mlx-lm server :8082") < tbl.index("local-medium-next")
    assert "2 deployments on 4 endpoints" in flat
    assert "serves 1 deployment, on the eval gateway where no agent can call it" in flat
    # the rows: model, build, tunings from the route, planned at fit's arithmetic (15 + 10% = 16.5; 30 + 10% = 33.0)
    assert "example-org/Example-27B-4bit" in s and "example-org/Example-2-27B-4bit" in s
    live = re.search(r'<tr>\s*<th scope="row"><a href="/models/a/local-medium">.*?</tr>', s, re.S).group(0)
    cells = text_of(live)
    assert "32K" in cells and "8K" in cells and "Off" in cells and "16.5" in cells and "Live" in cells
    assert "engine default, not reported" in cells                      # slots: Tockmox records none
    cand = re.search(r'<tr class="cand">.*?</tr>', s, re.S).group(0)
    assert "33.0" in text_of(cand) and "Candidate -next" in text_of(cand)
    # the bar: totals in GiB, the usable line and the legend
    assert "49.5 GiB planned of 256.0 GiB" in flat
    assert "Pinned, serving 16.5 GiB" in flat and "Candidate (-next) 33.0 GiB" in flat and "Free 206.5 GiB" in flat
    assert "192.0 GiB usable (75%)" in flat
    assert re.search(r'class="membar" role="img"[^>]*aria-label="[^"]*local-medium 16.5[^"]*local-medium-next 33.0 \(candidate\)[^"]*free 206.5', t)
    assert len(re.findall(r'<svg x="[\d.]+%" y="0" width="[\d.]+%" height="34" class="seg (pinned|candidate)"', s)) == 2
    # both links: the alias to its page (the candidate to its candidate page, and to the alias it replaces)
    assert 'href="/models/a/local-medium"' in s
    assert 'href="/models/c/local-medium"' in s and live.count("/models/a/local-medium") == 1
    assert 'href="/nodes/' not in s                                      # the page does not link to itself


def test_the_bar_draws_without_inline_styles_the_csp_would_block(tmp_path):
    t, c = page(tmp_path)
    assert "style=" not in section(t)
    assert "style-src 'self'" in c.get("/nodes/alpha").headers["content-security-policy"]


def test_defaults_are_labelled_and_the_route_params_the_columns_do_not_show_sit_under_more_settings(tmp_path):
    t, _ = page(tmp_path)
    s = section(t)
    cand = text_of(re.search(r'<tr class="cand">.*?</tr>', s, re.S).group(0))
    assert "engine default" in cand and "Off" not in cand               # nothing stated on the candidate's route
    assert "More settings for local-medium" in text_of(s) and "temperature" in s and "0.2" in s
    assert "More settings for local-medium-next" not in text_of(s)


def test_a_deployment_with_unknown_size_is_listed_and_left_out_of_the_bar(tmp_path):
    odd = {"alias": "local-odd", "model": "example-org/mystery-4bit", "node": "alpha", "endpoint": "llama-8081"}
    t, _ = page(tmp_path, extra_routes=[odd])
    s = section(t)
    flat = text_of(s)
    assert "local-odd" in flat and "size unknown" in flat
    assert "Not in the bar: local-odd (size unknown: not in the bar)" in flat
    assert "49.5 GiB planned of 256.0 GiB" in flat                       # unchanged by it
    assert "local-odd" not in re.search(r'aria-label="([^"]*)"', s).group(1)


def test_an_endpoint_that_serves_nothing_says_so_and_a_node_with_no_routes_still_renders(tmp_path):
    t, _ = page(tmp_path)
    assert "serves no model yet" in text_of(section(t))               # the llama-server and Ollama endpoints
    (tmp_path / "b").mkdir()
    t2, _ = page(tmp_path / "b", nid="beta")
    f = text_of(section(t2))
    assert "local-embed" in f and "4.4 GiB planned of 64.0 GiB" in f and "48.0 GiB usable (75%)" in f


def test_the_existing_sections_are_kept(tmp_path):
    t, _ = page(tmp_path)
    for h in ("hw-h", "eps-h", "place-h"):
        assert f'id="{h}"' in t
    assert t.index('id="models-h"') < t.index('id="hw-h"')


def test_the_models_page_links_each_local_deployment_to_its_node(tmp_path):
    c, _ = models_client(tmp_path, inventory=inventory())
    t = c.get("/models").text
    assert t.count('href="/nodes/alpha"') >= 1                          # the candidate's row, and the catalog's routes column
    assert re.search(r'<code>local-medium-next</code>.*?<a href="/nodes/alpha">alpha</a>', t, re.S)
    assert '(<a href="/nodes/alpha">alpha</a>)' in t                    # the catalog's routes column
    # a node link is a real page
    assert c.get("/nodes/alpha").status_code == 200

# SPDX-License-Identifier: Apache-2.0
"""Tests of the mlx-lm request guard (roles/engine_mlx_lm/files/tockmox_mlx_lm_guard.py).

The decision (screen) and the ceiling parser are tested directly. The handler wrapping is tested against a
stand-in APIHandler that reads its body the way mlx_lm.server 0.32.2 does (Content-Length, then rfile).
When mlx_lm is importable, InstalledRelease also checks that the installed mlx_lm.server still has what the
guard relies on; run the suite with a release installed before adding it to engine_mlx_lm_guard_vetted.

    python3 -m unittest discover -s ai-node/tests/unit -v
"""
import email.message
import importlib.machinery
import importlib.util
import inspect
import io
import json
import os
import re
import subprocess
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AI = os.path.dirname(os.path.dirname(HERE))
GUARD_PATH = os.path.join(AI, "roles", "engine_mlx_lm", "files", "tockmox_mlx_lm_guard.py")

_loader = importlib.machinery.SourceFileLoader("tockmox_mlx_lm_guard", GUARD_PATH)
_spec = importlib.util.spec_from_loader("tockmox_mlx_lm_guard", _loader)
G = importlib.util.module_from_spec(_spec)
_loader.exec_module(G)

SERVED = "org/Served-27B-8bit"
SIBLING = "org/Sibling-122B-8bit"


def stand_in_server():
    """A fresh module with an APIHandler that does what mlx_lm.server 0.32.2's does with a request body."""

    class APIHandler:
        def __init__(self, path, raw, cli):
            self.path = path
            self.headers = email.message.Message()
            if raw is not None:
                self.headers["Content-Length"] = str(len(raw))
            self.rfile = io.BytesIO(raw or b"")
            self.wfile = io.BytesIO()
            self.response_generator = types.SimpleNamespace(cli_args=cli)
            self.created = 1700000000
            self.status = None
            self.seen = None
            self.sent = []

        def _set_completion_headers(self, status_code=200):
            self.status = status_code

        def send_header(self, k, v):
            self.sent.append((k, v))

        def end_headers(self):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length"))
            raw = self.rfile.read(n)
            try:
                self.seen = json.loads(raw.decode())
                self.status = 200
            except ValueError:
                self.status = 400
            self.seen_raw = raw

        def handle_models_request(self):
            self.status = 200
            self.wfile.write(json.dumps({"data": [{"id": "every"}, {"id": "model"}]}).encode())

    return types.SimpleNamespace(APIHandler=APIHandler)


def cli(max_tokens=512):
    return types.SimpleNamespace(model=SERVED, max_tokens=max_tokens)


def run(body, ceiling=None, path="/v1/chat/completions", max_tokens=512, raw=None):
    srv = stand_in_server()
    G.install(srv, ceiling)
    h = srv.APIHandler(path, raw if raw is not None else json.dumps(body).encode(), cli(max_tokens))
    original_rfile = h.rfile
    h.do_POST()
    h.rfile_restored = h.rfile is original_rfile
    h.answer = json.loads(h.wfile.getvalue().decode()) if h.wfile.getvalue() else None
    return h


MSG = [{"role": "user", "content": "hi"}]


class Pin(unittest.TestCase):
    def test_the_declared_model_passes_byte_for_byte(self):
        body = {"model": SERVED, "messages": MSG, "max_tokens": 10}
        h = run(body)
        self.assertEqual(h.status, 200)
        self.assertEqual(h.seen_raw, json.dumps(body).encode())

    def test_default_model_and_no_model_pass(self):
        self.assertEqual(run({"model": "default_model", "messages": MSG}).status, 200)
        self.assertEqual(run({"messages": MSG}).status, 200)

    def test_a_sibling_model_is_404_and_never_reaches_mlx_lm(self):
        h = run({"model": SIBLING, "messages": MSG})
        self.assertEqual(h.status, 404)
        self.assertIsNone(h.seen)
        self.assertEqual(h.answer["error"]["code"], "model_not_found")
        self.assertIn(SERVED, h.answer["error"]["message"])
        self.assertTrue(h.rfile_restored)

    def test_a_path_or_a_non_string_model_is_refused_too(self):
        self.assertEqual(run({"model": "/opt/tockmox/models/hf/hub/x", "messages": MSG}).status, 404)
        self.assertEqual(run({"model": 7, "messages": MSG}).status, 404)

    def test_text_completions_are_pinned_as_well(self):
        self.assertEqual(run({"model": SIBLING, "prompt": "hi"}, path="/v1/completions").status, 404)
        self.assertEqual(run({"model": SIBLING, "messages": MSG}, path="/chat/completions").status, 404)

    def test_adapters_and_a_draft_model_are_400(self):
        h = run({"model": SERVED, "messages": MSG, "adapters": "/tmp/a"})
        self.assertEqual((h.status, h.answer["error"]["param"]), (400, "adapters"))
        h = run({"model": SERVED, "messages": MSG, "draft_model": SIBLING})
        self.assertEqual((h.status, h.answer["error"]["param"]), (400, "draft_model"))
        self.assertIsNone(h.seen)

    def test_null_adapters_pass_and_a_null_draft_model_is_dropped(self):
        h = run({"model": SERVED, "messages": MSG, "adapters": None, "draft_model": None})
        self.assertEqual(h.status, 200)
        self.assertNotIn("draft_model", h.seen)

    def test_the_answer_is_json_with_a_length(self):
        h = run({"model": SIBLING, "messages": MSG})
        self.assertIn(("Content-Length", str(len(h.wfile.getvalue()))), h.sent)


class Ceiling(unittest.TestCase):
    def test_max_tokens_above_the_ceiling_is_lowered(self):
        h = run({"model": SERVED, "messages": MSG, "max_tokens": 32000}, ceiling=8192)
        self.assertEqual(h.seen["max_tokens"], 8192)

    def test_max_completion_tokens_above_the_ceiling_is_lowered(self):
        h = run({"model": SERVED, "messages": MSG, "max_completion_tokens": 32000, "max_tokens": 9000}, ceiling=8192)
        self.assertEqual((h.seen["max_completion_tokens"], h.seen["max_tokens"]), (8192, 8192))

    def test_a_request_under_the_ceiling_is_untouched(self):
        body = {"model": SERVED, "messages": MSG, "max_tokens": 100}
        self.assertEqual(run(body, ceiling=8192).seen_raw, json.dumps(body).encode())

    def test_a_request_asking_nothing_gets_the_ceiling_when_the_default_is_higher(self):
        self.assertEqual(run({"model": SERVED, "messages": MSG}, ceiling=4096, max_tokens=8192).seen["max_tokens"], 4096)

    def test_a_request_asking_nothing_keeps_a_lower_default(self):
        self.assertNotIn("max_tokens", run({"model": SERVED, "messages": MSG}, ceiling=8192, max_tokens=512).seen)

    def test_no_ceiling_leaves_the_request_as_asked(self):
        self.assertEqual(run({"model": SERVED, "messages": MSG, "max_tokens": 32000}).seen["max_tokens"], 32000)

    def test_the_content_length_follows_the_new_body(self):
        h = run({"model": SERVED, "messages": MSG, "max_tokens": 32000}, ceiling=8)
        self.assertEqual(int(h.headers["Content-Length"]), len(h.seen_raw))

    def test_a_non_integer_is_left_for_mlx_lm_to_refuse(self):
        self.assertEqual(run({"model": SERVED, "messages": MSG, "max_tokens": "lots"}, ceiling=8).seen["max_tokens"], "lots")
        self.assertIs(run({"model": SERVED, "messages": MSG, "max_tokens": True}, ceiling=8).seen["max_tokens"], True)


class Passthrough(unittest.TestCase):
    def test_bad_json_reaches_mlx_lm_unchanged(self):
        h = run(None, raw=b"{not json")
        self.assertEqual((h.status, h.seen_raw), (400, b"{not json"))

    def test_another_path_is_not_read(self):
        srv = stand_in_server()
        G.install(srv, None)
        h = srv.APIHandler("/v1/other", json.dumps({"model": SIBLING}).encode(), cli())
        h.do_POST()
        self.assertEqual(h.seen["model"], SIBLING)

    def test_a_request_without_a_length_is_left_to_mlx_lm(self):
        srv = stand_in_server()
        G.install(srv, None)
        h = srv.APIHandler("/v1/chat/completions", None, cli())
        with self.assertRaises(TypeError):  # the stand-in, like mlx-lm, answers it itself
            h.do_POST()


class Models(unittest.TestCase):
    def models(self, path):
        srv = stand_in_server()
        G.install(srv, None)
        h = srv.APIHandler(path, None, cli())
        h.handle_models_request()
        return h.status, json.loads(h.wfile.getvalue().decode())

    def test_only_the_declared_model_is_listed(self):
        status, d = self.models("/v1/models")
        self.assertEqual((status, [m["id"] for m in d["data"]]), (200, [SERVED]))

    def test_asking_for_the_declared_model_by_id_finds_it_and_another_finds_nothing(self):
        self.assertEqual([m["id"] for m in self.models("/v1/models/" + SERVED)[1]["data"]], [SERVED])
        self.assertEqual(self.models("/v1/models/" + SIBLING)[1]["data"], [])


class Startup(unittest.TestCase):
    def test_the_ceiling_is_read_from_the_environment(self):
        self.assertIsNone(G.parse_ceiling({}))
        self.assertIsNone(G.parse_ceiling({G.CEILING_ENV: ""}))
        self.assertEqual(G.parse_ceiling({G.CEILING_ENV: " 8192 "}), 8192)
        for bad in ("0", "-1", "8.5", "lots", "1e4"):
            with self.assertRaises(ValueError, msg=bad):
                G.parse_ceiling({G.CEILING_ENV: bad})

    def test_a_bad_ceiling_exits_64_before_mlx_lm_is_imported(self):
        env = dict(os.environ, **{G.CEILING_ENV: "lots"})
        r = subprocess.run([sys.executable, "-I", GUARD_PATH, "--model", SERVED], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 64, r.stderr)
        self.assertIn(G.CEILING_ENV, r.stderr)

    def test_a_release_without_a_wrapped_handler_is_refused(self):
        srv = stand_in_server()
        del srv.APIHandler.handle_models_request
        with self.assertRaises(RuntimeError) as e:
            G.install(srv, None)
        self.assertIn("handle_models_request", str(e.exception))
        with self.assertRaises(RuntimeError):
            G.install(types.SimpleNamespace(), None)


class Role(unittest.TestCase):
    def read(self, *rel):
        with open(os.path.join(AI, *rel), encoding="utf-8") as f:
            return f.read()

    def test_every_instance_starts_through_the_guard_and_restarts_when_it_changes(self):
        role = self.read("roles", "engine_mlx_lm", "tasks", "macos.yml")
        self.assertIn("'/bin/python', '-I', engine_mlx_lm_guard, '--model', item.repo", role)
        self.assertNotIn("/bin/mlx_lm.server'", role)
        self.assertIn("engine_mlx_lm_guard_copy is changed", role)
        self.assertIn("tn_mlx_version in engine_mlx_lm_guard_vetted", role)
        self.assertIn("TOCKMOX_MLX_MAX_OUTPUT_TOKENS", role)

    def test_every_vetted_release_and_every_patched_release_agree(self):
        defaults = self.read("roles", "engine_mlx_lm", "defaults", "main.yml")
        vetted = json.loads(re.search(r"(?m)^engine_mlx_lm_guard_vetted: (\[.*\])$", defaults).group(1))
        self.assertTrue(vetted)
        patches = os.path.join(AI, "roles", "engine_mlx_lm", "files", "patches")
        for version in os.listdir(patches) if os.path.isdir(patches) else []:
            self.assertIn(version, vetted, "a patch for mlx-lm %s, a release the guard does not run on" % version)

    def test_the_schema_bounds_the_ceiling(self):
        mlx = json.loads(self.read("schema", "ai-node.v1.schema.json"))["properties"]["engines"]["properties"]["mlx-lm"]
        c = mlx["properties"]["maxOutputTokens"]
        self.assertEqual((c["type"], c["minimum"]), ("integer", 1))


try:
    import mlx_lm.server as INSTALLED  # only where a release is installed
except Exception:  # pragma: no cover - the usual case on CI
    INSTALLED = None


@unittest.skipIf(INSTALLED is None, "mlx_lm is not installed here")
class InstalledRelease(unittest.TestCase):
    """What the guard relies on in the installed mlx_lm.server."""

    def test_the_wrapped_handlers_exist(self):
        for name in G.WRAPPED:
            self.assertTrue(callable(getattr(INSTALLED.APIHandler, name, None)), name)

    def test_do_post_reads_the_body_and_the_fields_the_guard_screens(self):
        src = inspect.getsource(INSTALLED.APIHandler.do_POST)
        for needle in ('self.headers.get("Content-Length")', "self.rfile.read(content_length)",
                       'self.body.get("model", "default_model")', 'self.body.get("adapters", None)',
                       'self.body.get("draft_model", "default_model")', 'self.body.get("max_completion_tokens", None)',
                       '"max_tokens", self.response_generator.cli_args.max_tokens'):
            self.assertIn(needle, src)
        for path in G.COMPLETIONS:
            self.assertIn('"%s"' % path, src)

    def test_the_server_answers_one_request_per_connection(self):
        # The guard swaps rfile for one request; HTTP/1.0 closes the connection after it.
        self.assertEqual(getattr(INSTALLED.APIHandler, "protocol_version", "HTTP/1.0"), "HTTP/1.0")


if __name__ == "__main__":
    unittest.main()

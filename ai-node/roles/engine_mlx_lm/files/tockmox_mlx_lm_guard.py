# SPDX-License-Identifier: Apache-2.0
"""tockmox_mlx_lm_guard: mlx_lm.server under the request guard every toolkit mlx-lm engine runs with.

    <venv>/bin/python -I tockmox_mlx_lm_guard.py --model REPO-ID [mlx_lm.server options ...]

Every option goes to mlx_lm.server unchanged. Before the server starts, three of its request handlers are
wrapped in this process; the installed package is not changed.

PIN. A process serves the one model it was started with. mlx_lm.server treats a request's "model" as a name
to load, so naming any other model in the Hugging Face cache swaps those weights in place of the declared
model, and "adapters" or "draft_model" load further weights from a path the client chooses. Here a completion
request whose model is neither the --model value nor "default_model" is answered 404 (model_not_found), and
one that names adapters or a draft model is answered 400, before mlx-lm sees it. GET /v1/models lists only
the --model id.

CEILING. With TOCKMOX_MLX_MAX_OUTPUT_TOKENS=N in the environment, no request generates more than N tokens:
a max_tokens or max_completion_tokens above N is lowered to N, so the answer ends with finish_reason "length",
and a request that sends neither gets the smaller of N and --max-tokens. mlx-lm on its own takes whatever
the request asks.

The wrapped handlers are internal to mlx-lm. The engine role runs this only on an mlx-lm release it lists
as vetted (engine_mlx_lm_guard_vetted), and the process refuses to start when a handler it wraps is missing.

Exit: what mlx_lm.server exits with; 64 a bad TOCKMOX_MLX_MAX_OUTPUT_TOKENS; 70 mlx-lm lacks a wrapped handler.
"""
import io
import json
import logging
import os
import sys

COMPLETIONS = ("/v1/completions", "/v1/chat/completions", "/chat/completions")
DEFAULT_MODEL = "default_model"
CEILING_ENV = "TOCKMOX_MLX_MAX_OUTPUT_TOKENS"
WRAPPED = ("do_POST", "handle_models_request", "_set_completion_headers")


def parse_ceiling(env):
    """The output-token ceiling from the environment: None when unset or empty, else a positive int."""
    raw = (env.get(CEILING_ENV) or "").strip()
    if not raw:
        return None
    if not raw.isdigit() or int(raw) < 1:
        raise ValueError("%s must be a whole number of at least 1, got %r" % (CEILING_ENV, raw))
    return int(raw)


def _error(message, param, code):
    return {"error": {"message": message, "type": "invalid_request_error", "param": param, "code": code}}


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def screen(body, served, ceiling, default_max_tokens):
    """Decide one completion request.

    Returns (status, error_body) to refuse it, or (None, body) to pass it on, where body may be a changed
    copy. A body that is not a JSON object passes unchanged: mlx-lm answers it with its own 400.
    """
    if not isinstance(body, dict):
        return None, body
    model = body.get("model", DEFAULT_MODEL)
    if model not in (served, DEFAULT_MODEL):
        return 404, _error("This engine serves %s only. It does not load %r: ask the route for this model, "
                           "or the engine that serves the other one." % (served, model), "model", "model_not_found")
    if body.get("adapters") is not None:
        return 400, _error("This engine does not load adapters named by a request.", "adapters", "unsupported_parameter")
    if body.get("draft_model", DEFAULT_MODEL) not in (DEFAULT_MODEL, None):
        return 400, _error("This engine does not load a draft model named by a request.", "draft_model",
                           "unsupported_parameter")
    out = dict(body)
    # An explicit null draft model would make mlx-lm reload the declared model without the configured draft.
    if "draft_model" in out and out["draft_model"] is None:
        del out["draft_model"]
    if ceiling is not None:
        for key in ("max_completion_tokens", "max_tokens"):
            if _is_int(out.get(key)) and out[key] > ceiling:
                out[key] = ceiling
        if out.get("max_completion_tokens") is None and out.get("max_tokens") is None:
            if not _is_int(default_max_tokens) or default_max_tokens > ceiling:
                out["max_tokens"] = ceiling
    return None, (body if out == body else out)


def _send_json(handler, status, payload):
    data = json.dumps(payload).encode()
    handler._set_completion_headers(status)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)
    handler.wfile.flush()


def install(server_module, ceiling):
    """Wrap mlx_lm.server.APIHandler in place. Raises RuntimeError when a handler it wraps is missing."""
    handler_cls = getattr(server_module, "APIHandler", None)
    missing = [n for n in WRAPPED if not callable(getattr(handler_cls, n, None))]
    if handler_cls is None or missing:
        raise RuntimeError("mlx_lm.server has no APIHandler.%s; this release is not one the guard was vetted on"
                           % ", APIHandler.".join(missing or ["*"]))
    original_post = handler_cls.do_POST

    def do_POST(self):
        if self.path not in COMPLETIONS:
            return original_post(self)
        try:
            length = int(self.headers.get("Content-Length"))
        except (TypeError, ValueError):
            return original_post(self)  # mlx-lm answers 411 or 400
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode())
        except (UnicodeDecodeError, ValueError):
            body = None
        new = raw
        if body is not None:
            cli = self.response_generator.cli_args
            status, result = screen(body, cli.model, ceiling, getattr(cli, "max_tokens", None))
            if status is not None:
                logging.warning("tockmox guard: %d %s for model %r", status, result["error"]["code"],
                                str(body.get("model"))[:200])
                return _send_json(self, status, result)
            if result is not body:
                new = json.dumps(result).encode()
        saved = self.rfile
        self.rfile = io.BytesIO(new)
        del self.headers["Content-Length"]
        self.headers["Content-Length"] = str(len(new))
        try:
            return original_post(self)
        finally:
            self.rfile = saved

    def handle_models_request(self):
        served = self.response_generator.cli_args.model
        parts = self.path.split("?", 1)[0].split("/")
        wanted = "/".join(parts[3:]) if len(parts) > 3 else ""
        data = [] if wanted not in ("", served) else [
            {"id": served, "object": "model", "created": getattr(self, "created", 0), "owned_by": "tockmox-ai-node"}]
        _send_json(self, 200, {"object": "list", "data": data})

    handler_cls.do_POST = do_POST
    handler_cls.handle_models_request = handle_models_request


def main(argv=None):
    try:
        ceiling = parse_ceiling(os.environ)
    except ValueError as e:
        print("tockmox_mlx_lm_guard: %s" % e, file=sys.stderr)
        return 64
    import mlx_lm.server as server_module  # inside the engine's virtual environment
    try:
        install(server_module, ceiling)
    except RuntimeError as e:
        print("tockmox_mlx_lm_guard: %s" % e, file=sys.stderr)
        return 70
    sys.argv = [sys.argv[0]] + list(sys.argv[1:] if argv is None else argv)
    server_module.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())

# SPDX-License-Identifier: Apache-2.0
# A minimal OpenAI-compatible backend for tests/policy-gate/run.sh. Answers
# every chat completion with a fixed reply naming itself, and appends one line
# per request to a log file, so the test can count what reached it.
# Minimal OpenAI-compatible backend that records every request it receives.
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
port, name, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _rec(self):
        with open(log, "a") as f: f.write(json.dumps({"t": time.time(), "path": self.path}) + "\n")
    def do_GET(self):
        self._rec(); b = json.dumps({"object": "list", "data": [{"id": "fake", "object": "model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n); self._rec()
        b = json.dumps({"id": "x", "object": "chat.completion", "created": int(time.time()), "model": "fake",
                        "choices": [{"index": 0, "message": {"role": "assistant", "content": f"hello from {name}"}, "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 3, "total_tokens": 4}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
HTTPServer(("127.0.0.1", port), H).serve_forever()

# SPDX-License-Identifier: Apache-2.0
"""A small OpenAI-compatible client for the eval runner: one completion, plain or streamed, with timings.

It speaks only to the base URL it is given (the eval gateway), follows no redirect, sends the key only in the
Authorization header, and records what the runner needs: the reply text, tool calls, finish reason, usage, time to
first token and time to the complete answer, and, when streaming, the shape of the event stream.
"""
from __future__ import annotations

import json
import time

import httpx


class GatewayError(RuntimeError):
    pass


def complete(base_url: str, key: str, model: str, messages: list, *, tools=None, response_format=None,
             max_tokens: int = 512, temperature: float = 0.0, seed: int | None = None, stream: bool = False,
             timeout: float = 300.0) -> dict:
    """Returns {"content", "tool_calls": [{"name", "arguments"}], "finish_reason", "usage", "ttft_s", "total_s",
    "reasoning_chars", "stream": {"events", "done", "usage_chunk", "order_ok"} (stream only)}. reasoning_chars counts
    the reasoning text an engine returns beside the answer (reasoning_content or reasoning), so a caller can tell a
    model that spent its token budget thinking from one that answered nothing."""
    body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
    if seed is not None:
        body["seed"] = seed
    if tools:
        body["tools"] = tools
    if response_format:
        body["response_format"] = response_format
    if stream:
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
    url = base_url.rstrip("/") + "/v1/chat/completions"
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    t0 = time.monotonic()
    with httpx.Client(timeout=timeout, follow_redirects=False) as c:
        if not stream:
            r = c.post(url, headers=headers, json=body)
            total = time.monotonic() - t0
            if r.status_code != 200:
                raise GatewayError(f"{model}: HTTP {r.status_code}: {r.text[:200]}")
            d = r.json()
            ch = (d.get("choices") or [{}])[0]
            msg = ch.get("message") or {}
            return {"content": msg.get("content") or "", "tool_calls": _calls(msg.get("tool_calls")),
                    "finish_reason": ch.get("finish_reason"), "usage": d.get("usage") or {},
                    "ttft_s": total, "total_s": total, "reasoning_chars": len(_reasoning(msg))}
        return _stream(c, url, headers, body, t0, model)


def _reasoning(part) -> str:
    """The reasoning text in a message or a stream delta: LiteLLM passes reasoning_content, some engines reasoning."""
    v = part.get("reasoning_content") or part.get("reasoning") or ""
    return v if isinstance(v, str) else ""


def _calls(raw) -> list:
    out = []
    for tc in raw or []:
        fn = (tc or {}).get("function") or {}
        out.append({"name": fn.get("name"), "arguments": fn.get("arguments") or ""})
    return out


def _stream(c, url, headers, body, t0, model) -> dict:
    content, calls, finish, usage, ttft, reasoning = [], {}, None, {}, None, 0
    events, done, usage_chunk, order_ok, after_done = 0, False, False, True, False
    with c.stream("POST", url, headers=headers, json=body) as r:
        if r.status_code != 200:
            raise GatewayError(f"{model}: HTTP {r.status_code}: {r.read()[:200]!r}")
        for line in r.iter_lines():
            if not line or not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                continue
            if done:
                after_done = True
            events += 1
            try:
                d = json.loads(data)
            except ValueError:
                order_ok = False
                continue
            if d.get("usage"):
                usage, usage_chunk = d["usage"], True
            for ch in d.get("choices") or []:
                delta = ch.get("delta") or {}
                reasoning += len(_reasoning(delta))
                if delta.get("content"):
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    content.append(delta["content"])
                for tc in delta.get("tool_calls") or []:
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    i = tc.get("index", 0)
                    slot = calls.setdefault(i, {"name": "", "arguments": ""})
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        slot["name"] = fn["name"]
                    slot["arguments"] += fn.get("arguments") or ""
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
    total = time.monotonic() - t0
    return {"content": "".join(content), "tool_calls": [calls[k] for k in sorted(calls)], "finish_reason": finish,
            "usage": usage, "ttft_s": ttft if ttft is not None else total, "total_s": total, "reasoning_chars": reasoning,
            "stream": {"events": events, "done": done, "usage_chunk": usage_chunk,
                       "order_ok": order_ok and not after_done}}

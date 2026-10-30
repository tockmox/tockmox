# SPDX-License-Identifier: Apache-2.0
"""eval-set/1: a versioned, classified set of cases and how each is graded (DESIGN-2026-10-29-eval-runner §4.2).

A set is a directory  evals/sets/<class>/<version>/  holding

  set.yaml      schema: eval-set/1, id, version, class, classification (REQUIRED), grader: rule, criterion,
                margin, min_effect (paired), bar (absolute), epochs, max_tokens, description,
                tool_parse_bar (optional, default 0.02: the most tool-call parse failures the candidate may show
                over the reliability leg before the verdict fails whatever its quality),
                speed_criterion (optional, {decode_tok_s_min_ratio: r}: candidate decode tokens/s over the
                incumbent's must reach r, or a quality pass reads as a tradeoff)
  cases.jsonl   one case per line: {"id", "messages", "tools"?, "response_format"?, "max_tokens"?, "grade": {...}}

Grades are deterministic (REQ-0045 ruling 1: a model judge is a separate, calibrated path, not this one):

  exact         the reply, stripped, equals `value`
  contains      the reply contains every string in `all` (and, when given, none in `none`)
  regex         the reply matches `pattern` (Python re, search)
  json_schema   the reply is JSON that validates against `schema` (jsonschema)
  tool_call     exactly one tool call to `name`, whose arguments are JSON containing `arguments` (a subset match)
  no_tool_call  no tool call at all (the model must answer, not reach for a tool)

A set's content hash (sha256 over set.yaml and cases.jsonl, in that order) is what a verdict names, so two runs on
the same version but edited cases can never be counted as the same evidence.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, field

import yaml

from .. import verdict_stats as vs

SCHEMA = "eval-set/1"
CLASSIFICATIONS = ("public", "internal", "confidential", "restricted")
GRADE_TYPES = ("exact", "contains", "regex", "json_schema", "tool_call", "no_tool_call")
MAX_CASES = 2000
_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


class SetError(ValueError):
    pass


@dataclass
class Case:
    id: str
    messages: list
    grade: dict
    tools: list = field(default_factory=list)
    response_format: dict | None = None
    max_tokens: int | None = None
    classification: str = ""     # TM-1249: a row may carry a class above its set's (a replay row, say); never below


@dataclass
class EvalSet:
    id: str
    version: str
    klass: str
    classification: str
    criterion: str
    cases: list
    sha256: str
    margin: float = 0.05
    min_effect: float = 0.05
    bar: float = 0.9
    epochs: int = 1
    max_tokens: int = 512
    path: str = ""
    tool_parse_bar: float = 0.02
    speed_criterion: dict = field(default_factory=dict)

    def tool_cases(self) -> list:
        """The cases that offer tools: what the tool-call reliability leg cycles through."""
        return [c for c in self.cases if c.tools]


def _case(raw: dict, i: int) -> Case:
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str) or not raw["id"]:
        raise SetError(f"case {i}: needs an id")
    msgs = raw.get("messages")
    if not isinstance(msgs, list) or not msgs or not all(isinstance(m, dict) and m.get("role") for m in msgs):
        raise SetError(f"case {raw['id']}: messages must be a non-empty list of {{role, content}}")
    g = raw.get("grade")
    if not isinstance(g, dict) or g.get("type") not in GRADE_TYPES:
        raise SetError(f"case {raw['id']}: grade.type must be one of {GRADE_TYPES}")
    t = g["type"]
    need = {"exact": ["value"], "contains": ["all"], "regex": ["pattern"], "json_schema": ["schema"],
            "tool_call": ["name"], "no_tool_call": []}[t]
    for k in need:
        if k not in g:
            raise SetError(f"case {raw['id']}: a {t} grade needs {k!r}")
    if t == "regex":
        try:
            re.compile(g["pattern"])
        except re.error as e:
            raise SetError(f"case {raw['id']}: bad pattern ({e})") from None
    if t in ("tool_call", "no_tool_call") and not raw.get("tools"):
        raise SetError(f"case {raw['id']}: a {t} grade needs the case to offer tools")
    rc = raw.get("classification", "") or ""
    if rc and rc not in CLASSIFICATIONS:
        raise SetError(f"case {raw['id']}: classification must be one of {CLASSIFICATIONS}, got {rc!r}")
    return Case(raw["id"], msgs, g, list(raw.get("tools") or []), raw.get("response_format"), raw.get("max_tokens"), rc)


def run_class(es) -> str:
    """TM-1249: the highest class among the set and its rows: what every request of a run on this set carries."""
    order = {c: i for i, c in enumerate(CLASSIFICATIONS)}
    return max([es.classification] + [c.classification for c in es.cases if c.classification], key=lambda c: order[c])


def load(directory: str, repo_path: str = "") -> EvalSet:
    sp, cp = os.path.join(directory, "set.yaml"), os.path.join(directory, "cases.jsonl")
    try:
        sb, cb = open(sp, "rb").read(), open(cp, "rb").read()
    except OSError as e:
        raise SetError(f"{directory}: needs set.yaml and cases.jsonl ({e})") from None
    meta = yaml.safe_load(sb) or {}
    if meta.get("schema") != SCHEMA:
        raise SetError(f'{sp}: needs "schema: {SCHEMA}"')
    for k in ("id", "version", "class", "criterion"):
        if not isinstance(meta.get(k), str) or not meta[k]:
            raise SetError(f"{sp}: missing {k!r}")
    if not _ID.match(meta["id"]) or not _ID.match(meta["class"]):
        raise SetError(f"{sp}: id and class must be slugs")
    if meta.get("classification") not in CLASSIFICATIONS:
        raise SetError(f"{sp}: classification is required and must be one of {CLASSIFICATIONS} "
                       "(an unclassified set cannot be checked against the route it is sent to)")
    if meta.get("grader", "rule") != "rule":
        raise SetError(f"{sp}: this runner grades deterministically (grader: rule); a judged class is a separate path")
    cases = []
    for i, line in enumerate(cb.decode("utf-8").splitlines()):
        if line.strip():
            try:
                cases.append(_case(json.loads(line), i))
            except ValueError as e:
                raise SetError(f"{cp}: line {i + 1}: {e}") from None
    if not cases or len(cases) > MAX_CASES:
        raise SetError(f"{cp}: needs 1 to {MAX_CASES} cases")
    if len({c.id for c in cases}) != len(cases):
        raise SetError(f"{cp}: case ids must be unique")

    def frac(k, default):
        v = meta.get(k, default)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v < 1:
            raise SetError(f"{sp}: {k} must be a fraction in [0, 1)")
        return float(v)
    epochs = meta.get("epochs", 1)
    if isinstance(epochs, bool) or not isinstance(epochs, int) or not 1 <= epochs <= 20:
        raise SetError(f"{sp}: epochs must be 1 to 20")
    speed = {}
    if meta.get("speed_criterion") is not None:
        try:
            speed = vs.check_speed_criterion(meta["speed_criterion"])
        except vs.StatsError as e:
            raise SetError(f"{sp}: {e}") from None
    h = hashlib.sha256(sb + b"\0" + cb).hexdigest()
    return EvalSet(meta["id"], str(meta["version"]), meta["class"], meta["classification"], meta["criterion"], cases, h,
                   frac("margin", 0.05), frac("min_effect", 0.05), frac("bar", 0.9), epochs,
                   int(meta.get("max_tokens", 512)), repo_path or directory, frac("tool_parse_bar", vs.DEFAULT_TOOL_PARSE_BAR), speed)


# ---------------------------------------------------------------- grading

def grade(case: Case, reply: dict) -> tuple[bool, str]:
    """reply = {"content": str, "tool_calls": [{"name", "arguments"}], "finish_reason": str}. Returns (passed, why)."""
    g, text = case.grade, (reply.get("content") or "")
    calls = reply.get("tool_calls") or []
    t = g["type"]
    if t == "exact":
        ok = text.strip() == str(g["value"]).strip()
        return ok, "" if ok else "the reply is not the expected text"
    if t == "contains":
        missing = [s for s in g["all"] if s not in text]
        present = [s for s in g.get("none", []) if s in text]
        return (not missing and not present), (f"missing {missing}" if missing else f"contains {present}" if present else "")
    if t == "regex":
        ok = re.search(g["pattern"], text) is not None
        return ok, "" if ok else "the reply does not match"
    if t == "json_schema":
        try:
            doc = json.loads(_strip_fence(text))
        except ValueError:
            return False, "the reply is not JSON"
        import jsonschema
        try:
            jsonschema.validate(doc, g["schema"])
        except jsonschema.ValidationError as e:
            return False, f"schema: {e.message[:120]}"
        return True, ""
    if t == "no_tool_call":
        return (not calls), "" if not calls else f"called {calls[0].get('name')}"
    # tool_call
    if len(calls) != 1:
        return False, f"{len(calls)} tool calls, expected exactly one"
    c = calls[0]
    if c.get("name") != g["name"]:
        return False, f"called {c.get('name')}, expected {g['name']}"
    try:
        args = json.loads(c.get("arguments") or "{}") if isinstance(c.get("arguments"), str) else (c.get("arguments") or {})
    except ValueError:
        return False, "the arguments are not JSON"
    want = g.get("arguments") or {}
    for k, v in want.items():
        if args.get(k) != v:
            return False, f"argument {k} is {args.get(k)!r}, expected {v!r}"
    return True, ""


def _strip_fence(text: str) -> str:
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else ""
        if t.rstrip().endswith("```"):
            t = t.rstrip()[:-3]
    return t.strip()

# SPDX-License-Identifier: Apache-2.0
"""A stdlib validator for the subset of JSON Schema the report schema uses.

The image is stdlib-only on purpose (nothing to pull at run time, nothing for a
dark site to mirror), so the differential Job cannot import `jsonschema`. It
still refuses to store a report its own published schema rejects: a report that
does not match the contract an integrator depends on is a defect, not a result.

Supported keywords: type, required, properties, items, enum, const. Anything
else in the schema is IGNORED, and tests/test_schema.py proves this subset
agrees with a full validator on every real report and every mutation it tries.
"""
import json, os

_TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}

DEFAULT_SCHEMA = os.environ.get(
    "POSTURE_SCHEMA",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema", "report-v0.schema.json"))


def _is(value, t):
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, _TYPES[t])


def errors(value, schema, path="$"):
    out = []
    t = schema.get("type")
    if t is not None:
        ts = t if isinstance(t, list) else [t]
        if not any(_is(value, x) for x in ts):
            return ["%s: expected %s, got %s" % (path, "|".join(ts), type(value).__name__)]
    if "const" in schema and value != schema["const"]:
        out.append("%s: expected const %r, got %r" % (path, schema["const"], value))
    if "enum" in schema and value not in schema["enum"]:
        out.append("%s: %r not in %r" % (path, value, schema["enum"]))
    if isinstance(value, dict):
        for k in schema.get("required", []):
            if k not in value:
                out.append("%s: missing required %r" % (path, k))
        for k, sub in (schema.get("properties") or {}).items():
            if k in value:
                out += errors(value[k], sub, "%s.%s" % (path, k))
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for i, v in enumerate(value):
            out += errors(v, schema["items"], "%s[%d]" % (path, i))
    return out


def validate(report, schema_path=None):
    schema = json.load(open(schema_path or DEFAULT_SCHEMA))
    return errors(report, schema)

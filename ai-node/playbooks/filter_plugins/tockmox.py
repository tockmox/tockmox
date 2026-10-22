# SPDX-License-Identifier: Apache-2.0
"""Filters the ai-node roles share, kept in Python so they can be tested without Ansible.

Everything here is a pure function of its arguments. The roles call them as, for example,
``item | tockmox_instance_label(tn_prefix)``.
"""
import json
import os
import re

__metaclass__ = type


def _slug(instance):
    """The part of a service name that identifies the instance.

    An endpoint id usually already starts with its engine ("mlx-lm-8080"), and the label is then
    not allowed to say the engine twice.
    """
    iid = str(instance["id"])
    engine = str(instance["engine"])
    return iid if iid.startswith(engine) else engine + "-" + iid


def tockmox_instance_slug(instance):
    """mlx-lm-8080 for {id: mlx-lm-8080, engine: mlx-lm}; mlx-lm-eval for {id: eval, engine: mlx-lm}."""
    return _slug(instance)


def tockmox_instance_label(instance, prefix):
    """The LaunchDaemon label of an instance: <prefix>.<engine>-<id>, and <prefix>.ollama for Ollama."""
    if instance["engine"] == "ollama":
        return str(prefix) + ".ollama"
    return str(prefix) + "." + _slug(instance)


def tockmox_hf_snapshot(ref, revision, root):
    """Where the Hugging Face cache puts one revision of one repository under <root>/models/hf."""
    if not re.match(r"^[0-9a-f]{40}$", str(revision)):
        raise ValueError("a Hugging Face revision must be a 40-hex commit, got %r" % (revision,))
    repo = str(ref).replace("/", "--")
    return "%s/models/hf/hub/models--%s/snapshots/%s" % (str(root).rstrip("/"), repo, revision)


def tockmox_hf_repo_dir(ref, root):
    """The directory of one repository in the Hugging Face cache."""
    return "%s/models/hf/hub/models--%s" % (str(root).rstrip("/"), str(ref).replace("/", "--"))


def tockmox_choose_gguf(candidates, model):
    """Pick the GGUF file to serve out of the *.gguf files found in a snapshot, or ''.

    One file: that one. A split model (every file is -NNNNN-of-MMMMM and exactly one is -00001-of-):
    the first shard. Otherwise the single file whose name contains the model's own name (the part
    after the last slash), compared without regard to case. Anything else is ambiguous: ''.
    """
    files = sorted(str(c) for c in candidates)
    if len(files) == 1:
        return files[0]
    if not files:
        return ""
    first = [f for f in files if "-00001-of-" in f]
    if len(first) == 1 and all("-of-" in f for f in files):
        return first[0]
    name = str(model).split("/")[-1].lower()
    hits = [f for f in files if name and name in os.path.basename(f).lower()]
    if len(hits) == 1:
        return hits[0]
    return ""


def tockmox_ollama_parts(ref):
    """Split an Ollama reference into (host, namespace, name, tag) the way Ollama stores it.

    example:30b -> registry.ollama.ai / library / example / 30b
    user/model  -> registry.ollama.ai / user / model / latest
    host.tld/ns/model:tag is kept as written.
    """
    ref = str(ref)
    tag = "latest"
    # A tag is what follows the last colon, unless that colon belongs to a host:port part.
    head, _, tail = ref.rpartition(":")
    if head and "/" not in tail:
        ref, tag = head, tail
    parts = ref.split("/")
    if len(parts) == 1:
        return ("registry.ollama.ai", "library", parts[0], tag)
    if len(parts) == 2:
        return ("registry.ollama.ai", parts[0], parts[1], tag)
    return (parts[0], "/".join(parts[1:-1]), parts[-1], tag)


def tockmox_ollama_manifest(ref, root):
    """Path of an Ollama model's manifest under <root>/models/ollama."""
    host, ns, name, tag = tockmox_ollama_parts(ref)
    return "%s/models/ollama/manifests/%s/%s/%s/%s" % (str(root).rstrip("/"), host, ns, name, tag)


# --------------------------------------------------------------------------------------------
# A small JSON Schema validator for the two site files. The node does not trust the renderer
# having run: ai_node_assert checks both files against ai-node/schema/*.json before any role
# acts. Standard library only, so it runs under whatever Python Ansible runs on. It implements the
# keywords those schemas use and refuses (reports) a schema keyword it does not know, so a schema
# that grows a keyword cannot silently weaken the check.

_KNOWN = {
    "$schema", "$id", "$defs", "$ref", "title", "description", "type", "enum", "const", "pattern",
    "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "uniqueItems", "items",
    "properties", "required", "additionalProperties", "allOf", "anyOf", "oneOf", "if", "then", "else",
}


def _is_type(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and value.is_integer())
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    return False


def _canon(value):
    return json.dumps(value, sort_keys=True, default=str)


def _walk(value, schema, root, path, errors):
    """Append 'path: message' to errors for every way value does not satisfy schema."""
    where = path or "(top level)"
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            errors.append("%s: the schema has a $ref the node cannot resolve (%s)" % (where, ref))
            return
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        _walk(value, target, root, path, errors)
    for key in schema:
        if key not in _KNOWN:
            errors.append("%s: the schema uses a keyword this checker does not know (%s)" % (where, key))
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, t) for t in types):
            errors.append("%s: must be of type %s" % (where, " or ".join(types)))
            return
    if "const" in schema and _canon(value) != _canon(schema["const"]):
        errors.append("%s: must be %s" % (where, json.dumps(schema["const"])))
    if "enum" in schema and _canon(value) not in [_canon(x) for x in schema["enum"]]:
        errors.append("%s: must be one of %s" % (where, ", ".join(json.dumps(x) for x in schema["enum"])))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append("%s: is shorter than %d characters" % (where, schema["minLength"]))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append("%s: is longer than %d characters" % (where, schema["maxLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append("%s: does not match the pattern %s" % (where, schema["pattern"]))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append("%s: is below the minimum %s" % (where, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append("%s: is above the maximum %s" % (where, schema["maximum"]))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append("%s: needs at least %d items" % (where, schema["minItems"]))
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append("%s: allows at most %d items" % (where, schema["maxItems"]))
        if schema.get("uniqueItems") and len({_canon(x) for x in value}) != len(value):
            errors.append("%s: items must be unique" % where)
        if "items" in schema:
            for i, item in enumerate(value):
                _walk(item, schema["items"], root, "%s[%d]" % (path, i), errors)
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                errors.append("%s: %s is required" % (where, name))
        for name, sub in value.items():
            sub_path = "%s.%s" % (path, name) if path else str(name)
            if name in props:
                _walk(sub, props[name], root, sub_path, errors)
            else:
                extra = schema.get("additionalProperties", True)
                if extra is False:
                    errors.append("%s: %s is not a known key" % (where, name))
                elif isinstance(extra, dict):
                    _walk(sub, extra, root, sub_path, errors)
    for sub in schema.get("allOf", []):
        _walk(value, sub, root, path, errors)
    if "anyOf" in schema:
        if not any(not _errors_of(value, s, root, path) for s in schema["anyOf"]):
            errors.append("%s: matches none of the allowed shapes" % where)
    if "oneOf" in schema:
        hits = sum(1 for s in schema["oneOf"] if not _errors_of(value, s, root, path))
        if hits != 1:
            errors.append("%s: must match exactly one of the allowed shapes (matches %d)" % (where, hits))
    if "if" in schema:
        if not _errors_of(value, schema["if"], root, path):
            if "then" in schema:
                _walk(value, schema["then"], root, path, errors)
        elif "else" in schema:
            _walk(value, schema["else"], root, path, errors)


def _errors_of(value, schema, root, path):
    out = []
    _walk(value, schema, root, path, out)
    return out


def tockmox_schema_errors(doc, schema_text):
    """The reasons doc does not satisfy the JSON Schema in schema_text (a JSON string): [] when it does."""
    schema = json.loads(schema_text) if isinstance(schema_text, str) else schema_text
    errors = []
    _walk(doc, schema, schema, "", errors)
    return errors


class FilterModule(object):
    """Ansible entry point."""

    def filters(self):
        return {
            "tockmox_instance_slug": tockmox_instance_slug,
            "tockmox_instance_label": tockmox_instance_label,
            "tockmox_hf_snapshot": tockmox_hf_snapshot,
            "tockmox_hf_repo_dir": tockmox_hf_repo_dir,
            "tockmox_choose_gguf": tockmox_choose_gguf,
            "tockmox_ollama_manifest": tockmox_ollama_manifest,
            "tockmox_schema_errors": tockmox_schema_errors,
        }

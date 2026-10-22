# SPDX-License-Identifier: Apache-2.0
"""Unit tests for the Python the AI-node toolkit ships: the Ansible filters, the model helper that
verifies and prunes model files, and the pf evidence reader. No Ansible, no macOS, no network.

    python3 -m unittest discover -s ai-node/tests/unit -v
"""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AI = os.path.dirname(os.path.dirname(HERE))


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(AI, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


F = load("tockmox_filters", "playbooks/filter_plugins/tockmox.py")
M = load("tockmox_model_sync", "roles/model_sync/files/tockmox_model_sync.py")
P = load("pf_evidence", "roles/firewall/files/pf_evidence.py")

REV = "ab" * 20


class Filters(unittest.TestCase):
    def test_label_does_not_repeat_the_engine(self):
        inst = {"id": "mlx-lm-8080", "engine": "mlx-lm"}
        self.assertEqual(F.tockmox_instance_label(inst, "com.example.node"), "com.example.node.mlx-lm-8080")

    def test_label_adds_the_engine_when_the_id_does_not_say_it(self):
        inst = {"id": "eval", "engine": "mlx-lm"}
        self.assertEqual(F.tockmox_instance_label(inst, "p"), "p.mlx-lm-eval")

    def test_ollama_label_is_fixed(self):
        self.assertEqual(F.tockmox_instance_label({"id": "ollama-11434", "engine": "ollama"}, "p"), "p.ollama")

    def test_labels_of_distinct_instances_are_distinct(self):
        insts = [{"id": "mlx-lm-8080", "engine": "mlx-lm"}, {"id": "mlx-lm-8082", "engine": "mlx-lm"},
                 {"id": "llama-server-8090", "engine": "llama-server"}, {"id": "ollama-11434", "engine": "ollama"}]
        labels = [F.tockmox_instance_label(i, "p") for i in insts]
        self.assertEqual(len(set(labels)), len(labels))

    def test_hf_snapshot_path(self):
        self.assertEqual(
            F.tockmox_hf_snapshot("org/Name", REV, "/opt/tockmox/"),
            "/opt/tockmox/models/hf/hub/models--org--Name/snapshots/" + REV)

    def test_hf_snapshot_refuses_a_branch_name(self):
        with self.assertRaises(ValueError):
            F.tockmox_hf_snapshot("org/Name", "main", "/r")

    def test_choose_gguf(self):
        self.assertEqual(F.tockmox_choose_gguf(["a/M-Q4.gguf"], "org/M"), "a/M-Q4.gguf")
        self.assertEqual(F.tockmox_choose_gguf([], "org/M"), "")
        split = ["M-00002-of-00003.gguf", "M-00001-of-00003.gguf", "M-00003-of-00003.gguf"]
        self.assertEqual(F.tockmox_choose_gguf(split, "org/M"), "M-00001-of-00003.gguf")
        self.assertEqual(F.tockmox_choose_gguf(["x-Q4.gguf", "x-Q8.gguf"], "org/Other"), "", "two unrelated files are ambiguous")
        self.assertEqual(F.tockmox_choose_gguf(["Model-Q4.gguf", "mmproj-f16.gguf"], "org/model"), "Model-Q4.gguf")

    def test_ollama_manifest_paths(self):
        self.assertEqual(F.tockmox_ollama_manifest("example:30b", "/r"),
                         "/r/models/ollama/manifests/registry.ollama.ai/library/example/30b")
        self.assertEqual(F.tockmox_ollama_manifest("user/model", "/r"),
                         "/r/models/ollama/manifests/registry.ollama.ai/user/model/latest")
        self.assertEqual(F.tockmox_ollama_manifest("host.example:5000/ns/model:t", "/r"),
                         "/r/models/ollama/manifests/host.example:5000/ns/model/t")

    def test_the_plugin_registers_what_the_roles_call(self):
        names = set(F.FilterModule().filters())
        used = set()
        for dirpath, _d, files in os.walk(AI):
            if "/tests" in dirpath or "/.cache" in dirpath:
                continue
            for n in files:
                if n.endswith((".yml", ".yaml", ".j2")):
                    with open(os.path.join(dirpath, n)) as f:
                        used |= set(re.findall(r"\b(tockmox_[a-z_]+)\b(?=\s*[(|)}])", f.read()))
        # only the filters we define start with these names; variables share the prefix, so look at pipes
        piped = set()
        for dirpath, _d, files in os.walk(AI):
            if "/tests" in dirpath or "/.cache" in dirpath:
                continue
            for n in files:
                if n.endswith((".yml", ".yaml", ".j2")):
                    with open(os.path.join(dirpath, n)) as f:
                        piped |= set(re.findall(r"\|\s*(tockmox_[a-z_]+)", f.read()))
        self.assertTrue(piped, "expected the roles to use at least one filter")
        self.assertEqual(piped - names, set(), "a role calls a filter the plugin does not register")
        del used


def make_hf(root, ref, revision, files, name_by="sha256"):
    """Build a cache snapshot: blobs named by their hash, snapshot entries linking to them."""
    repo = os.path.join(M.hub_dir(root), M.repo_dirname(ref))
    snap = os.path.join(repo, "snapshots", revision)
    os.makedirs(os.path.join(repo, "blobs"), exist_ok=True)
    os.makedirs(snap, exist_ok=True)
    for rel, data in files.items():
        if name_by == "sha1":
            h = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        else:
            h = hashlib.sha256(data).hexdigest()
        blob = os.path.join(repo, "blobs", h)
        with open(blob, "wb") as f:
            f.write(data)
        os.makedirs(os.path.dirname(os.path.join(snap, rel)), exist_ok=True)
        os.symlink(os.path.relpath(blob, os.path.dirname(os.path.join(snap, rel))), os.path.join(snap, rel))
    return snap


class ModelSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_verify_accepts_a_snapshot_whose_blobs_match_their_names(self):
        make_hf(self.root, "org/m", REV, {"model.safetensors": b"weights", "config.json": b"{}"})
        ok, detail = M.verify_hf(self.root, "org/m", REV)
        self.assertTrue(ok, detail)
        self.assertTrue(os.path.exists(M.stamp_path(self.root, "org/m", REV)))
        self.assertTrue(M.check_hf(self.root, "org/m", REV)[0])

    def test_verify_accepts_git_sha1_named_blobs(self):
        make_hf(self.root, "org/m", REV, {"config.json": b"{}"}, name_by="sha1")
        self.assertTrue(M.verify_hf(self.root, "org/m", REV)[0])

    def test_verify_refuses_a_tampered_file(self):
        snap = make_hf(self.root, "org/m", REV, {"model.safetensors": b"weights"})
        with open(os.path.realpath(os.path.join(snap, "model.safetensors")), "wb") as f:
            f.write(b"poisoned")
        ok, detail = M.verify_hf(self.root, "org/m", REV)
        self.assertFalse(ok)
        self.assertIn("hashes to", detail)
        self.assertFalse(os.path.exists(M.stamp_path(self.root, "org/m", REV)), "a failed model must not be stamped")

    def test_verify_refuses_a_branch_name_and_a_missing_snapshot(self):
        self.assertFalse(M.verify_hf(self.root, "org/m", "main")[0])
        self.assertFalse(M.verify_hf(self.root, "org/m", REV)[0])

    def test_check_notices_a_changed_file_set(self):
        snap = make_hf(self.root, "org/m", REV, {"a": b"1"})
        M.verify_hf(self.root, "org/m", REV)
        with open(os.path.join(snap, "extra"), "w") as f:
            f.write("x")
        self.assertFalse(M.check_hf(self.root, "org/m", REV)[0])

    def test_ollama_digest(self):
        path = M.ollama_manifest(self.root, "example:30b")
        os.makedirs(os.path.dirname(path))
        with open(path, "wb") as f:
            f.write(b"manifest bytes")
        good = hashlib.sha256(b"manifest bytes").hexdigest()
        self.assertTrue(M.check_ollama(self.root, "example:30b", "sha256:" + good)[0])
        ok, detail = M.check_ollama(self.root, "example:30b", "sha256:" + "0" * 64)
        self.assertFalse(ok)
        self.assertIn(good, detail)
        self.assertFalse(M.check_ollama(self.root, "absent:1", "sha256:" + good)[0])

    def test_ollama_reference_round_trip(self):
        for ref in ("example:30b", "user/model:latest", "host.example/ns/model:t"):
            path = M.ollama_manifest(self.root, ref)
            self.assertEqual(M.ollama_ref_from_manifest(self.root, path), ref)

    def desired(self, *revs):
        return [{"model": "org/m", "artifact": {"kind": "huggingface", "ref": "org/m", "revision": r}} for r in revs]

    def test_prune_refuses_an_empty_desired_list(self):
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        with self.assertRaises(SystemExit):
            M.prune(self.root, [], 7)
        self.assertTrue(os.path.isdir(M.snapshot_dir(self.root, "org/m", REV)))

    def test_prune_waits_out_the_grace_period_then_removes_and_audits(self):
        old = "cd" * 20
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        make_hf(self.root, "org/m", old, {"b": b"2"})
        d = self.desired(REV)
        r = M.prune(self.root, d, 7, now=1_000_000)
        self.assertEqual(r["removed"], [])
        self.assertEqual(len(r["pending"]), 1)
        self.assertTrue(os.path.isdir(M.snapshot_dir(self.root, "org/m", old)), "still inside the grace period")
        r = M.prune(self.root, d, 7, now=1_000_000 + 8 * 86400)
        self.assertEqual(len(r["removed"]), 1)
        self.assertFalse(os.path.isdir(M.snapshot_dir(self.root, "org/m", old)))
        self.assertTrue(os.path.isdir(M.snapshot_dir(self.root, "org/m", REV)), "the wanted revision stays")
        with open(os.path.join(self.root, "var", "audit", "model-updates.jsonl")) as f:
            lines = [json.loads(l) for l in f]
        self.assertEqual(lines[-1]["verdict"], "removed")
        self.assertEqual(lines[-1]["audit_schema"], "v0")

    def test_the_audit_file_is_never_a_followed_link(self):
        # var/audit is group-writable, so the other account could plant a link at the file's name.
        victim = os.path.join(self.root, "victim")
        with open(victim, "w") as f:
            f.write("keep\n")
        os.chmod(victim, 0o600)
        d = os.path.join(self.root, "var", "audit")
        os.makedirs(d)
        os.symlink(victim, os.path.join(d, "model-updates.jsonl"))
        with self.assertRaises(OSError):
            M.audit_line(self.root, "verified", "huggingface", "org/m", REV)
        with open(victim) as f:
            self.assertEqual(f.read(), "keep\n", "nothing was appended through the link")
        self.assertEqual(os.stat(victim).st_mode & 0o777, 0o600, "and its mode was not changed")

    def test_a_model_that_comes_back_resets_its_clock(self):
        old = "cd" * 20
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        make_hf(self.root, "org/m", old, {"b": b"2"})
        M.prune(self.root, self.desired(REV), 7, now=1_000_000)
        M.prune(self.root, self.desired(REV, old), 7, now=1_000_000 + 5 * 86400)
        r = M.prune(self.root, self.desired(REV), 7, now=1_000_000 + 9 * 86400)
        self.assertEqual(r["removed"], [], "the clock restarted when the revision was wanted again")

    def test_dry_run_changes_nothing(self):
        old = "cd" * 20
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        make_hf(self.root, "org/m", old, {"b": b"2"})
        M.prune(self.root, self.desired(REV), 0, dry_run=True, now=5)
        self.assertTrue(os.path.isdir(M.snapshot_dir(self.root, "org/m", old)))

    def test_report_lists_only_what_is_on_disk(self):
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        d = self.desired(REV) + [{"model": "gone", "artifact": {"kind": "huggingface", "ref": "o/gone", "revision": "ef" * 20}}]
        out = os.path.join(self.root, "present.tsv")
        self.assertEqual(M.report(self.root, d, out), 1)
        with open(out) as f:
            rows = [l.split("\t") for l in f.read().splitlines()]
        self.assertEqual(rows[0][:3], ["org/m", REV, "huggingface"])

    def test_the_command_line_exit_codes(self):
        script = os.path.join(AI, "roles/model_sync/files/tockmox_model_sync.py")
        make_hf(self.root, "org/m", REV, {"a": b"1"})
        ok = subprocess.run([sys.executable, "-I", script, "verify-hf", self.root, "org/m", REV], capture_output=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        bad = subprocess.run([sys.executable, "-I", script, "verify-hf", self.root, "org/m", "cd" * 20], capture_output=True)
        self.assertEqual(bad.returncode, 3)


class PfEvidence(unittest.TestCase):
    def count(self, text, ports=(22,), cidrs=("192.0.2.0/24",)):
        nets = [P.ipaddress.ip_network(c) for c in cidrs]
        return P.count(text.splitlines(), set(ports), nets)

    def test_an_established_admin_session_counts(self):
        self.assertEqual(self.count("all tcp 192.0.2.10:22 <- 192.0.2.77:51234       ESTABLISHED:ESTABLISHED"), 1)

    def test_the_other_arrow_direction_counts(self):
        self.assertEqual(self.count("all tcp 192.0.2.77:51234 -> 192.0.2.10:22       ESTABLISHED:ESTABLISHED"), 1)

    def test_a_session_from_outside_the_admin_networks_does_not(self):
        self.assertEqual(self.count("all tcp 192.0.2.10:22 <- 203.0.113.9:51234       ESTABLISHED:ESTABLISHED"), 0)

    def test_a_session_to_another_port_does_not(self):
        self.assertEqual(self.count("all tcp 192.0.2.10:8080 <- 192.0.2.77:51234       ESTABLISHED:ESTABLISHED"), 0)

    def test_a_half_open_state_does_not(self):
        self.assertEqual(self.count("all tcp 192.0.2.10:22 <- 192.0.2.77:51234       SYN_SENT:CLOSED"), 0)
        self.assertEqual(self.count("all udp 192.0.2.10:22 <- 192.0.2.77:51234       MULTIPLE:SINGLE"), 0)

    def test_ipv6(self):
        self.assertEqual(self.count("all tcp fd00::10[22] <- fd00::77[51234]       ESTABLISHED:ESTABLISHED", cidrs=("fd00::/64",)), 1)
        self.assertEqual(self.count("all tcp fd00::10[22] <- fd00::77[51234]       ESTABLISHED:ESTABLISHED"), 0, "a v6 peer is not in a v4 network")

    def test_garbage_is_ignored(self):
        self.assertEqual(self.count("hello\n\nall tcp not-an-address <- also-not       ESTABLISHED:ESTABLISHED"), 0)


class Repository(unittest.TestCase):
    def test_every_role_the_playbook_imports_exists(self):
        with open(os.path.join(AI, "playbooks/ai-node.yml")) as f:
            text = f.read()
        roles = set(re.findall(r"^\s*name:\s*([a-z_]+)\s*$", text, re.M))
        imported = set(re.findall(r"import_role:\s*\n\s*name:\s*([a-z_]+)", text))
        self.assertTrue(imported, "the playbook imports no roles?")
        for r in imported | {x for x in roles if os.path.isdir(os.path.join(AI, "roles", x))}:
            self.assertTrue(os.path.isfile(os.path.join(AI, "roles", r, "tasks", "main.yml")), "role %s has no tasks/main.yml" % r)

    def test_every_included_role_exists(self):
        names = set()
        for dirpath, _d, files in os.walk(os.path.join(AI, "roles")):
            for n in files:
                if n.endswith(".yml"):
                    with open(os.path.join(dirpath, n)) as f:
                        names |= set(re.findall(r"(?:include_role|import_role):\s*\n\s*name:\s*([a-z_]+)", f.read()))
        for r in names:
            self.assertTrue(os.path.isfile(os.path.join(AI, "roles", r, "tasks", "main.yml")), "role %s is included but missing" % r)

    def test_every_role_refuses_linux_with_the_phase_6_sentence(self):
        for r in sorted(os.listdir(os.path.join(AI, "roles"))):
            if r == "launchd_service":
                continue  # a helper the macOS tasks of other roles call; it is never entered on Linux
            with open(os.path.join(AI, "roles", r, "tasks", "main.yml")) as f:
                text = f.read()
            self.assertIn("tn_linux_message", text, "role %s does not stop on Linux" % r)

    def test_no_em_dash_anywhere(self):
        bad = []
        for dirpath, _d, files in os.walk(AI):
            if "/.cache" in dirpath or "__pycache__" in dirpath:
                continue
            for n in files:
                p = os.path.join(dirpath, n)
                try:
                    with open(p, encoding="utf-8") as f:
                        if chr(0x2014) in f.read():
                            bad.append(os.path.relpath(p, AI))
                except (UnicodeDecodeError, OSError):
                    pass
        self.assertEqual(bad, [])

    def test_every_file_has_an_spdx_line(self):
        missing = []
        for dirpath, _d, files in os.walk(AI):
            if "/.cache" in dirpath or "__pycache__" in dirpath or ".pytest_cache" in dirpath or "/schema" in dirpath:
                continue
            for n in files:
                if n in (".yamllint", ".ansible-lint", "secrets.sops.yaml") or n.endswith((".pyc", ".md")):
                    continue
                p = os.path.join(dirpath, n)
                try:
                    with open(p, encoding="utf-8") as f:
                        head = f.read(400)
                except (UnicodeDecodeError, OSError):
                    continue
                if "SPDX-License-Identifier" not in head and not head.startswith("# GENERATED"):
                    missing.append(os.path.relpath(p, AI))
        self.assertEqual(missing, [])


class StartWrapper(unittest.TestCase):
    """Engines and exporters start through the firewall role's wrapper; nothing else does."""

    def test_every_engine_and_exporter_job_is_firewalled(self):
        for role in ("engine_ollama", "engine_mlx_lm", "engine_llama_server", "exporters"):
            with open(os.path.join(AI, "roles", role, "tasks", "macos.yml")) as f:
                text = f.read()
            self.assertGreater(text.count("launchd_service_args"), 0, role)
            self.assertEqual(text.count("launchd_service_args"), text.count("launchd_service_firewalled: true"),
                             "%s starts a job that does not go through start-when-firewalled" % role)

    def test_no_other_role_listens_through_the_wrapper_by_accident(self):
        for role in os.listdir(os.path.join(AI, "roles")):
            if role in ("engine_ollama", "engine_mlx_lm", "engine_llama_server", "exporters", "launchd_service", "firewall"):
                continue
            for dirpath, _d, files in os.walk(os.path.join(AI, "roles", role)):
                for n in files:
                    if n.endswith((".yml", ".j2")):
                        with open(os.path.join(dirpath, n)) as f:
                            self.assertNotIn("launchd_service_firewalled: true", f.read(), os.path.join(dirpath, n))


class RootWritesStayOutOfServiceWritableDirs(unittest.TestCase):
    """The log directory is not group-writable, and root never follows a link when it writes in a tree the
    service account owns."""

    def test_the_log_directory_is_not_group_writable(self):
        import yaml
        with open(os.path.join(AI, "roles", "macos_accounts", "defaults", "main.yml")) as f:
            tree = yaml.safe_load(f)["macos_accounts_tree"]
        log = [e for e in tree if e["path"] == "log"][0]
        self.assertEqual(log["mode"], "0755")
        with open(os.path.join(AI, "bootstrap-node.sh")) as f:
            self.assertIn('"log:c:0755"', f.read())

    def test_root_does_not_follow_links_when_it_makes_the_log_files_and_the_tree(self):
        import yaml
        for rel in (("launchd_service", "tasks", "main.yml"), ("macos_accounts", "tasks", "macos.yml")):
            with open(os.path.join(AI, "roles", *rel)) as f:
                text = f.read()
            self.assertIn("follow: false", text, "/".join(rel))
        with open(os.path.join(AI, "roles", "launchd_service", "tasks", "main.yml")) as f:
            tasks = yaml.safe_load(f)
        touch = [t for blk in tasks for t in (blk.get("block") or [blk]) if "ansible.builtin.file" in t and t["ansible.builtin.file"].get("state") == "touch"]
        self.assertEqual(len(touch), 1)
        self.assertIs(touch[0]["ansible.builtin.file"]["follow"], False)


class SiteData(unittest.TestCase):
    """The two site files are data. They reach the play as tn_site.ai_node and tn_site.desired and nothing
    else, are checked against their schemas first, and are never evaluated as templates."""

    EXAMPLE = os.path.join(AI, "examples", "site", "ai-nodes", "example-mac")

    @classmethod
    def schema(cls, name):
        with open(os.path.join(AI, "schema", name)) as f:
            return f.read()

    def docs(self):
        import yaml
        with open(os.path.join(self.EXAMPLE, "ai-node.yaml")) as f:
            a = yaml.safe_load(f)
        with open(os.path.join(self.EXAMPLE, "desired.yaml")) as f:
            d = yaml.safe_load(f)
        return a, d

    def test_the_examples_pass_and_unknown_keys_do_not_at_any_depth(self):
        a, d = self.docs()
        self.assertEqual(F.tockmox_schema_errors(a, self.schema("ai-node.v1.schema.json")), [])
        self.assertEqual(F.tockmox_schema_errors(d, self.schema("desired.v1.schema.json")), [])
        d["gpu_memory_sysctl"] = "/tmp/evil"
        d["firewall"]["extra"] = 1
        d["instances"][0]["models"][0]["artifact"]["extra"] = 1
        errs = F.tockmox_schema_errors(d, self.schema("desired.v1.schema.json"))
        self.assertIn("(top level): gpu_memory_sysctl is not a known key", errs)
        self.assertIn("firewall: extra is not a known key", errs)
        self.assertTrue(any("artifact: extra is not a known key" in e for e in errs), errs)

    def test_wrong_types_enums_patterns_and_missing_keys_are_refused(self):
        a, _d = self.docs()
        a["os"]["filevault"] = False          # an unquoted off
        a["gpu"]["wiredLimitMiB"] = "lots"
        del a["access"]
        errs = F.tockmox_schema_errors(a, self.schema("ai-node.v1.schema.json"))
        self.assertTrue(any(e.startswith("os.filevault:") for e in errs), errs)
        self.assertTrue(any(e.startswith("gpu.wiredLimitMiB:") for e in errs), errs)
        self.assertIn("(top level): access is required", errs)

    def test_it_agrees_with_the_jsonschema_module_when_that_is_installed(self):
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        import copy
        a, d = self.docs()
        for name, doc in (("ai-node.v1.schema.json", a), ("desired.v1.schema.json", d)):
            schema = json.loads(self.schema(name))
            mutations = [lambda x: x, lambda x: x.update(zzz=1), lambda x: x.pop("schema"), lambda x: x.update(schema="nope"),
                         lambda x: x.update(aiNodeId=5)]
            for mutate in mutations:
                doc2 = copy.deepcopy(doc)
                mutate(doc2)
                mine = F.tockmox_schema_errors(doc2, json.dumps(schema)) == []
                theirs = jsonschema.Draft202012Validator(schema).is_valid(doc2)
                self.assertEqual(mine, theirs, name)

    def test_the_validator_refuses_a_keyword_it_does_not_know(self):
        errs = F.tockmox_schema_errors({}, json.dumps({"type": "object", "patternProperties": {"x": {}}}))
        self.assertTrue(any("does not know" in e for e in errs), errs)

    def test_site_vars_nests_everything_and_marks_it_unsafe(self):
        import yaml
        S = load("site_vars", "playbooks/site_vars.py")
        with tempfile.TemporaryDirectory() as t:
            for name, body in (("a.yaml", "aiNodeId: n1\nfirewall_pfctl: /tmp/evil\n"), ("d.yaml", "x: \"{{ lookup('pipe', 'id') }}\"\n")):
                with open(os.path.join(t, name), "w") as f:
                    f.write(body)
            out = os.path.join(t, "out.yml")
            self.assertEqual(S.main(["site_vars", os.path.join(t, "a.yaml"), os.path.join(t, "d.yaml"), out]), 0)
            with open(out) as fh:
                text = fh.read()
            self.assertEqual([l for l in text.splitlines() if l and not l.startswith(" ") and not l.startswith("#")], ["tn_site: !unsafe"])

            class L(yaml.SafeLoader):
                pass
            L.add_constructor("!unsafe", lambda loader, node: loader.construct_mapping(node, deep=True))
            data = yaml.load(text, Loader=L)
            self.assertEqual(list(data), ["tn_site"])
            self.assertEqual(data["tn_site"]["ai_node"]["firewall_pfctl"], "/tmp/evil")
            self.assertEqual(data["tn_site"]["desired"]["x"], "{{ lookup('pipe', 'id') }}")
            with open(os.path.join(t, "bad.yaml"), "w") as f:
                f.write("- a list\n")
            self.assertEqual(S.main(["site_vars", os.path.join(t, "bad.yaml"), os.path.join(t, "d.yaml"), out + "2"]), 2)
            self.assertFalse(os.path.exists(out + "2"))

    def test_the_schema_check_is_the_first_task_of_the_first_role_and_the_assert_always_runs(self):
        import yaml
        with open(os.path.join(AI, "roles", "ai_node_assert", "tasks", "main.yml")) as f:
            tasks = yaml.safe_load(f)
        self.assertEqual(tasks[0]["name"], "Refuse site files that do not match their schemas")
        with open(os.path.join(AI, "playbooks", "ai-node.yml")) as f:
            play = yaml.safe_load(f)[0]
        first = play["tasks"][0]["block"][0]
        self.assertEqual(first["ansible.builtin.import_role"]["name"], "ai_node_assert")
        self.assertIn("always", first["tags"])

    def test_no_role_or_play_reads_a_site_key_as_a_variable(self):
        """Every top-level key the schemas allow is a name a site file could have set before; none may appear as a
        bare variable in any expression. The site's data is reached only as tn_site.ai_node.* / tn_site.desired.*
        (through tn_ai_node and tn_desired)."""
        import yaml
        keys = set()
        for name in ("ai-node.v1.schema.json", "desired.v1.schema.json"):
            keys |= set(json.loads(self.schema(name))["properties"])
        files = []
        for base in (os.path.join(AI, "roles"), os.path.join(AI, "playbooks")):
            for dirpath, _d, names in os.walk(base):
                files += [os.path.join(dirpath, n) for n in names if n.endswith((".yml", ".j2"))]
        exprs = []

        def collect(node, where):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k in ("when", "that", "until", "failed_when", "changed_when", "loop", "with_items") and not isinstance(v, (dict,)):
                        for item in (v if isinstance(v, list) else [v]):
                            if isinstance(item, str):
                                exprs.append((where, item))
                    collect(v, where)
            elif isinstance(node, list):
                for v in node:
                    collect(v, where)
            elif isinstance(node, str):
                for m in re.finditer(r"\{\{(.*?)\}\}|\{%(.*?)%\}", node, re.S):
                    exprs.append((where, m.group(1) or m.group(2)))

        for p in files:
            with open(p) as f:
                text = f.read()
            if p.endswith(".j2"):
                for m in re.finditer(r"\{\{(.*?)\}\}|\{%(.*?)%\}", text, re.S):
                    exprs.append((p, m.group(1) or m.group(2)))
            else:
                for doc in yaml.safe_load_all(text):
                    collect(doc, p)
        bad = []
        for where, e in exprs:
            bare = re.sub(r"'[^']*'|\"[^\"]*\"", "''", e)
            for k in keys:
                if re.search(r"(?<![\w.])%s\b" % re.escape(k), bare):
                    bad.append("%s: %s in %s" % (os.path.relpath(where, AI), k, " ".join(e.split())[:100]))
        self.assertEqual(bad, [])

    def test_only_the_converger_and_the_namespace_set_extra_vars(self):
        with open(os.path.join(AI, "bin", "tockmox-ai-node-converge")) as f:
            text = f.read()
        flags = re.findall(r'(?:^[ \t]+|" )-e "([^"=]*)', text, re.M)
        self.assertEqual(sorted(set(flags)), ["@$SITE_VARS", "tockmox_admin_user", "tockmox_ai_node_id", "tockmox_converge_interval",
                                               "tockmox_node_dir", "tockmox_signing_mode", "tockmox_toolkit_dir"])


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: Apache-2.0
"""Render the templates with Jinja2 alone and check what comes out: the LaunchDaemon plist must be
well-formed whatever the values contain, and the shell scripts the firewall role installs must parse.

    python3 -m unittest discover -s ai-node/tests/unit -v
"""
import os
import plistlib
import re
import subprocess
import tempfile
import unittest

try:
    import jinja2
except ImportError:  # pragma: no cover
    jinja2 = None

AI = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def render(rel, **ctx):
    path = os.path.join(AI, rel)
    env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True, autoescape=False)
    # Ansible's filters that are not in plain Jinja2.
    env.filters["bool"] = lambda v: str(v).lower() in ("1", "true", "yes", "on")
    with open(path) as f:
        return env.from_string(f.read()).render(**ctx)


PLIST_DEFAULTS = dict(
    launchd_service_label="com.example.node.x", launchd_service_user="", launchd_service_args=["/bin/echo", "hi"],
    launchd_service_run_at_load=True, launchd_service_interval=0, launchd_service_keep_alive=True,
    launchd_service_log="", launchd_service_workdir="", launchd_service_env={}, launchd_service_process_type="Interactive",
    launchd_service_firewalled=False, launchd_service_start_wrapper="/usr/local/libexec/tockmox-ai-node/start-when-firewalled",
)


@unittest.skipIf(jinja2 is None, "jinja2 is not installed")
class Plist(unittest.TestCase):
    def plist(self, **over):
        ctx = dict(PLIST_DEFAULTS)
        ctx.update(over)
        return plistlib.loads(render("roles/launchd_service/templates/daemon.plist.j2", **ctx).encode())

    def test_a_service_that_stays_up(self):
        d = self.plist(launchd_service_user="inference", launchd_service_log="/opt/tockmox/log/x.log")
        self.assertEqual(d["Label"], "com.example.node.x")
        self.assertEqual(d["UserName"], "inference")
        self.assertIs(d["KeepAlive"], True)
        self.assertNotIn("StartInterval", d)
        self.assertEqual(d["StandardOutPath"], "/opt/tockmox/log/x.log")

    def test_a_timer_has_an_interval_and_no_keep_alive(self):
        d = self.plist(launchd_service_interval=900, launchd_service_keep_alive=False)
        self.assertEqual(d["StartInterval"], 900)
        self.assertNotIn("KeepAlive", d)

    def test_a_one_shot_has_neither(self):
        d = self.plist(launchd_service_keep_alive=False)
        self.assertNotIn("KeepAlive", d)
        self.assertNotIn("StartInterval", d)

    def test_special_characters_survive(self):
        nasty = 'a&b <c> "d" \'e\''
        d = self.plist(launchd_service_args=["/bin/sh", "-c", nasty], launchd_service_env={"K": nasty, "A": "1"})
        self.assertEqual(d["ProgramArguments"][2], nasty)
        self.assertEqual(d["EnvironmentVariables"]["K"], nasty)

    def test_numbers_in_arguments_become_strings(self):
        d = self.plist(launchd_service_args=["/bin/x", "--port", 8080])
        self.assertEqual(d["ProgramArguments"], ["/bin/x", "--port", "8080"])

    def test_a_firewalled_job_runs_the_wrapper_first(self):
        d = self.plist(launchd_service_firewalled=True, launchd_service_args=["/opt/homebrew/bin/ollama", "serve"])
        self.assertEqual(d["ProgramArguments"],
                         ["/usr/local/libexec/tockmox-ai-node/start-when-firewalled", "/opt/homebrew/bin/ollama", "serve"])

    def test_other_jobs_do_not(self):
        d = self.plist(launchd_service_args=["/opt/homebrew/bin/ollama", "serve"])
        self.assertEqual(d["ProgramArguments"], ["/opt/homebrew/bin/ollama", "serve"])

    def test_the_environment_is_sorted_so_the_file_does_not_flap(self):
        a = render("roles/launchd_service/templates/daemon.plist.j2", **dict(PLIST_DEFAULTS, launchd_service_env={"B": "1", "A": "2"}))
        b = render("roles/launchd_service/templates/daemon.plist.j2", **dict(PLIST_DEFAULTS, launchd_service_env={"A": "2", "B": "1"}))
        self.assertEqual(a, b)


@unittest.skipIf(jinja2 is None, "jinja2 is not installed")
class OneShot(unittest.TestCase):
    """The detached jobs (the firewall's timed rollback, the converge job's reload) are plists
    bootstrapped into the system domain. `launchctl submit` started nothing visible on macOS 27.0.1."""

    def oneshot(self, **ctx):
        return plistlib.loads(render("roles/launchd_service/templates/oneshot.plist.j2", **ctx).encode())

    def test_runs_once_at_load_and_never_stays_up(self):
        d = self.oneshot(oneshot_label="com.tockmox.ai-node.pf-rollback",
                         oneshot_args=["/bin/sh", "/usr/local/libexec/tockmox-ai-node/pf-rollback.sh", 5],
                         oneshot_log="/var/db/tockmox-ai-node/pf.log")
        self.assertEqual(d["Label"], "com.tockmox.ai-node.pf-rollback")
        self.assertEqual(d["ProgramArguments"], ["/bin/sh", "/usr/local/libexec/tockmox-ai-node/pf-rollback.sh", "5"])
        self.assertIs(d["RunAtLoad"], True)
        for k in ("KeepAlive", "StartInterval", "UserName"):
            self.assertNotIn(k, d)
        self.assertEqual(d["StandardErrorPath"], "/var/db/tockmox-ai-node/pf.log")

    def test_a_shell_line_survives_as_one_argument(self):
        line = "sleep 15; launchctl bootout system/x.converge; launchctl bootstrap system /L/x.converge.plist & <ok>"
        d = self.oneshot(oneshot_label="x.converge-reload", oneshot_args=["/bin/sh", "-c", line])
        self.assertEqual(d["ProgramArguments"], ["/bin/sh", "-c", line])
        self.assertNotIn("StandardOutPath", d)


class NoBlindProbe(unittest.TestCase):
    def test_no_role_reads_netstat(self):
        hits = []
        for root, _, files in os.walk(os.path.join(AI, "roles")):
            for name in files:
                path = os.path.join(root, name)
                with open(path, errors="replace") as f:
                    for n, line in enumerate(f, 1):
                        if re.search(r"\bnetstat\b", line.split("#", 1)[0]):
                            hits.append("%s:%d" % (os.path.relpath(path, AI), n))
        self.assertEqual(hits, [], "netstat lists no sockets under a Python parent on macOS 27; use lsof as root")


class NoSubmit(unittest.TestCase):
    def test_no_role_uses_launchctl_submit(self):
        hits = []
        for root, _, files in os.walk(os.path.join(AI, "roles")):
            for name in files:
                path = os.path.join(root, name)
                with open(path, errors="replace") as f:
                    for n, line in enumerate(f, 1):
                        code = line.split("#", 1)[0]
                        if re.search(r"launchctl\s+submit\b", code):
                            hits.append("%s:%d" % (os.path.relpath(path, AI), n))
        self.assertEqual(hits, [], "launchctl submit starts nothing visible on macOS 27; use a one-shot plist")


@unittest.skipIf(jinja2 is None, "jinja2 is not installed")
class Firewall(unittest.TestCase):
    CTX = dict(
        firewall_boot_marker="/var/db/tockmox-ai-node/pf-boot-ok", firewall_sysctl="/usr/sbin/sysctl", firewall_launchctl="/bin/launchctl",
        firewall_last_confirmed="/var/db/tockmox-ai-node/pf-last-confirmed.rules", firewall_minimal_rules="/var/db/tockmox-ai-node/pf-minimal.rules",
        firewall_libexec="/usr/local/libexec/tockmox-ai-node", firewall_launchd_dir="/Library/LaunchDaemons",
        firewall_start_wrapper="/usr/local/libexec/tockmox-ai-node/start-when-firewalled",
        tn_node_id="n1", firewall_boot_label="com.example.node.pf", firewall_anchor_name="com.apple/250.tockmox", firewall_state_dir="/var/db/tockmox-ai-node",
        firewall_pfctl="/sbin/pfctl", firewall_anchor_file="/etc/pf.anchors/x.allowlist", firewall_rollback_minutes=5,
        tn_firewall=dict(adminCidrs=["192.0.2.0/24", "198.51.100.7/32"], adminPorts=[22], enginePorts=[8082, 8080, 11434],
                         engineAllowFrom=["203.0.113.5/32"], exporterPorts=[9100, 9101], exporterAllowFrom=["203.0.113.6/32"]),
    )

    def test_the_anchor_blocks_every_managed_port_after_the_allows(self):
        text = render("roles/firewall/templates/anchor.conf.j2", **self.CTX)
        rules = [l for l in text.splitlines() if re.match(r"^(pass|block)", l)]
        self.assertTrue(rules[0].startswith("pass in quick on lo0"))
        self.assertTrue(rules[-1].startswith("block return in quick"))
        self.assertEqual(sum(1 for r in rules if r.startswith("block")), 1)
        self.assertIn("flags any keep state", [r for r in rules if "tockmox_admin" in r][0])
        managed = re.search(r'managed_ports = "\{ (.*?) \}"', text).group(1)
        self.assertEqual(managed, "22, 8080, 8082, 9100, 9101, 11434")

    def test_an_admin_list_is_sorted_so_the_file_is_stable(self):
        text = render("roles/firewall/templates/anchor.conf.j2", **self.CTX)
        self.assertIn("{ 192.0.2.0/24, 198.51.100.7/32 }", text)

    def test_no_engine_ports_no_engine_rule(self):
        ctx = dict(self.CTX)
        fw = dict(ctx["tn_firewall"], enginePorts=[])
        ctx["tn_firewall"] = fw
        text = render("roles/firewall/templates/anchor.conf.j2", **ctx)
        self.assertNotIn("tockmox_engine_clients", text)
        self.assertNotIn("engine_ports", text)

    def test_the_scripts_are_valid_posix_sh(self):
        for rel in ("roles/firewall/templates/pf-load.sh.j2", "roles/firewall/templates/pf-rollback.sh.j2",
                    "roles/firewall/templates/stop-listeners.sh.j2"):
            text = render(rel, **self.CTX)
            self.assertTrue(text.startswith("#!/bin/sh\n"), rel + " must start with the shebang")
            with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
                f.write(text)
            try:
                r = subprocess.run(["sh", "-n", f.name], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            finally:
                os.unlink(f.name)

    def test_the_wrapper_is_a_bash_script_that_parses(self):
        text = render("roles/firewall/templates/start-when-firewalled.sh.j2", **self.CTX)
        self.assertTrue(text.startswith("#!/bin/bash\n"))
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write(text)
        try:
            r = subprocess.run(["bash", "-n", f.name], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            os.unlink(f.name)
        self.assertIn("exec \"$@\"", text)
        self.assertIn("kern.boottime", text)

    def test_the_rollback_never_flushes_the_anchor(self):
        text = render("roles/firewall/templates/pf-rollback.sh.j2", **self.CTX)
        code = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
        self.assertEqual([l for l in code if re.search(r"(^|\s)-F(\s|$)", l)], [], "an empty anchor opens the managed ports")
        self.assertNotIn("pf.conf", text)
        self.assertIn('-a "$ANCHOR" -f "$LAST"', text)
        self.assertIn('-a "$ANCHOR" -f "$MINIMAL"', text)

    def test_the_loader_removes_the_marker_before_it_loads_anything(self):
        text = render("roles/firewall/templates/pf-load.sh.j2", **self.CTX)
        first_rm = text.index('/bin/rm -f "$MARKER"\n\n')
        self.assertLess(first_rm, text.index('-f /etc/pf.conf'))
        self.assertLess(first_rm, text.index('-a "$ANCHOR" -f "$RULES"'))
        self.assertLess(text.index('-a "$ANCHOR" -f "$RULES"'), text.rindex("mark ||"))

    def test_the_minimal_ruleset_blocks_the_managed_ports_and_never_a_world_open_anchor(self):
        text = render("roles/firewall/templates/minimal.conf.j2", **self.CTX)
        rules = [l for l in text.splitlines() if re.match(r"^(pass|block)", l)]
        self.assertTrue(rules[0].startswith("pass in quick on lo0"))
        self.assertTrue(rules[-1].startswith("block return in quick"))
        self.assertIn('closed_ports = "{ 8080, 8082, 9100, 9101, 11434 }"', text)
        self.assertIn('admin_ports = "{ 22 }"', text)


if __name__ == "__main__":
    unittest.main()

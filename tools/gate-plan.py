#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Which gates check-all.sh runs, and on which shard.
#
#   tools/gate-plan.py plan --list LIST [--changed FILE] [--shard I/N] [--inputs YAML] [--weights TSV] --out PLAN
#   tools/gate-plan.py check-inputs --list LIST [--inputs YAML]
#   tools/gate-plan.py aggregate --list LIST RESULTS.tsv...
#   tools/gate-plan.py weights RESULTS.tsv... > tools/gate-weights.tsv
#   tools/gate-plan.py --selftest
#
# check-all.sh calls this; nobody needs to run it by hand. LIST is what `check-all.sh --list`
# prints (ordinal, key, serial flag, name; tab-separated). The plan is one line per gate:
# ordinal, key, decision (run | unselected | othershard), shard, reason.
#
# SELECTION. A pull request runs a gate when a changed path matches one of the gate's
# declared inputs in tools/gate-inputs.yaml. A gate with NO declaration always runs, and a change to
# any `always_full` path (the runner, the planner, the declarations, the toolchain, the workflow)
# runs every gate. With no list of changed paths every gate runs: a local check-all.sh, every push
# to main and the nightly run are all full runs, and the nightly is what catches an input a
# declaration forgot. A selection is only ever narrowed by a declaration somebody wrote; it is
# never guessed.
#
# SHARDS. The gates that will run are split across N shards by measured seconds
# (tools/gate-weights.tsv; a gate with no measurement weighs DEFAULT_WEIGHT): heaviest first, each
# to the lightest shard so far, ties to the lowest shard number. Every gate lands on exactly one
# shard, so the shards' results together are one unsharded run. Gates registered with serial_gate
# read or build a shared directory, so they all go to one shard together. A gate that does not run
# (unselected, or skipped by check-all.sh itself) is recorded on shard 1 so its line is reported
# exactly once: shard 1's plan says unselected, every other shard's says othershard.
#
# Standard library only, plus PyYAML for the declarations, which check-all.sh already requires.
import os
import re
import sys

DEFAULT_WEIGHT = 10.0
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INPUTS = os.path.join(HERE, "gate-inputs.yaml")
WEIGHTS = os.path.join(HERE, "gate-weights.tsv")


def die(msg):
    print("gate-plan: " + msg, file=sys.stderr)
    sys.exit(1)


def read_list(path):
    gates = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                die("%s: expected 4 tab-separated fields, got %d: %r" % (path, len(parts), line[:80]))
            ordv, key, serial, name = parts
            gates.append({"ord": int(ordv), "key": key, "serial": serial == "1", "name": name})
    ords = [g["ord"] for g in gates]
    if ords != list(range(1, len(gates) + 1)):
        die("%s: ordinals are not 1..%d in order" % (path, len(gates)))
    return gates


def glob_re(pattern):
    # '**' crosses directories, '*' and '?' do not. A pattern ending in '/' means everything under it.
    if pattern.endswith("/"):
        pattern += "**"
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3; continue
        if pattern.startswith("**", i):
            out.append(".*"); i += 2; continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def load_inputs(path):
    import yaml  # check-all.sh asserts PyYAML before it gets here
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    classes = doc.get("classes") or {}
    for cname, globs in classes.items():
        if not isinstance(globs, list) or not all(isinstance(g, str) for g in globs):
            die("%s: class %s must be a list of path globs" % (path, cname))
    gates = {}
    for key, entries in (doc.get("gates") or {}).items():
        if not isinstance(entries, list) or not entries:
            die("%s: gate %r must list at least one input" % (path, key))
        globs = []
        for e in entries:
            if not isinstance(e, str):
                die("%s: gate %r has a non-string input %r" % (path, key, e))
            if e.startswith("@"):
                if e[1:] not in classes:
                    die("%s: gate %r names an unknown class %s" % (path, key, e))
                globs.extend(classes[e[1:]])
            else:
                globs.append(e)
        gates[key] = globs
    always = doc.get("always_full") or []
    return {"always": always, "gates": gates, "classes": classes}


def load_weights(path):
    w = {}
    if not os.path.exists(path):
        return w
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            key, _, secs = line.rstrip("\n").rpartition("\t")
            try:
                w[key] = float(secs)
            except ValueError:
                die("%s: bad seconds on line %r" % (path, line[:80]))
    return w


def matches(globs, paths):
    regs = [glob_re(g) for g in globs]
    return [p for p in paths if any(r.match(p) for r in regs)]


def select(gates, decl, changed):
    """Return {ord: (decision, reason)} for decision in run | unselected."""
    out = {}
    if changed is None:
        for g in gates:
            out[g["ord"]] = ("run", "full run")
        return out
    hit = matches(decl["always"], changed)
    if hit:
        for g in gates:
            out[g["ord"]] = ("run", "always_full path changed: " + hit[0])
        return out
    for g in gates:
        globs = decl["gates"].get(g["key"])
        if globs is None:
            out[g["ord"]] = ("run", "no inputs declared")
            continue
        m = matches(globs, changed)
        out[g["ord"]] = ("run", "input changed: " + m[0]) if m else ("unselected", "inputs unchanged")
    return out


def assign(gates, sel, n, weights):
    """Return {ord: shard}. Deterministic: same inputs, same assignment."""
    shard_of, load = {}, [0.0] * (n + 1)
    items = []  # (weight, first ord, [ords])
    serial = [g for g in gates if g["serial"] and sel[g["ord"]][0] == "run"]
    if serial:
        items.append((sum(weights.get(g["key"], DEFAULT_WEIGHT) for g in serial), serial[0]["ord"], [g["ord"] for g in serial]))
    for g in gates:
        if g["serial"] and sel[g["ord"]][0] == "run":
            continue
        if sel[g["ord"]][0] != "run" or g["key"].startswith("skip:"):
            shard_of[g["ord"]] = 1
            continue
        items.append((weights.get(g["key"], DEFAULT_WEIGHT), g["ord"], [g["ord"]]))
    items.sort(key=lambda t: (-t[0], t[1]))
    for wt, _, ords in items:
        s = min(range(1, n + 1), key=lambda i: (load[i], i))
        load[s] += wt
        for o in ords:
            shard_of[o] = s
    return shard_of, load


def parse_shard(spec):
    m = re.match(r"^([1-9][0-9]*)/([1-9][0-9]*)$", spec or "")
    if not m or int(m.group(1)) > int(m.group(2)):
        die("--shard wants I/N with 1 <= I <= N, got %r" % spec)
    return int(m.group(1)), int(m.group(2))


def args_of(argv, flags):
    vals, rest, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            if i + 1 >= len(argv):
                die(a + " needs a value")
            vals[a] = argv[i + 1]; i += 2
        else:
            rest.append(a); i += 1
    return vals, rest


def cmd_plan(argv):
    v, rest = args_of(argv, {"--list", "--changed", "--shard", "--inputs", "--weights", "--out"})
    if rest or "--list" not in v or "--out" not in v:
        die("plan --list LIST [--changed FILE] [--shard I/N] [--inputs YAML] [--weights TSV] --out PLAN")
    gates = read_list(v["--list"])
    decl = load_inputs(v.get("--inputs", INPUTS))
    changed = None
    if "--changed" in v:
        with open(v["--changed"], encoding="utf-8") as f:
            changed = sorted({l.strip() for l in f if l.strip()})
    sel = select(gates, decl, changed)
    i, n = parse_shard(v["--shard"]) if "--shard" in v else (1, 1)
    weights = load_weights(v.get("--weights", WEIGHTS))
    shard_of, load = assign(gates, sel, n, weights)
    with open(v["--out"], "w", encoding="utf-8") as f:
        for g in gates:
            dec, why = sel[g["ord"]]
            s = shard_of[g["ord"]]
            # Only the gate's own shard reports it; every other shard records othershard. That holds for
            # an unselected gate too (its shard is 1): written as unselected on every shard, the
            # aggregate saw it once per shard and went red on every pull request it narrowed.
            if s != i:
                dec = "othershard"
            f.write("%d\t%s\t%s\t%d\t%s\n" % (g["ord"], g["key"], dec, s, why))
    runs = sum(1 for g in gates if sel[g["ord"]][0] == "run")
    mine = sum(1 for g in gates if sel[g["ord"]][0] == "run" and shard_of[g["ord"]] == i)
    msg = "%d of %d gates selected" % (runs, len(gates))
    msg += " (paths changed: %d)" % len(changed) if changed is not None else " (full run)"
    if n > 1:
        msg += "; shard %d/%d runs %d of them, about %d gate-seconds (shards: %s)" % (
            i, n, mine, round(load[i]), " ".join(str(round(x)) for x in load[1:]))
    print(msg)


def cmd_check_inputs(argv):
    """Every declared key names a gate that exists, every class is used, every glob matches a tracked file."""
    v, rest = args_of(argv, {"--list", "--inputs", "--files"})
    if rest:
        die("check-inputs [--list LIST] [--inputs YAML] [--files TRACKED]")
    if "--list" not in v:
        # No list given: ask check-all.sh for the one it registers now.
        import subprocess
        import tempfile
        out = subprocess.run(["bash", os.path.join(HERE, "check-all.sh"), "--list"], capture_output=True, text=True)
        if out.returncode != 0:
            die("check-all.sh --list failed: " + out.stderr.strip()[-300:])
        with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
            f.write(out.stdout)
            v["--list"] = f.name
        gates = read_list(v["--list"])
        os.unlink(v["--list"])
    else:
        gates = read_list(v["--list"])
    decl = load_inputs(v.get("--inputs", INPUTS))
    if "--files" in v:
        with open(v["--files"], encoding="utf-8") as f:
            tracked = [l.strip() for l in f if l.strip()]
    else:
        import subprocess
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    bad = 0
    keys = {g["key"] for g in gates}
    dup = sorted({g["key"] for g in gates if [h["key"] for h in gates].count(g["key"]) > 1})
    for k in dup:
        print("FAIL: two gates share the key %r; declarations could not tell them apart" % k); bad += 1
    for k in sorted(decl["gates"]):
        if k not in keys:
            print("FAIL: gate-inputs.yaml declares %r, which check-all.sh does not register (renamed or removed?)" % k); bad += 1
    import yaml
    with open(v.get("--inputs", INPUTS), encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    used = {e[1:] for es in (raw.get("gates") or {}).values() for e in es if isinstance(e, str) and e.startswith("@")}
    for c in sorted(set(decl["classes"]) - used):
        print("FAIL: class %s is declared and no gate uses it" % c); bad += 1
    seen = set()
    for g in list(decl["always"]) + [x for gl in decl["gates"].values() for x in gl]:
        if g in seen:
            continue
        seen.add(g)
        if not matches([g], tracked):
            print("FAIL: input %r matches no tracked file (a typo here silently narrows a selection)" % g); bad += 1
    declared = sum(1 for g in gates if g["key"] in decl["gates"])
    if bad:
        print("%d problem(s) in tools/gate-inputs.yaml" % bad)
        return 1
    print("  ok: %d of %d gates declare their inputs; the other %d always run" % (declared, len(gates), len(gates) - declared))
    return 0


def read_results(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("ord\t") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                die("%s: short line %r" % (path, line[:80]))
            rows.append({"ord": int(p[0]), "key": p[1], "status": p[2], "rc": p[3], "secs": p[4], "name": p[5]})
    return rows


def cmd_aggregate(argv):
    v, files = args_of(argv, {"--list"})
    if "--list" not in v or not files:
        die("aggregate --list LIST RESULTS.tsv...")
    gates = read_list(v["--list"])
    seen, bad = {}, 0
    for path in files:
        for r in read_results(path):
            if r["status"] == "othershard":
                continue
            if r["ord"] in seen:
                print("FAIL: gate %d (%s) reported by two shards" % (r["ord"], r["name"])); bad += 1
            seen[r["ord"]] = r
    for g in gates:
        r = seen.get(g["ord"])
        if r is None:
            print("FAIL: no shard reported gate %d: %s" % (g["ord"], g["name"])); bad += 1
        elif r["key"] != g["key"]:
            print("FAIL: gate %d is %r in the list and %r in a shard's results" % (g["ord"], g["key"], r["key"])); bad += 1
    counts = {}
    for r in seen.values():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    for r in sorted(seen.values(), key=lambda r: r["ord"]):
        if r["status"] in ("fail", "timeout"):
            print("FAILED: %s" % r["name"]); bad += 1
        elif r["status"] == "skip" and r["rc"] != "2":
            # check-all.sh writes skip only for exit 2 with a "SKIPPED: reason" line; any other pair is a row nothing honest wrote.
            print("FAILED: %s (a skip row must carry exit status 2, this has %r)" % (r["name"], r["rc"])); bad += 1
    timed = sorted((r for r in seen.values() if r["secs"] not in ("", "-")), key=lambda r: -float(r["secs"]))
    print("Every gate reported once: %d gates; %s" % (len(seen), ", ".join("%d %s" % (c, s) for s, c in sorted(counts.items()))))
    print("Slowest gates:")
    for r in timed[:5]:
        print("%6ss  %s" % (r["secs"], r["name"]))
    return 1 if bad else 0


def cmd_weights(files):
    secs = {}
    for path in files:
        for r in read_results(path):
            if r["status"] in ("pass", "fail") and r["secs"] not in ("", "-"):
                secs.setdefault(r["key"], []).append(float(r["secs"]))
    print("# Measured seconds per gate key, for tools/gate-plan.py's shard balance. Data, not a gate:")
    print("# a stale number only makes the shards less even. Refresh from full runs' results:")
    print("#   tools/gate-plan.py weights build/check-all-results.tsv... > tools/gate-weights.tsv")
    for k in sorted(secs):
        v = sorted(secs[k])
        print("%s\t%g" % (k, v[len(v) // 2]))
    return 0


def selftest():
    import tempfile
    bad = 0

    def expect(cond, what):
        nonlocal bad
        if cond:
            print("  ok: " + what)
        else:
            print("  FAIL: " + what); bad += 1

    d = tempfile.mkdtemp()
    lst = os.path.join(d, "list.tsv")
    with open(lst, "w") as f:
        f.write("1\ttools/a.sh\t0\tgate a\n2\ttools/a.sh --selftest\t0\tgate a selftest\n3\ttools/docs.sh\t0\tdocs gate\n"
                "4\tinline:lint\t0\tlint\n5\ttools/counts.sh\t1\tcounts\n6\ttools/claims.sh\t1\tclaims\n"
                "7\tskip:gitleaks\t0\tgitleaks\n8\ttools/big.sh --selftest\t0\tbig\n")
    inp = os.path.join(d, "in.yaml")
    with open(inp, "w") as f:
        f.write("always_full: [tools/check-all.sh, tools/lib/]\nclasses:\n  render: ['charts/**', ci/]\n"
                "gates:\n  tools/a.sh: ['@render', tools/a.sh]\n  tools/a.sh --selftest: ['@render', tools/a.sh]\n"
                "  tools/docs.sh: ['docs/**/*.md', tools/docs.sh]\n  tools/big.sh --selftest: ['@render']\n"
                "  tools/counts.sh: ['@render']\n  tools/claims.sh: ['docs/**', '@render']\n")
    wts = os.path.join(d, "w.tsv")
    with open(wts, "w") as f:
        f.write("# c\ntools/big.sh --selftest\t500\ntools/a.sh --selftest\t200\ntools/a.sh\t50\ntools/counts.sh\t30\ntools/claims.sh\t20\n")
    gates = read_list(lst)
    decl = load_inputs(inp)

    def run_set(changed):
        return {o for o, (dec, _) in select(gates, decl, changed).items() if dec == "run"}

    expect(run_set(None) == set(range(1, 9)), "no list of changed paths runs every gate")
    expect(run_set(["docs/x/y.md"]) == {3, 4, 6, 7}, "a docs-only change runs the docs gates and the undeclared ones only")
    expect(run_set(["charts/tockmox-ai/values.yaml"]) == {1, 2, 4, 5, 6, 7, 8}, "a chart change runs every render gate")
    expect(run_set(["tools/lib/x.sh"]) == set(range(1, 9)), "an always_full path runs every gate")
    expect(run_set(["README.txt"]) == {4, 7}, "an unrelated path runs only the undeclared gates")
    expect(4 in run_set([]) and 7 in run_set([]), "a gate with no declaration always runs, even with nothing changed")
    expect(glob_re("docs/**/*.md").match("docs/a.md") and glob_re("docs/**/*.md").match("docs/a/b/c.md")
           and not glob_re("docs/*.md").match("docs/a/b.md") and glob_re("ci/").match("ci/a/b"),
           "globs: ** crosses directories, * does not, a trailing / means everything under it")
    for n in (1, 2, 3, 4, 7):
        sel = select(gates, decl, None)
        s1, _ = assign(gates, sel, n, load_weights(wts))
        s2, _ = assign(gates, sel, n, load_weights(wts))
        ok = set(s1) == set(range(1, 9)) and all(1 <= s <= n for s in s1.values()) and s1 == s2
        expect(ok, "%d shard(s): every gate on exactly one shard, the same way twice" % n)
        expect(s1[5] == s1[6], "%d shard(s): the serial gates share a shard" % n)
    sel = select(gates, decl, None)
    s3, load3 = assign(gates, sel, 3, load_weights(wts))
    expect(s3[8] != s3[2] and max(load3[1:]) == 500, "3 shards: the two heaviest gates are apart and the heaviest is alone")
    # The plan file: one shard's run set plus the others' is the whole run set.
    union = set()
    for i in (1, 2, 3):
        out = os.path.join(d, "p%d" % i)
        old = sys.stdout
        sys.stdout = open(os.devnull, "w")
        try:
            cmd_plan(["--list", lst, "--inputs", inp, "--weights", wts, "--shard", "%d/3" % i, "--out", out])
        finally:
            sys.stdout.close(); sys.stdout = old
        with open(out) as f:
            rows = [l.split("\t") for l in f]
        mine = {int(r[0]) for r in rows if r[2] == "run"}
        expect(not (mine & union), "shard %d/3 runs nothing another shard runs" % i)
        union |= mine
    expect(union == set(range(1, 9)), "the three shards' run sets are the unsharded run set")
    # A narrowed run (a pull request): across the shards' plans, every gate has exactly one decision
    # that is not othershard, so the aggregate sees each gate once, unselected ones included.
    chg = os.path.join(d, "changed")
    with open(chg, "w") as f:
        f.write("docs/x/y.md\n")
    owners = {}
    for i in (1, 2, 3):
        out = os.path.join(d, "n%d" % i)
        old = sys.stdout
        sys.stdout = open(os.devnull, "w")
        try:
            cmd_plan(["--list", lst, "--inputs", inp, "--weights", wts, "--changed", chg, "--shard", "%d/3" % i, "--out", out])
        finally:
            sys.stdout.close(); sys.stdout = old
        with open(out) as f:
            for r in (l.split("\t") for l in f):
                if r[2] != "othershard":
                    owners.setdefault(int(r[0]), []).append((i, r[2]))
    expect(sorted(owners) == list(range(1, 9)) and all(len(v) == 1 for v in owners.values()),
           "a narrowed run: every gate, unselected ones included, is reported by exactly one shard")
    expect(all(v == [(1, "unselected")] for o, v in owners.items() if o in (1, 2, 5, 8)),
           "a narrowed run: the unselected gates are reported on shard 1 as unselected")
    # aggregate goes red on a gate nobody reported and on a duplicate.
    r1 = os.path.join(d, "r1.tsv")
    with open(r1, "w") as f:
        f.write("ord\tkey\tstatus\trc\tseconds\tname\n")
        for g in gates[:-1]:
            f.write("%d\t%s\tpass\t0\t1\t%s\n" % (g["ord"], g["key"], g["name"]))
    old = sys.stdout; sys.stdout = open(os.devnull, "w")
    try:
        missing = cmd_aggregate(["--list", lst, r1])
        twice = cmd_aggregate(["--list", lst, r1, r1])
    finally:
        sys.stdout.close(); sys.stdout = old
    expect(missing == 1, "aggregate goes red when a gate is reported by no shard")
    for rc_text, want, what in (("2", 0, "a skip row with exit status 2 is not a failure"), ("1", 1, "a skip row whose exit status is not 2 is a failure")):
        r3 = os.path.join(d, "r3.tsv")
        with open(r3, "w") as f:
            f.write("ord\tkey\tstatus\trc\tseconds\tname\n")
            for i, g in enumerate(gates):
                st, rc = ("skip", rc_text) if i == 0 else ("pass", "0")
                f.write("%d\t%s\t%s\t%s\t1\t%s\n" % (g["ord"], g["key"], st, rc, g["name"]))
        old = sys.stdout; sys.stdout = open(os.devnull, "w")
        try:
            got = cmd_aggregate(["--list", lst, r3])
        finally:
            sys.stdout.close(); sys.stdout = old
        expect(got == want, "aggregate: " + what)
    expect(twice == 1, "aggregate goes red when a gate is reported by two shards")
    files = os.path.join(d, "files")
    with open(files, "w") as f:
        f.write("tools/a.sh\ntools/docs.sh\ndocs/a.md\ncharts/x/Chart.yaml\nci/values.yaml\ntools/check-all.sh\ntools/lib/x.sh\n")
    old = sys.stdout; sys.stdout = open(os.devnull, "w")
    try:
        good = cmd_check_inputs(["--list", lst, "--inputs", inp, "--files", files])
        with open(inp, "a") as f:
            f.write("  tools/gone.sh: [tools/gone.sh]\n")
        stale = cmd_check_inputs(["--list", lst, "--inputs", inp, "--files", files])
    finally:
        sys.stdout.close(); sys.stdout = old
    expect(good == 0, "check-inputs passes a clean declaration file")
    expect(stale == 1, "check-inputs goes red on a declared gate that does not exist and a path that matches nothing")
    if bad:
        print("gate-plan selftest: %d failure(s)" % bad)
        return 1
    print("gate-plan selftest: ok")
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__ or open(__file__).read().split("\nimport os")[0])
        return 0
    if argv[0] == "--selftest":
        return selftest()
    cmd, rest = argv[0], argv[1:]
    if cmd == "plan":
        cmd_plan(rest); return 0
    if cmd == "check-inputs":
        return cmd_check_inputs(rest)
    if cmd == "aggregate":
        return cmd_aggregate(rest)
    if cmd == "weights":
        return cmd_weights(rest)
    die("unknown command %r (plan, check-inputs, aggregate, weights, --selftest)" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

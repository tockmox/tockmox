# SPDX-License-Identifier: Apache-2.0
"""The checks behind tools/check-kured-gate.sh.

    kured_gate.py check LEDGER DOC RENDERED.yaml...   print findings, exit 1 on any
    kured_gate.py regexp LEDGER [RENDERED.yaml...]    print the gate regexp the ledger (and annotations) imply

LEDGER is tools/kured-gate.txt. DOC is the page that prints the regexp for an
operator to paste. RENDERED.yaml is `helm template` output of a layer.

The question this answers: kured holds a reboot only for the alerts a site names
in alertFilterRegexp, so an alert nobody named never holds one, and nothing
errors when that is the one that mattered. Every alert Tockmox authors is
therefore classified once, block or pass, and an alert with no classification
fails the build.
"""
import glob
import os
import re
import sys

import yaml

try:
    _LOADER = yaml.CSafeLoader
except AttributeError:  # pragma: no cover
    _LOADER = yaml.SafeLoader

ANNOTATION = "kured_gate"
DECISIONS = ("block", "pass")
OURS_LABEL = "tockmox.com/managed-by"
LINE = re.compile(r"^(alert|upstream)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+(block|pass))?\s*#\s*(\S.*)$")


def parse_ledger(path):
    """Return (alerts, upstream, findings). alerts: name -> (decision, line)."""
    alerts, upstream, findings = {}, {}, []
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = LINE.match(line.strip())
            if not m:
                findings.append(
                    "%s:%d is not `alert NAME block|pass  # reason` or `upstream NAME  # reason`: %s" % (path, n, line.strip()))
                continue
            kind, name, decision, _why = m.groups()
            if kind == "alert":
                if decision is None:
                    findings.append("%s:%d: alert %s has no decision (block or pass)" % (path, n, name))
                    continue
                if name in alerts:
                    findings.append("%s:%d: alert %s is classified twice (first at line %d)" % (path, n, name, alerts[name][1]))
                    continue
                alerts[name] = (decision, n)
            else:
                if decision is not None:
                    findings.append("%s:%d: upstream %s takes no decision; every upstream entry is a block" % (path, n, name))
                    continue
                if name in upstream:
                    findings.append("%s:%d: upstream %s is listed twice" % (path, n, name))
                    continue
                upstream[name] = n
    return alerts, upstream, findings


def blocking_names(alerts, upstream, annotated):
    names = {a for a, (d, _) in alerts.items() if d == "block"}
    names |= set(upstream)
    names |= {a for a, d in annotated.items() if d == "block"}
    return sorted(names)


def regexp_for(names):
    return "^(" + "|".join(names) + ")$"


def load_rules(paths):
    """Return (ours, theirs). ours: alert -> dict(annotation, rule, layer); theirs: set of alert names."""
    ours, theirs = {}, set()
    for path in paths:
        layer = os.path.basename(path).rsplit(".", 1)[0]
        with open(path) as fh:
            for doc in yaml.load_all(fh, Loader=_LOADER):
                if not (isinstance(doc, dict) and doc.get("kind") == "PrometheusRule"):
                    continue
                mine = ((doc.get("metadata") or {}).get("labels") or {}).get(OURS_LABEL) == "tockmox"
                for group in (doc.get("spec") or {}).get("groups") or []:
                    for rule in group.get("rules") or []:
                        name = rule.get("alert")
                        if not name:
                            continue
                        if mine:
                            ours[name] = {
                                "annotation": (rule.get("annotations") or {}).get(ANNOTATION),
                                "rule": doc["metadata"]["name"],
                                "layer": layer,
                                "severity": (rule.get("labels") or {}).get("severity"),
                            }
                        else:
                            theirs.add(name)
    return ours, theirs


def template_of(name, root="charts"):
    """The chart template that writes `alert: NAME`, for the message."""
    pat = re.compile(r"^\s*-?\s*alert:\s*%s\s*$" % re.escape(name))
    for f in sorted(glob.glob(os.path.join(root, "*", "templates", "*.y*ml"))):
        try:
            with open(f) as fh:
                for n, line in enumerate(fh, 1):
                    if pat.match(line):
                        return "%s:%d" % (f, n)
        except OSError:
            continue
    return None


def doc_regexp(doc_path):
    """The value printed for alertFilterRegexp in DOC, and whether alertFilterMatchOnly: true sits beside it."""
    text = open(doc_path).read()
    m = re.search(r'^\s*alertFilterRegexp:\s*"([^"\n]*)"\s*$', text, re.M)
    match_only = re.search(r"^\s*alertFilterMatchOnly:\s*true\s*$", text, re.M) is not None
    return (m.group(1) if m else None), match_only


def check(ledger, doc, rendered, template_root="charts"):
    alerts, upstream, findings = parse_ledger(ledger)
    ours, theirs = load_rules(rendered)
    if not ours:
        return ["no Tockmox-authored alert rendered at all; the render or the %s label is wrong, and every check below would pass on nothing" % OURS_LABEL]

    annotated = {}
    for name, info in sorted(ours.items()):
        ann = info["annotation"]
        if ann is not None and ann not in DECISIONS:
            findings.append("%s (%s) carries annotation %s: %r; the value is block or pass" % (name, info["rule"], ANNOTATION, ann))
            continue
        if ann is not None:
            annotated[name] = ann
        in_ledger = name in alerts
        if ann is not None and in_ledger:
            findings.append("%s is classified twice: annotation %s and a line in %s; keep one" % (name, ANNOTATION, ledger))
        elif ann is None and not in_ledger:
            where = template_of(name, template_root) or "layer %s, PrometheusRule %s" % (info["layer"], info["rule"])
            findings.append(
                "UNCLASSIFIED %s (%s, severity %s): the reboot gate has no decision for this alert. "
                "Add `alert %s block  # why` or `alert %s pass  # why` to %s, or set the annotation %s: block|pass on the rule in %s"
                % (name, info["layer"], info["severity"], name, name, ledger, ANNOTATION, where))

    for name, (_d, n) in sorted(alerts.items()):
        if name not in ours:
            findings.append("%s:%d classifies %s, which no layer renders as a Tockmox alert; renamed or removed? Edit or delete the line" % (ledger, n, name))
    for name, n in sorted(upstream.items()):
        if name in ours:
            findings.append("%s:%d lists %s as upstream, but Tockmox authors it; use an `alert` line" % (ledger, n, name))
        elif name not in theirs:
            findings.append("%s:%d lists upstream alert %s, which no rendered subchart ships; renamed or dropped upstream, so the gate would silently lose it" % (ledger, n, name))

    want = blocking_names(alerts, upstream, annotated)
    printed, match_only = doc_regexp(doc)
    if printed is None:
        findings.append("%s prints no `alertFilterRegexp: \"...\"` line; the page is where an operator reads the gate" % doc)
    else:
        try:
            rx = re.compile(printed)
        except re.error as e:
            findings.append("%s: the printed alertFilterRegexp does not compile: %s" % (doc, e))
            rx = None
        if rx is not None:
            for name in sorted(ours):
                decision = annotated.get(name) or (alerts.get(name) or (None,))[0]
                if decision is None:
                    continue
                hit = rx.search(name) is not None
                if decision == "block" and not hit:
                    findings.append("%s: the printed alertFilterRegexp does not match %s, which is classified block" % (doc, name))
                if decision == "pass" and hit:
                    findings.append("%s: the printed alertFilterRegexp matches %s, which is classified pass" % (doc, name))
            for name in sorted(upstream):
                if rx.search(name) is None:
                    findings.append("%s: the printed alertFilterRegexp does not match upstream %s" % (doc, name))
        if printed != regexp_for(want):
            findings.append("%s: the printed alertFilterRegexp is not what %s implies; run `tools/check-kured-gate.sh --print-regexp` and paste it" % (doc, ledger))
    if not match_only:
        findings.append("%s does not print `alertFilterMatchOnly: true` beside the regexp; kured reads the regexp as an EXCLUSION list without it, which inverts the gate" % doc)
    return findings


PLANTED = """\
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: planted
  labels:
    tockmox.com/managed-by: tockmox
spec:
  groups:
    - name: planted
      rules:
        - alert: %s
          expr: vector(1)
          labels:
            severity: critical
%s"""


def selftest(ledger, doc, rendered):
    """Prove the check goes red on each way the gate can be bypassed, and stays green on the legitimate ones."""
    import shutil
    import tempfile

    tmp = tempfile.mkdtemp(prefix="kured-gate-")
    fails = []
    try:
        base = check(ledger, doc, rendered)
        if base:
            print("selftest FAIL: the tree itself is red, so no mutation below proves anything:")
            for f in base:
                print("    " + f)
            return 1
        print("  baseline: the tree is green")

        led = open(ledger).read()
        dtext = open(doc).read()
        printed = doc_regexp(doc)[0]
        blocks = [l for l in led.splitlines() if l.startswith("alert ") and " block " in l]
        passes = [l for l in led.splitlines() if l.startswith("alert ") and " pass " in l]
        victim_pass = passes[0].split()[1]
        victim_block = blocks[0].split()[1]
        plant_n = [0]

        def variant(led_text=None, doc_text=None, extra_render=None):
            plant_n[0] += 1
            d = os.path.join(tmp, "v%d" % plant_n[0])
            os.makedirs(d)
            lp, dp = os.path.join(d, "ledger.txt"), os.path.join(d, "doc.md")
            open(lp, "w").write(led if led_text is None else led_text)
            open(dp, "w").write(dtext if doc_text is None else doc_text)
            rp = list(rendered)
            if extra_render:
                ep = os.path.join(d, "extra.yaml")
                open(ep, "w").write(extra_render)
                rp.append(ep)
            return check(lp, dp, rp)

        def red(label, want, **kw):
            got = variant(**kw)
            if any(want in g for g in got):
                print("  red   ok: %s" % label)
            else:
                print("  red   FAIL: %s: wanted a finding containing %r, got %s" % (label, want, got or "nothing (the gate stayed green)"))
                fails.append(label)

        def green(label, **kw):
            got = variant(**kw)
            if not got:
                print("  green ok: %s" % label)
            else:
                print("  green FAIL: %s: expected no finding, got %s" % (label, got))
                fails.append(label)

        # 1. THE POINT OF THE GATE: a new alert, nobody classified it.
        red("a new critical alert with no classification", "UNCLASSIFIED TockmoxInvented",
            extra_render=PLANTED % ("TockmoxInvented", ""))
        red("an existing alert whose ledger line was deleted", "UNCLASSIFIED " + victim_pass,
            led_text="\n".join(l for l in led.splitlines() if not l.startswith("alert %s " % victim_pass)) + "\n")
        # 2. The legitimate ways in.
        green("a new alert classified by annotation: pass",
              extra_render=PLANTED % ("TockmoxInvented", "          annotations:\n            kured_gate: pass\n"))
        red("a new alert classified block by annotation, regexp not updated", "does not match TockmoxInvented",
            extra_render=PLANTED % ("TockmoxInvented", "          annotations:\n            kured_gate: block\n"))
        green("a new alert classified block by annotation, regexp updated",
              extra_render=PLANTED % ("TockmoxInvented", "          annotations:\n            kured_gate: block\n"),
              doc_text=dtext.replace(printed, regexp_for(sorted(set(printed[2:-2].split("|")) | {"TockmoxInvented"}))))
        # 3. Ways to be classified wrongly.
        red("an annotation with a value that is neither block nor pass", "the value is block or pass",
            extra_render=PLANTED % ("TockmoxInvented", "          annotations:\n            kured_gate: maybe\n"))
        red("an alert classified twice, by annotation and by ledger", "classified twice",
            extra_render=PLANTED % (victim_pass, "          annotations:\n            kured_gate: pass\n"))
        red("a ledger line that does not parse", "is not `alert NAME", led_text=led + "alert TockmoxBroken\n")
        red("a ledger line with no reason", "is not `alert NAME", led_text=led + "alert TockmoxBroken block\n")
        red("an alert listed twice", "is classified twice",
            led_text=led + "alert %s pass  # again\n" % victim_pass)
        # 4. The ledger rotting.
        red("a ledger line for an alert that no longer renders", "no layer renders",
            led_text=led + "alert TockmoxNoSuchAlert block  # gone\n")
        red("an upstream alert the subchart no longer ships", "no rendered subchart ships",
            led_text=led + "upstream KubeletDownRenamedUpstream  # renamed\n")
        # 5. The printed regexp drifting from the decisions.
        red("a block alert dropped from the printed regexp", "does not match " + victim_block,
            doc_text=dtext.replace(printed, printed.replace(victim_block + "|", "").replace("|" + victim_block, "")))
        red("a block alert flipped to pass but still in the printed regexp", "matches %s, which is classified pass" % victim_block,
            led_text=led.replace("alert %s " % victim_block, "alert %s " % victim_block, 1).replace(
                [l for l in led.splitlines() if l.startswith("alert %s " % victim_block)][0],
                [l for l in led.splitlines() if l.startswith("alert %s " % victim_block)][0].replace(" block ", " pass  ", 1)))
        red("a pass alert flipped to block with the regexp not updated", "does not match " + victim_pass,
            led_text=led.replace(
                [l for l in led.splitlines() if l.startswith("alert %s " % victim_pass)][0],
                [l for l in led.splitlines() if l.startswith("alert %s " % victim_pass)][0].replace(" pass ", " block ", 1)))
        red("the printed regexp is not anchored, so it matches by substring", "not what",
            doc_text=dtext.replace(printed, printed[1:]))
        # 6. The page.
        red("the page drops alertFilterMatchOnly: true", "EXCLUSION list",
            doc_text=re.sub(r"^\s*alertFilterMatchOnly:\s*true\s*$", "", dtext, flags=re.M))
        red("the page prints no regexp", "prints no `alertFilterRegexp",
            doc_text=re.sub(r'^\s*alertFilterRegexp:.*$', "", dtext, flags=re.M))
        # 7. An empty render must not pass on nothing.
        empty = os.path.join(tmp, "empty.yaml")
        open(empty, "w").write("")
        got = check(ledger, doc, [empty])
        if any("no Tockmox-authored alert rendered" in g for g in got):
            print("  red   ok: a render with no Tockmox alerts")
        else:
            print("  red   FAIL: a render with no Tockmox alerts passed: %s" % got)
            fails.append("empty render")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print("selftest FAILED: %d case(s): %s" % (len(fails), "; ".join(fails)))
        return 1
    print("selftest PASSED")
    return 0


def main(argv):
    if len(argv) >= 4 and argv[0] == "selftest":
        return selftest(argv[1], argv[2], argv[3:])
    if len(argv) >= 2 and argv[0] == "regexp":
        alerts, upstream, findings = parse_ledger(argv[1])
        if findings:
            print("\n".join(findings), file=sys.stderr)
            return 1
        annotated = {}
        if len(argv) > 2:
            ours, _ = load_rules(argv[2:])
            annotated = {n: i["annotation"] for n, i in ours.items() if i["annotation"] in DECISIONS}
        print(regexp_for(blocking_names(alerts, upstream, annotated)))
        return 0
    if len(argv) >= 4 and argv[0] == "check":
        findings = check(argv[1], argv[2], argv[3:])
        for f in findings:
            print("FAIL %s" % f)
        ours, _ = load_rules(argv[3:])
        print("check-kured-gate: %d Tockmox alert(s) checked against %s, %d finding(s)" % (len(ours), argv[1], len(findings)))
        return 1 if findings else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

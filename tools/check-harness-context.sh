#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Every kubectl and helm call the executed-docs harness makes must name its
# cluster. TM-0797.
#
#   ./tools/check-harness-context.sh              scan the harness
#   ./tools/check-harness-context.sh --selftest   prove the scan goes red
#
# WHY. A bare `kubectl` targets whatever KUBECONFIG and current-context the
# caller happens to have. The harness creates and deletes VMs, Secrets, Services
# and namespaces, so a bare call is one wrong shell away from doing that to a
# cluster nobody meant. The 0.7.0 lab pass found netpol-adversary.sh calling
# bare kubectl; it was safe that day only because the caller had pointed
# KUBECONFIG at a lab-only file. After INC-2026-09-29-01 (a lab uninstall
# script deleted about 100 CRDs on production) the standing rule is a literal
# context on every call in anything an operator runs.
#
# WHAT IT ASSERTS, on the files under tests/executed-docs/ (shell scripts),
# .github/workflows/executed-docs.yaml, which drives them, and tools/publish-docs.sh
# (TM-0807, which creates and deletes a pod in an operator's cluster):
#
#   1. Every kubectl or helm invocation in command position carries
#      --context / --kube-context in the same command.
#   2. The value is a variable reference ("$VAR" or "${VAR}"), never a literal
#      and never a command substitution: a literal cannot be refused when
#      empty, and `--context=` with an EMPTY value silently means the current
#      context (docs/deployment/fresh-install.md § Name the cluster).
#   3. The file (or, for the workflow, each STEP) REFUSES when that variable is
#      empty: it contains `${VAR:?`. The guard is what turns an unset variable
#      into a stop instead of a fall-back to the ambient cluster.
#
# THE TWO VARIABLES. KUBE_CONTEXT names the cluster under test (the guest, or
# the lab cluster netpol-adversary.sh is pointed at). TOCKMOX_SUBSTRATE_CONTEXT
# names the hypervisor cluster that hosts the throwaway VM. They are different
# clusters, and a script that needs both uses both.
#
# EXEMPTIONS ARE WRITTEN, NOT IMPLIED. A call that cannot carry a context
# (a `kubectl config` edit of a kubeconfig file that reaches no cluster; a
# command that runs INSIDE a pod, where the pod's own service account is the
# only identity) is marked, and the mark must give a reason:
#
#   ... kubectl config unset ...        # ctx-exempt: edits a file, reaches no cluster
#   # ctx-exempt-begin: in-pod script, runs under the pod's own service account
#   ...
#   # ctx-exempt-end
#
# A mark with no reason is itself a failure, and so is an unclosed region.
#
# WHAT COUNTS AS A CALL. A command word in code (line start, after | & ; ( $( or
# a backtick, after then/do/if/sudo, after VAR=value prefixes); the first word of
# a string handed to printf, eval or sh -c; and the second argument of
# assert_artifact / assert_artifact_xfail, which the library evals. An unquoted
# heredoc body is expanded by the shell, so only a $( ) or backtick in it counts;
# a quoted heredoc body is data. Strings that merely NAME kubectl (assertion
# labels, extractor --containing keys, echo text) are not calls.
#
# WHAT THIS DOES NOT PROVE. It reads text. A command assembled at run time
# (`$KUBECTL_BIN get ...`, an eval of a string built elsewhere, a function that
# wraps kubectl and is called with a name this scan does not know) is not seen.
# The scanner was itself wrong twice while being written (a `$(` inside double
# quotes hid every call after it, and an apostrophe in a heredoc swallowed 750
# lines); --selftest holds the cases that found those, but it is a hand-written
# tokenizer, not a shell parser.
# It cannot tell that the named context is the RIGHT cluster, only that one is
# named and that an empty name is refused. Documentation blocks that the harness
# extracts and runs verbatim are the page's text, not harness calls; the pages
# carry their own KUBE_CONTEXT guard and this scan does not read them.
#
# Exit 0 pass, 1 findings, 2 skipped (python3 absent).
set -uo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || { echo "SKIPPED: python3 not found" >&2; exit 2; }

scan() { # scan <root-for-relative-paths>
python3 - "$1" <<'PY'
import os, re, shlex, sys

root = sys.argv[1]
targets = []
for dp, dn, fn in os.walk(os.path.join(root, "tests/executed-docs")):
    dn.sort()
    for f in sorted(fn):
        if f.endswith(".sh"):
            targets.append(os.path.join(dp, f))
wf = os.path.join(root, ".github/workflows/executed-docs.yaml")
if os.path.exists(wf):
    targets.append(wf)
# Shipped scripts that an operator runs against their own cluster follow the same
# rule (TM-0807): tools/publish-docs.sh creates and deletes a pod.
for extra in ("tools/publish-docs.sh",):
    if os.path.exists(os.path.join(root, extra)):
        targets.append(os.path.join(root, extra))

# A command word is a call when it starts a command IN CODE (not inside a
# quoted string that merely names it): line start, after a control operator, a
# subshell or backtick, after a shell keyword or sudo/exec, or after leading
# VAR=value assignments. Separately, the first word of a printf/-c string is a
# command handed to eval or a shell, so that counts too.
LEAD = (r"(?:^|[|&;(`{!]|\b(?:then|do|else|elif|if|while|until|exec|sudo|time)\s)")
ASSIGN = r"(?:[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|\S*)\s+)*"
CALL = re.compile(LEAD + r"\s*" + ASSIGN + r"((?:kubectl|helm))(?![\w./=-])")
RUNS = re.compile(r"(?:printf|eval|-c)\s+$")
ASSERT = re.compile(r"(?:^|[\s;&|(])assert_artifact(?:_xfail)?(?=\s)")
QSTART = re.compile(r"\s*((?:kubectl|helm))(?=\s|$)")
FLAG = re.compile(r"--(?:kube-)?context(?:=|\s+)(\\?[\"']?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?\\?[\"']?|\S+)")
NEXT = re.compile(r"ctx-exempt-next:\s*(.*)$")
EXEMPT = re.compile(r"ctx-exempt:\s*(\S.*)$")
BEGIN = re.compile(r"ctx-exempt-begin:\s*(.*)$")
END = re.compile(r"ctx-exempt-end")
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")

def code_view(text, state=None):
    """Return (view, state). view has every character that is NOT executable
    code (inside quotes, comments) blanked to a space, except that text inside
    $( ) and backticks nested in double quotes stays visible. state is the
    quote state left open at the end ('' when closed)."""
    out = []
    openq = []            # positions of quotes that OPEN a string from code
    stack = ["code"]      # frames: code, dq, sq, sub(depth), bt
    depth = [0]
    i, n = 0, len(text)
    if state:
        stack = list(state)
        depth = [0] * len(stack)
    def is_code():
        return stack[-1] in ("code", "sub", "bt")
    while i < n:
        c = text[i]
        top = stack[-1]
        if top == "sq":
            out.append(" ")
            if c == "'":
                stack.pop(); depth.pop()
            i += 1; continue
        if c == "\\" and top != "sq":
            out.append(" " if not is_code() else c)
            if i + 1 < n:
                out.append(" " if not is_code() else text[i + 1])
            i += 2; continue
        if top == "dq":
            if c == '"':
                stack.pop(); depth.pop(); out.append(" ")
            elif c == "$" and text[i:i+2] == "$(":
                stack.append("sub"); depth.append(0); out.append(" ("); i += 2; continue
            elif c == "`":
                stack.append("bt"); depth.append(0); out.append(" ")
            else:
                out.append(" ")
            i += 1; continue
        # code-like frames: code, sub, bt
        if c == "#" and (i == 0 or text[i-1] in " \t;(|&"):
            out.append(" " * (n - i))
            break
        if c == "'":
            openq.append(i); stack.append("sq"); depth.append(0); out.append(" ")
        elif c == '"':
            openq.append(i); stack.append("dq"); depth.append(0); out.append(" ")
        elif c == "$" and text[i:i+2] == "$(":
            stack.append("sub"); depth.append(0); out.append(" ("); i += 2; continue
        elif c == "`":
            if top == "bt":
                stack.pop(); depth.pop(); out.append(" ")
            else:
                stack.append("bt"); depth.append(0); out.append(c)
        elif c == "(" and top == "sub":
            depth[-1] += 1; out.append(c)
        elif c == ")" and top == "sub":
            if depth[-1] == 0:
                stack.pop(); depth.pop(); out.append(" ")
            else:
                depth[-1] -= 1; out.append(c)
        else:
            out.append(c)
        i += 1
    left = [f for f in stack[1:]] if len(stack) > 1 else []
    return "".join(out), left, openq

def heredocs_in(buf, view):
    """Heredoc markers that sit in code (not inside a quoted string)."""
    out = []
    for m in HEREDOC.finditer(buf):
        if view[m.start():m.start() + 2] == "<<":
            out.append((m.group(3), m.group(1) == "-", m.group(2) != ""))
    return out

def units(path, per_line_quotes):
    """Yield (first_lineno, text, kind, view, openq). Joins backslash
    continuations and, for shell, multi-line quoted strings. Heredoc bodies are
    yielded as their own units, kind 'hd-quoted' or 'hd-open', and are never fed
    to the quote tokenizer: their apostrophes are prose, not shell."""
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    i = 0
    pending = []
    def body(delim, dash, quoted):
        nonlocal i
        while i < len(lines):
            raw = lines[i]; i += 1
            if (raw.strip() if dash else raw) == delim:
                yield i, raw, "hd-end", raw, []
                return
            yield i, raw, "hd-quoted" if quoted else "hd-open", raw, []
    while i < len(lines):
        start = i + 1
        buf = lines[i]
        i += 1
        if pending:
            delim, dash, quoted = pending.pop(0)
            if (buf.strip() if dash else buf) == delim:
                yield start, buf, "hd-end", buf, []
                continue
            yield start, buf, "hd-quoted" if quoted else "hd-open", buf, []
            pending.insert(0, (delim, dash, quoted))
            continue
        consumed = 0
        while True:
            if buf.endswith("\\") and i < len(lines):
                buf = buf[:-1] + " " + lines[i]; i += 1; continue
            view, left, _q = code_view(buf)
            hds = heredocs_in(buf, view)
            if len(hds) > consumed and i < len(lines) and (left or per_line_quotes is False):
                # bodies start after the physical line that holds the marker
                for h in hds[consumed:]:
                    for u in body(*h):
                        yield u
                consumed = len(hds)
            if left and not per_line_quotes and i < len(lines):
                buf = buf + "\n" + lines[i]; i += 1; continue
            break
        view, left, openq = code_view(buf)
        for h in heredocs_in(buf, view)[consumed:]:
            pending.append(h)
        yield start, buf, "code", view, openq

findings = []
for path in targets:
    rel = os.path.relpath(path, root)
    text = open(path, encoding="utf-8", errors="replace").read()
    per_line = path.endswith(".yaml")
    in_region, region_line = False, 0
    skip_next = False
    # Where a refusal counts. A shell file is one scope. A workflow is checked
    # STEP BY STEP: a guard in the preflight step does not protect the teardown
    # step, which runs `if: always()` after a preflight that may have refused,
    # with the same empty variable.
    scopes = [[set(), []]]          # [used_vars, lines_of_scope]
    STEP = re.compile(r"^\s*- (?:name|uses):")
    for ln, line, kind, view, openq in units(path, per_line):
        if kind == "hd-end":
            continue
        if per_line and STEP.match(line):
            scopes.append([set(), []])
        scopes[-1][1].append(line)
        used_vars = scopes[-1][0]
        b = BEGIN.search(line)
        if b and kind == "code":
            if not b.group(1).strip():
                findings.append((rel, ln, "ctx-exempt-begin with no reason"))
            in_region, region_line = True, ln
            continue
        if END.search(line) and kind == "code":
            in_region = False
            continue
        nx = NEXT.search(line)
        if nx and kind == "code" and line.strip().startswith("#"):
            if not nx.group(1).strip():
                findings.append((rel, ln, "ctx-exempt-next with no reason"))
            skip_next = True
            continue
        if in_region:
            continue
        if skip_next and kind == "code" and not line.strip().startswith("#"):
            skip_next = False
            continue
        if kind == "hd-quoted":
            continue          # data handed to something else, never expanded here
        if kind == "hd-open":
            # An unquoted heredoc body is expanded by THIS shell: only an
            # unescaped $( ) or backtick in it runs here.
            parts = re.findall(r"(?<!\\)\$\((.*?)\)|(?<!\\)`(.*?)`", line)
            view = " ".join(" ; ".join(p) for p in parts)
            if not view.strip():
                continue
        elif line.strip().startswith("#"):
            continue
        exm = EXEMPT.search(line)
        if "ctx-exempt:" in line and not exm:
            findings.append((rel, ln, "ctx-exempt mark with no reason"))
        calls = [(m.start(1), m.group(1)) for m in CALL.finditer(view)]
        if kind == "code":
            for q in openq:
                # A quoted string is a command when it is handed to something
                # that runs it: printf-built probe strings (later eval'd), eval,
                # and sh/bash/zsh -c. Descriptions and extractor keys that merely
                # mention kubectl are not.
                if not RUNS.search(line[:q]):
                    continue
                m = QSTART.match(line, q + 1)
                if m:
                    calls.append((m.start(1), m.group(1)))
            # assert_artifact / assert_artifact_xfail evaluate their SECOND
            # argument as a command line.
            for am in ASSERT.finditer(view):
                try:
                    words = shlex.split(line[am.end():])
                except ValueError:
                    continue
                if len(words) >= 2:
                    m2 = re.match(r"\s*(kubectl|helm)(?=\s|$)", words[1])
                    if m2:
                        # position: find the word in the line for the segment
                        idx = line.find(words[1][:20], am.end())
                        calls.append((idx if idx >= 0 else am.end(), m2.group(1)))
        calls.sort()
        src = line if kind == "code" else view
        for k, (pos, name) in enumerate(calls):
            if exm:
                continue
            end = calls[k + 1][0] if k + 1 < len(calls) else len(src)
            seg = src[pos:end]
            f = FLAG.search(seg)
            one = " ".join(line.split())[:100]
            if not f:
                findings.append((rel, ln, "bare %s: %s" % (name, one)))
            elif not f.group(2):
                findings.append((rel, ln, "--context is not a variable reference (%s): %s" % (f.group(1), one)))
            else:
                used_vars.add(f.group(2))
    if in_region:
        findings.append((rel, region_line, "ctx-exempt-begin never closed"))
    for uv, sl in scopes:
        body_text = text if not per_line else "\n".join(sl)
        for v in sorted(uv):
            if ("${%s:?" % v) not in body_text:
                where = "this step" if per_line else "this file"
                findings.append((rel, 0, "uses --context \"$%s\" but %s never refuses when it is empty (no ${%s:?...} guard)" % (v, where, v)))

for rel, ln, msg in findings:
    print("FAIL %s:%s: %s" % (rel, ln, msg))
print("scanned %d files" % len(targets))
sys.exit(1 if findings else 0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-ctx.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/tests/executed-docs/paths"
  good='kubectl --context="$KUBE_CONTEXT" get nodes'
  guard=': "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"'
  t="$tmp/tests/executed-docs/paths/x.sh"
  sc=0
  case_() { # name expect-rc body...
    local name="$1" want="$2"; shift 2
    printf '%s\n' "$@" > "$t"
    scan "$tmp" >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq "$want" ]; then echo "  ok   selftest: $name (rc=$rc)"
    else echo "  FAIL selftest: $name wanted rc=$want got rc=$rc"; sc=1; fi
  }
  case_ "a guarded call with a context passes"      0 "$guard" "$good"
  case_ "a bare kubectl goes red"                    1 "$guard" "kubectl get nodes"
  case_ "a bare helm goes red"                       1 "$guard" 'helm -n argocd list'
  case_ "a bare call after a pipe goes red"          1 "$guard" 'echo x | kubectl apply -f -'
  case_ "a bare call inside \$( ) goes red"          1 "$guard" 'x="$(kubectl get ns)"'
  case_ "a bare call on a continuation line goes red" 1 "$guard" 'kubectl -n a \' '  get pod'
  case_ "a context on a continuation line passes"    0 "$guard" 'kubectl -n a \' '  --context="$KUBE_CONTEXT" get pod'
  case_ "a printf-built command string goes red"     1 "$guard" "printf 'kubectl -n %s get pod' a"
  case_ "an env prefix does not hide a bare call"    1 "$guard" 'KUBECONFIG=/x kubectl get nodes'
  case_ "the second call of a pipe must carry it too" 1 "$guard" 'kubectl --context="$KUBE_CONTEXT" create ns a | kubectl apply -f -'
  case_ "a literal context goes red"                 1 "$guard" 'kubectl --context=prod get nodes'
  case_ "a context with no empty-refusal goes red"   1 "$good"
  case_ "an exemption with a reason passes"          0 'kubectl config view  # ctx-exempt: reads a file only'
  case_ "an exemption with no reason goes red"       1 'kubectl config view  # ctx-exempt:'
  case_ "an exempt region passes"                    0 '# ctx-exempt-begin: runs in a pod' 'kubectl get cm' '# ctx-exempt-end'
  case_ "an unclosed exempt region goes red"         1 '# ctx-exempt-begin: runs in a pod' 'kubectl get cm'
  case_ "a command string given to assert_artifact goes red" 1 "$guard" 'assert_artifact "d" "kubectl get x" "y"'
  case_ "the same string with a context passes"      0 "$guard" 'assert_artifact "d" "kubectl --context=\"$KUBE_CONTEXT\" get x" "y"'
  case_ "an assertion label naming kubectl is not a call" 0 "$guard" 'assert_artifact "kubectl get x lists it" "echo ok" "ok"'
  case_ "an extractor key naming helm is not a call" 0 'bash extract --containing '"'"'helm install argocd'"'"''
  case_ "a heredoc body handed to a pod is not a call" 0 "cat <<'EOF'" 'kubectl get pods' 'EOF'
  case_ "a command substitution inside an open heredoc runs here" 1 "$guard" 'cat <<EOF' 'x: $(kubectl get ns)' 'EOF'
  case_ "a call inside \$( ) inside double quotes goes red" 1 "$guard" 'if [ "$(kubectl auth can-i get pods)" = yes ]; then :; fi'
  case_ "an apostrophe in a heredoc body does not hide a later bare call" 1 "$guard" 'cat <<YAML' "it's a heredoc body" 'YAML' 'kubectl get nodes'
  case_ "a heredoc inside a command substitution inside quotes does not hide a later bare call" 1 "$guard" 'm="$(cat <<YAML' "don't" 'YAML' ')"' 'kubectl get nodes'
  case_ "prose naming kubectl is not a call"         0 'echo "MISSING TOOL: kubectl"' 'need kubectl' 'command -v helm >/dev/null'
  # A workflow is checked step by step: a guard in one step does not cover another.
  mkdir -p "$tmp/.github/workflows"
  wf="$tmp/.github/workflows/executed-docs.yaml"
  printf '%s\n' 'jobs:' '  j:' '    steps:' '      - name: a' '        run: |' \
    '          : "${TOCKMOX_SUBSTRATE_CONTEXT:?empty}"' \
    '          kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" get vm' \
    '      - name: b' '        run: |' \
    '          kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" delete vm --all' > "$wf"
  printf '' > "$t"
  scan "$tmp" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 1 ]; then echo "  ok   selftest: a workflow step using the variable without its own refusal goes red (rc=$rc)"
  else echo "  FAIL selftest: workflow step guard wanted rc=1 got rc=$rc"; sc=1; fi
  rm -f "$wf"
  # And the real tree must be green for the mutation cases above to mean anything.
  scan . >/dev/null 2>&1 && echo "  ok   selftest: the real harness tree is clean" \
    || { echo "  FAIL selftest: the real harness tree has findings (run without --selftest)"; sc=1; }
  exit "$sc"
fi

scan .

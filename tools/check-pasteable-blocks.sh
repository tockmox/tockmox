#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Enforce that every ```bash block in docs/ pastes into an interactive shell
# exactly as printed, and that the information a copy button strips is not the
# information a reader needs most.
#
#   ./tools/check-pasteable-blocks.sh              check every page under docs/
#   ./tools/check-pasteable-blocks.sh --selftest   prove the rules actually trip
#   ./tools/check-pasteable-blocks.sh FILE...      check specific files
#
# WHY THIS EXISTS (TM-0484). Three findings, all reproduced on the platform the
# docs name as a supported workstation rather than reasoned about:
#
#   RULE 1 -- no `#` inside a ```bash fence, in either position.
#
#     macOS has shipped zsh as the default login shell since 10.15 and
#     INTERACTIVE_COMMENTS is OFF in an interactive zsh, so `#` is not a comment
#     character. Measured on a stock macOS zsh 2026-09-11, `setopt | grep -i
#     interactivecomments` printing nothing:
#
#       % # WORKSTATION
#       zsh: command not found: #
#
#     A LEADING `#` therefore errors once per comment line, interleaved with real
#     output, and iTerm2's bracketed paste means a multi-line paste runs every
#     line rather than stopping at the first.
#
#     A TRAILING `#` is worse, because it can fail silently. The words after it
#     become arguments to the command:
#
#       kubectl get nodes        # wait for Ready   -> kubectl gets '#' 'wait' ...
#       $EDITOR values.yaml      # or global.yaml   -> opens FOUR files, no error
#
#     `export FOO=bar # note` is the exception that misleads: it does NOT error,
#     because `#` is a real special parameter in zsh, so `export '#'` is
#     meaningful. Measured 2026-09-11. Do not generalise from it -- that
#     observation is why this rule covers both positions rather than only the
#     leading one.
#
#   RULE 2 -- every ```bash fence on a TWO-HOST page carries a host marker in
#             the prose above it.
#
#     SCOPED, and the scope is the correction that makes this rule honest. The
#     first version applied it to every page under docs/ and was wrong on 148
#     blocks: `values-contract.md` runs jq queries against a clone and
#     `verify.md` checks a downloaded release, and neither has a
#     workstation-versus-node axis at all. Forcing a marker onto those blocks
#     manufactures noise, and a gate that flags correct work earns an exemption
#     list and then stops being believed -- the same argument tools/doc-claims.txt
#     makes for its digits-only patterns.
#
#     A page is two-host if it SAYS SO: it carries a **NODE** marker, or it has
#     a "## Where each command runs" section. Self-declaring rather than a list
#     in this script, because a hard-coded list of filenames is escaped by the
#     next file somebody adds.
#
#     WORKSTATION/NODE decides which machine a command runs on, and it used to
#     live in a `#` line: the one element of a code block that every "copy"
#     control strips and that reads as decoration. TM-0469 made those markers
#     present and consistent; it did not make them survive a copy. The marker is
#     now **WORKSTATION** or **NODE** in the paragraph before the fence.
#
#     The lookback is to the previous fence, NOT a fixed number of lines. A
#     three-line lead-in paragraph is good prose and an early draft of this
#     check rejected it, which would have made the gate an argument for worse
#     writing.
#
#   RULE 4 -- a placeholder must not look like a real value.
#
#     Added 2026-09-11 after three instances in one day, none of which RULE 3
#     could see because none matched a placeholder convention:
#
#       tockmox.your.domain   fresh-install.md, 5 sites. Pastes cleanly, installs
#                             cleanly, and puts a domain you do not own into the
#                             API server certificate. Found much later.
#       REGISTRY_HOST         airgap-prep/SKILL.md. Bare uppercase, no YOUR_,
#                             no brackets. Reads as a hostname.
#       modelGateway          not a placeholder at all, but the same failure:
#                             a real key that silently accepts what belongs
#                             somewhere else (TM-0498).
#
#     The rule documentation-standard § 5 already states is "make it obviously
#     not-a-value". This is that sentence made checkable. A token is suspicious
#     when it is a bare ALL_CAPS_WORD used as a VALUE -- assigned, or sitting in
#     a URL or hostname position -- and is neither prefixed YOUR_ nor bracketed.
#
#     DELIBERATELY NARROW, because the false-positive cost here is high: real
#     environment variables are also ALL_CAPS. Only two positions are checked,
#     both of which are where a pasted fake value does damage:
#       - the right-hand side of an assignment  FOO=REGISTRY_HOST
#       - inside a URL or image reference       docker://REGISTRY_HOST/x
#     A bare $VAR reference, an exported name, and anything already carrying
#     YOUR_ or <> are all left alone.
#
#   RULE 5 -- no `read -p` inside a ```bash fence.
#
#     Added 2026-09-13 (TM-0537). zsh has no `-p` PROMPT flag on `read`; there
#     `-p` means "read from a coprocess". So `read -rs -p "token: " TOK` on the
#     shell macOS ships prints `read: -p: no coprocess`, one line among several,
#     and continues with TOK unset. Measured on the rc3 gate 2026-09-12: two
#     repository Secrets were created with an EMPTY password, each carried the
#     right label, each passed the page's own success condition, and the
#     failure surfaced three phases later as nine layers in ComparisonError
#     ... the one error install.md itself calls undiagnosable.
#
#     The portable form is two commands, and the docs now use it everywhere:
#
#       printf 'token: '; read -rs TOK; echo
#
#     Four occurrences across three pages were fixed by hand. This rule is the
#     half that catches the next one, because the failure is silent in exactly
#     the way that survives a review: the block LOOKS like it prompted.
#
#     The match is `read` followed by flag groups, one of which contains `p`
#     (`-p`, `-rp`, `-sp`, `-rs -p`). A variable named `p` after `-r` does not
#     match, and `read -r f` in a while-loop does not match.
#
#   RULE 6 -- a variable assigned a multi-word value is never expanded unquoted.
#
#     Added 2026-09-14. zsh does NOT word-split an unquoted $VAR (SH_WORD_SPLIT
#     is off), so this documented success condition:
#
#       BASE="--set global.internalDomain=x --set global.lanCIDR=y"
#       helm template t charts/tockmox-ai $BASE | grep -c '^kind:'
#
#     hands helm ONE argument on the shell macOS ships, helm exits 1 with
#     "unknown flag: --set global.internalDomain", grep -c prints 0 for BOTH
#     lines ... and the page then tells the reader "if the two numbers are
#     equal, your key is wrong". Measured 2026-09-14 by pasting the block into
#     zsh 5.8 (8 and 0 under bash, 0 and 0 under zsh). Same family as RULE 5:
#     the block looks right, the error goes somewhere else, the page blames the
#     reader. The fix is to write the flags out, or use an array expanded as
#     "${ARR[@]}", which both shells split the same way.
#
#     The match: within one fence, NAME=<quoted value containing whitespace>
#     followed by $NAME or ${NAME} on a later line outside double quotes.
#     Quoted expansions ("$NAME"), single-word values, and array expansions do
#     not match.
#
#   RULE 7 -- once a page names its cluster, every block that runs kubectl
#             pins it (TM-0844).
#
#     `kubectl --context=` with an EMPTY value does not error: it falls back to
#     the current context. So `--context="$KUBE_CONTEXT"` alone fails OPEN the
#     moment the variable goes empty, onto whatever cluster was touched last,
#     which happened live (fresh-install.md, "A guard, not only the export").
#     The guard line `: "${KUBE_CONTEXT:?...}"` turns that into a stop.
#
#     SCOPED like RULE 2: the rule starts at the first ```bash block that
#     exports or guards a *CONTEXT variable. Blocks before it have nothing to
#     pin to (fresh-install.md checks the new kubeconfig before naming the
#     cluster). From there on, a block that calls kubectl must carry a
#     `: "${..._CONTEXT:?` guard line (or itself export the context), and every
#     kubectl call in it, including inside $( ) and after xargs, must carry
#     --context. `k3s kubectl` (node-local) and `kubectl config ...` (reads the
#     local kubeconfig, reaches no cluster) are exempt. Continuation lines are
#     joined before counting. Found 2026-10-07: upgrade.md's steps 0-7 ran
#     unpinned while its later guards pointed at a "Before you begin" that never
#     exported KUBE_CONTEXT; uninstall.md pinned nothing at all.
#
#   RULE 3 -- no hand-substitution token inside a ```bash fence, except in a
#             block that is itself a setup block.
#
#     A setup block is one that ASSIGNS the token (`export FOO=YOUR_FOO`). That
#     is the whole pattern: the reader substitutes once, at the top, and every
#     later block reads the variable. `YOUR_SITE_REPO_URL` at five call sites
#     was five chances to spell it differently, against a consumer (ArgoCD) that
#     compares character for character.
#
# SCOPE: ```bash fences under docs/ only. A ```sh or ```console fence is a
# recorded transcript rather than an instruction, which is the same line
# tests/executed-docs/INVENTORY.md draws, and restyling quoted output is not
# this project's business.
#
# WHY NOT markdownlint / Vale: the same build-or-adopt scan recorded in
# tools/check-docs-style.sh applies unchanged. Neither can express "inside a
# bash fence but not inside a block that assigns this token", which is the
# distinction doing all the work here. This repository already hosts ten bash
# check scripts and adds nothing new by hosting an eleventh.
#
# PORTABILITY: must run on macOS /bin/bash 3.2.57 as well as the Wolfi runner.
# No mapfile, no associative arrays, no `${var,,}`. A bare `"$@"` under `set -u`
# on bash 3.2 errors on an empty array, so argument handling counts first.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF/.." && pwd)"

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; X=$'\033[0m'
else R=""; G=""; Y=""; B=""; X=""; fi

FAILED=0
CHECKED=0

fail() { printf '%s  FAIL%s %s\n' "$R" "$X" "$*" >&2; FAILED=$((FAILED + 1)); }
pass() { printf '%s  ok%s   %s\n' "$G" "$X" "$*"; }

# ---------------------------------------------------------------- the checker
#
# One awk pass per file. Reports one line per violation, prefixed with the rule
# number so the summary can say which rule is failing rather than only that
# something is.
check_file() {
  local file="$1" twohost=0
  # A page declares itself two-host by carrying a NODE marker or a
  # "Where each command runs" section. Computed here rather than inside awk so
  # the awk pass stays single-purpose.
  if grep -qE '\*\*[^*]*(NODE|CLIENT|CONNECTED)\*\*|^## Where each command runs' "$file" 2>/dev/null; then
    twohost=1
  fi
  awk -v FNAME="$file" -v TWOHOST="$twohost" '
    function flush_block(   i, tok) {
      # RULE 3 is evaluated at block close, because a token is permitted when
      # THIS block assigns it, and the assignment may come after the use.
      for (tok in used) {
        if (!(tok in assigned)) {
          printf "%s:%d: RULE3 hand-substitution token %s inside a bash fence that does not assign it\n",
                 FNAME, used[tok], tok
        }
      }
      delete used; delete assigned; delete multiword
    }

    # NORMALISE INDENTATION FIRST. Fences indented inside a list item are real
    # documented commands, and until 2026-09-13 this gate could not see them:
    # an anchored /^```bash$/ matched only a flush-left fence, so two NODE
    # commands in fresh-install.md were exempt from every rule here. Proven with
    # a fixture carrying a RULE 1 violation ... flush-left caught it, the same
    # bytes indented by two spaces passed clean. A gate whose scope silently
    # excludes part of its subject is the defect this repository keeps finding.
    { bare = $0; sub(/^[ \t]+/, "", bare) }

    # Track the paragraph text since the last fence, for RULE 2.
    bare == "```bash" {
      inblock = 1; blockstart = NR
      if (TWOHOST == 1 && marker_seen != 1) {
        printf "%s:%d: RULE2 bash fence with no **WORKSTATION** or **NODE** marker in the prose above it\n",
               FNAME, NR
      }
      next
    }

    bare ~ /^```/ {
      if (inblock) { flush_block(); inblock = 0; marker_seen = 0 }
      else { infence = !infence }     # a non-bash fence; do not scan it
      next
    }

    inblock {
      # RULE 1 -- any # at all, either position.
      if (index($0, "#") > 0) {
        printf "%s:%d: RULE1 comment character inside a bash fence: %s\n", FNAME, NR, $0
      }
      # RULE 5 -- `read` with a flag group containing p. The flag groups may
      # come in any order (`read -rs -p`), so allow any number of them before
      # the one that carries the p.
      if ($0 ~ /(^|[ \t;|&(])read[ \t]+(-[a-zA-Z]+[ \t]+)*-[a-zA-Z]*p([ \t]|$)/) {
        printf "%s:%d: RULE5 read -p is bash-only and reads NOTHING on zsh ... use printf then read -rs: %s\n", FNAME, NR, $0
      }
      # RULE 4 -- a bare ALL_CAPS token used as a VALUE, carrying neither the
      # YOUR_ prefix nor brackets. Two positions only; see the header for why
      # this is narrow. $VAR references are excluded by requiring no $ before.
      r4 = $0
      # No interval expressions ({4,}) in this awk program: mawk, the default
      # awk on Debian and Ubuntu, matched `[A-Z0-9_]{4,}` as exactly four, so
      # `=AUTHENTIK_SECRET_KEY=` was cut to `AUTHE`, its next character was
      # not `=`, and the key-name exemption below never applied. Six false
      # RULE4 findings on a clean tree (2026-10-06). Spelled out instead.
      while (match(r4, /(=|:\/\/|\/)[A-Z][A-Z0-9_][A-Z0-9_][A-Z0-9_][A-Z0-9_][A-Z0-9_]*/)) {
        cand = substr(r4, RSTART, RLENGTH)
        sub(/^(=|:\/\/|\/)/, "", cand)
        pre  = (RSTART > 1) ? substr(r4, RSTART - 1, 1) : " "
        post = substr(r4, RSTART + RLENGTH, 1)
        # post == "=" means this token is a KEY NAME, not a value:
        #   --from-literal=AUTHENTIK_SECRET_KEY="$AK"   correct as written
        # Without this test the rule fired on eleven correct lines and six
        # real ones. Eleven false positives is how a gate earns an exemption
        # list and then stops being believed.
        if (cand !~ /^YOUR_/ && pre != "$" && pre != "{" && post != "=" \
            && !(cand in r4seen)) {
          r4seen[cand] = 1
          printf "%s:%d: RULE4 %s looks like a value but is a placeholder ... prefix it YOUR_ or make it a variable\n",
                 FNAME, NR, cand
        }
        r4 = substr(r4, RSTART + RLENGTH)
      }

      # RULE 6 -- an unquoted expansion of a variable this block assigned a
      # multi-word value. Assignments first (so the assignment line itself is
      # not a use), then uses on later lines with quoted spans removed.
      if (match($0, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=("[^"]*[ \t][^"]*"|'"'"'[^'"'"']*[ \t][^'"'"']*'"'"')/)) {
        a6 = substr($0, RSTART, RLENGTH); sub(/^[ \t]*(export[ \t]+)?/, "", a6); sub(/=.*$/, "", a6)
        multiword[a6] = NR
      } else {
        u6 = $0
        gsub(/"[^"]*"/, "", u6); gsub(/'"'"'[^'"'"']*'"'"'/, "", u6)
        for (v6 in multiword) {
          if (u6 ~ ("\\$" v6 "([^A-Za-z0-9_]|$)") || u6 ~ ("\\$\\{" v6 "\\}")) {
            printf "%s:%d: RULE6 $%s holds a multi-word value (line %d) and is expanded unquoted here ... zsh passes it as ONE argument: %s\n",
                   FNAME, NR, v6, multiword[v6], $0
          }
        }
      }

      # RULE 3 -- collect uses and assignments of hand-substitution tokens.
      line = $0
      while (match(line, /YOUR_[A-Z0-9_]+|<[A-Z][A-Z0-9_][A-Z0-9_][A-Z0-9_]*>/)) {
        tok = substr(line, RSTART, RLENGTH)
        # An assignment is NAME=TOKEN or export NAME=TOKEN on this line.
        if (line ~ ("=" tok)) assigned[tok] = 1
        else if (!(tok in used)) used[tok] = NR
        line = substr(line, RSTART + RLENGTH)
      }
      next
    }

    # Outside any fence: look for the host marker.
    !infence {
      # The marker may sit anywhere inside a bold span, so that
      # "**Step 2 ... WORKSTATION**, once" counts. Requiring it to follow "**"
      # immediately rejected correct prose in the first draft of this check.
      #
      # FOUR host words, not two. WORKSTATION and NODE cover the deployment
      # pages. CLIENT is the second host on tls-and-trust: every machine you
      # browse a console from, which may be the workstation and is still a
      # separate pass. CONNECTED is the second host on airgap: a host outside
      # the boundary, never a cluster node. With only two words, both of those
      # pages had to write markers like "CLIENT, a separate pass from
      # WORKSTATION" purely to satisfy the regex ... the gate dictating prose
      # rather than checking it, which is the failure this rule prevents.
      #
      # NOTE: no apostrophes anywhere in this awk program. It is single-quoted
      # in the shell, so one apostrophe in a comment ends the program and the
      # script dies with a syntax error far from the cause.
      if ($0 ~ /\*\*[^*]*(WORKSTATION|NODE|CLIENT|CONNECTED)/) marker_seen = 1
    }

    END { if (inblock) flush_block() }
  ' "$file"
  check_rule7 "$file"
}

# RULE 7 is its own pass: it needs page-level state (has the page named its
# cluster yet?) that the per-block pass above does not carry. Portable awk only:
# no interval expressions and no escaped braces, which is the TM-0769 lesson
# (mawk 20200120 silently never matched one).
check_rule7() {
  awk -v FNAME="$1" '
    BEGIN { KRE = "(^|[^A-Za-z0-9_./-])kubectl([ \t]|$)" }
    { bare = $0; sub(/^[ \t]+/, "", bare) }
    bare == "```bash" { inb = 1; start = NR; guard = 0; assigns = 0; logical = ""; viol = ""; nk = 0; next }
    bare ~ /^```/ {
      if (inb && named) {
        if (nk > 0 && !guard && !assigns)
          printf "%s:%d: RULE7 block runs kubectl with no *_CONTEXT guard line\n", FNAME, start
        printf "%s", viol
      }
      if (inb && (assigns || guard)) named = 1
      inb = 0; next
    }
    inb {
      if (index(bare, ": \"${") == 1 && index(bare, "CONTEXT:?") > 0) guard = 1
      if ($0 ~ /(^|[ ;])export [A-Z_]*CONTEXT=/) assigns = 1
      logical = logical " " $0
      if ($0 ~ /\\[ \t]*$/) next
      l = logical; logical = ""
      gsub(/k3s kubectl/, "k3s_kctl", l); gsub(/kubectl config /, "kctl_config ", l)
      n = 0; t = l; while (match(t, KRE)) { n++; t = substr(t, RSTART + RLENGTH) }
      c = 0; t = l; while (match(t, /--context[= ]/)) { c++; t = substr(t, RSTART + RLENGTH) }
      nk += n
      if (n > c) viol = viol sprintf("%s:%d: RULE7 %d kubectl call(s) but %d --context\n", FNAME, NR, n, c)
    }
  ' "$1"
}

# ---------------------------------------------------------------- selftest
#
# A gate that cannot be shown to go red is a gate nobody should trust. Each
# fixture trips exactly one rule.
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  printf '**WORKSTATION**\n\n```bash\nkubectl get nodes\n```\n' > "$tmp/clean.md"
  printf '**WORKSTATION**\n\n```bash\n# WORKSTATION\nkubectl get nodes\n```\n' > "$tmp/r1-lead.md"
  printf '**WORKSTATION**\n\n```bash\nkubectl get nodes   # wait\n```\n' > "$tmp/r1-trail.md"
  # r2: a TWO-HOST page (it declares the section) whose fence has no marker.
  printf '## Where each command runs\n\nNo marker here.\n\n```bash\nkubectl get nodes\n```\n' > "$tmp/r2.md"
  # r2-single: the SAME unmarked fence on a page that is not two-host. Must be
  # clean, and this fixture is why RULE2 is scoped rather than universal.
  printf 'A reference page.\n\n```bash\njq . charts/x/values.schema.json\n```\n' > "$tmp/r2-single.md"
  printf '**WORKSTATION**\n\n```bash\ngit clone YOUR_SITE_REPO_URL\n```\n' > "$tmp/r3.md"
  printf '**WORKSTATION**\n\n```bash\nexport SITE_REPO_URL=YOUR_SITE_REPO_URL\n```\n' > "$tmp/r3-setup.md"
  # A transcript fence must be ignored entirely, including its # lines.
  printf '**WORKSTATION**\n\n```\n# this is quoted output\n```\n' > "$tmp/transcript.md"
  # RULE 4: a bare ALL_CAPS token used as a VALUE, in the two checked positions.
  printf '**WORKSTATION**\n\n```bash\ncurl "https://GIT_HOST/x"\n```\n' > "$tmp/r4-url.md"
  printf '**WORKSTATION**\n\n```bash\nkubectl create secret generic s --from-literal=K=VALUE_FROM_ABOVE\n```\n' > "$tmp/r4-value.md"
  # RULE 4 must NOT fire on a Secret KEY NAME, which is the same shape one
  # character earlier. Eleven of these exist in the tree and all are correct.
  printf '**WORKSTATION**\n\n```bash\nkubectl create secret generic s --from-literal=AUTHENTIK_SECRET_KEY="$AK"\n```\n' > "$tmp/r4-keyname.md"
  # Nor on a plain variable reference.
  printf '**WORKSTATION**\n\n```bash\ncurl "https://$GIT_HOST/x"\n```\n' > "$tmp/r4-varref.md"
  # RULE 5: the exact line that made an empty Secret on 2026-09-12, and the
  # combined-flag spelling of the same mistake.
  printf '**WORKSTATION**\n\n```bash\nread -rs -p "read-only token: " TOK && echo\n```\n' > "$tmp/r5-split.md"
  printf '**WORKSTATION**\n\n```bash\nread -rsp "token: " TOK\n```\n' > "$tmp/r5-joined.md"
  # RULE 5 must NOT fire on the portable form, on a while-read loop, or on a
  # variable that happens to be named p.
  printf '**WORKSTATION**\n\n```bash\nprintf "token: "; read -rs TOK; echo\n```\n' > "$tmp/r5-portable.md"
  printf '**WORKSTATION**\n\n```bash\ngit ls-files | while IFS= read -r f; do echo "$f"; done\n```\n' > "$tmp/r5-loop.md"
  printf '**WORKSTATION**\n\n```bash\nread -r p\n```\n' > "$tmp/r5-varnamed-p.md"
  # RULE 6: the customising.md shape measured 2026-09-14 (0 and 0 under zsh).
  printf '**WORKSTATION**\n\n```bash\nBASE="--set a=1 --set b=2"\nhelm template t charts/x $BASE | grep -c kind:\n```\n' > "$tmp/r6-unquoted.md"
  # RULE 6 must NOT fire on a quoted expansion, a single-word value, an array
  # expanded as "${A[@]}", or the assignment line itself.
  printf '**WORKSTATION**\n\n```bash\nMSG="two words"\necho "$MSG"\n```\n' > "$tmp/r6-quoted.md"
  printf '**WORKSTATION**\n\n```bash\nREV="v0.6.0"\ngit checkout $REV\n```\n' > "$tmp/r6-single.md"
  printf '**WORKSTATION**\n\n```bash\nBASE=(--set a=1 --set b=2)\nhelm template t charts/x "${BASE[@]}"\n```\n' > "$tmp/r6-array.md"
  # SCOPE, not a rule. A fence indented inside a list item is a real documented
  # command and this check could not see one until 2026-09-13: two NODE commands
  # in fresh-install.md were exempt from every rule above purely because of the
  # leading spaces. These two fixtures are the guard ... indent-violation must
  # count exactly as its flush-left twin r1-lead does, and indent-transcript
  # proves normalising indentation did not also start scanning quoted output.
  printf '**WORKSTATION**\n\n1. A step:\n\n   ```bash\n   # NODE\n   sudo snapper list\n   ```\n' > "$tmp/indent-violation.md"
  printf '**WORKSTATION**\n\n1. A step:\n\n   ```\n   # quoted output\n   ```\n' > "$tmp/indent-transcript.md"

  # RULE 7. Each fixture names its cluster in a first block (R7_NAME), then
  # tests one shape. r7-before-naming proves the scope: a kubectl block BEFORE
  # the page names its cluster is not this rule's business.
  local R7_NAME R7_GUARD
  R7_NAME='**WORKSTATION**\n\n```bash\nexport KUBE_CONTEXT=YOUR_KUBE_CONTEXT\n```\n\n**WORKSTATION**\n\n```bash\n'
  R7_GUARD=': "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"\n'
  printf "${R7_NAME}"'kubectl --context="$KUBE_CONTEXT" get nodes\n```\n' > "$tmp/r7-no-guard.md"
  printf "${R7_NAME}${R7_GUARD}"'kubectl get nodes\n```\n' > "$tmp/r7-no-context.md"
  printf "${R7_NAME}${R7_GUARD}"'kubectl --context="$KUBE_CONTEXT" get pv -o name | xargs -r kubectl delete\n```\n' > "$tmp/r7-xargs.md"
  printf "${R7_NAME}${R7_GUARD}"'for k in $(kubectl api-resources -o name); do\n  kubectl --context="$KUBE_CONTEXT" get "$k"\ndone\n```\n' > "$tmp/r7-subshell.md"
  printf "${R7_NAME}${R7_GUARD}"'kubectl --context="$KUBE_CONTEXT" -n a \\\n  get pods\nkubectl config get-contexts\nsudo /usr/local/bin/k3s kubectl get nodes\n```\n' > "$tmp/r7-clean.md"
  printf '**WORKSTATION**\n\n```bash\nkubectl get nodes\n```\n\n**WORKSTATION**\n\n```bash\nexport KUBE_CONTEXT=YOUR_KUBE_CONTEXT\n```\n' > "$tmp/r7-before-naming.md"

  local f expect got
  for f in clean:0 r1-lead:1 r1-trail:1 r2:1 r2-single:0 r3:1 r3-setup:0 \
           transcript:0 r4-url:1 r4-value:1 r4-keyname:0 r4-varref:0 \
           r5-split:1 r5-joined:1 r5-portable:0 r5-loop:0 r5-varnamed-p:0 \
           r6-unquoted:1 r6-quoted:0 r6-single:0 r6-array:0 \
           indent-violation:1 indent-transcript:0 \
           r7-no-guard:1 r7-no-context:1 r7-xargs:1 r7-subshell:1 \
           r7-clean:0 r7-before-naming:0; do
    name="${f%%:*}"; expect="${f##*:}"
    got="$(check_file "$tmp/$name.md" | wc -l | tr -d ' ')"
    if [[ "$got" == "$expect" ]]; then
      pass "selftest $name: $got violation(s), expected $expect"
    else
      fail "selftest $name: $got violation(s), expected $expect"
      check_file "$tmp/$name.md" >&2
      status=1
    fi
  done
  return $status
}

# ---------------------------------------------------------------- main
main() {
  if [[ $# -gt 0 ]] && [[ "$1" == "--selftest" ]]; then
    printf '%s== selftest%s\n' "$B" "$X"
    selftest || exit 1
    printf '\n%s  all rules trip as designed%s\n' "$G" "$X"
    exit 0
  fi

  if [[ $# -gt 0 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
  fi

  local files out
  if [[ $# -gt 0 ]]; then
    # ONE PATH PER LINE. `files="$*"` joined argv with a space while IFS was
    # still default, and the loop below then split on newline -- so two
    # arguments arrived as one impossible path and the script reported
    # "examined no files". Found independently by two reviewers on 2026-09-11,
    # both of whom worked around it by invoking the script once per file. The
    # refuse-on-zero-files guard below is what turned it into a visible failure
    # rather than a green run over nothing.
    files="$(printf '%s\n' "$@")"
  else
    cd "$REPO_ROOT"
    files="$(find docs -name '*.md' | sort)"
  fi

  # bash 3.2: iterate the newline-separated list rather than an array.
  local IFS=$'\n'
  for f in $files; do
    [[ -f "$f" ]] || { fail "no such file: $f"; continue; }
    CHECKED=$((CHECKED + 1))
    out="$(check_file "$f")"
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" >&2
      FAILED=$((FAILED + 1))
    fi
  done
  unset IFS

  # A check that examines nothing must not exit 0. bash 3.2 exits 0 examining
  # NOTHING often enough that this repository has been bitten by it.
  if [[ "$CHECKED" -eq 0 ]]; then
    printf '%s  examined no files -- refusing to report success%s\n' "$R" "$X" >&2
    exit 1
  fi

  printf '\n%s== pasteable blocks: %d file(s) examined%s\n' "$B" "$CHECKED" "$X"
  if [[ "$FAILED" -gt 0 ]]; then
    printf '%s  %d file(s) carry a violation%s\n' "$R" "$FAILED" "$X" >&2
    printf '%s  see tools/check-pasteable-blocks.sh for what each rule means%s\n' "$Y" "$X" >&2
    exit 1
  fi
  printf '%s  every bash block is pasteable and labelled%s\n' "$G" "$X"
}

main "$@"

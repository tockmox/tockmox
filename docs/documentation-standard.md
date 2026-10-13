---
okf_version: "0.2"
type: Reference
title: "Documentation standard"
description: "How Tockmox pages are structured: what belongs on a task page, what moves to a component page, and the rules a procedure has to satisfy before it ships."
tags: [documentation, standard, style, procedures, diataxis, plain-language]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [contributor, machine]
---

# Documentation standard

**A page that is accurate and unusable has failed.** Every rule below exists
because a reader could not act on something that was, word for word, correct.

This standard governs `docs/`. It sits alongside two existing mechanical rules
that it does not replace: the [frontmatter contract](frontmatter-contract.md)
and the no-meaning-carrying-emoji rule in
[CONTRIBUTING](../CONTRIBUTING.md#documentation-style).

## Who the reader is

**A competent stranger, in a hurry, arriving in the middle.** They run
Kubernetes. They did not read the previous page. They cannot ask a follow-up
question. They have no local knowledge and no answer key.

That reader is not a simplifying assumption, it is the actual measurement: an
external installer working from the published docs alone. Writing for someone
who already knows how this works produces pages that only work for people who
already know how this works.

## The four jobs, and the one that goes wrong

Documentation does four jobs, and they do not substitute for each other
(Diátaxis):

| Job | Answers | Reader's state |
|---|---|---|
| **Tutorial** | "Take me through it once" | Learning, no goal of their own yet |
| **How-to** | "I need to do X" | Has a goal, wants the shortest correct route |
| **Reference** | "What are the exact values" | Knows what they want, needs precision |
| **Explanation** | "Why is it like this" | Not doing anything right now |

**The failure that produces a wall of text is explanation colonising a how-to.**
Rationale, trade-offs, history and hard-won gotchas accumulate inside a
procedure until the steps are no longer visible. Every sentence is worth
keeping. None of them belong between step 3 and step 4.

**The fix is relocation, never deletion.** Rationale earns a home on a component
or reference page, and the task page links to it. A page thinned by cutting its
knowledge has traded one failure for a worse one.

## Task pages and component pages

**Task page** ... one task, start to finish, minimum sufficient prose. If a
reader has a goal and needs the shortest correct route, this is where they are.

**Component page** ... everything true about a component: why it is configured
this way, what the alternatives cost, the traps, the history, the dated
verifications. This is where rationale goes when it is evicted from a procedure.

The split test: **can the reader finish the task without reading this
paragraph?** If yes, it belongs on the component page. If they cannot finish
*correctly* without it, it stays ... compressed to the decision, with the
reasoning linked.

A task page may exceed its natural length only when the extra material is
required to complete the task. Length is a symptom, not the disease, but it is
the symptom that shows up first: at time of writing `deployment/prerequisites.md`
is 432 lines, the longest page in the set, and it shipped two defects that
survived because nobody could see them in the prose.

## Required rules for any page containing a procedure

### 1. Before you begin

Every procedure opens with what the reader needs **in hand**, not scattered
through the steps. Prerequisites discovered halfway are a defect in the
procedure (ISO/IEC/IEEE 82079-1, completeness for task).

State: what must already exist, what they need access to, what they need
installed locally, and roughly how long it takes.

### 2. Required and optional are marked, never inferred

A reader who cannot tell which steps apply to them will do all of them or stop.
Mark every step or section:

- **Required** ... the default; state it when a section is mixed
- **Optional** ... say what the reader gets by doing it, and what they lose by not
- **Conditional** ... state the condition first, as a test they can run:
  "**If** `kubectl get sc` shows more than one default, do this"

Never rely on a reader inferring optionality from tone or placement.

### 3. Choices are decision points, not paragraphs

Where the docs offer alternatives, the reader must be able to pick without
reading both branches in full. Give a decision table or a diagram, then the
chosen branch.

Both branches are **paths** and both get tested. The route people happen to use
gets exercised by use; the one beside it rots silently, and it is the one a
stranger picks. See the [testing standard](testing-standard.md).

### 4. Every step states how the reader knows it worked

A step with no success condition cannot be followed with confidence, and cannot
be tested (82079-1, verifiability). Give the command **and** the expected
output, or the observable state. Label it with one of exactly two phrasings,
**"Success condition"** or **"Passes when"**, because the executed-docs harness
counts those two forms and no others when it records whether a page states any;
a third synonym reads to the harness as an absence.

Where the success condition is subtle, say what the failure looks like too ...
especially when a failure reads as something else. "This error names Authentik
and the cause is ServiceLB" is worth more than three paragraphs of theory.

### 5. Commands are copy-pasteable and complete

Real values, not placeholders, wherever a real value exists. Where a placeholder
is unavoidable, make it obviously not-a-value (`YOUR_SITE_REPO_URL`) and say
where the real one comes from. Never a command that must be edited in a way the
text does not describe.

**A value the reader chooses once is a variable, not a placeholder.** The path
to the reader's site repository clone is the most substituted value on the
site, and it used to be spelled three ways across pages, so a reader who
substituted one form silently missed the others. It is now the shell variable
`SITE_REPO`: the page's "Before you begin" exports it once
(`export SITE_REPO=YOUR_SITE_REPO_PATH`), and every bash block that reads it
carries `: "${SITE_REPO:?...}"` so a block pasted into a fresh shell stops with a
message rather than running `cd` against the home directory. The site
repository path is never an angle-bracket placeholder, in any spelling, and
every bash block that reads `$SITE_REPO` carries the guard; both are asserted
in `tools/doc-claims.txt`.

**Three classes of input, and confusing them is what turns a procedure into a
questionnaire.** Every value a page asks for is exactly one of these:

| Class | Example | Who answers |
|---|---|---|
| **Infrastructure choice** | which CNI, which ingress, which CSI | **Tockmox answers.** A profile. Never a prompt and never a placeholder |
| **Site fact** | internal domain, LAN CIDR, address-pool range, the site repository URL | **Only the operator knows.** Asking is correct; asking twice is not. Export it once, guard every read |
| **Derivable fact** | chart version, node IP, kube context, pod and service CIDRs | **Tockmox measures it and shows the answer for confirmation.** Never a blank prompt, and never a placeholder the reader hand-copies |

**A derived value is derived by command, and then shown to the reader to
confirm.** This paragraph used to say the opposite ... that a value read out of
the previous step, such as a chart version, should stay an angle-bracket
placeholder precisely so the reader could see it had to be read rather than
decided. That was wrong in a way worth recording, because it argued for the
defect from the property that motivated it. Making the reader act as a clipboard
between two blocks is a step that can fail, and it fails silently: the wrong
chart version installs cleanly and is discovered much later. The visibility that
paragraph wanted is real, and a confirmation line delivers it without the
copying:

```bash
export ARGOCD_CHART_VERSION="$(helm search repo argo/argo-cd --versions \
  | awk 'NR==2 {print $2}')"
helm search repo argo/argo-cd --version "$ARGOCD_CHART_VERSION"
```

The second line reprints exactly what the first chose, so the reader confirms a
value rather than transcribing one. `fresh-install.md` sections 6 and 7 are the
worked examples. Ruled 2026-09-11 (TM-0484).

**Derive with a command you can reason about.** The first version of the block
above used `sed -n 's/.*"version":"\([^"]*\)".*/\1/p'` over `helm ... -o json`
and returned the **oldest** chart version, because `.*` is greedy and matched
the last occurrence. It was caught before it shipped by running it against
sample input rather than by reading it. A derivation is a command like any
other: it gets tested, not reviewed.

**Pasteable means pasteable into zsh.** macOS ships zsh as the login shell,
and a block that is correct bash and wrong zsh is wrong on the platform the
docs name as a supported workstation. Two forms are known to fail there and
are refused by `tools/check-pasteable-blocks.sh`: `#` inside a fence (not a
comment character in an interactive zsh), and `read -p` (no prompt flag on
zsh's `read`, where `-p` means a coprocess). The second is the worse one,
because it fails silently: the block looks like it prompted, the variable is
empty, and the Secret it feeds is created and labelled and useless. A prompted
secret is `printf 'x: '; read -rs VAR; echo`, followed by a printed byte count
so an empty paste is visible at the prompt rather than three phases later.
Ruled 2026-09-13 (TM-0537).

### 6. Dated claims carry their date and their scope

"Verified on k3s 2026-08-15" is a good habit that becomes a trap when the claim
outlives the check. Any claim about runtime behaviour states what was tested,
when, and on what version. If a claim cannot be tested, it is written as a
belief, not a fact.

The stronger form is to make the claim executable and let CI carry it. Prose
that asserts runtime behaviour is the most expensive kind to maintain.

## Use non-text where it carries structure better

Prose doing a diagram's job is the most common wall of text. Reach for:

- **A table** for a decision with more than two outcomes, for a comparison
  across more than two dimensions, or for any "which of these applies to me"
- **A Mermaid diagram** for a sequence with a branch, for an architecture whose
  shape matters, for an ordering constraint that prose states as "before" and
  "after" three times
- **A callout** for a single trap, once, at the point of use ... not a wall of
  warnings at the top that the reader scrolls past

Accessibility is not optional here (WCAG 2.2 AA):

- Every diagram has a **text equivalent** that conveys the same information ...
  not a caption naming it
- **A symbol's accessible name must state its meaning.** A screen reader
  announces "white heavy check mark" where you meant "supported". This is why
  the emoji rule exists, and it applies to any glyph carrying meaning
- Do not encode meaning in colour alone
- Tables are for data, not layout, and get real headers

## Language

Four outcome tests (ISO 24495-1): the reader gets **what they need**, can
**find** it, can **understand** it, and can **use** it. All four are properties
of what the reader ends up doing, which is what makes them checkable rather than
arguable.

In practice:

- **Name the task in the heading, not the component.** "Install ArgoCD" beats
  "ArgoCD". A reader scanning for their task cannot find a noun.
- Second person, imperative, present tense. "Run", not "you should run" or "one
  might run".
- One action per numbered step.
- Front-load the sentence: the action first, the qualification after.
- Define an unavoidable term once, at first use, or link it. Do not define
  Kubernetes.

**Plain language is not simplification of the subject.** This product is
deployed by people who run clusters. The difficulty belongs in the domain, not
in the sentence.

## `status: stable` describes the document, never the procedure

Frontmatter `status:` is a **document lifecycle** state. `stable` means the page
is finished, reviewed and expected not to churn. **It says nothing whatever
about whether anyone has executed what the page describes.**

Those are two independent axes, and this project spends most of its time in the
square where they disagree: a page can be complete, accurate and carefully
reviewed while documenting a procedure no one has run end to end. That is not a
failure state here, it is the normal one before an executed-docs path exists for
it.

**Where the other axis lives:** `tests/executed-docs/INVENTORY.md`. That file,
and only that file, says which documented paths have been executed and which
remain open. A page marked `stable` and listed OPEN in the inventory is exactly
consistent, and both statements are true.

This is written down because an outside reader on 2026-09-03 read `stable`
across all migrated pages as an assurance of verification, which is a reasonable
reading of the word and not what it means. Until the frontmatter carries an
evidence field of its own, the inventory is the answer and this paragraph is the
signpost to it.

## What this standard does not cover

- **Where a page lives in navigation, and nav depth** ... that is information
  architecture, and it is owned separately.
- **Whether a documented procedure is correct** ... reading a page cannot
  establish that. See the [testing standard](testing-standard.md); a page is
  not certified by review, and `status: stable` is not a certification either
  (see the section above).
- **The mechanical rules already enforced** ... frontmatter and emoji, which have
  their own gates and are not restated here.

## Applying this to an existing page

In order, because the order matters:

1. **Identify the jobs the page is currently doing.** Most long pages are doing
   three.
2. **Move the explanation out**, to a component page, linked. Do not cut it.
3. **Extract the "before you begin"** from wherever it is currently scattered.
4. **Mark required, optional and conditional** on what remains.
5. **Give every step a success condition.** This is where you discover which
   steps nobody has run.
6. **Replace prose that is doing a table's or a diagram's job.**
7. **Hand the page to the testing harness.** If a procedure cannot be executed
   as written, the page is not finished ... which is usually where the real
   defects surface.

Step 5 and step 7 are the ones that find bugs. The rest make the page readable.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

---
okf_version: "0.2"
type: Reference
title: "Why Tockmox?"
description: "The argument for owning the platform your AI runs on, made to a skeptic."
tags: [rationale, positioning, control, sovereignty, argument]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Why Tockmox?

*The argument, made to a skeptic. If it survives you, it will survive the
market.*

## The case, in six parts

1. Useful models now fit on hardware you can own.
2. The value is in the system around the model, not the weights.
3. Some things you should not have to hand over.
4. You are renting at a price you do not set.
5. Access is a dependency you do not control.
6. You would rather work on the AI part.

*These are positions, not neutral observations. Each is stated narrowly enough
to be argued with, and cited where a citation exists. The detail follows.*

**1. Useful models now fit on hardware you can own.** A class of efficient
mixture-of-experts models delivers frontier-adjacent results inside 128-256 GB
of unified memory, where the largest open models need three to five times that.
The frontier keeps moving and open models trail it by months rather than
generations ... but the question that decides whether you can run your own has
already flipped from "no" to "which box".

**2. The value is in the system around the model, not the weights.** This is
the bet the whole project rests on: as models converge toward a commodity, the
durable advantage is the architecture, the data, and the operational discipline
wrapped around them. If that is wrong, Tockmox is a well-engineered answer to a
question nobody asked.

**3. Some things you should not have to hand over.** The most useful thing to
ask an AI is usually the thing you would least like copied: your diagnosis,
your finances, your legal exposure, the draft you have not shown anyone.
Sending it to an API means a copy exists somewhere you do not control ...
retained for a window you did not set, reachable by staff reviewing for abuse,
subject to that provider's jurisdiction, and discoverable from them in
proceedings you may never be party to.

The exposure runs deeper on a consumer plan. Business and enterprise agreements
generally prohibit training on customer content, which is why "they train on
your data" is a weak argument aimed at an enterprise buyer. It is not a weak
argument for everyone else: consumer tiers are governed by different terms,
defaults are set by the provider rather than negotiated by you, and those
defaults have changed more than once without anyone's permission being
re-asked. The person with the most at stake in a conversation is usually the
one on the plan with the least say in what happens to it.

Every copy is a surface, and the only copy nobody can compel, breach, or retain
past its welcome is the one that never left. Organisations reach the same
conclusion by a longer route ... controller obligations, sector rules, audit
... but the individual case arrives there first and more plainly.

**4. You are renting at a price you do not set.** Per-token billing is a
variable cost on someone else's price list, revised on their schedule. Hardware
you own is a capital cost on yours.

This is not all-or-nothing. Most of what people actually use AI for ...
retrieval over their own documents, summarising, drafting, structured
extraction, classification ... is well within reach of models you can run
yourself. The frontier earns its price on the genuinely hard reasoning, and
that is a smaller share of the work than the bill suggests. Run what fits at
home, escalate deliberately when the problem warrants it, and pay per token
only for the part that needed it. That is a routing decision, and a gateway is
where routing lives.

And the model is only part of what you are running. The harness around it is
the part that accumulates: your document store, your vector index, your agent
state, the tool integrations, the conversation history, the record of what was
asked and answered. That is where your context actually lives, and it is worth
keeping regardless of where the tokens are generated. Someone who uses frontier
models exclusively still has every reason to own the rest of the stack ... the
model is the part you can swap, and everything around it is the part you would
hate to lose.

**5. Access is a dependency you do not control.** Your model can be retired,
your product can be discontinued, your terms can change ... and access can be
withdrawn by someone who is not your vendor at all.

On 12 June 2026 the US Commerce Department directed Anthropic to suspend access
to Claude Fable 5 and Mythos 5 for foreign nationals ... inside or outside the
United States, and including its own employees. Rather than segment access by
nationality, Anthropic disabled both models for every customer. Commerce lifted
the controls at the end of that month. It was the first known use of US
export-control authority against a specific frontier model, and most of the
people who lost access were not who the directive was about.

That is the shape of the risk, and it is not rare. In 2023 Italy's
data-protection authority ordered a halt to OpenAI's processing of Italian
users' data, and OpenAI withdrew ChatGPT from Italy for four weeks. After the
Irish Data Protection Commission raised concerns, Meta paused training its
models on EU user data in June 2024, and Meta AI did not reach EU users until
March 2025. Apple has said Siri AI will not ship in the EU on iOS 27, iPadOS 27
or watchOS 27, citing the Digital Markets Act, with no timeline offered. On the
vendor side, OpenAI is shutting down Agent Builder on 30 November 2026, and
Anthropic's published floor for retiring a public model is at least 60 days ...
a floor it has used, retiring models on 60, 61 and 62 days' notice this year,
though other retirements ran far longer: Claude Opus 3 was given 189.

None of this is bad faith. All of it is someone else's decision becoming your
outage. A model running on your own hardware is subject to none of it.

**6. You would rather work on the AI part.** 82% of container users surveyed by
the CNCF run Kubernetes in production, and 97% of respondents to its Argo CD
survey run Argo CD in production ... the parts
are proven, and plenty of people reading this could wire them together. The
question is whether you want to. Storage replication, single sign-on,
certificate rotation, backups that prove they restore, alerts that fire when
something goes quiet ... none of that is the reason you got interested in this,
and all of it is between you and the reason you did.

Tockmox is the rest of the stack, so the part you care about is the part you
spend your time on. For anyone who genuinely cannot build this alone, that is
the difference between having it and not. For everyone else it is the
difference between building it and having built it.

Together they describe a real, unmet need.

## So we built it

Tockmox is that build, open. Your own AI, on hardware you own, that keeps
working when the internet, your vendor, or the regulator does not. It is
extracted from a live reference deployment that runs under production
discipline, and that deployment now runs the released chart rather than its own
tree: the maintainer's homelab has been on a Tockmox tag since 2026-10-02. The
**entire infrastructure layer is free**: the charts, the
installer, the runbooks, the bill of materials. Anyone can stand up a
right-sized version for the cost of the hardware, owing nobody anything.

What is not free, plainly: if you want someone else to run it for you ...
managed operation and support ... that is a service. The build itself is
yours to keep, replicate, fork, and extend. The give-away is the point, not
the bait.

## The honesty rule

Every capability claim in this repository is either backed by something you
can run, or labelled not-yet-built on the page that describes it. The
[capabilities summary](../README.md#what-you-get) is the headline;
[what-you-get](usage/what-you-get.md) is the inventory; and where the
reference deployment runs something this release does not yet ship, the gap
is stated rather than blurred. A claim you can check is worth more than a
claim you have to trust.

The same rule applies to the claims this page makes about the world, which is
what the sources below are for. Every one links to the vendor, regulator or
survey that published it, so the argument can be checked rather than believed.

<a id="sources"></a>

## Sources

Verified 2026-08-31. Where a figure describes a narrower population than a
casual reading would suggest, the population is named rather than rounded off.

**Export controls, June 2026.** Anthropic's
[statement on Fable 5 and Mythos 5 access](https://www.anthropic.com/news/fable-mythos-access);
Greenberg Traurig,
[AI Company Anthropic Suspends Access to Claude Fable 5, Claude Mythos 5 Following US Export Control Directive](https://www.gtlaw.com/en/insights/2026/6/ai-company-anthropic-suspends-access-to-claude-fable-5-claude-mythos-5-following-us-export-control-directive)
(17 June 2026), which records the Commerce Department directive and that
Anthropic disabled the models for all customers rather than segmenting by
nationality. The controls were lifted at the end of June.

**Italy and ChatGPT, 2023.** The Garante's
[order of 30 March 2023](https://www.garanteprivacy.it/home/docweb/-/docweb-display/docweb/9870847)
imposed a temporary limitation on processing Italian users' data; OpenAI
withdrew the service in response. Access was
[reinstated on 28 April 2023](https://www.garanteprivacy.it/home/docweb/-/docweb-display/docweb/9881490).

**Meta AI in Europe.** The Irish Data Protection Commission's
[statement on Meta AI](https://www.dataprotection.ie/en/news-media/latest-news/dpc-statement-meta-ai)
records Meta pausing model training on EU user data in June 2024 after the DPC
raised concerns; Meta AI
[reached 41 European countries on 19 March 2025](https://about.fb.com/news/2025/03/europe-meet-your-newest-assistant-meta-ai/).

**Siri AI in the EU.** Apple,
[Due to DMA, Siri AI delayed in EU for iOS 27 and iPadOS 27](https://www.apple.com/newsroom/2026/06/due-to-dma-siri-ai-delayed-in-eu-for-ios-27-and-ipados-27/)
(8 June 2026). EU users do get Siri AI on macOS 27 and visionOS 27; Apple
states no timeline for iOS and iPadOS.

**OpenAI Agent Builder.** OpenAI's
[deprecations page](https://developers.openai.com/api/docs/deprecations):
deprecation announced 3 June 2026, shutdown scheduled 30 November 2026.

**Anthropic model retirement notice.** Anthropic's
[model deprecations page](https://platform.claude.com/docs/en/about-claude/model-deprecations)
publishes "at least 60 days' notice before model retirement for publicly
released models". The 60, 61 and 62-day figures are Claude Haiku 3, Opus 4.1,
and Sonnet 4 / Opus 4; the same page records Claude Opus 3 retiring 189 days
after its announcement.

**Kubernetes and Argo CD in production.** CNCF's
[2025 Annual Cloud Native Survey](https://www.cncf.io/announcements/2026/01/20/kubernetes-established-as-the-de-facto-operating-system-for-ai-as-production-use-hits-82-in-2025-cncf-annual-cloud-native-survey/)
reports 82% of *container users* running Kubernetes in production. The 97%
figure is from CNCF's
[2025 Argo CD End User Survey](https://www.cncf.io/announcements/2025/07/24/cncf-end-user-survey-finds-argo-cd-as-majority-adopted-gitops-solution-for-kubernetes/)
and describes *survey respondents* running Argo CD in production, not a
population estimate over all adopters.

## Right-sized: down small, up and out

The pattern scales in both directions: strip it to one mini-PC and one
Apple-silicon box and a small office gets sovereign AI on a shelf; grow it
to an HA cluster, a second inference node, and multiple sites without
changing the model. One pattern, one set of open runbooks, sized from a
closet to a campus.

That is a claim about the **architecture**, and it should not be read as a
claim about the support model. The pattern scales; a project with one
maintainer and one reference deployment does not yet, and pretending otherwise
would be the kind of thing this page exists to avoid.

## Who this is for

The spine is constant ... **sovereignty, confidentiality, continuity, and cost
you control** ... and the rule of thumb is simple: the more valuable or
regulated the data, the stronger the case.

### Individuals and households

People who want the real thing rather than a toy: a homelab that runs to
production discipline, a private assistant over your own documents, a household
that would rather own its stack than rent it. It is Kubernetes underneath, but
**ownership, not Kubernetes, is the benefit.**

This is the segment the project was built from. Being straight about the
evidence for that: the documentation is tested against one reference
deployment, operated by its author. External validation has not happened yet.
Until it does, treat "built for households" as an intent this project is held
to rather than a result it has demonstrated.

Best suited today to experienced self-hosters, or to a household with a
technical operator. It is not a one-click desktop application, and the
[installation path](deployment/install.md) does not pretend to be one.

### Small businesses and practices

Healthcare practices keeping PHI in the building. Law firms preserving
privilege. Financial and accounting firms with residency and audit rules. Where
the constraint is regulatory, keeping inference inside your own boundary
removes a question rather than managing it.

Removing a question is not the same as answering one, and this is the boundary
worth stating plainly rather than leaving to be inferred. Running a model on
your own hardware does not by itself make a deployment HIPAA-compliant, does
not establish or preserve attorney-client privilege, and does not satisfy an
audit regime. Those outcomes come from your policies, your agreements, your
controls and your evidence. What this platform gives you is a smaller surface
to make those arguments about, and the audit trail, access control and
retention behaviour to make them with. Read that as a better starting position,
never as a compliance claim ... and if a vendor tells you otherwise about their
product, that is worth noticing.

---

## A note from Jeff Maaks, maintainer

Tockmox was my main in World of Warcraft for years, a gnome mage who also
happened to be an engineer. When I finally stopped playing I couldn't quite let
him go, so he got a second life. That gnome face in the gear on the Tockmox
mark represents him.

Naming it after him wasn't a branding exercise. I'd been building this on
nights and weekends for longer than I care to add up, partly because it's
genuinely useful and mostly because I love this stuff and wanted to see if I
could pull it off. I won't pretend that seeing his name come up on the login
screen, after all those years, didn't do something to me. So yeah. It's a pile
of humming computers in my office, and I'm oddly proud of it.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

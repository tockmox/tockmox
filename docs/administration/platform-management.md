---
okf_version: "0.2"
type: HowTo
title: "Platform Management"
description: "Turn on the Tockmox UI's read-only operations view: the platform's operations roles, the scheduled work each one owns, the numbers each one watches, what the page may read, and how a site replaces the catalog."
tags: [tockmox-ui, platform-management, operations, itil, scheduled-work, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-23
tockmox:
  classification: public
  audience: [operator]
---

# Platform Management

Platform Management is a read-only page in the [Tockmox UI](tockmox-ui.md)
that shows the platform's operations as a small team of roles named after the
ITIL 4 practices they cover: a Platform Manager who leads, and an Incident
Manager, a Capacity Manager, a Continuity Manager and so on below. For each
role the page shows two separate facts: how its **practice** is doing (the
scheduled work it owns and the numbers it watches, live today) and how its
**agent** is doing (from an agent ledger, if you run one). A role with no agent
yet reads **Not started**; it never makes a practice look healthy or broken.

> **Experimental, and off by default.** It needs the Tockmox UI turned on
> (`tockmoxUi.enabled`) and then its own switch. The values keys may change
> before they are marked stable.

The page runs nothing and changes nothing. It has no write routes and renders
no model output. A role's catalog entry says what it may read, what it may
propose and what it must never do; that entry is data the page displays, not
an instruction anything follows.

## Turn it on

In the AI layer's values:

```yaml
tockmoxUi:
  enabled: true
  config:
    features:
      platform:
        enabled: true
        timezone: America/Chicago      # the zone the page shows times and evaluates planned work in; default UTC
```

Only administrators (`roles.adminGroup`) see it. With the switch off there is
no route and no menu entry: `/platform` answers 404.

Optional keys under `config.features.platform`:

| Key | What it does |
|---|---|
| `ledgerUrl` | Your agent orchestrator's read API (`GET <ledgerUrl>/v1/jobs`). Unset, every role's agent reads **Not connected**, which is Unknown and never healthy. Must be an absolute `http(s)` URL; with a token, prefer `https`, because over `http` the token crosses the network in clear. |
| `interfaceUrl` | Where a person answers an agent's question. The page links there; approving never happens on this page. |
| `clusterTimezone` | The zone your cluster's controller manager runs in, default UTC. A CronJob that sets no `timeZone` fires in that zone, and kube-state-metrics reports it only as `local`, so the page needs telling. |
| `specialistsUrl` | A specialist host (its base URL). Turns on the **Cases** pages and the specialists' served state: see "Cases" below. Unset, every Cases view reads **Not connected**, never an empty list. Must be an absolute `http(s)` URL. |
| `workflowSuccessQuery` | A PromQL query returning each Argo CronWorkflow's last success time, labelled `namespace` and `cronworkflow`. Unset, a CronWorkflow's last run shows but not whether it passed, and it reads Unknown. |

The ledger is yours, so the chart does not know its address or its token:

```yaml
tockmoxUi:
  secrets:
    platformLedgerToken: my-ledger-token   # a Secret you create, key: token
  networkPolicy:
    extraEgress:
      - to:
          - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: my-orchestrator}}
        ports: [{port: 8080, protocol: TCP}]
```

## What it reads, and what that adds

| Read | From | What turning it on adds | Control |
|---|---|---|---|
| Argo CronWorkflows | the Kubernetes API, `list` on `cronworkflows`, every namespace | **One new permission.** The UI's ServiceAccount can read every CronWorkflow's spec, including inline scripts and parameters. | The rule is rendered only when the switch is on. `list` only: no `get` on Secrets, no `watch`, no writes. The page shows names, schedules, suspend state and last run, never a spec body. Admins only. |
| CronJobs and their Jobs | kube-state-metrics, through Prometheus | Nothing: the UI already reads Prometheus. | |
| Each role's numbers | PromQL instant queries named in the catalog | A site catalog can query any series Prometheus holds and show the value to admins. | The catalog is a ConfigMap your site commits, so a new query is a reviewed change. Instant, read-only queries. |
| Cases | the specialist host: `POST /s/service-desk/v1/list` and `/get` as the caller `client/tockmox-ui`, and `GET /v1/index` | Record metadata (ids, titles, states, who worked them, links) and timeline steps leave the host for the UI. | The token is a Secret you name (`secrets.platformSpecialistsToken`), mounted read-only only when the switch is on; the desk admits that caller to `list`, `get` and `timeline` only. Egress is yours to add. Words a model wrote never render. |
| Agent runs | the ledger, `GET /v1/jobs` with a bearer token | Job metadata (role, status, cost, times) leaves the orchestrator for the UI. | The token is a Secret you name, mounted read-only only when the switch is on. The UI can reach the ledger only through egress you add. The page shows job fields, never an answer's text. |

If the catalog does not load (a site catalog with any mistake in it, or a
missing ConfigMap), or `timezone` names no known zone, the rest of the UI keeps
working and `/platform` answers 503 with the reason, for administrators.
Nothing on it reads healthy.

## How the page decides

- **Absence is not green.** A schedule that never ran, a number Prometheus did
  not return, an agent with no ledger: each reads **Unknown** with the reason,
  never OK.
- **Late, then missed.** A scheduled job is **Late** inside a grace period after
  its expected run (a tenth of its interval, at least 10 minutes and at most 2
  hours) and **Missed** after it. Its last *success* decides, not its last run:
  a job whose newest run fails reads **Failed** (a run that failed a pod and then
  succeeded on a retry is not a failure). A run still going after twice its
  interval, or an hour, whichever is longer, reads **Running too long**. One that
  has never run reads **Never run** and a suspended one **Paused**; both are
  Unknown, so a practice that owns one cannot read healthy.
- **Several schedules.** An Argo CronWorkflow with a `schedules` list is judged
  against every entry: the run due is the latest any of them called for.
- **Numbers.** A query that answers NaN (a ratio of zero over zero) reads
  Unknown. An optional number reads **Not installed** only while its component
  has never reported; once it has (`presence` in the catalog), silence reads
  Unknown.
- **Agents.** With a ledger connected, a role's agent reads **Healthy** only
  when its newest run completed; any other status it does not know reads
  Unknown with that word. An item waiting on a person whose profile is no role
  in the catalog is still listed, under "no role in this catalog". If the
  ledger does not answer, the page says so instead of "nothing waiting".
- **Owned or not.** Every CronJob and CronWorkflow belongs to the first role whose
  pattern matches its name. An Argo CronWorkflow labelled
  `tockmox.com/practice: <role id>` belongs to that role whatever its name (CronJobs
  are read through kube-state-metrics, which does not carry their labels, so they
  match by name only). Work no role owns is listed as **No owner**, so nothing
  scheduled is invisible.
- **Planned and external.** Work a role will own but that is not deployed shows
  as **Planned**. Work that runs somewhere this page cannot see (another tool)
  can be listed as external; it is never shown healthy.

## Cases

With `specialistsUrl` set, Platform Management reads the **Service Desk** on a
specialist host: the register where the operations agents keep every incident,
problem, change and known error, with an enforced lifecycle and a timeline.

- `/platform/cases` answers "what waits on me, and what did the agents do":
  open cases first (anything waiting on you, then failed hand-offs, then what is
  past its role's time budget), then the cases closed in the last 30 days. Each
  row says who it waits on (you, an agent, the accountable role, or the open
  record it links to, followed down the chain), since when, and which agents
  worked it. `?role=<role id>` narrows it to one role.
- Each role's page gains **Its cases** (the ones it is accountable for, plus the
  ones one of its agents worked) and **Agents that do its work**.
- `/platform/cases/<id>` shows the record's facts, the rest of its case, and every
  step: when, which agent (and for which role), what kind of step, and its links.
- `/platform/specialists` lists every specialist the roles name, with two facts
  kept apart: how far it is built, and whether the host serves it now.

The page renders a step's words only when the desk says the desk itself or a
rule wrote them. A step a model may have worded (the desk marks every entry, from
the host's record of which calls had a model answer), or one an assistant or a
client wrote, shows that it happened, who did it and its links, and leaves the
words to the conversation. A link renders only as an `https` URL or a record id.
A desk that does not answer reads Unknown, never "nothing pending".

```yaml
tockmoxUi:
  secrets:
    platformSpecialistsToken: tockmox-ui-specialists   # a Secret you create, key: token
  networkPolicy:
    extraEgress:
      - to:
          - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: my-specialists}}
        ports: [{port: 8080, protocol: TCP}]
  config:
    features:
      platform:
        enabled: true
        specialistsUrl: http://specialist-host.my-specialists:8080
```

On the host, the token's sha256 goes in its callers file as `client/tockmox-ui`.

**The specialists field.** Each role in the catalog carries `agentRole` (its id
in the specialists' roles file, which the desk uses) and `specialists`
(`[{id, state}]`, state `built`, `specced` or `proposed`), and the catalog
records the roles file's hash in `specialistsSource`. All three are generated.
To rewrite them from the roles file:

```bash
python3 tools/gen-platform-specialists.py path/to/roles/platform-roles.yaml
```

To check for drift instead (exit 1 when the catalog is not what the roles file
makes it):

```bash
python3 tools/gen-platform-specialists.py --check path/to/roles/platform-roles.yaml
```

The script changes only those keys. When the hash the host publishes differs
from the catalog's, the role and specialist pages say the list is out of date.

## Replacing the catalog

The roles, what each owns and what each watches are a catalog file, version 2.
The product ships a default (below). A site replaces it whole with a ConfigMap,
key `catalog.yaml`:

```yaml
tockmoxUi:
  platformCatalog:
    configMap: my-platform-catalog
```

The catalog loads when the UI starts, so after changing the ConfigMap, restart
the UI (`kubectl -n <ai namespace> rollout restart deployment/tockmox-ui`).
Start from the product's file, `tockmox-ui/app/platform_catalog.yaml`, whose
header documents every field. Adding a role is a row there, not a deployment.
To give one Argo CronWorkflow to a role without touching the catalog, label it
`tockmox.com/practice: <role id>`.

## The default catalog

Three teams after ITIL 4's value chain: Run keeps the service healthy, Change
plans and delivers what changes it, Improve governs and learns. Modes:
**Observe** reads and reports; **Propose** drafts a change for a person to
approve; **Act** (no role has it) would run named, reversible actions.

<!-- BEGIN generated by tools/gen-platform-catalog-doc.py: do not edit by hand -->

**Run.** Keeps the platform healthy today. Notices, investigates, forecasts and proves recovery.

| Role | Mode | ITIL 4 practice | Owns scheduled work matching | Watches |
|---|---|---|---|---|
| Platform Manager (lead) | Propose | Service level management; Measurement and reporting; Service desk | none yet; 2 planned | none yet |
| Incident Manager | Observe | Incident management; Monitoring and event management | `tockmox-heartbeat`, `.*alert-relay.*`; 1 planned | Critical alerts firing, Warnings firing, Alert pipeline heartbeat, Endpoints answering |
| Problem Manager | Observe | Problem management | `.*catches.*`; 1 planned | Different alerts fired this week |
| Capacity Manager | Observe | Capacity and performance management | `.*capacity.*` | Busiest node, memory used, Busiest node, CPU over the last hour, Fullest volume, AI requests served locally, last 24h |
| Continuity Manager | Observe | Service continuity management; Availability management | `.*drill.*`, `.*backup.*`, `snapshot-.*`, `.*restore.*`, `.*export.*` | Days since a restore drill passed, Backup jobs whose last run did not succeed |
| Security Manager | Propose | Information security management | `.*posture.*`, `.*scan.*`, `.*trivy.*`, `.*key-check.*`; 1 planned | Days until the next certificate expires, Critical vulnerabilities with a fix |
| Request Manager | Propose | Service request management; Service catalogue management | none yet; 1 planned | none yet |

**Change.** Plans and delivers what changes the platform, and lets a change through only when it is ready.

| Role | Mode | ITIL 4 practice | Owns scheduled work matching | Watches |
|---|---|---|---|---|
| Project Manager (lead) | Propose | Project management; Portfolio management | none yet; 1 planned | none yet |
| Scrum Master | Propose | Project management (iterative delivery); Workforce and talent management | none yet; 3 planned | none yet |
| Change Manager | Propose | Change enablement | `.*renovate.*`, `.*label-reconciler.*`; 1 planned | Layers not both synced with git and healthy, Layers degraded or missing |
| Release Manager | Propose | Release management; Deployment management | none yet; 1 planned | none yet |
| Test Manager | Observe | Service validation and testing | none yet; 1 planned | none yet |
| Configuration and Asset Manager | Observe | Service configuration management; IT asset management; Infrastructure and platform management | none yet; 1 planned | Cluster nodes not ready, AI nodes running an unverified configuration |
| Supplier Manager | Observe | Supplier management; Relationship management | none yet; 2 planned | none yet |

**Improve.** Governs and learns. Measures how well the platform is run, keeps knowledge current and watches cost and risk.

| Role | Mode | ITIL 4 practice | Owns scheduled work matching | Watches |
|---|---|---|---|---|
| Improvement Manager (lead) | Propose | Continual improvement; Measurement and reporting; Strategy management | none yet; 1 planned | none yet |
| Knowledge Manager | Propose | Knowledge management | none yet; 1 planned | none yet |
| Finance Manager | Observe | Service financial management | none yet; 1 planned | Frontier spend, last 24h, Frontier spend, last 30 days, Least budget left on any gateway key |
| Architect | Propose | Architecture management; Service design | none yet; 1 planned | none yet |
| Risk and Compliance Manager | Observe | Risk management; Information security management (compliance) | none yet; 1 planned | none yet |

<!-- END generated -->

## What is not in this version

Agents themselves. This page shows roles, their work and their numbers today,
and reads an agent ledger and a specialist host if you have them; Tockmox does
not ship an agent or an orchestrator. No approvals, no actions and no Act mode:
a case waiting on you links to where you decide (the pull request), never to a
button here.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

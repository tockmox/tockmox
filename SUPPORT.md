# Support

Setting expectations honestly, because an overpromise here is worse than a
modest promise kept.

## What Tockmox is, staffing-wise

A solo-maintained open source project. There is no support team, no SLA, and no
paid tier that changes that today. Responses are best-effort and depend on what
else is happening that week.

There is also no peer community yet. Discussions is open and the maintainer
reads it, but today it is a way to reach the maintainer, not a place where
someone else will answer first. That will change or it will not; either way you
should plan on the current state.

If you are considering Tockmox for something that must not break, plan on the
basis that **you are your own first line of support**. The documentation and
the runbooks exist to make that realistic.

## Where to go

| You have | Go to |
|---|---|
| A question about how something works | [Discussions](https://github.com/tockmox/tockmox/discussions) |
| Something is broken | [Issues](https://github.com/tockmox/tockmox/issues) |
| A security vulnerability | [SECURITY.md](SECURITY.md) ... **never a public issue** |
| A documentation gap | An issue. These are genuinely welcome |
| A values-interface gap | An issue. Also genuinely welcome ... see below |

## Before opening an issue

Please include:

```bash
kubectl -n argocd get application <name> \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n argocd get application <name> \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
kubectl version -o json | head -20
```

Plus the Tockmox revision you are on. Most reports that stall do so because
somebody has to ask for these first.

Check [troubleshooting](docs/operations/troubleshooting.md). The failures that
actually happen on a first install are documented there, symptom first, with
causes.

## The issue we most want

**"I had to patch or replace something because Tockmox would not let me
configure it."**

That is a values-interface gap, and it is a bug in the project rather than a
support request. Exposing the value is usually a small change and it removes
your upgrade burden permanently. These get priority.

## If you cannot use GitHub

**support@tockmox.com**. Slower than an issue, and it loses the benefit of
other people finding the answer later, but it exists.

## What is out of scope

- Debugging your Kubernetes cluster itself
- Debugging upstream components (Grafana, ArgoCD, Longhorn) that are not
  misconfigured by Tockmox
- Architecture consulting for your deployment
- Anything with a deadline attached

None of that is a brush-off. It is the difference between what one person can
sustainably do and what would burn the project out.

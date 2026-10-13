<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-selfcheck

**Sync wave 5** · Implemented

Deterministic self-monitoring. Never invokes a model.

Will contain: backup monitoring, restore drills, the drill lane, capacity
drift checks.

## The principle

Checks are deterministic and never call a model. A platform whose health
monitoring depends on an AI being up has a circular dependency at exactly the
worst moment.

Absence and staleness render **not-green**, never green. A status that can go
green because the checker died is worse than no status.

See [backup and restore](../../docs/operations/backup-restore.md).

## Values

Globals are documented once in
[docs/administration/configuration.md](../../docs/administration/configuration.md).
This chart's own values are in `values.yaml`, and `values.schema.json`
rejects bad input at lint and at sync.

## Installing on its own

Every layer is an independent Argo Application, so you can take this one alone:

```bash
# once per clone: register chart repos and fetch dependencies
./tools/helm-deps.sh

helm template t charts/tockmox-selfcheck \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/selfcheck.yaml
```

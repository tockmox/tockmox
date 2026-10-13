<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-crds

**Sync wave 0** · Implemented

Every CustomResourceDefinition Tockmox needs, installed before anything that uses one.

## Why CRDs are a separate chart

Helm's own guidance, and it removes an entire class of failure rather than
patching instances of it: a custom resource applied before its definition
exists fails, and the failure is order-dependent and intermittent.

Putting every CRD in one wave-0 chart makes the ordering explicit and total.

**Not included:** CRDs owned by the distribution (`k3s.cattle.io`,
`helm.cattle.io`). Shipping those back to the cluster that defines them would
be wrong.

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

helm template t charts/tockmox-crds \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/crds.yaml
```

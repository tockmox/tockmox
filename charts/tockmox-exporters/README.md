<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-exporters

**Sync wave 3** · Implemented

Hardware and service exporters.

Separate from observability on purpose: these are the components most likely to
be wrong for your hardware. Disable the whole layer with one flag if your
estate differs, without losing metrics and logs.

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

helm template t charts/tockmox-exporters \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/exporters.yaml
```

<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-identity

**Sync wave 4** · Implemented

Single sign-on.

One invalid blueprint poisons discovery for the whole set, so every shipped
blueprint has to apply on an empty Authentik. What each of the three gates
proves, and what the greenfield gate has and has not been run against, is in
[identity](../../docs/administration/identity.md#the-greenfield-rule-for-blueprints).

![The Authentik admin overview this layer deploys, carrying Tockmox branding, on a greenfield cluster immediately after the first-run setup was completed ... system status OK, one worker, one outpost, and the setup itself showing in the recent-events list](../../docs/assets/getting-started/authentik-admin.jpg)

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

helm template t charts/tockmox-identity \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/identity.yaml
```

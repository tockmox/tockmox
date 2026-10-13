<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-common

Library chart. Not installable on its own.

Provides the helpers every layer chart uses, so labelling and naming are
defined once:

| Helper | Purpose |
|---|---|
| `tockmox.labels` | Standard labels on every shipped object |
| `tockmox.namespace` | Reserved-prefix namespace naming |
| `tockmox.internalHost` | `<service>.<global.internalDomain>` |
| `tockmox.image` | Honours `global.imageRegistry` for air-gapped mirrors |
| `tockmox.ingress` | One Ingress per shipped UI: derived hostname, TLS from `global.certIssuer` |

Every Tockmox-managed object carries `app.kubernetes.io/part-of: tockmox` and
`tockmox.com/layer: <layer>`, which is what makes ours and yours
machine-distinguishable.

Consumed as a `file://` dependency by the layer charts. Verified to resolve
correctly in ArgoCD's repo-server, not just under local `helm dependency build`.

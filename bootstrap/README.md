<!-- tockmox:banner:begin -->
<div align="center">

<img src="../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# Bootstrap

## Three prerequisites, installed by hand

A prerequisite is something that either cannot install itself, or must exist
before the GitOps loop can read your repository. Nothing else qualifies, which
is why cert-manager, MetalLB, Longhorn and Traefik are **not** here ... Tockmox
installs those as wave-2 charts.

1. **A conformant Kubernetes cluster** with a CNI and a default StorageClass.
2. **ArgoCD.** It cannot bootstrap itself, and self-managing it is a known
   failure mode.
3. **sealed-secrets, plus your own key.** It must exist before the first
   SealedSecret in your site repository syncs. From 0.7.0
   `./install/tockmox-install.sh bootstrap-secrets` installs (or adopts) it,
   exports its key encrypted and seals your credentials; you can still install
   it by hand. See [installation, Phase 2.5](../docs/deployment/install.md#the-bootstrap-route-bootstrap-secrets).

Full detail and versions: [docs/deployment/prerequisites.md](../docs/deployment/prerequisites.md).

## Then generate your site repository

There is no ready-made manifest to apply here, on purpose. The Applications
reference **your** site repository, and only you know its URL.

```bash
./install/tockmox-install.sh --config tockmox.yaml
```

That produces, in your site repo:

```
bootstrap/
  root.yaml                    the ONLY thing you apply by hand
  applications/
    tockmox-crds.yaml          wave 0
    tockmox-policy.yaml        wave 1
    tockmox-platform.yaml      wave 2
    ...                        one per enabled layer
```

## Why app-of-apps

`root.yaml` is a parent Application whose resources are the nine layer
Applications. That structure is what gives their `sync-wave` annotations
effect.

This matters and it is easy to get wrong: ArgoCD orders resources **within** an
Application. Nine Applications applied flat with `kubectl` all sync at once and
their wave annotations do nothing at all. The parent is not decoration.

```bash
kubectl apply -f bootstrap/root.yaml
kubectl -n argocd get applications -w
```

See [docs/deployment/install.md](../docs/deployment/install.md).

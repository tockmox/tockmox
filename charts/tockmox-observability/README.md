<!-- tockmox:banner:begin -->
<div align="center">

<img src="../../docs/assets/tockmox-lockup-horizontal-steel.svg" alt="Tockmox" width="320">

<em>Magic is just well-documented engineering</em>

</div>

---
<!-- tockmox:banner:end -->

# tockmox-observability

**Sync wave 3** · Implemented

Metrics, logs, dashboards, alerting.

Contains: kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki,
Alloy, and the notification path ... ntfy, an Alertmanager-to-ntfy bridge, and
Apprise for fan-out. Grafana is at `grafana.<internalDomain>`, ntfy at
`ntfy.<internalDomain>`.

Alertmanager routes to the bridge, and the bridge exports its own delivery
health so a broken notification path is visible on a dashboard rather than
announced by the mechanism that is broken. One thing you must do: create the
`tockmox-ntfy-auth` Secret, or ntfy stays `deny-all` and nothing is delivered
... see [secrets](../../docs/administration/secrets.md) and
[monitoring](../../docs/operations/monitoring.md).

**Already usable:** the dashboard extension point. Any ConfigMap labelled
`grafana_dashboard: "1"` is discovered once Grafana is running, and matching
a UID replaces one of ours. See
[customising](../../docs/administration/customising.md).

![Grafana's dashboard list on a fresh install of this layer, showing the Alertmanager, CoreDNS, etcd and kubernetes-mixin boards discovered from ConfigMaps labelled grafana_dashboard](../../docs/assets/getting-started/grafana-dashboards.jpg)

![The ntfy console subscribed to the alerts topic, showing three alerts this layer actually delivered ... a Watchdog heartbeat and two Tockmox warning alerts ... which is what makes it evidence of the notification path rather than a picture of an empty inbox](../../docs/assets/monitoring/ntfy-alert-delivered.jpg)

## Alert inhibition

This layer keeps kube-prometheus-stack's default inhibition rules. A critical alert mutes the warning and info
alerts with the same `alertname` in the same `namespace`, a warning mutes the info alert with the same
`alertname` in the same `namespace`, and `InfoInhibitor` holds back info alerts in a namespace while any warning
fires there. The rules match on `[namespace, alertname]`, not on the object, so a critical alert on one volume
or node also mutes the same-named warning on another one in that namespace.

That scope is a decision, not an omission (2026-10-23). On the reference site, 30 days of alert history,
inhibited alerts included, held no `(alertname, namespace)` pair that fired at both critical and warning, at
any time or at the same moment at five-minute resolution; 102 warning, 15 critical and 9 info pairs fired in
that window. That is one site over one month. Adding object labels such as `persistentvolumeclaim` or
`instance` to `equal:` only ever narrows inhibition, so its failure direction is more notifications, never
fewer. If your site sees a critical alert hiding a warning on a different object, set
`kube-prometheus-stack.alertmanager.config.inhibit_rules` in your observability values; a site value replaces
the whole list, so carry the rules you want to keep.

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

helm template t charts/tockmox-observability \
  -f your-site/site/values/global.yaml \
  -f your-site/site/values/observability.yaml
```

# SPDX-License-Identifier: Apache-2.0
"""Configuration: one YAML file rendered from chart values, plus a few env overrides.

The file is the only place a console URL, a group name or a source address comes
from. Nothing here is user-supplied at request time, which is what makes the
redirects and the launcher safe to build from it.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

import yaml

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")

# Routes the app owns. A launcher id may not shadow one, or a redirect would
# capture a page (or a page would capture a redirect) depending on route order.
RESERVED_IDS = frozenset({
    "api", "auth", "static", "status", "version", "upgrade", "tabs", "recovery",
    "healthz", "logout", "login", "favicon.ico", "check-updates", "nodes", "models",
    "capabilities", "signed-out",
})


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class App:
    id: str
    name: str
    url: str
    description: str = ""
    icon: str = "app"
    groups: tuple[str, ...] = ("*",)

    def visible_to(self, groups: set[str]) -> bool:
        return "*" in self.groups or bool(groups.intersection(self.groups))


@dataclass(frozen=True)
class Feature:
    id: str
    name: str
    enabled: bool
    admin_only: bool = True
    options: dict = field(default_factory=dict)


@dataclass(frozen=True)
class Settings:
    site_name: str
    domain: str
    tockmox_repo: str
    admin_group: str
    apps: tuple[App, ...]
    features: tuple[Feature, ...]
    kube_url: str
    kube_token_file: str
    kube_ca_file: str
    argocd_namespace: str
    argocd_stale_s: float
    prometheus_url: str
    alertmanager_url: str
    alertmanager_heartbeat: str
    update_enabled: bool
    update_feed_url: str
    update_public_keys: tuple[str, ...]
    update_interval_s: int
    oidc_issuer: str
    oidc_client_id: str
    oidc_client_secret: str
    oidc_redirect_url: str
    oidc_scopes: str
    session_secret: str
    session_max_age_s: int
    account_url: str
    source_timeout_s: float
    secure_cookies: bool
    nodes: "NodesSettings" = None
    lifecycle: "LifecycleSettings" = None
    docs_url: str = ""                     # the on-cluster documentation site (TM-1014)
    docs_repo_url: str = "https://github.com/tockmox/tockmox"   # the docs in the source repo, for when the site is down
    capabilities: tuple = ()               # ((name, configured_on), ...) as the AI layer resolved them (TM-1017)
    oidc_end_session: bool = True          # Sign out also ends the identity provider's session (TM-1014)
    oidc_post_logout_url: str = ""         # sent as post_logout_redirect_uri only when set (the issuer may refuse an unregistered one)

    def app(self, app_id: str) -> App | None:
        for a in self.apps:
            if a.id == app_id:
                return a
        return None

    def feature(self, fid: str) -> Feature | None:
        for f in self.features:
            if f.id == fid:
                return f
        return None


@dataclass(frozen=True)
class NodesSettings:
    """inferenceNodes (REQ-0047). The inventory itself is site values; the rest is how the UI may help."""
    inventory: object                      # app.nodes.Inventory
    probe_allowed: tuple[str, ...] = ()    # EMPTY = probing off (the default)
    probe_denied: tuple[str, ...] = ()     # added to the always-denied ranges; the cluster CIDRs land here
    probe_timeout_s: float = 3.0
    probe_max_bytes: int = 1 << 20
    gateway_model_list: tuple = ()         # the rendered gateway route list, when the chart passes it in
    gateway_sources: tuple[str, ...] = ()  # where the gateway's requests come FROM (for node firewalls)
    values_file: str = "values.yaml"       # where the admin commits the change, as the site repo names it
    raw: dict = None                       # the block as written, so a generated change carries every key


def _parse_nodes(raw: dict) -> NodesSettings:
    import ipaddress

    from . import nodes as nodesmod
    raw = raw or {}
    try:
        inv = nodesmod.parse_inventory(raw)
    except nodesmod.NodeError as e:
        raise ConfigError(f"inferenceNodes: {e}") from None
    probe = raw.get("probe") or {}
    cluster = raw.get("cluster") or {}

    def cidrs(v, what):
        out = []
        for c in v or []:
            try:
                out.append(str(ipaddress.ip_network(str(c), strict=False)))
            except ValueError:
                raise ConfigError(f"inferenceNodes.{what}: {c!r} is not a CIDR") from None
        return tuple(out)

    for k in ("timeoutSeconds", "maxBytes"):
        try:
            float(probe.get(k, 1))
        except (TypeError, ValueError):
            raise ConfigError(f"inferenceNodes.probe.{k} must be a number") from None
    allowed = cidrs(probe.get("allowedCidrs"), "probe.allowedCidrs")
    for c in allowed:
        if ipaddress.ip_network(c).prefixlen == 0:
            raise ConfigError("inferenceNodes.probe.allowedCidrs: a /0 would let the probe reach anything; name the range your nodes live in")
    denied = cidrs(probe.get("deniedCidrs"), "probe.deniedCidrs") + cidrs(
        [cluster.get("podCidr", "10.42.0.0/16"), cluster.get("serviceCidr", "10.43.0.0/16")], "cluster")
    gw = raw.get("gateway") or {}
    ml = gw.get("modelList") or []
    if not isinstance(ml, list):
        raise ConfigError("inferenceNodes.gateway.modelList must be a list")
    return NodesSettings(inventory=inv, probe_allowed=allowed, probe_denied=denied,
                         probe_timeout_s=float(probe.get("timeoutSeconds", 3)),
                         probe_max_bytes=int(probe.get("maxBytes", 1 << 20)),
                         gateway_model_list=tuple(ml),
                         gateway_sources=cidrs(gw.get("sourceCidrs"), "gateway.sourceCidrs"),
                         values_file=str(raw.get("valuesFile", "values.yaml")), raw=dict(raw))


@dataclass(frozen=True)
class LifecycleSettings:
    """modelLifecycle (REQ-0048). The catalog and profiles are site values; the report is the watcher's."""
    lifecycle: object                      # app.models.Lifecycle
    report_file: str = ""                  # the watcher's output; empty = no watcher
    report_max_age_s: float = 2 * 86400
    demand_query: str = 'sum by (model_group) (increase(litellm_deployment_success_responses_total[7d]))'
    watch_enabled: bool = False
    raw: dict = None
    verdicts_dir: str = ""                 # where the UI READS REQ-0045 comparative verdicts; empty = none yet
    verdicts_repo_path: str = "evals/verdicts"   # where those files sit in the site repo (recorded in a promotion)
    requests_repo_path: str = "evals/requests"   # where an eval request generated here is to be committed
    provider_pages: dict = None            # provider -> https page template for hosted models (TM-0938)
    modelkit_registries: dict = None       # registry host -> https page template for ModelKit sources (TM-0938)


def _parse_lifecycle(raw: dict, inventory) -> LifecycleSettings:
    from . import models as ml
    raw = raw or {}
    try:
        lc = ml.parse(raw)
    except (ml.LifecycleError, ValueError, TypeError) as e:
        raise ConfigError(f"modelLifecycle: {e}") from None
    problems = ml.check_promotions(lc, inventory)
    if problems:
        # rule 2 (REQ-0048): the UI will not start on values where an alias moved without a passing eval
        raise ConfigError("modelLifecycle promotion gate: " + "; ".join(problems))
    w = raw.get("watch") or {}
    try:
        max_age = float(raw.get("reportMaxAgeSeconds", 2 * 86400))
    except (TypeError, ValueError):
        raise ConfigError("modelLifecycle.reportMaxAgeSeconds must be a number") from None
    paths = {}
    for k, default in (("verdictsRepoPath", "evals/verdicts"), ("evalRequestsRepoPath", "evals/requests")):
        v = str(raw.get(k, default) or default).strip("/")
        if not re.match(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", v) or ".." in v.split("/"):
            raise ConfigError(f"modelLifecycle.{k} must be a relative path inside the site repo")
        paths[k] = v
    pages = raw.get("providerPages") or {}
    if not isinstance(pages, dict) or not all(isinstance(v, str) and ml._URL.match(v.replace("{model}", "m")) for v in pages.values()):
        raise ConfigError("modelLifecycle.providerPages must map a provider to an https:// URL ({model} is filled in)")
    regs = raw.get("modelkitRegistries") or {}
    if not isinstance(regs, dict) or not all(
            isinstance(k, str) and ml.REGISTRY_HOST.match(k) and isinstance(v, str)
            and ml._URL.match(v.replace("{repository}", "r").replace("{reference}", "t")) for k, v in regs.items()):
        raise ConfigError("modelLifecycle.modelkitRegistries must map a registry host (host or host:port) to an https:// URL "
                          "({repository} and {reference} are filled in)")
    return LifecycleSettings(lc, str(raw.get("reportFile", "") or ""), max_age,
                             str(raw.get("demandQuery", LifecycleSettings.demand_query)), bool(w.get("enabled", False)), dict(raw),
                             str(raw.get("verdictsDir", "") or ""), paths["verdictsRepoPath"], paths["evalRequestsRepoPath"],
                             dict(pages), dict(regs))


def _parse_capabilities(raw) -> tuple:
    if raw is None:
        return ()
    if not isinstance(raw, dict) or not all(isinstance(k, str) and isinstance(v, bool) for k, v in raw.items()):
        raise ConfigError("capabilities must map a capability name to true or false (the chart renders it)")
    return tuple(sorted(raw.items()))


def _read_secret(path: str | None, env: str) -> str:
    if os.environ.get(env):
        return os.environ[env]
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    return ""


def _check_url(u: str, what: str) -> str:
    if not re.match(r"^https?://[A-Za-z0-9.\-]+(:\d+)?(/[^\s]*)?$", u or ""):
        raise ConfigError(f"{what}: not an absolute http(s) URL: {u!r}")
    return u.rstrip("/")


def parse(doc: dict) -> Settings:
    apps = []
    seen = set()
    for raw in doc.get("apps") or []:
        aid = str(raw.get("id", ""))
        if not ID_RE.match(aid):
            raise ConfigError(f"app id {aid!r} must match {ID_RE.pattern}")
        if aid in RESERVED_IDS:
            raise ConfigError(f"app id {aid!r} is reserved by the UI")
        if aid in seen:
            raise ConfigError(f"app id {aid!r} is duplicated")
        seen.add(aid)
        groups = tuple(raw.get("groups") or ["*"])
        apps.append(App(id=aid, name=str(raw.get("name", aid)),
                        url=_check_url(str(raw.get("url", "")), f"apps.{aid}.url"),
                        description=str(raw.get("description", "")),
                        icon=str(raw.get("icon", "app")), groups=groups))

    def _opt_url(v, what):
        return _check_url(str(v), what) if v else ""

    feats = []
    names = {"posture": "Security posture", "scanning": "Vulnerability scanning", "agents": "Agents", "platform": "Platform Management"}
    for fid, raw in (doc.get("features") or {}).items():
        raw = dict(raw or {})
        for k in ("url", "rendererUrl", "apiUrl", "ledgerUrl", "interfaceUrl", "specialistsUrl"):
            if raw.get(k):
                raw[k] = _opt_url(raw[k], f"features.{fid}.{k}")
        feats.append(Feature(id=fid, name=raw.get("name", names.get(fid, fid)),
                             enabled=bool(raw.get("enabled", False)),
                             admin_only=bool(raw.get("adminOnly", True)),
                             options={k: v for k, v in raw.items()
                                      if k not in ("enabled", "name", "adminOnly")}))

    # /platform is a route only while Platform Management is on, so the id is reserved only then: a site
    # with an app called "platform" and the feature off keeps working after an upgrade.
    if any(f.id == "platform" and f.enabled for f in feats) and "platform" in seen:
        raise ConfigError("app id 'platform' is reserved by the UI while features.platform is enabled")

    src = doc.get("sources") or {}
    kube = src.get("kubernetes") or {}
    upd = doc.get("updateCheck") or {}
    oidc = doc.get("oidc") or {}
    sess = doc.get("session") or {}
    site = doc.get("site") or {}

    enabled = bool(upd.get("enabled", False))   # OFF unless the operator says otherwise
    keys = tuple(upd.get("publicKeys") or [])
    feed = str(upd.get("feedUrl", ""))
    if enabled and not keys:
        raise ConfigError("updateCheck.enabled needs at least one updateCheck.publicKeys entry")
    if enabled and not (feed.startswith("https://") or feed.startswith("file:///")):
        raise ConfigError("updateCheck.feedUrl must be https:// or file:///")

    secret = _read_secret(sess.get("secretFile"), "TOCKMOX_UI_SESSION_SECRET")
    if len(secret) < 32:
        raise ConfigError("session secret missing or shorter than 32 characters")

    return Settings(
        site_name=str(site.get("name", "Tockmox")),
        domain=str(site.get("domain", "")),
        # Empty means "derive it": the Tockmox layers are the Applications whose
        # first source path is charts/tockmox-<layer>, whatever repository
        # serves them. A site that mirrors the product repository (every
        # air-gapped site, and both 0.8.0 labs) used to read "Version unknown
        # ... No Argo CD application points at the Tockmox repository" until
        # it set this key, which no page named (TM-0979). Set it to pin the
        # match to one repository URL instead.
        tockmox_repo=str(doc.get("tockmoxRepo") or "").rstrip("/"),
        admin_group=str((doc.get("roles") or {}).get("adminGroup", "tockmox-admins")),
        apps=tuple(apps),
        features=tuple(feats),
        kube_url=str(kube.get("url", "https://kubernetes.default.svc")).rstrip("/"),
        kube_token_file=str(kube.get("tokenFile", "/var/run/secrets/kubernetes.io/serviceaccount/token")),
        kube_ca_file=str(kube.get("caFile", "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")),
        argocd_namespace=str(kube.get("argocdNamespace", "argocd")),
        argocd_stale_s=float(kube.get("argocdStaleSeconds", 600)),
        prometheus_url=str((src.get("prometheus") or {}).get("url", "")).rstrip("/"),
        alertmanager_url=str((src.get("alertmanager") or {}).get("url", "")).rstrip("/"),
        alertmanager_heartbeat=str((src.get("alertmanager") or {}).get("heartbeat", "Watchdog")),
        update_enabled=enabled,
        update_feed_url=feed,
        update_public_keys=keys,
        update_interval_s=int(upd.get("intervalSeconds", 86400)),
        oidc_issuer=str(oidc.get("issuer", "")).rstrip("/"),
        oidc_client_id=str(oidc.get("clientId", "tockmox-ui")),
        oidc_client_secret=_read_secret(oidc.get("clientSecretFile"), "TOCKMOX_UI_OIDC_CLIENT_SECRET"),
        oidc_redirect_url=str(oidc.get("redirectUrl", "")),
        oidc_scopes=str(oidc.get("scopes", "openid profile email")),
        session_secret=secret,
        session_max_age_s=int(sess.get("maxAgeSeconds", 8 * 3600)),
        account_url=_opt_url(site.get("accountUrl", ""), "site.accountUrl"),
        source_timeout_s=float(src.get("timeoutSeconds", 4)),
        secure_cookies=bool(sess.get("secureCookies", True)),
        nodes=(nodes := _parse_nodes(doc.get("inferenceNodes") or {})),
        lifecycle=_parse_lifecycle(doc.get("modelLifecycle") or {}, nodes.inventory),
        docs_url=_opt_url(site.get("docsUrl", ""), "site.docsUrl"),
        docs_repo_url=_opt_url(site.get("docsRepoUrl", "https://github.com/tockmox/tockmox"), "site.docsRepoUrl"),
        capabilities=_parse_capabilities(doc.get("capabilities")),
        oidc_end_session=bool(oidc.get("endSession", True)),
        # Validated, then sent EXACTLY as written: the issuer matches it against the registered
        # post-logout URI byte for byte (Authentik's strict mode), so the trailing slash the other
        # URLs here lose would turn a registered "https://ui.example/" into a refused logout.
        oidc_post_logout_url=(_check_url(str(oidc["postLogoutRedirectUrl"]), "oidc.postLogoutRedirectUrl") and str(oidc["postLogoutRedirectUrl"]))
        if oidc.get("postLogoutRedirectUrl") else "",
    )


def load(path: str | None = None) -> Settings:
    path = path or os.environ.get("TOCKMOX_UI_CONFIG", "/etc/tockmox-ui/config.yaml")
    with open(path, encoding="utf-8") as fh:
        return parse(yaml.safe_load(fh) or {})

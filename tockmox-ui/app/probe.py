# SPDX-License-Identifier: Apache-2.0
"""The probe (REQ-0047 AC-47.3): ask a named host which engines it serves. Bounded on purpose.

This is the one place the UI connects to an address an admin typed, so it is the one
place an SSRF would live. The rules, each with a test and the first three with a
planted-defect gate:

  * OFF until the operator names a range: an empty allowedCidrs refuses everything.
  * Loopback, link-local (cloud metadata lives there), unspecified, multicast and the
    cluster's own pod/service ranges are refused even when the allowlist covers them.
  * The name is resolved ONCE and every request goes to that address (the original name
    rides in Host and SNI), so a second DNS answer cannot move the probe.
  * Fixed GET paths per engine, ports from the node type plus at most four typed ones.
  * No redirects, a per-request timeout, a response cap, JSON or nothing.
  * A pasted bearer token goes on these requests only; it is never stored or echoed.
"""
from __future__ import annotations

import ipaddress
import json
import re
import socket
from dataclasses import dataclass, field
from typing import Callable
from urllib.parse import urlsplit

import httpx

from .nodes import CATALOG, ENGINES, estimate_size_gib, planning_size

ALWAYS_DENIED = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32",
    "::/128", "::1/128", "fe80::/10", "ff00::/8", "::ffff:127.0.0.0/104", "::ffff:169.254.0.0/112",
    # IPv6 forms that embed an IPv4 address and can reach it through a translator (review finding)
    "64:ff9b::/96", "64:ff9b:1::/48", "2002::/16", "::/96", "100::/64")]
MAX_PORTS = 12
MAX_EXTRA_PORTS = 4


class Refused(ValueError):
    pass


@dataclass
class Model:
    id: str
    size_gib: float | None = None
    size_source: str = ""      # engine | estimate | ""
    loaded: bool | None = None
    detail: str = ""


@dataclass
class Finding:
    port: int
    engine: str | None          # None = nothing recognisable answered
    url: str
    version: str = ""
    models: list[Model] = field(default_factory=list)
    reason: str = ""
    auth_required: bool = False
    hint: str = ""
    suggested: str = ""         # an engine to pre-select when the answer could not prove one


@dataclass
class ProbeResult:
    host: str
    address: str
    findings: list[Finding]

    @property
    def found(self) -> list[Finding]:
        return [f for f in self.findings if f.engine]


def _nets(cidrs) -> list:
    out = []
    for c in cidrs or []:
        out.append(ipaddress.ip_network(str(c), strict=False))
    return out


class Prober:
    def __init__(self, allowed_cidrs, denied_cidrs=(), timeout: float = 3.0, max_bytes: int = 1 << 20,
                 transport: httpx.BaseTransport | None = None,
                 resolver: Callable = socket.getaddrinfo):
        self.allowed = _nets(allowed_cidrs)
        self.denied = ALWAYS_DENIED + _nets(denied_cidrs)
        self.timeout, self.max_bytes = timeout, max_bytes
        self.transport, self.resolver = transport, resolver

    @property
    def enabled(self) -> bool:
        return bool(self.allowed)

    # ------------------------------------------------------------ target checks

    def check_address(self, ip) -> None:
        ip = ipaddress.ip_address(ip)
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            self.check_address(ip.ipv4_mapped)
        for n in self.denied:
            if ip.version == n.version and ip in n:
                raise Refused(f"{ip} is in a range Tockmox never probes ({n})")
        if not any(ip.version == n.version and ip in n for n in self.allowed):
            raise Refused(f"{ip} is outside inferenceNodes.probe.allowedCidrs")

    def resolve(self, host: str) -> str:
        if not self.enabled:
            raise Refused("probing is off: set inferenceNodes.probe.allowedCidrs to the range your inference nodes live in")
        host = (host or "").strip().strip("[]").rstrip(".")
        from .nodes import _host_ok
        if not host or not _host_ok(host):
            # the same rule the node record uses, so a probe that succeeds can always be recorded
            raise Refused("enter a host name or an IP address, nothing else")
        try:
            ip = ipaddress.ip_address(host)
            addrs = [str(ip)]
        except ValueError:
            try:
                infos = self.resolver(host, None, 0, socket.SOCK_STREAM)
            except (socket.gaierror, UnicodeError, OSError):
                raise Refused(f"{host} does not resolve") from None
            addrs = sorted({i[4][0] for i in infos})
            if not addrs:
                raise Refused(f"{host} does not resolve")
        for a in addrs:          # every answer must pass, so a mixed answer cannot sneak one through
            self.check_address(a)
        return addrs[0]

    # ------------------------------------------------------------ requests

    def _get(self, client: httpx.Client, scheme: str, host: str, address: str, port: int, path: str,
             token: str) -> tuple[int, object]:
        netloc = f"[{address}]" if ":" in address else address
        headers = {"Host": host if port in (80, 443) else f"{host}:{port}", "Accept": "application/json",
                   "User-Agent": "tockmox-ui-probe"}
        if token:
            headers["Authorization"] = "Bearer " + token
        ext = {"sni_hostname": host} if scheme == "https" else {}
        with client.stream("GET", f"{scheme}://{netloc}:{port}{path}", headers=headers, extensions=ext) as r:
            if 300 <= r.status_code < 400:
                return r.status_code, None          # never followed
            buf = b""
            for chunk in r.iter_bytes():
                buf += chunk
                if len(buf) > self.max_bytes:
                    raise Refused("answer larger than the probe's cap")
            if r.status_code != 200:
                return r.status_code, None
            try:
                return 200, json.loads(buf.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                return 200, None

    def probe(self, host: str, node_type: str, extra_ports=(), token: str = "", scheme: str = "http") -> ProbeResult:
        if scheme not in ("http", "https"):
            raise Refused("scheme must be http or https")
        if token and (len(token) > 4096 or any(not (33 <= ord(ch) <= 126) for ch in token)):
            raise Refused("the token must be printable characters with no spaces")
        address = self.resolve(host)
        kind = CATALOG.get(node_type, CATALOG["openai-compatible"])
        ports: list[tuple[int, list[str]]] = []
        for eng in kind["engines"]:
            p = ENGINES[eng]["port"]
            hit = next((x for x in ports if x[0] == p), None)
            if hit:
                hit[1].append(eng)
            else:
                ports.append((p, [eng]))
        extras = []
        for p in list(extra_ports)[:MAX_EXTRA_PORTS]:
            p = int(p)
            if not 0 < p < 65536:
                raise Refused(f"port {p} is not a port")
            if all(x[0] != p for x in ports):
                extras.append((p, list(SIGNATURES) + ["mlx-lm"]))   # a typed port could be any engine
        ports = (ports + extras)[:MAX_PORTS]
        findings = []
        name = host.strip().strip("[]").rstrip(".")
        with httpx.Client(timeout=self.timeout, follow_redirects=False, transport=self.transport,
                          trust_env=False) as c:
            for port, engines in ports:
                findings.append(self._probe_port(c, scheme, name, address, port, engines, token))
        return ProbeResult(name, address, findings)

    def _probe_port(self, c, scheme, host, address, port, engines, token) -> Finding:
        url = f"{scheme}://{host if ':' not in host else '[' + host + ']'}:{port}"
        get = lambda path: self._get(c, scheme, host, address, port, path, token)  # noqa: E731
        try:
            order = _ordered(engines)
            for eng in order:
                f = SIGNATURES[eng](get, port, url)
                if f is not None:
                    return f
            st, body = get("/v1/models")
            if st in (401, 403):
                return Finding(port, None, url, reason=f"answered HTTP {st}: needs a token", auth_required=True)
            if st == 200 and _openai_models(body) is not None:
                f = Finding(port, "openai-compatible", url, models=_openai_models(body))
                if "mlx-lm" in engines and all("/" in m.id for m in f.models):
                    f.hint = ("answers like mlx-lm (Hugging Face repo ids on a Mac, nothing else to go on), "
                              "so mlx-lm is pre-selected below; change it if you know better")
                    f.suggested = "mlx-lm"
                return f
            return Finding(port, None, url, reason=f"no engine recognised (HTTP {st})" if st else "no engine recognised")
        except Refused as e:
            return Finding(port, None, url, reason=str(e))
        except httpx.TimeoutException:
            return Finding(port, None, url, reason="timed out")
        except httpx.ConnectError:
            return Finding(port, None, url, reason="refused or unreachable")
        except httpx.HTTPError as e:
            return Finding(port, None, url, reason=type(e).__name__)

    def read_builds(self, url: str, engine: str, token: str = "") -> "BuildReading":
        """Which build of each model a committed endpoint holds (TM-0934). Same fences as probe(): raises
        Refused when the address may not be probed, and otherwise returns a reading whose reason says why
        nothing could be read."""
        parts = urlsplit(url)
        scheme = parts.scheme or "http"
        if scheme not in ("http", "https"):
            raise Refused("scheme must be http or https")
        host = parts.hostname or ""
        port = parts.port or (443 if scheme == "https" else 80)
        address = self.resolve(host)
        out = BuildReading(url, engine)
        with httpx.Client(timeout=self.timeout, follow_redirects=False, transport=self.transport,
                          trust_env=False) as c:
            get = lambda path: self._get(c, scheme, host, address, port, path, token)  # noqa: E731
            try:
                if engine == "ollama":
                    st, tags = get("/api/tags")
                    if st != 200 or not isinstance(tags, dict):
                        out.reason = f"/api/tags answered HTTP {st}" + (": needs a token" if st in (401, 403) else "")
                        return out
                    out.how = "Ollama /api/tags digest"
                    for m in (tags.get("models") or [])[:500]:
                        if isinstance(m, dict) and isinstance(m.get("name"), str):
                            out.builds[ollama_name(m["name"])] = norm_build(m.get("digest"))
                elif engine == "llama-server":
                    st, props = get("/props")
                    if st != 200 or not isinstance(props, dict):
                        out.reason = f"/props answered HTTP {st}" + (": needs a token" if st in (401, 403) else "")
                        return out
                    hit = _SNAPSHOT.search(str(props.get("model_path") or ""))
                    out.how = "llama-server model path (Hugging Face cache snapshot)"
                    st, body = get("/v1/models")
                    for m in _openai_models(body) or []:
                        out.builds[m.id] = hit.group(1) if hit else ""
                    if not out.builds:
                        out.reason = "llama-server listed no model"
                else:
                    out.reason = f"{ENGINES.get(engine, {}).get('name', engine)} does not report which build it loaded"
            except Refused as e:
                out.reason = str(e)
            except httpx.TimeoutException:
                out.reason = "timed out"
            except httpx.ConnectError:
                out.reason = "refused or unreachable"
            except httpx.HTTPError as e:
                out.reason = type(e).__name__
        return out


def _ordered(engines):
    # most distinctive signature first; the generic /v1/models fallback runs after all of them
    pri = ["ollama", "lm-studio", "llama-server", "nim", "tgi", "sglang", "vllm", "exo"]
    return [e for e in pri if e in engines]


def _openai_models(body):
    if not isinstance(body, dict) or not isinstance(body.get("data"), list):
        return None
    out = []
    for m in body["data"][:200]:
        if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"]:
            sz = estimate_size_gib(m["id"])
            out.append(Model(m["id"][:200], sz, "estimate" if sz else ""))
    return out


def _gib(n) -> float | None:
    """Bytes from an engine's listing as a planning size: a tenth of a GiB at least, None when unknown."""
    try:
        return planning_size(float(n) / (1 << 30))
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------ engine signatures
# Each returns a Finding when the port is that engine, else None. Fixed paths only.

def _sig_ollama(get, port, url):
    st, v = get("/api/version")
    if st != 200 or not isinstance(v, dict) or not isinstance(v.get("version"), str):
        return None
    f = Finding(port, "ollama", url, version=v["version"][:40])
    st, tags = get("/api/tags")
    loaded = set()
    st2, ps = get("/api/ps")
    if st2 == 200 and isinstance(ps, dict):
        loaded = {m.get("name") for m in ps.get("models") or [] if isinstance(m, dict)}
    if st == 200 and isinstance(tags, dict):
        for m in (tags.get("models") or [])[:200]:
            if isinstance(m, dict) and isinstance(m.get("name"), str):
                d = m.get("details") or {}
                f.models.append(Model(m["name"][:200], _gib(m.get("size")), "engine", m["name"] in loaded,
                                      " ".join(str(x) for x in (d.get("parameter_size"), d.get("quantization_level")) if x)))
    return f


def _sig_lmstudio(get, port, url):
    st, v = get("/api/v0/models")
    if st != 200 or not isinstance(v, dict) or not isinstance(v.get("data"), list):
        return None
    if not any(isinstance(m, dict) and "state" in m for m in v["data"]):
        return None
    f = Finding(port, "lm-studio", url)
    for m in v["data"][:200]:
        if isinstance(m, dict) and isinstance(m.get("id"), str):
            sz = estimate_size_gib(m["id"])
            f.models.append(Model(m["id"][:200], sz, "estimate" if sz else "", m.get("state") == "loaded",
                                  " ".join(str(x) for x in (m.get("arch"), m.get("quantization")) if x)))
    return f


def _sig_llamaserver(get, port, url):
    st, p = get("/props")
    if st != 200 or not isinstance(p, dict) or not ("default_generation_settings" in p or "build_info" in p):
        return None
    f = Finding(port, "llama-server", url, version=str(p.get("build_info", ""))[:60])
    st, body = get("/v1/models")
    f.models = _openai_models(body) or []
    for m in f.models:
        m.loaded = True
    if st in (401, 403):
        f.auth_required = True
    return f


def _sig_nim(get, port, url):
    st, _ = get("/v1/health/ready")
    if st != 200:
        return None
    st, meta = get("/v1/metadata")
    if st != 200 or not isinstance(meta, dict):
        return None
    st, v = get("/v1/version")
    f = Finding(port, "nim", url, version=str((v or {}).get("release", "") if isinstance(v, dict) else "")[:40])
    f.models = _openai_models(get("/v1/models")[1]) or []
    return f


def _sig_tgi(get, port, url):
    st, i = get("/info")
    if st != 200 or not isinstance(i, dict) or "model_id" not in i:
        return None
    f = Finding(port, "tgi", url, version=str(i.get("version", ""))[:40])
    sz = estimate_size_gib(str(i["model_id"]))
    f.models = [Model(str(i["model_id"])[:200], sz, "estimate" if sz else "", True)]
    return f


def _sig_sglang(get, port, url):
    st, i = get("/get_model_info")
    if st != 200 or not isinstance(i, dict) or "model_path" not in i:
        return None
    f = Finding(port, "sglang", url)
    f.models = _openai_models(get("/v1/models")[1]) or []
    return f


def _sig_vllm(get, port, url):
    st, v = get("/version")
    if st != 200 or not isinstance(v, dict) or not isinstance(v.get("version"), str):
        return None
    st, body = get("/v1/models")
    models = _openai_models(body)
    if models is None:
        return None
    owned = {m.get("owned_by") for m in (body.get("data") or []) if isinstance(m, dict)}
    if "vllm" not in owned:
        return None
    return Finding(port, "vllm", url, version=v["version"][:40], models=models)


def _sig_exo(get, port, url):
    if port != ENGINES["exo"]["port"]:
        return None
    st, body = get("/v1/models")
    models = _openai_models(body)
    if models is None:
        return None
    return Finding(port, "exo", url, models=models, hint="the exo default port answered; check it is exo")


SIGNATURES = {"ollama": _sig_ollama, "lm-studio": _sig_lmstudio, "llama-server": _sig_llamaserver,
              "nim": _sig_nim, "tgi": _sig_tgi, "sglang": _sig_sglang, "vllm": _sig_vllm, "exo": _sig_exo}


# ------------------------------------------------------------ which build a node holds (TM-0934)
# The catalog pins a build (an Ollama manifest digest, a Hugging Face commit); the node holds one. Reading
# the node's side is a request to an address an admin committed, so it goes through the same fences as the
# probe: the endpoint's host is resolved and checked by Prober.resolve, fixed GET paths, no redirects, the cap.

_SNAPSHOT = re.compile(r"/snapshots/([0-9a-f]{40})(?:/|$)")


@dataclass
class BuildReading:
    url: str
    engine: str
    builds: dict = field(default_factory=dict)   # model id -> build hex ("" = listed, build not readable)
    how: str = ""                                # what the build was read from
    reason: str = ""                             # set when nothing could be read; the caller reads Unknown


def norm_build(v) -> str:
    """'sha256:ABC..' and 'abc..' are the same build; anything that is not hex is no build at all."""
    s = str(v or "").strip().lower()
    s = s[7:] if s.startswith("sha256:") else s
    return s if re.fullmatch(r"[0-9a-f]{7,64}", s) else ""


def ollama_name(m: str) -> str:
    """Ollama lists `phi4` as `phi4:latest`; a route may say either."""
    return m if ":" in m.rsplit("/", 1)[-1] else m + ":latest"

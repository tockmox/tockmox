#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# AUDIT THE GATEWAY'S VIRTUAL KEYS (TM-0991). The key policy (modelGateway.keyPolicy) runs on every key generate,
# update and regenerate, so it never sees a key that already exists until that key is next written. This lists the
# existing keys the policy would refuse, so they can be fixed before the policy is turned on, and found afterwards:
#
#   OPEN     the model list is empty, `*` or `all-proxy-models`: LiteLLM lets the key call EVERY model, today,
#            whether or not the policy is on (for a team key, the team's own list may narrow it; the policy still
#            refuses the key's next update)
#   NEXT     the key names a model ending in a refused suffix (-next by default): a candidate on a production key
#   NO-MCP   the key states no MCP access (no object_permission.mcp_servers, or an empty one), which LiteLLM reads
#            as every MCP server; the policy refuses a NEW key like this, and an update that sends an empty list
#   BLOCKED  a key with any of the above that LiteLLM has blocked: it refuses every call, so it is reported and
#            not counted; unblocking it brings the finding back
#
#   tools/audit-keys.sh --context CTX [--namespace tockmox-ai] [--deployment tockmox-ai-litellm]
#                       [--allow ALIAS]... [--suffix -next]... [--no-suffix]
#   tools/audit-keys.sh --url http://127.0.0.1:4000 [...]      # PROXY_MASTER_KEY from the environment
#
# With --context it runs inside the LiteLLM pod (kubectl exec, the pod's own PROXY_MASTER_KEY, plain HTTP on
# localhost), so the master key never leaves the cluster, and it reads only (GET /key/list). It prints aliases and
# LiteLLM's masked key names (sk-...abcd), never a key. --allow names an alias the policy allows every model to (the
# console's key: modelGateway.keyPolicy.allowAllModelsAliases, plus the console-key Job's own alias); --suffix and
# --no-suffix mirror modelGateway.keyPolicy.refuseSuffixes.
#
# Exit 0: no finding. 1: at least one finding (each line says which). 2: the audit could not run.
set -uo pipefail

CTX="" NS="tockmox-ai" DEPLOY="tockmox-ai-litellm" URL="" ALLOW="" SUFFIXES="-next" SUFFIX_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    CTX="${2:-}"; shift 2 ;;
    --namespace)  NS="${2:-}"; shift 2 ;;
    --deployment) DEPLOY="${2:-}"; shift 2 ;;
    --url)        URL="${2:-}"; shift 2 ;;
    --allow)      ALLOW="$ALLOW,${2:-}"; shift 2 ;;
    --suffix)     [ "$SUFFIX_SET" = 1 ] || SUFFIXES=""; SUFFIX_SET=1; SUFFIXES="$SUFFIXES,${2:-}"; shift 2 ;;
    --no-suffix)  SUFFIXES=""; SUFFIX_SET=1; shift ;;
    -h|--help)    sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "audit-keys: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
if [ -n "$CTX" ] && [ -n "$URL" ]; then echo "audit-keys: --context and --url are exclusive" >&2; exit 2; fi
if [ -z "$CTX" ] && [ -z "$URL" ]; then echo "audit-keys: name the cluster (--context) or a proxy (--url); there is no default" >&2; exit 2; fi

# The audit itself: stdlib only, so it runs in the LiteLLM image as it is. argv: base URL, allow list, suffixes.
read -r -d '' AUDIT <<'PY'
import json, os, sys, urllib.request, urllib.error
base, allow, suffixes = sys.argv[1].rstrip("/"), set(filter(None, sys.argv[2].split(","))), tuple(filter(None, sys.argv[3].split(",")))
mk = os.environ.get("PROXY_MASTER_KEY")
if not mk:
    print("audit-keys: PROXY_MASTER_KEY is not set", file=sys.stderr); sys.exit(2)
def get(path):
    req = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + mk})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)
keys, page = [], 1
try:
    while True:
        d = get("/key/list?return_full_object=true&include_team_keys=true&size=100&page=%d" % page)
        rows = d.get("keys", []) if isinstance(d, dict) else d
        keys += [r for r in rows if isinstance(r, dict)]
        if not isinstance(d, dict) or page >= int(d.get("total_pages") or 1):
            break
        page += 1
except (urllib.error.URLError, ValueError, OSError) as e:
    print("audit-keys: /key/list failed: %s" % e, file=sys.stderr); sys.exit(2)
WILD = {"*", "all-proxy-models"}
findings = blocked = 0
for k in sorted(keys, key=lambda r: (r.get("key_alias") or "", r.get("key_name") or "")):
    name = "%s (%s)" % (k.get("key_alias") or "(no alias)", k.get("key_name") or "?")
    models = list(k.get("models") or [])
    team = k.get("team_id")
    out = []
    if (not models or WILD & set(models)) and (k.get("key_alias") or "") not in allow:
        what = "no model list" if not models else "the wildcard " + sorted(WILD & set(models))[0]
        out.append("OPEN    %s: %s%s" % (name, what, " (team %s: its list may narrow it)" % team if team else ""))
    nxt = [m for m in models if any(str(m).endswith(s) for s in suffixes)]
    if nxt:
        out.append("NEXT    %s: names %s" % (name, ", ".join(nxt)))
    op = k.get("object_permission") or {}
    servers = op.get("mcp_servers") if isinstance(op, dict) else None
    if not servers:
        out.append("NO-MCP  %s: %s" % (name, "no MCP statement" if servers is None else "an empty mcp_servers list"))
    elif "*" in servers:
        out.append("NO-MCP  %s: mcp_servers holds '*'" % name)
    if out and k.get("blocked"):
        # LiteLLM refuses every call from a blocked key, so it reaches nothing today; it is reported, not counted.
        # Unblocking it brings back exactly what the lines below would have said.
        print("BLOCKED %s: refuses every call while blocked; unblocked it is %s" % (
            name, "; ".join(o.split(None, 1)[0] + " (" + o.split(": ", 1)[1] + ")" for o in out)))
        blocked += 1
        continue
    for line in out:
        print(line)
    findings += len(out)
print("audit-keys: %d key(s), %d finding(s)%s" % (len(keys), findings,
      ", %d blocked key(s) reported, not counted" % blocked if blocked else ""))
sys.exit(1 if findings else 0)
PY

if [ -n "$URL" ]; then
  exec python3 -c "$AUDIT" "$URL" "$ALLOW" "$SUFFIXES"
fi
command -v kubectl >/dev/null 2>&1 || { echo "audit-keys: kubectl not on PATH" >&2; exit 2; }
exec kubectl --context "$CTX" -n "$NS" exec "deploy/$DEPLOY" -c litellm -- \
  python3 -c "$AUDIT" "http://127.0.0.1:4000" "$ALLOW" "$SUFFIXES"

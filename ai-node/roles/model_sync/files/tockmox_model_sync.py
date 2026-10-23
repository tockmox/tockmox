#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Model store helper for the model_sync role. Standard library only.

  check-hf    <root> <ref> <revision>            fast check of a verified snapshot (exit 0, or 3)
  verify-hf   <root> <ref> <revision> [--token-file F]   hash every file of a snapshot, write the stamp
  check-ollama <root> <ref> <digest>             does the stored manifest hash to the pinned digest
  prune       <root> --desired FILE --keep-days N [--ollama BIN --ollama-host H] [--dry-run]
  report      <root> --desired FILE --out FILE   write the models-present table the facts exporter reads
  audit       <root> --verdict V --kind K --ref R --revision REV [--detail D]

A Hugging Face snapshot holds symlinks into ../../blobs/. A blob is named by what it must hash
to: 64 hex is the SHA-256 of the content (a large LFS file), 40 hex is the git blob SHA-1 (a small
file). That is what makes a pinned revision checkable without trusting the downloader.

One exception, measured on macOS 27 with hf 2.2.0 (2026-10-22): a file stored with Hugging Face's
Xet backend is cached under its Xet hash, which is 64 hex but not the SHA-256 of the content and
cannot be recomputed with the standard library. For such a blob the helper reads the Hub's record
of the file at the pinned commit (the tree API) and requires both: the blob's name is the Xet hash
the Hub lists for that path, and the content's SHA-256 is the LFS SHA-256 the Hub lists for it.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------- naming

def repo_dirname(ref):
    return "models--" + ref.replace("/", "--")


def hub_dir(root):
    return os.path.join(root, "models", "hf", "hub")


def snapshot_dir(root, ref, revision):
    return os.path.join(hub_dir(root), repo_dirname(ref), "snapshots", revision)


def store_dir(root):
    return os.path.join(root, "models", ".tockmox")


def stamp_path(root, ref, revision):
    return os.path.join(store_dir(root), "verified", "%s@%s.json" % (repo_dirname(ref), revision))


def ollama_parts(ref):
    tag = "latest"
    head, _, tail = ref.rpartition(":")
    if head and "/" not in tail:
        ref, tag = head, tail
    parts = ref.split("/")
    if len(parts) == 1:
        return ("registry.ollama.ai", "library", parts[0], tag)
    if len(parts) == 2:
        return ("registry.ollama.ai", parts[0], parts[1], tag)
    return (parts[0], "/".join(parts[1:-1]), parts[-1], tag)


def ollama_manifest(root, ref):
    host, ns, name, tag = ollama_parts(ref)
    return os.path.join(root, "models", "ollama", "manifests", host, ns, name, tag)


def ollama_ref_from_manifest(root, path):
    """The reference Ollama shows for a manifest file, or None for a path that is not one."""
    base = os.path.join(root, "models", "ollama", "manifests")
    rel = os.path.relpath(path, base).split(os.sep)
    if len(rel) < 4:
        return None
    host, ns, tag, name = rel[0], "/".join(rel[1:-2]), rel[-1], rel[-2]
    if host == "registry.ollama.ai" and ns == "library":
        return "%s:%s" % (name, tag)
    if host == "registry.ollama.ai":
        return "%s/%s:%s" % (ns, name, tag)
    return "%s/%s/%s:%s" % (host, ns, name, tag)


# ---------------------------------------------------------------- hashing

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(path):
    size = os.path.getsize(path)
    h = hashlib.sha1()
    h.update(b"blob %d\0" % size)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot_files(snap):
    out = []
    for dirpath, _dirs, files in os.walk(snap):
        for name in files:
            full = os.path.join(dirpath, name)
            out.append((os.path.relpath(full, snap), full))
    return sorted(out)


# ---------------------------------------------------------------- hf

def hub_tree(ref, revision, token=None, endpoint=None, timeout=60):
    """The Hub's record of every file in a model repo at a commit: {path: {size, sha256, xet}}.
    sha256 is the LFS object id (absent for small files); xet is the Xet hash (absent when the file
    is not stored with Xet). Follows the API's Link: rel="next" pages."""
    endpoint = (endpoint or os.environ.get("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
    url = "%s/api/models/%s/tree/%s?recursive=true&expand=true" % (
        endpoint, urllib.parse.quote(ref, safe="/"), urllib.parse.quote(revision, safe=""))
    headers = {"User-Agent": "tockmox-ai-node-model-sync"}
    if token:
        headers["Authorization"] = "Bearer %s" % token
    out = {}
    while url:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
            entries = json.load(r)
            link = r.headers.get("Link", "") or ""
        if not isinstance(entries, list):
            raise ValueError("the Hub's tree answer is not a list")
        for e in entries:
            if not isinstance(e, dict) or e.get("type") != "file" or not isinstance(e.get("path"), str):
                continue
            lfs = e.get("lfs") if isinstance(e.get("lfs"), dict) else {}
            out[e["path"]] = {"size": e.get("size"), "sha256": lfs.get("oid"), "xet": e.get("xetHash")}
        m = re.search(r'<([^>]+)>\s*;\s*rel="next"', link)
        url = m.group(1) if m else None
    return out


def read_token(path):
    if not path:
        return None
    try:
        with open(path) as f:
            return f.read().strip() or None
    except OSError:
        return None


def verify_hf(root, ref, revision, log=print, token=None, fetch_tree=hub_tree):
    """Hash every file in the snapshot against its blob name. Returns (ok, detail).
    A 64-hex blob whose content does not hash to its name is accepted only as a Xet-named blob:
    the Hub's record at this commit must give that name as the file's Xet hash and the content's
    SHA-256 as its LFS SHA-256."""
    if not HEX40.match(revision):
        return False, "revision is not a 40-hex commit"
    snap = snapshot_dir(root, ref, revision)
    if not os.path.isdir(snap):
        return False, "no snapshot at %s" % snap
    files = snapshot_files(snap)
    if not files:
        return False, "the snapshot is empty"
    manifest = {}
    total = 0
    tree = None
    for rel, full in files:
        if not os.path.exists(full):
            return False, "%s is a dangling link" % rel
        blob = os.path.basename(os.path.realpath(full))
        if HEX64.match(blob):
            got = sha256_file(full)
        elif HEX40.match(blob):
            got = git_blob_sha1(full)
        else:
            return False, "%s points at %s, which is not named by a hash" % (rel, blob)
        size = os.path.getsize(full)
        named_by = "sha256" if HEX64.match(blob) else "git-sha1"
        if got != blob:
            if not HEX64.match(blob):
                return False, "%s hashes to %s but its blob is named %s" % (rel, got, blob)
            if tree is None:
                try:
                    tree = fetch_tree(ref, revision, token=token)
                except (OSError, ValueError) as e:
                    return False, ("%s hashes to %s but its blob is named %s, and the Hub's record of the file "
                                   "at %s could not be read to check a Xet name: %s" % (rel, got, blob, revision, e))
            rec = tree.get(rel) or {}
            if rec.get("xet") != blob or rec.get("sha256") != got or rec.get("size") not in (None, size):
                return False, ("%s hashes to %s but its blob is named %s; the Hub lists sha256 %s, xet %s, size %s "
                               "for it at %s" % (rel, got, blob, rec.get("sha256"), rec.get("xet"), rec.get("size"), revision))
            named_by = "xet"
        total += size
        manifest[rel] = {"size": size, "blob": blob, "named_by": named_by}
    stamp = stamp_path(root, ref, revision)
    os.makedirs(os.path.dirname(stamp), exist_ok=True)
    tmp = stamp + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"ref": ref, "revision": revision, "verified_at": int(time.time()),
                   "bytes": total, "files": manifest}, f, sort_keys=True)
    os.replace(tmp, stamp)
    return True, "%d files, %d bytes" % (len(manifest), total)


def check_hf(root, ref, revision):
    """Cheap re-check against the stamp: same files, same sizes, nothing dangling."""
    stamp = stamp_path(root, ref, revision)
    snap = snapshot_dir(root, ref, revision)
    try:
        with open(stamp) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return False, "not verified yet"
    if rec.get("revision") != revision or not os.path.isdir(snap):
        return False, "no snapshot"
    now = {rel: full for rel, full in snapshot_files(snap)}
    if set(now) != set(rec.get("files", {})):
        return False, "the file set changed"
    for rel, meta in rec["files"].items():
        full = now[rel]
        if not os.path.exists(full) or os.path.getsize(full) != meta["size"]:
            return False, "%s changed size" % rel
    return True, "stamp ok"


# ---------------------------------------------------------------- ollama

def check_ollama(root, ref, digest):
    path = ollama_manifest(root, ref)
    if not os.path.isfile(path):
        return False, "no manifest at %s" % path
    want = digest.split(":", 1)[-1]
    got = sha256_file(path)
    if got != want:
        return False, "manifest hashes to sha256:%s, pinned sha256:%s" % (got, want)
    return True, "manifest digest ok"


# ---------------------------------------------------------------- audit

def audit_line(root, verdict, kind, ref, revision, detail="", now=None):
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now if now is not None else time.time())),
        "tockmox_audit": 1,
        "audit_schema": "v0",
        "event": "update_event",
        "artifact": "%s:%s" % (kind, ref),
        "bundle_version": revision,
        "signature_identity": "pinned-revision",
        "verdict": verdict,
        "source": kind,
        "host": socket.gethostname().split(".")[0],
        "detail": detail,
    }
    path = os.path.join(root, "var", "audit", "model-updates.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # The directory is group-writable (the converge and service accounts both append), so the
    # last component could be a link put there by the other account: never follow it.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o664)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
        try:
            os.fchmod(f.fileno(), 0o664)
        except OSError:
            pass  # the file belongs to the other account; its mode was set when it was created
    return rec


# ---------------------------------------------------------------- prune

def load_desired(path):
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("desired must be a JSON list")
    return data


def hf_inventory(root):
    """{repo dirname: [revision, ...]} for what is in the cache."""
    inv = {}
    hub = hub_dir(root)
    if not os.path.isdir(hub):
        return inv
    for name in sorted(os.listdir(hub)):
        if not name.startswith("models--"):
            continue
        snaps = os.path.join(hub, name, "snapshots")
        revs = sorted(os.listdir(snaps)) if os.path.isdir(snaps) else []
        inv[name] = revs
    return inv


def ollama_inventory(root):
    base = os.path.join(root, "models", "ollama", "manifests")
    refs = []
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            ref = ollama_ref_from_manifest(root, os.path.join(dirpath, name))
            if ref:
                refs.append(ref)
    return sorted(refs)


def remove_hf_revision(root, dirname, revision):
    repo = os.path.join(hub_dir(root), dirname)
    try:
        os.remove(os.path.join(store_dir(root), "verified", "%s@%s.json" % (dirname, revision)))
    except OSError:
        pass
    shutil.rmtree(os.path.join(repo, "snapshots", revision), ignore_errors=True)
    refs = os.path.join(repo, "refs")
    if os.path.isdir(refs):
        for dirpath, _d, files in os.walk(refs):
            for n in files:
                p = os.path.join(dirpath, n)
                try:
                    with open(p) as f:
                        if f.read().strip() == revision:
                            os.remove(p)
                except OSError:
                    pass
    snaps = os.path.join(repo, "snapshots")
    left = os.listdir(snaps) if os.path.isdir(snaps) else []
    if not left:
        shutil.rmtree(repo, ignore_errors=True)
        return
    keep = set()
    for rev in left:
        for _rel, full in snapshot_files(os.path.join(snaps, rev)):
            keep.add(os.path.basename(os.path.realpath(full)))
    blobs = os.path.join(repo, "blobs")
    if os.path.isdir(blobs):
        for b in os.listdir(blobs):
            if b not in keep:
                os.remove(os.path.join(blobs, b))


def prune(root, desired, keep_days, ollama=None, ollama_host=None, dry_run=False, now=None):
    now = int(now if now is not None else time.time())
    if not desired:
        raise SystemExit("refusing to prune: the desired list is empty (an empty list is a mistake, not a request to delete every model)")
    want_hf = {}
    want_ollama = set()
    for item in desired:
        art = item["artifact"]
        if art["kind"] == "huggingface":
            want_hf.setdefault(repo_dirname(art["ref"]), set()).add(art["revision"])
        elif art["kind"] == "ollama":
            want_ollama.add(art["ref"] if ":" in art["ref"].rsplit("/", 1)[-1] else art["ref"] + ":latest")
    candidates = []
    for dirname, revs in hf_inventory(root).items():
        for rev in revs:
            if rev not in want_hf.get(dirname, set()):
                candidates.append(("hf", dirname, rev, "%s@%s" % (dirname, rev)))
    for ref in ollama_inventory(root):
        if ref not in want_ollama:
            candidates.append(("ollama", ref, "", "ollama:%s" % ref))
    track_path = os.path.join(store_dir(root), "unreferenced.json")
    try:
        with open(track_path) as f:
            seen = json.load(f)
    except (OSError, ValueError):
        seen = {}
    keys = {c[3] for c in candidates}
    seen = {k: v for k, v in seen.items() if k in keys}
    removed, pending = [], []
    for kind, a, b, key in candidates:
        first = seen.setdefault(key, now)
        if now - first >= keep_days * 86400:
            removed.append(key)
            if dry_run:
                continue
            if kind == "hf":
                remove_hf_revision(root, a, b)
                audit_line(root, "removed", "huggingface", a.replace("models--", "", 1).replace("--", "/"), b,
                           "unreferenced for %d days" % ((now - first) // 86400), now)
            else:
                if ollama:
                    env = dict(os.environ)
                    if ollama_host:
                        env["OLLAMA_HOST"] = ollama_host
                    subprocess.run([ollama, "rm", a], env=env, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                audit_line(root, "removed", "ollama", a, "", "unreferenced for %d days" % ((now - first) // 86400), now)
            seen.pop(key, None)
        else:
            pending.append({"key": key, "days_left": int((first + keep_days * 86400 - now) // 86400) + 1})
    if not dry_run:
        os.makedirs(store_dir(root), exist_ok=True)
        tmp = track_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(seen, f, sort_keys=True)
        os.replace(tmp, track_path)
    return {"removed": sorted(removed), "pending": sorted(pending, key=lambda p: p["key"])}


# ---------------------------------------------------------------- report

def report(root, desired, out):
    """One tab-separated line per desired model that is on disk now: model, revision, kind, path."""
    lines = []
    for item in desired:
        art = item["artifact"]
        if art["kind"] == "huggingface":
            path = snapshot_dir(root, art["ref"], art["revision"])
            if os.path.isdir(path):
                lines.append("\t".join([item["model"], art["revision"], "huggingface", path]))
        elif art["kind"] == "ollama":
            path = ollama_manifest(root, art["ref"])
            if os.path.isfile(path):
                lines.append("\t".join([item["model"], art["revision"], "ollama", path]))
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        f.write("".join(l + "\n" for l in sorted(lines)))
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)
    return len(lines)


# ---------------------------------------------------------------- cli

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("check-hf", "verify-hf"):
        s = sub.add_parser(name)
        s.add_argument("root")
        s.add_argument("ref")
        s.add_argument("revision")
        if name == "verify-hf":
            s.add_argument("--token-file", default="")
    s = sub.add_parser("check-ollama")
    s.add_argument("root")
    s.add_argument("ref")
    s.add_argument("digest")
    s = sub.add_parser("prune")
    s.add_argument("root")
    s.add_argument("--desired", required=True)
    s.add_argument("--keep-days", type=int, required=True)
    s.add_argument("--ollama")
    s.add_argument("--ollama-host")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("report")
    s.add_argument("root")
    s.add_argument("--desired", required=True)
    s.add_argument("--out", required=True)
    s = sub.add_parser("audit")
    s.add_argument("root")
    s.add_argument("--verdict", required=True)
    s.add_argument("--kind", required=True)
    s.add_argument("--ref", required=True)
    s.add_argument("--revision", default="")
    s.add_argument("--detail", default="")
    a = p.parse_args(argv)

    if a.cmd == "check-hf":
        ok, msg = check_hf(a.root, a.ref, a.revision)
        print(msg)
        return 0 if ok else 3
    if a.cmd == "verify-hf":
        ok, msg = verify_hf(a.root, a.ref, a.revision, token=read_token(a.token_file))
        print(msg)
        return 0 if ok else 3
    if a.cmd == "check-ollama":
        ok, msg = check_ollama(a.root, a.ref, a.digest)
        print(msg)
        return 0 if ok else 3
    if a.cmd == "prune":
        res = prune(a.root, load_desired(a.desired), a.keep_days, a.ollama, a.ollama_host, a.dry_run)
        print(json.dumps(res, sort_keys=True))
        return 0
    if a.cmd == "report":
        print(report(a.root, load_desired(a.desired), a.out))
        return 0
    if a.cmd == "audit":
        audit_line(a.root, a.verdict, a.kind, a.ref, a.revision, a.detail)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

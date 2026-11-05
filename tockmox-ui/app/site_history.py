# SPDX-License-Identifier: Apache-2.0
"""Platform > Site history: where the site's history lives, whether the off-site copy holds it, and whether the last
rebuild drill passed (specs/site-forge/SPEC.md "Keeping it safe" and "Rebuilding" in the planning repo).

One pure function, `view`, turns what the sources say into what the page shows, so every state is tested from a
fixture. It reads:

  state    tockmox-actions' /v1/forge/state: main's commit and time from the forge, and the two CronJobs
           bootstrap-forge makes (<release>-offsite, <release>-drill-check) with their destination and drill settings
  jobs     the CronJobs' rows from kube-state-metrics (last success, whether the newest run failed)
  alerts   the active alerts: the three the observability layer raises for the site repository are the same words
           the page uses, so the page and the phone never disagree

The copy job succeeds only when the destination holds the forge's current main (install/forge-offsite-copy.sh), so a
success at or after main's commit means the copy MATCHES; before that it is PENDING for 15 minutes (the alert's
window) and BEHIND after. The drill check succeeds only when the last drill on record passed and is younger than its
limit, so its success is the drill's state; the record's own date and time taken are the drill's, kept at the
destination.
"""
from __future__ import annotations

from datetime import datetime, timezone

PENDING_S = 15 * 60                  # the copy-behind alert's window (charts/tockmox-observability siteForge)
DRILL_CHECK_S = 26 * 3600            # siteForge.drillCheckHours: the drill check runs daily
COPY_BEHIND = "TockmoxSiteRepositoryCopyBehind"
NO_COPY = "TockmoxSiteRepositoryNoOffsiteCopy"
DRILL_OVERDUE = "TockmoxSiteRebuildDrillOverdue"


def _ts(iso: str) -> float | None:
    try:
        return datetime.fromisoformat(str(iso).replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def _mins(s: float) -> str:
    m = int(s // 60)
    if m < 60:
        return f"{m} minute{'s' if m != 1 else ''}"
    h = m // 60
    return f"{h} hour{'s' if h != 1 else ''}" if h < 48 else f"{h // 24} days"


def view(state: dict | None, jobs: list | None, alerts: list | None, now: float, jobs_known: bool = True,
         alerts_known: bool = True) -> dict:
    """{"repo": {...}, "offsite": {...}, "drill": {...}} each with state (ok | warning | critical | unknown), a word and a
    sentence; jobs_known/alerts_known False when that source did not answer (its absence is not good news)."""
    st = state or {}
    ns = st.get("jobs_namespace", "")
    firing = {a.get("name"): a for a in alerts or []}

    def row(cj):
        if not cj:
            return None
        return next((j for j in jobs or [] if j.get("namespace") == ns and j.get("name") == cj.get("name")), None)

    main = st.get("main") or {}
    main_t = _ts(main.get("time", ""))
    if st.get("paused"):
        repo = {"state": "warning", "word": "Not answering",
                "text": "The site's forge is not answering. Argo CD keeps running what is applied, and nothing new "
                        "can be approved until it is back."}
    elif main.get("sha"):
        repo = {"state": "ok", "word": "Answering",
                "text": f"main is at {main['sha'][:7]}" + (f", made {_mins(now - main_t)} ago" if main_t else "") + "."}
    else:
        repo = {"state": "unknown", "word": "Unknown",
                "text": "The forge's main could not be read" + (f": {st['main_error']}" if st.get("main_error") else ".")}

    # ---- the off-site copy
    cj = st.get("copy")
    r = row(cj)
    copy_unread = any(n.endswith("-offsite") for n in st.get("unreadable", []))
    if NO_COPY in firing or (cj is None and not copy_unread and not st.get("paused") and state is not None):
        a = firing.get(NO_COPY) or {}
        copy = {"state": "warning", "word": "No off-site copy",
                "text": a.get("summary") or "This site's history has no off-site copy: if the forge's volume is lost, "
                                            "so is every change not yet copied. Set a destination with bootstrap-forge.",
                "silenced": a.get("silenced"), "none": True}
    elif cj is None:
        copy = {"state": "unknown", "word": "Unknown", "text": "The copy job could not be read."}
    else:
        dest = cj.get("destination") or "an unnamed destination"
        how = {"bucket": "a bucket", "git": "a git remote"}.get(cj.get("mode", ""), "a destination")
        base = {"destination": dest, "how": how, "name": cj.get("name"), "suspended": cj.get("suspended")}
        last = (r or {}).get("last_success")
        if not jobs_known:
            copy = dict(base, state="unknown", word="Unknown", text="kube-state-metrics did not answer, so when the "
                        "copy last succeeded is not known. That is not the same as it being behind.")
        elif COPY_BEHIND in firing:
            a = firing[COPY_BEHIND]
            copy = dict(base, state="critical", word="Behind", silenced=a.get("silenced"),
                        text=a.get("summary") or "The off-site copy has not held the forge's main for 15 minutes.")
        elif cj.get("suspended"):
            copy = dict(base, state="warning", word="Suspended", text="The copy job is suspended, so nothing new is copied.")
        elif last and main_t and last >= main_t:
            copy = dict(base, state="ok", word="Matches",
                        text=f"The copy at {dest} held main {_mins(now - last)} ago, after main's last change.")
        elif main_t and now - main_t < PENDING_S:
            copy = dict(base, state="unknown", word="Copy pending",
                        text=f"main changed {_mins(now - main_t)} ago; the copy runs every minute and is checked for "
                             "15 minutes before it counts as behind.")
        elif last is None:
            copy = dict(base, state="warning", word="Not copied yet",
                        text="The copy job has never succeeded" + (" (its newest run failed)." if (r or {}).get("last_failed") else "."))
        elif main_t:
            copy = dict(base, state="critical", word="Behind",
                        text=f"main changed {_mins(now - main_t)} ago and the copy last held it {_mins(now - last)} ago.")
        else:
            copy = dict(base, state="unknown", word="Unknown", text="main's time could not be read, so the copy cannot be compared.")

    # ---- the last rebuild drill
    dj = st.get("drill")
    d = row(dj)
    if dj is None:
        unread = state is None or any(n.endswith("-drill-check") for n in st.get("unreadable", []))
        drill = {"state": "unknown", "word": "Unknown" if unread else "Not set up",
                 "text": "The drill check could not be read." if unread else
                         "This forge has no drill check yet: re-run bootstrap-forge to add it, then run "
                         "tockmox-install.sh rebuild-drill."}
    else:
        limit = f"{dj.get('max_days') or '92'} days"
        base = {"name": dj.get("name"), "limit": limit}
        last = (d or {}).get("last_success")
        if not jobs_known and DRILL_OVERDUE not in firing:
            drill = dict(base, state="unknown", word="Unknown", text="kube-state-metrics did not answer, so the drill "
                         "check's last result is not known.")
        elif DRILL_OVERDUE in firing:
            a = firing[DRILL_OVERDUE]
            drill = dict(base, state="critical", word="Failed or overdue", silenced=a.get("silenced"),
                         text=a.get("summary") or f"The last rebuild drill failed, or passed more than {limit} ago.")
        elif (d or {}).get("last_failed"):
            drill = dict(base, state="critical", word="Failed or overdue",
                         text=f"The drill check's newest run failed: the last drill failed, passed more than {limit} "
                              "ago, or none is on record yet. Its log says which.")
        elif last and now - last < DRILL_CHECK_S:
            drill = dict(base, state="ok", word="Passed",
                         text=f"The last drill on record passed and is within {limit} (checked {_mins(now - last)} ago).")
        elif last is None:
            drill = dict(base, state="unknown", word="Not checked yet", text="The drill check has not run yet.")
        else:
            drill = dict(base, state="warning", word="Not checked lately",
                         text=f"The drill check last succeeded {_mins(now - last)} ago.")
    # "offsite", not "copy": in a template v.copy is the dict's own copy() method, not this key
    return {"repo": repo, "offsite": copy, "drill": drill,
            "sources": {"jobs": jobs_known, "alerts": alerts_known}}

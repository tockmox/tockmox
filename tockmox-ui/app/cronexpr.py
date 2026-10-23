# SPDX-License-Identifier: Apache-2.0
"""A small five-field cron evaluator: next and previous fire times, in a named time zone.

Enough for Kubernetes CronJob and Argo CronWorkflow schedules: numbers, `*`, lists, ranges,
steps, three-letter month and day names, and the @hourly/@daily/@weekly/@monthly/@yearly macros.
Day-of-month and day-of-week follow robfig/cron, the parser Kubernetes and Argo use: when both
fields are restricted a day matches if EITHER matches, and a field that starts with `*` (`*`, `*/2`)
is not restricted, so `0 0 */2 * 1` means Mondays that fall on an odd day. A leading
`CRON_TZ=<zone>` overrides the zone it is given.

Not supported (refused with ValueError, never guessed): `L`, `W`, `#`, `?`, seconds fields.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

_MACROS = {"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
           "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"}
_MON = {n: i for i, n in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split(), 1)}
_DOW = {n: i for i, n in enumerate("sun mon tue wed thu fri sat".split())}


def _field(text: str, lo: int, hi: int, names: dict | None = None) -> tuple[set[int], bool]:
    """Returns (values, restricted). restricted is False for a field that starts with `*` (robfig's
    star bit), so `*/2` in a day field still combines with the other day field by AND."""
    out: set[int] = set()
    for part in text.lower().split(","):
        if not part.strip():
            raise ValueError(f"{text!r} has an empty list item")
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
            if step < 1:
                raise ValueError("step must be >= 1")
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            x, y = part.split("-", 1)
            a, b = _val(x, names), _val(y, names)
        else:
            a = _val(part, names)
            b = hi if step != 1 else a
        if a < lo or b > hi or a > b:
            raise ValueError(f"{text!r} is out of range {lo}-{hi}")
        out.update(range(a, b + 1, step))
    return out, not text.strip().startswith("*")


def _val(x: str, names):
    if names and x in names:
        return names[x]
    if not x.isdigit():
        raise ValueError(f"unsupported cron token {x!r}")
    return int(x)


class Cron:
    def __init__(self, expr: str, tz: str = "UTC"):
        raw = expr.strip()
        if raw.startswith(("CRON_TZ=", "TZ=")):
            head, raw = raw.split(None, 1)
            tz = head.split("=", 1)[1]
        raw = _MACROS.get(raw, raw)
        parts = raw.split()
        if len(parts) != 5:
            raise ValueError(f"expected five cron fields, got {len(parts)}")
        self.expr, self.tz = expr.strip(), ZoneInfo(tz or "UTC")
        self.minutes, _ = _field(parts[0], 0, 59)
        self.hours, _ = _field(parts[1], 0, 23)
        self.dom, self.dom_r = _field(parts[2], 1, 31)
        self.months, _ = _field(parts[3], 1, 12, _MON)
        dow, self.dow_r = _field(parts[4], 0, 7, _DOW)
        self.dow = {d % 7 for d in dow}

    def _day_ok(self, d: datetime) -> bool:
        if d.month not in self.months:
            return False
        dom_ok = d.day in self.dom
        dow_ok = (d.isoweekday() % 7) in self.dow
        if self.dom_r and self.dow_r:
            return dom_ok or dow_ok
        return dom_ok and dow_ok        # robfig: either field starred means both must match

    def _scan(self, start_ts: float, direction: int) -> float | None:
        """Walk local wall-clock time minute by minute, skipping whole days and hours that cannot
        match, for at most a little over four years. Wall times that do not exist (spring-forward)
        are skipped; ambiguous ones (fall-back) take the first occurrence."""
        t = datetime.fromtimestamp(start_ts, self.tz).replace(second=0, microsecond=0, tzinfo=None)
        t += timedelta(minutes=direction)
        limit = 366 * 4 * 24 * 60
        n = 0
        while n < limit:
            if not self._day_ok(t):
                t = (t.replace(hour=0, minute=0) + timedelta(days=1)) if direction > 0 else (t.replace(hour=23, minute=59) - timedelta(days=1))
                n += 1440
                continue
            if t.hour not in self.hours:
                t = (t.replace(minute=0) + timedelta(hours=1)) if direction > 0 else (t.replace(minute=59) - timedelta(hours=1))
                n += 60
                continue
            if t.minute in self.minutes:
                aware = t.replace(tzinfo=self.tz, fold=0)
                back = aware.astimezone(timezone.utc).astimezone(self.tz).replace(tzinfo=None)
                if back == t:   # a real wall time
                    return aware.timestamp()
            t += timedelta(minutes=direction)
            n += 1
        return None

    def next_after(self, ts: float) -> float | None:
        return self._scan(ts, +1)

    def prev_before(self, ts: float) -> float | None:
        """The most recent fire time at or before ts."""
        return self._scan(ts + 60, -1)

    def interval_hint(self, ts: float) -> float | None:
        """Seconds between the last fire and the next one around ts: the cadence a reader expects."""
        p, n = self.prev_before(ts), self.next_after(ts)
        return (n - p) if (p and n) else None


def describe(expr: str) -> str:
    """Plain-English cadence for the common shapes; the raw expression otherwise."""
    raw = expr.strip()
    if raw.startswith(("CRON_TZ=", "TZ=")):
        raw = raw.split(None, 1)[1]
    raw = _MACROS.get(raw, raw)
    p = raw.split()
    if len(p) != 5:
        return expr
    m, h, dom, mon, dow = p
    days = {"*": "", "1-5": "weekdays", "0": "Sundays", "1": "Mondays", "2": "Tuesdays", "3": "Wednesdays",
            "4": "Thursdays", "5": "Fridays", "6": "Saturdays", "0,6": "weekends", "1,4": "Mondays and Thursdays"}
    if m.isdigit() and h == "*" and dom == mon == dow == "*":
        return f"hourly at :{int(m):02d}"
    if m.startswith("*/") and h == dom == mon == dow == "*":
        return f"every {m[2:]} minutes"
    if m.isdigit() and h.isdigit() and mon == "*":
        at = f"{int(h):02d}:{int(m):02d}"
        if dom == "*" and dow in days:
            return f"daily at {at}" if dow == "*" else f"{days[dow]} at {at}"
        if dom.isdigit() and dow == "*":
            return f"monthly on day {dom} at {at}"
    return expr

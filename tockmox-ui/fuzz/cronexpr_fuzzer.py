# SPDX-License-Identifier: Apache-2.0
"""Fuzz the cron evaluator (app/cronexpr.py) that the Platform page uses to say when a schedule is due or late.

Schedules come from the cluster (CronJobs, Argo CronWorkflows) and from the catalog, so the evaluator must refuse what
it cannot read, and answer correctly for what it accepts. The properties:

  1. Cron(expr, tz) either builds or raises ValueError / ZoneInfoNotFoundError, its documented refusals.
  2. next_after(ts), when it answers, is later than ts, on a whole minute, and a time the expression fires at in the
     schedule's zone (minute, hour, month, and the robfig day-of-month / day-of-week rule), and no fire time in the
     day after ts was skipped on the way to it.
  3. prev_before(ts), when it answers, is at or before ts and earlier than next_after(ts), and is also a fire time.

Run it in ClusterFuzzLite (.clusterfuzzlite/), or locally with atheris installed:
    python3 tockmox-ui/fuzz/cronexpr_fuzzer.py -max_total_time=60
"""
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfoNotFoundError

import atheris

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

with atheris.instrument_imports():
    from app import cronexpr

# A plain zone, a DST zone, a 30-minute DST shift and a 45-minute offset: the wall-clock edge cases the scan handles.
ZONES = ("UTC", "America/Chicago", "Australia/Lord_Howe", "Pacific/Chatham")
TS_MAX = 4102444800   # 2100-01-01T00:00Z
WINDOW = 86400        # how far past ts the brute-force completeness check looks


def fires_at(c: "cronexpr.Cron", ts: float) -> bool:
    """Judged here from the parsed fields, not with the evaluator's own day test, so a fault in that test shows."""
    t = datetime.fromtimestamp(ts, c.tz)
    if t.second or t.minute not in c.minutes or t.hour not in c.hours or t.month not in c.months:
        return False
    dom_ok, dow_ok = t.day in c.dom, (t.isoweekday() % 7) in c.dow
    # robfig/cron: both day fields restricted -> either may match; otherwise both must
    return (dom_ok or dow_ok) if (c.dom_r and c.dow_r) else (dom_ok and dow_ok)


def check(expr: str, tz: str, ts: int) -> None:
    try:
        c = cronexpr.Cron(expr, tz)
    except (ValueError, ZoneInfoNotFoundError):
        return
    cronexpr.describe(expr)
    n = c.next_after(ts)
    if n is not None:
        assert n > ts and n % 60 == 0, (expr, tz, ts, n)
        assert fires_at(c, n), (expr, tz, ts, n)
    # and none was skipped: no fire time in the day after ts comes before the one it named (brute force, minute by minute)
    first = (ts // 60 + 1) * 60
    end = min(int(n) if n is not None else first + WINDOW, first + WINDOW)
    for m in range(first, end, 60):
        assert not fires_at(c, m), (expr, tz, ts, m, n)
    p = c.prev_before(ts)
    if p is not None:
        assert p <= ts and p % 60 == 0, (expr, tz, ts, p)
        assert fires_at(c, p), (expr, tz, ts, p)
        assert n is None or p < n, (expr, tz, ts, p, n)


def test_one_input(data: bytes) -> None:
    fdp = atheris.FuzzedDataProvider(data)
    tz = ZONES[fdp.ConsumeIntInRange(0, len(ZONES) - 1)]
    ts = fdp.ConsumeIntInRange(0, TS_MAX)
    expr = fdp.ConsumeUnicodeNoSurrogates(fdp.remaining_bytes())
    check(expr, tz, ts)


def main() -> None:
    atheris.Setup(sys.argv, test_one_input)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

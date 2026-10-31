# SPDX-License-Identifier: Apache-2.0
"""The last build check (TM-0934), shared by the node pages and the Models page (TM-1296).

Git holds the build each model is pinned to; the node holds the one it actually serves. A check reads every pinned Ollama and
Hugging Face route's node through the probe's fences and keeps the answer in memory only (the UI writes nothing). An old check
does not vouch for today (AC-48.4's rule): after MAX_AGE_S it reads Unknown again.

  BuildChecks(prober).rows(lifecycle, inventory) -> [models.DriftRow]    what the page shows now
  BuildChecks(prober).run(lifecycle, inventory)                          the check itself (POST /models/builds)
"""
from __future__ import annotations

import datetime

from . import models as ml
from .probe import Refused

MAX_AGE_S = 3600


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


class BuildChecks:
    def __init__(self, prober=None):
        self.prober = prober
        self.at = None                  # when the last check ran
        self.readings: dict = {}        # (node id, endpoint id) -> probe.BuildReading, or a string saying why not

    @property
    def probe_on(self) -> bool:
        return self.prober is not None and self.prober.enabled

    def rows(self, lc: ml.Lifecycle, inv) -> list:
        if not self.probe_on:
            return ml.build_drift(lc, inv, {}, "probing is off: set inferenceNodes.probe.allowedCidrs to read the nodes")
        if self.at is None:
            return ml.build_drift(lc, inv, {}, "not checked yet")
        age = (_now() - self.at).total_seconds()
        if age > MAX_AGE_S or age < -60:
            return ml.build_drift(lc, inv, {}, f"last checked over {MAX_AGE_S // 60} minutes ago: check again")
        return ml.build_drift(lc, inv, self.readings)

    def run(self, lc: ml.Lifecycle, inv) -> None:
        """Read each (node, endpoint) once. With probing off nothing is read and nothing changes."""
        if not self.probe_on:
            return
        readings = {}
        for _e, r in ml.drift_targets(lc, inv):
            key = (r.node, r.endpoint)
            n = inv.node(r.node)
            ep = n.endpoint(r.endpoint) if n else None
            if key in readings or ep is None:
                continue
            try:
                readings[key] = self.prober.read_builds(ep.url, ep.engine)
            except Refused as ex:
                readings[key] = str(ex)
        self.readings, self.at = readings, _now()

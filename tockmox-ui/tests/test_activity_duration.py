# SPDX-License-Identifier: Apache-2.0
"""Activity names a silence's length the way the form offered it: 7 days, not 168h. The stored value stays hours.

Run from tockmox-ui/: python -m pytest tests/test_activity_duration.py
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import actions as act  # noqa: E402


def silence(hours):
    return act.intent("silence", {"part": "layer-ai", "label": "Forgejo",
                                  "alerts": [{"alertname": "KubePodNotReady", "namespace": "forgejo"}]},
                      {"hours": hours, "reason": "planned work"}, "a")


@pytest.mark.parametrize("hours,said", [(1, "1 hour"), (4, "4 hours"), (24, "24 hours"), (168, "7 days"),
                                        (72, "3 days"), (50, "2 days, 2 hours")])
def test_activity_row_names_the_length_in_the_form_s_words(hours, said):
    row = act.describe(silence(hours))["summary"]
    assert row.endswith(f" for {said}"), row
    assert "168h" not in row and f"{hours}h" not in row


def test_the_stored_value_is_still_hours():
    it = silence(168)
    act.describe(it)
    assert it["params"]["hours"] == 168


@pytest.mark.parametrize("minutes,said", [(30, "30 minutes"), (1, "1 minute"), (60, "1 hour"), (90, "1 hour, 30 minutes"),
                                          (120, "2 hours"), (1440, "24 hours"), (2880, "2 days"),
                                          (10080, "7 days"), (10080 + 120 + 30, "7 days, 2 hours, 30 minutes")])
def test_a_duration_of_any_size_reads_in_days_hours_and_minutes(minutes, said):
    assert act.human_span(minutes) == said

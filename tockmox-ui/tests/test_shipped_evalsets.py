# SPDX-License-Identifier: Apache-2.0
"""The eval sets the runner ships with (app/evalsets/<class>/<version>/): every one loads, is big enough to count as
evidence, and has graders that can fail. A grader that cannot go red makes a verdict meaningless, so each set is
checked three ways: the runner's known-bad control must fail it, a hand-written correct reply must pass each of a
spread of cases (and a plausible wrong one must not), and every case is checked for the structural mistakes that
make a grader unfair (an expected argument the offered tool would reject, a copy target that is not in the prompt)."""
import json
import os

import jsonschema
import pytest

from app.runner import evalset, legs

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "evalsets")


def _dirs():
    out = []
    for klass in sorted(os.listdir(ROOT)):
        for version in sorted(os.listdir(os.path.join(ROOT, klass))):
            out.append((klass, version))
    return out


SHIPPED = _dirs()
IDS = [f"{k}/{v}" for k, v in SHIPPED]
_cache = {}


def load(klass, version="v1"):
    if (klass, version) not in _cache:
        _cache[(klass, version)] = evalset.load(os.path.join(ROOT, klass, version))
    return _cache[(klass, version)]


def case(es, cid):
    return next(c for c in es.cases if c.id == cid)


def say(text):
    return {"content": text, "tool_calls": [], "finish_reason": "stop"}


def call(name, **args):
    return {"content": "", "tool_calls": [{"name": name, "arguments": json.dumps(args)}], "finish_reason": "tool_calls"}


def passes(es, cid, reply):
    return evalset.grade(case(es, cid), reply if isinstance(reply, dict) else say(reply))[0]


def test_both_classes_are_shipped():
    assert {"large/v1", "agent/v1"} <= set(IDS)


# ------------------------------------------------------------------ every set loads and counts as evidence

@pytest.mark.parametrize("klass,version", SHIPPED, ids=IDS)
def test_a_shipped_set_loads_and_is_not_a_screening_set(klass, version):
    es = load(klass, version)
    assert (es.klass, es.version) == (klass, version) and es.id == klass
    assert es.classification == "public"          # it runs on any eval route, hosted or local
    assert len(es.cases) >= 30                    # fewer than 30 cases is screening: it can never say "better"
    assert len({c.id for c in es.cases}) == len(es.cases)
    assert es.epochs == 1 and 0 < es.bar < 1 and "\n" not in es.criterion
    for c in es.cases:
        assert 64 <= (c.max_tokens or es.max_tokens) <= 600, c.id
        assert c.messages[-1]["role"] == "user", f"{c.id}: a case ends on the user's turn"
    raw = open(os.path.join(ROOT, klass, version, "set.yaml")).read()
    assert raw.startswith("# SPDX-License-Identifier: Apache-2.0")


def test_the_large_set_shape():
    es = load("large")
    kinds = {}
    for c in es.cases:
        kinds[c.grade["type"]] = kinds.get(c.grade["type"], 0) + 1
    assert len(es.cases) == 48 and kinds == {"exact": 13, "json_schema": 10, "regex": 18, "contains": 7}
    assert es.bar == 0.85 and es.margin == 0.05 and es.min_effect == 0.05


def test_the_agent_set_shape():
    es = load("agent")
    kinds = {}
    for c in es.cases:
        kinds[c.grade["type"]] = kinds.get(c.grade["type"], 0) + 1
    assert len(es.cases) == 48 and kinds == {"tool_call": 36, "no_tool_call": 12}
    import yaml
    meta = yaml.safe_load(open(os.path.join(ROOT, "agent", "v1", "set.yaml")))
    assert meta["tool_parse_bar"] == 0.02 and es.bar == 0.85


# ------------------------------------------------------------------ the known-bad control

@pytest.mark.parametrize("klass,version", SHIPPED, ids=IDS)
def test_the_known_bad_control_fails_each_set(klass, version):
    res = legs.control(load(klass, version))
    assert res["passed"] is False, res
    assert res["pass_rate"] <= 0.3, res           # only a no_tool_call case may pass a reply that is wrong everywhere


def test_no_text_grader_accepts_the_control_reply():
    for klass, version in SHIPPED:
        for c in load(klass, version).cases:
            if c.grade["type"] not in ("no_tool_call",):
                assert not evalset.grade(c, say("known-bad control"))[0], c.id


# ------------------------------------------------------------------ structural checks on every case

def _sample(prop_schema, value):
    jsonschema.validate(value, prop_schema)


@pytest.mark.parametrize("klass,version", SHIPPED, ids=IDS)
def test_offered_tools_are_well_formed_and_expected_calls_are_legal(klass, version):
    es = load(klass, version)
    for c in es.cases:
        names = []
        for t in c.tools:
            assert t["type"] == "function"
            f = t["function"]
            jsonschema.Draft202012Validator.check_schema(f["parameters"])
            names.append(f["name"])
        assert len(names) == len(set(names)), c.id
        if c.grade["type"] == "tool_call":
            g = c.grade
            assert g["name"] in names, f"{c.id}: the expected tool is not offered"
            params = next(t["function"]["parameters"] for t in c.tools if t["function"]["name"] == g["name"])
            assert g["arguments"], c.id
            for k, v in g["arguments"].items():
                assert k in params["properties"], f"{c.id}: {k} is not a parameter of {g['name']}"
                _sample(params["properties"][k], v)       # the expected value is one the tool would accept
        if c.grade["type"] == "no_tool_call":
            assert len(names) >= 2, c.id                  # a lone tool makes "do not call it" a trick


@pytest.mark.parametrize("klass,version", SHIPPED, ids=IDS)
def test_tool_messages_follow_the_call_that_asked_for_them(klass, version):
    for c in load(klass, version).cases:
        open_ids = set()
        for m in c.messages:
            if m["role"] == "assistant" and m.get("tool_calls"):
                open_ids = {tc["id"] for tc in m["tool_calls"]}
            if m["role"] == "tool":
                assert m["tool_call_id"] in open_ids, f"{c.id}: a tool result with no call"


def test_every_tool_call_case_passes_its_own_expected_call_and_fails_the_obvious_mistakes():
    es = load("agent")
    for c in es.cases:
        if c.grade["type"] != "tool_call":
            continue
        g = c.grade
        assert evalset.grade(c, call(g["name"], **g["arguments"]))[0], c.id
        assert evalset.grade(c, call(g["name"], **g["arguments"], zz_extra="ok"))[0], c.id     # extra arguments are fine
        other = next(t["function"]["name"] for t in c.tools if t["function"]["name"] != g["name"])
        assert not evalset.grade(c, call(other, **g["arguments"]))[0], c.id                    # the wrong tool
        assert not evalset.grade(c, say("I would call it."))[0], c.id                          # no call
        two = {"content": "", "tool_calls": call(g["name"], **g["arguments"])["tool_calls"] * 2}
        assert not evalset.grade(c, two)[0], c.id                                              # two calls
        k, v = next(iter(g["arguments"].items()))
        bad = dict(g["arguments"])
        bad[k] = (v + "x" if isinstance(v, str) else (not v) if isinstance(v, bool) else v + 1 if isinstance(v, (int, float))
                  else v + ["x"] if isinstance(v, list) else {"kind": "x"})
        assert not evalset.grade(c, call(g["name"], **bad))[0], c.id                           # a wrong value


def test_every_no_tool_case_takes_an_answer_and_refuses_any_call():
    es = load("agent")
    for c in es.cases:
        if c.grade["type"] == "no_tool_call":
            assert evalset.grade(c, say("Here is the answer."))[0], c.id
            assert not evalset.grade(c, call(c.tools[0]["function"]["name"]))[0], c.id


def test_every_copy_case_asks_for_text_that_is_in_the_prompt_and_judges_it_exactly():
    es = load("large")
    n = 0
    for c in es.cases:
        if c.grade["type"] != "exact":
            continue
        n += 1
        v = c.grade["value"]
        assert v in c.messages[-1]["content"], c.id
        assert "Reply with only the text" in c.messages[-1]["content"], c.id
        assert evalset.grade(c, say(v))[0] and evalset.grade(c, say("\n" + v + "\n"))[0], c.id   # a trailing newline is harmless
        assert not evalset.grade(c, say(v[:-1]))[0] and not evalset.grade(c, say(v + v[-1]))[0], c.id
        assert not evalset.grade(c, say("```\n" + v + "\n```"))[0], c.id                          # a code fence is a different reply
    assert n >= 10


def test_every_json_case_has_a_valid_schema_that_rejects_empty_and_prose():
    es = load("large")
    n = 0
    for c in es.cases:
        if c.grade["type"] != "json_schema":
            continue
        n += 1
        jsonschema.Draft202012Validator.check_schema(c.grade["schema"])
        assert "Reply with only a JSON" in c.messages[-1]["content"], c.id
        for bad in ("{}", "[]", "Sure, here you go.", "null"):
            assert not evalset.grade(c, say(bad))[0], (c.id, bad)
    assert n == 10


# ------------------------------------------------------------------ oracles: a correct reply passes, a plausible wrong one fails

LARGE_COPY = {
    "copy-numbers": (
        "Order 7731-B shipped on 14 Nov 2025 to Unit 4, 1,208 Alder Rd., Bend, OR 97701. Items: 3 x $12.40 = $37.20; "
        "1 x $8.05 = $8.05; tax (6.25%) = $2.83. Total due: $48.08 (net 30).",
        [lambda t: t.replace("$48.08", "$48.80"), lambda t: t.replace("1,208", "1208"), lambda t: t.replace("Bend, OR", "Bend OR")]),
    "copy-curly-quotes": (
        "“We’ll meet at the old mill,” Ines said — “before the bells, not after.” "
        "He nodded… then asked, ‘Which mill?’",
        [lambda t: t.replace("“", '"').replace("”", '"'), lambda t: t.replace("’", "'"), lambda t: t.replace("…", "...")]),
    "copy-python": (
        "def moving_average(values, window=3):\n    if window <= 0:\n        raise ValueError(\"window must be positive\")\n"
        "    out = []\n    for i in range(len(values) - window + 1):\n        chunk = values[i:i + window]\n"
        "        out.append(sum(chunk) / window)\n    return out",
        [lambda t: t.replace("    ", "  "), lambda t: t.replace("i:i + window", "i : i + window"), lambda t: t.replace("<= 0", "< 0")]),
    "copy-makefile-tabs": (
        "build: main.o util.o\n\tcc -o app main.o util.o\n\nmain.o: main.c\n\tcc -c main.c",
        [lambda t: t.replace("\t", "    "), lambda t: t.replace("\n\n", "\n")]),
    "copy-accents": (
        "Crème brûlée costs €4.50 at Müller & Søn, Kraków; the naïve café owner "
        "added a 15% “service” fee.",
        [lambda t: "Creme brulee costs EUR4.50 at Muller & Son, Krakow; the naive cafe owner added a 15% \"service\" fee.",
         lambda t: t.replace("€", "$")]),
    "copy-backslashes": (
        "Pattern: ^\\d{3}-\\d{2}-[A-Z]{4}$ matches 123-45-ABCD but not 12-345-abcd; escape dots as \\. and use [^\\s]+ for tokens.",
        [lambda t: t.replace("\\d", "d"), lambda t: t.replace("\\.", ".")]),
    "copy-verse": (
        "The kettle ticks, the window fogs,\nthe cat  inspects a sleeping log;\nat half past six the street is slow—\nno one has anywhere to go.",
        [lambda t: t.replace("cat  ins", "cat ins"), lambda t: t.replace("—", "-")]),
}


@pytest.mark.parametrize("cid", sorted(LARGE_COPY))
def test_large_copy_oracle(cid):
    es = load("large")
    good, mutations = LARGE_COPY[cid]
    assert passes(es, cid, good) and passes(es, cid, good + "\n")
    for m in mutations:
        assert not passes(es, cid, m(good)), (cid, m(good)[:60])


INVOICE = {"invoice_number": "A-2291", "vendor": "Harbor Lane Bakery", "date": "2026-03-03", "total": 45.6, "currency": "EUR"}


def _with(base, **kw):
    d = dict(base)
    d.update(kw)
    return json.dumps(d)


def test_large_json_oracle():
    es = load("large")
    good = json.dumps(INVOICE)
    assert passes(es, "json-invoice", good) and passes(es, "json-invoice", "```json\n" + good + "\n```\n")
    assert passes(es, "json-invoice", json.dumps(INVOICE, indent=2).replace("45.6", "45.60"))
    assert not passes(es, "json-invoice", _with(INVOICE, total=54.6))
    assert not passes(es, "json-invoice", _with(INVOICE, date="3 March 2026"))
    assert not passes(es, "json-invoice", _with(INVOICE, total="45.60"))                  # a string is not a number
    assert not passes(es, "json-invoice", _with(INVOICE, subtotal=38.0))                  # a key nobody asked for
    assert not passes(es, "json-invoice", json.dumps({k: v for k, v in INVOICE.items() if k != "currency"}))
    assert not passes(es, "json-invoice", "Here it is: " + good)

    meeting = {"date": "2026-04-09", "start_time": "14:30", "room": "Birch",
               "attendees": ["ana@example.com", "li@example.com", "sam@example.org"], "duration_minutes": 90}
    assert passes(es, "json-meeting", json.dumps(meeting))
    assert not passes(es, "json-meeting", _with(meeting, room="Room Birch"))
    assert not passes(es, "json-meeting", _with(meeting, attendees=["li@example.com", "ana@example.com", "sam@example.org"]))
    assert not passes(es, "json-meeting", _with(meeting, duration_minutes="90"))

    tent = {"name": "TrailLite 2", "weight_kg": 1.85, "sleeps": 2, "in_stock": False, "pole_material": "aluminum"}
    assert passes(es, "json-product", json.dumps(tent))
    assert not passes(es, "json-product", _with(tent, in_stock=True))
    assert not passes(es, "json-product", _with(tent, in_stock="false"))
    assert not passes(es, "json-product", _with(tent, sleeps=2.5))

    addr = {"recipient": "Dr. Hana Okafor", "street": "77 Birchwood Ave", "unit": "Apt 5C", "city": "Springfield", "state": "MA",
            "postal_code": "01103", "country": "USA"}
    assert passes(es, "json-address", json.dumps(addr))
    assert not passes(es, "json-address", _with(addr, postal_code=1103))
    assert not passes(es, "json-address", _with(addr, postal_code="1103"))

    contact = {"name": "Ola Brandt", "email": "ola@example.net", "phone": None, "preferred_channel": "email"}
    assert passes(es, "json-nulls", json.dumps(contact))
    assert not passes(es, "json-nulls", _with(contact, phone="none"))
    assert not passes(es, "json-nulls", _with(contact, phone=""))

    scores = [{"name": "Mei", "score": 92}, {"name": "Ravi", "score": 88}, {"name": "Tomas", "score": 79}]
    assert passes(es, "json-scores-array", json.dumps(scores))
    assert not passes(es, "json-scores-array", json.dumps(list(reversed(scores))))
    assert not passes(es, "json-scores-array", json.dumps({"scores": scores}))

    recipe = {"dish": "Pancakes", "servings": 4, "ingredients": [
        {"name": "flour", "amount": 200, "unit": "g"}, {"name": "milk", "amount": 300, "unit": "ml"},
        {"name": "sugar", "amount": 1, "unit": "tbsp"}, {"name": "eggs", "amount": 2, "unit": "each"}]}
    assert passes(es, "json-recipe", json.dumps(recipe))
    wrong = json.loads(json.dumps(recipe))
    wrong["ingredients"][3]["unit"] = None
    assert not passes(es, "json-recipe", json.dumps(wrong))


MATH = {
    "math-change": ("6 muffins are 19.50 and 9 cookies are 16.20, so 35.70 is spent.\nAnswer: 14.3", ["14.5", "114.3", "35.7"]),
    "math-train": ("The trip is 4 h 35 min = 275 min; minus 25 is 250.\nAnswer: 250", ["275", "2500", "25"]),
    "math-tank": ("Net fill is 8 L/min, so 480 / 8 = 60.\nAnswer: 60", ["40", "120", "6"]),
    "math-discounts": ("120 x 0.75 = 90; 90 x 0.9 = 81.\nAnswer: 81", ["78", "84", "81.5"]),
    "math-consecutive": ("66 + 65 + 67 = 198; the largest is 67.\nAnswer: 67", ["66", "65", "198"]),
    "math-distance": ("7 km walking plus 10.5 km cycling.\nAnswer: 17.5", ["21", "7", "175"]),
    "math-ages": ("Ben is 17 and Alice is 21.\nAnswer: 17", ["21", "16", "13"]),
    "math-rectangle": ("Width 8, length 24.\nAnswer: 192", ["24", "64", "96"]),
}


@pytest.mark.parametrize("cid", sorted(MATH))
def test_large_math_oracle(cid):
    es = load("large")
    working, wrongs = MATH[cid]
    ans = working.rsplit("Answer: ", 1)[1]
    assert passes(es, cid, working) and passes(es, cid, working + "\n\n") and passes(es, cid, working.replace("Answer: ", "Answer:  ") + "  ")
    assert passes(es, cid, working.replace(f"Answer: {ans}", f"Answer: {ans}.0" if "." not in ans else f"Answer: {ans}0"))
    for w in wrongs:
        assert not passes(es, cid, working.rsplit("Answer: ", 1)[0] + f"Answer: {w}"), (cid, w)
    assert not passes(es, cid, f"The result is {ans}.")                              # no final Answer line
    assert not passes(es, cid, working + "\nI hope that helps.")                      # the Answer line must be last
    assert not passes(es, cid, f"Answer: {ans}\nActually, let me recheck: Answer: {int(float(ans)) + 1}")


def test_large_format_oracle():
    es = load("large")
    assert passes(es, "fmt-three-planets", "- mars\n- venus\n- earth\n")
    assert not passes(es, "fmt-three-planets", "- mars\n- mars\n- venus")                  # not three different planets
    assert not passes(es, "fmt-three-planets", "- mars\n- venus\n- moon")
    assert not passes(es, "fmt-three-planets", "- Mars\n- Venus\n- Earth")
    assert not passes(es, "fmt-three-planets", "Sure!\n- mars\n- venus\n- earth")
    assert not passes(es, "fmt-three-planets", "- mars\n- venus\n- earth\n- saturn")
    assert passes(es, "fmt-backwards", "M-H-T-Y-H-R")
    assert not passes(es, "fmt-backwards", "m-h-t-y-h-r") and not passes(es, "fmt-backwards", "MHTYHR")
    assert not passes(es, "fmt-backwards", "R-H-Y-T-H-M")
    assert passes(es, "fmt-lighthouse", "The fog parted when the beam swept across the harbor.")
    assert not passes(es, "fmt-lighthouse", "The fog parted, and the beam swept across the harbor.")
    assert not passes(es, "fmt-lighthouse", "The fog parted over the harbor.")
    assert passes(es, "fmt-five-words", "Heavy rain falls on roofs.")
    assert not passes(es, "fmt-five-words", "Heavy rain falls on old roofs.")
    assert not passes(es, "fmt-five-words", "Heavy rain falls on roofs")
    assert not passes(es, "fmt-five-words", "Heavy storms fall on roofs.")
    assert passes(es, "fmt-french", "Bonjour, merci.") and not passes(es, "fmt-french", "Good morning, thank you.")
    assert not passes(es, "fmt-french", "Bonjour, thank you.")
    assert passes(es, "fmt-leap-day", "2028-02-29\n") and not passes(es, "fmt-leap-day", "2028-03-01")
    assert not passes(es, "fmt-leap-day", "The day after is 2028-02-29.")
    assert passes(es, "fmt-symbols", "Au | Ag | Fe") and passes(es, "fmt-symbols", "Au|Ag|Fe")
    assert not passes(es, "fmt-symbols", "Au|Fe|Ag") and not passes(es, "fmt-symbols", "Au, Ag, Fe")
    assert passes(es, "fmt-sorted", "apple, cherry, mango, pear")
    assert not passes(es, "fmt-sorted", "pear, apple, mango, cherry") and not passes(es, "fmt-sorted", "apple, cherry, pear, mango")


def test_large_reasoning_oracle():
    es = load("large")
    for cid, good, wrongs in (
        ("reason-order", "Priya", ["Maya", "Jon", "Maya, Jon and Priya"]),
        ("reason-boxes", "Apples", ["Oranges", "Mixed"]),
        ("reason-day", "Thursday", ["Wednesday", "Friday", "Monday"]),
        ("reason-cabins", "2", ["1", "3", "2 and 3"]),
        ("reason-pets", "Dana", ["Eli", "Fay", "Dana or Fay"]),
    ):
        assert passes(es, cid, good) and passes(es, cid, good + "\n"), cid
        for w in wrongs:
            assert not passes(es, cid, w), (cid, w)


def test_the_large_oracle_spans_every_grader_type():
    es = load("large")
    covered = {case(es, cid).grade["type"] for cid in
               list(LARGE_COPY) + list(MATH) + ["json-invoice", "fmt-three-planets", "reason-order"]}
    assert covered == {"exact", "json_schema", "regex", "contains"}
    assert len(LARGE_COPY) + len(MATH) + 5 >= 12


# ------------------------------------------------------------------ agent oracle: written from the user's words, not from cases.jsonl

AGENT_CALLS = {
    "tc-weather-basic": ("get_weather", {"city": "Lisbon"}, {"city": "Porto"}),
    "tc-weather-days-units": ("get_weather", {"city": "Denver", "days": 5, "units": "fahrenheit"}, {"city": "Denver", "days": 5, "units": "celsius"}),
    "tc-thermostat-basic": ("set_thermostat", {"room": "bedroom", "temperature": 19, "unit": "celsius"}, {"room": "office", "temperature": 19, "unit": "celsius"}),
    "tc-thermostat-heat-f": ("set_thermostat", {"room": "living_room", "temperature": 70, "unit": "fahrenheit", "mode": "heat"},
                             {"room": "living_room", "temperature": 70, "unit": "fahrenheit", "mode": "cool"}),
    "tc-thermostat-after-weather": ("set_thermostat", {"room": "living_room", "temperature": 22, "unit": "celsius", "mode": "heat"},
                                    {"room": "living_room", "temperature": -2, "unit": "celsius", "mode": "heat"}),
    "tc-light-dim-warm": ("turn_on_light", {"room": "living_room", "brightness": 40, "color_temp": "warm"},
                          {"room": "living_room", "brightness": 0.4, "color_temp": "warm"}),
    "tc-light-off-after-chat": ("turn_off_light", {"room": "hallway"}, {"room": "kitchen"}),
    "tc-search-finance-pdf": ("search_documents", {"query": "2025 tax return", "folder": "finance", "file_type": "pdf", "max_results": 5},
                              {"query": "2025 tax return", "folder": "all", "file_type": "pdf", "max_results": 5}),
    "tc-search-exact-word": ("search_documents", {"query": "Zephyr"}, {"query": "zephyr"}),
    "tc-cal-basic": ("create_calendar_event", {"title": "Budget review", "date": "2026-03-11", "start_time": "15:00", "duration_minutes": 45},
                     {"title": "Budget review", "date": "2026-03-10", "start_time": "15:00", "duration_minutes": 45}),
    "tc-cal-attendees": ("create_calendar_event", {"title": "Design sync", "date": "2026-03-20", "start_time": "10:30",
                                                   "attendees": ["ana@example.com", "li@example.com"]},
                         {"title": "Design sync", "date": "2026-03-20", "start_time": "10:30", "attendees": ["ana@example.com"]}),
    "tc-cal-popup-reminder": ("create_calendar_event", {"title": "Dentist", "date": "2026-03-13", "start_time": "09:00", "duration_minutes": 60,
                                                        "reminder": {"minutes_before": 15, "method": "popup"}},
                              {"title": "Dentist", "date": "2026-03-13", "start_time": "09:00", "duration_minutes": 60,
                               "reminder": {"minutes_before": 15, "method": "email"}}),
    "tc-cal-email-reminder-day": ("create_calendar_event", {"title": "Team offsite planning", "date": "2026-04-02", "start_time": "13:00",
                                                            "duration_minutes": 120, "reminder": {"minutes_before": 1440, "method": "email"}},
                                  {"title": "Team offsite planning", "date": "2026-04-02", "start_time": "13:00", "duration_minutes": 120,
                                   "reminder": {"minutes_before": 1, "method": "email"}}),
    "tc-cal-not-todo": ("create_calendar_event", {"title": "Pay rent", "date": "2026-03-31", "start_time": "08:00"},
                        {"title": "Pay rent", "date": "2026-03-31", "start_time": "8:00"}),
    "tc-msg-sms": ("send_message", {"recipient": "Priya", "channel": "sms", "body": "Running late."}, {"recipient": "Priya", "channel": "email"}),
    "tc-msg-email": ("send_message", {"recipient": "sam@example.org", "channel": "email", "body": "The invoice is paid."},
                     {"recipient": "sam", "channel": "email"}),
    "tc-stock-follow-up": ("get_stock_price", {"ticker": "MSFT", "currency": "USD"}, {"ticker": "AAPL", "currency": "USD"}),
    "tc-convert-km-mi": ("convert_units", {"value": 42, "from_unit": "km", "to_unit": "mi"}, {"value": 42, "from_unit": "mi", "to_unit": "km"}),
    "tc-convert-after-weather": ("convert_units", {"value": 3, "from_unit": "celsius", "to_unit": "fahrenheit"},
                                 {"value": 22, "from_unit": "celsius", "to_unit": "fahrenheit"}),
    "tc-todo-due-tags": ("add_todo", {"title": "File expenses", "due_date": "2026-03-15", "priority": "medium", "tags": ["finance", "monthly"]},
                         {"title": "File expenses", "due_date": "2026-03-15", "priority": "medium", "tags": ["monthly", "finance"]}),
    "tc-music-playlist-vol-shuffle": ("play_music", {"target": {"kind": "playlist", "name": "Morning Run"}, "volume": 35, "shuffle": True},
                                      {"target": {"kind": "playlist", "name": "Morning Run"}, "volume": 35, "shuffle": False}),
    "tc-music-album": ("play_music", {"target": {"kind": "album", "name": "Kind of Blue"}},
                       {"target": {"kind": "artist", "name": "Kind of Blue"}}),
    "tc-timer-after-route": ("set_timer", {"minutes": 18, "label": "ride"}, {"minutes": 4, "label": "ride"}),
    "tc-alarm-weekdays": ("set_alarm", {"time": "06:45", "days": ["mon", "tue", "wed", "thu", "fri"]},
                          {"time": "06:45", "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}),
    "tc-room-cedar": ("book_meeting_room", {"room": "cedar", "date": "2026-03-11", "start_time": "14:00", "end_time": "15:30"},
                      {"room": "birch", "date": "2026-03-11", "start_time": "14:00", "end_time": "15:30"}),
    "tc-open-doc-from-results": ("open_document", {"doc_id": "doc-8841"}, {"doc_id": "doc-1207"}),
    "tc-lock-garage": ("lock_door", {"door": "garage", "action": "lock"}, {"door": "garage", "action": "unlock"}),
    "tc-directions-transit": ("get_directions", {"origin": "Union Station", "destination": "Art Museum", "mode": "transit"},
                              {"origin": "Art Museum", "destination": "Union Station", "mode": "transit"}),
}


@pytest.mark.parametrize("cid", sorted(AGENT_CALLS))
def test_agent_tool_call_oracle(cid):
    es = load("agent")
    name, good, wrong_args = AGENT_CALLS[cid]
    assert passes(es, cid, call(name, **good)), cid
    assert passes(es, cid, {"content": "Working on it.", "tool_calls": [{"name": name, "arguments": good}]}), cid   # arguments as an object
    assert not passes(es, cid, call(name, **wrong_args)), cid
    assert not passes(es, cid, call("get_weather" if name != "get_weather" else "set_timer", **good)), cid
    assert not passes(es, cid, say(f"Sure, I will use {name}.")), cid
    assert not passes(es, cid, {"content": "", "tool_calls": [{"name": name, "arguments": "{not json"}]}), cid


AGENT_NO_TOOL = {
    "nt-arithmetic": "12 times 12 is 144.",
    "nt-capital": "The capital of Australia is Canberra.",
    "nt-thanks": "You're welcome!",
    "nt-no-tool-fits": "I can't book flights with the tools I have here.",
    "nt-umbrella-after-weather": "Yes, take one: it is raining heavily in Seattle.",
    "nt-compare-after-stock": "Yes, $231.40 is more than $200.",
    "nt-count-results": "It found three documents.",
    "nt-define-word": "An idempotent operation gives the same result however many times you apply it.",
    "nt-mile-vs-km": "Yes, a mile is longer: about 1.6 kilometers.",
    "nt-missing-details-thermostat": "Which room, and what temperature?",
    "nt-missing-details-message": "How should I send it, and what should it say?",
    "nt-recall-city": "That forecast was for Reykjavik.",
}


@pytest.mark.parametrize("cid", sorted(AGENT_NO_TOOL))
def test_agent_no_tool_oracle(cid):
    es = load("agent")
    c = case(es, cid)
    assert passes(es, cid, say(AGENT_NO_TOOL[cid]))
    for t in c.tools:
        assert not passes(es, cid, call(t["function"]["name"])), (cid, t["function"]["name"])


def test_the_agent_oracle_covers_both_grader_types_and_enough_cases():
    es = load("agent")
    assert {case(es, cid).grade["type"] for cid in list(AGENT_CALLS) + list(AGENT_NO_TOOL)} == {"tool_call", "no_tool_call"}
    assert len(AGENT_CALLS) >= 12 and len(AGENT_NO_TOOL) == 12
    assert set(AGENT_NO_TOOL) == {c.id for c in es.cases if c.grade["type"] == "no_tool_call"}

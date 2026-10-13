#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""How many days the runner's Harvester credential has left.

Reads a bearer token on stdin, writes ONE classification word or an integer
day count on stdout, and never writes the token anywhere.

    nojwt        not a three-part JWT at all (client cert, exec plugin, empty)
    noexp        a JWT with no `exp` claim ... a legacy service-account token,
                 which does not expire
    rotating     a SHORT-LIVED token (total life <= 24h), so something rotates
                 it and "days remaining" is not the question to ask of it
    undecodable  a JWT whose payload will not base64/JSON decode
    <integer>    whole days until `exp`; negative means it expired that long ago

THE `rotating` CASE EXISTS BECAUSE THE FIRST VERSION OF THIS FILE GOT IT
BACKWARDS, and the hermetic test is what said so. Both this module's own
comment and `staged/arc-runners-devtest/README.md` asserted that a remaining-
life floor "can never fire" under option A. It fires on EVERY run: a projected
ServiceAccount token is minted with about an hour of life and replaced by
kubelet, so its remaining life is permanently near zero and a three-day floor
refuses the preferred design outright. The floor is only meaningful for a
credential that nothing rotates, and total lifetime is the readable proxy for
which kind is in hand.

WHY THIS IS A FILE rather than six lines inlined in the workflow. A check
buried in a `run:` block cannot be tested by anything: the only way to exercise
it is to run the sixty-minute job that contains it, against a credential in a
state you would have to manufacture on the rig. So it would ship unexercised,
which in this repository is the specific defect the harness exists to refuse
(`selftest` is hermetic and per-commit precisely so the extractor is not
trusted on inspection). As a module it is exercised by selftest.sh on every
commit, including the expired and the malformed cases, which are the two that
matter and the two nobody would ever reproduce by hand.

CORRECT UNDER EVERY CREDENTIAL OPTION TM-0345 IS CHOOSING BETWEEN, which is
why it is worth writing before the option is settled:

  - projected SA token (option A): about an hour of life, replaced by kubelet,
    so `rotating` ... and NOT a near-zero day count, see above.
  - static SA token (option C): legacy tokens carry no `exp`, so `noexp`.
  - the 168h status quo: converts a mid-run auth failure into a named refusal
    three days early.

WHAT IT DOES NOT DO, and there are two.

It reads the token's own claim about itself. It does not ask the API server
whether the token is still accepted, so a REVOKED but unexpired token reads as
healthy here and fails at the namespace probe two lines later. That is the
right split: this check answers "will this die during the run", and only that.

And `rotating` asserts the credential is of the self-renewing KIND. It says
nothing about whether the renewal is actually happening ... a wedged kubelet
leaves a short-lived token on disk to die, and this reports `rotating` right up
until it does. The sensor for that is the namespace probe failing, not this.
Do not let `rotating` read as "the credential is fine".
"""

import base64
import json
import sys
import time


# A credential minted with no more than this much total life is one something
# else renews; nothing hand-minted is this short. Kubernetes' own floor for a
# projected token is 10 minutes and the kubelet default is an hour, while the
# shortest credential ever issued here by hand is 168h ... so anywhere in
# between separates the two kinds cleanly, and 24h is not a close call in
# either direction.
ROTATING_MAX_LIFETIME_S = 24 * 3600


def classify(token, now=None):
    """Return a classification word, or an int of whole days until exp."""
    token = (token or "").strip()
    if token.count(".") != 2:
        return "nojwt"

    part = token.split(".")[1]
    # JWT uses base64url without padding; restore it before decoding.
    part += "=" * (-len(part) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(part))
    except Exception:
        return "undecodable"
    if not isinstance(claims, dict):
        return "undecodable"

    exp = claims.get("exp")
    if exp is None:
        return "noexp"
    if not isinstance(exp, (int, float)) or isinstance(exp, bool):
        # An `exp` that is not a number is not an expiry. Refusing to guess is
        # the point: a credential whose life cannot be READ is not one to start
        # a sixty-minute run on.
        return "undecodable"

    now = time.time() if now is None else now

    # Total life, when the token says when it was issued, decides WHICH
    # question applies. `iat` is standard on both projected and legacy
    # service-account tokens; if it is missing we cannot tell the kinds apart,
    # so we fall through to the day count and let the floor refuse. That
    # errs toward refusing rather than toward running on an unknown, which is
    # this preflight's rule everywhere else.
    iat = claims.get("iat")
    if isinstance(iat, (int, float)) and not isinstance(iat, bool):
        if (exp - iat) <= ROTATING_MAX_LIFETIME_S:
            return "rotating"

    # Floor division, so a credential with 2.9 days left reports 2 and trips a
    # `< 3` threshold. Rounding up here would let it die inside the run it was
    # cleared for, which is the entire failure being designed out.
    return int((exp - now) // 86400)


def main():
    print(classify(sys.stdin.read()))


if __name__ == "__main__":
    main()

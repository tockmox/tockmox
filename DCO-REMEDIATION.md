<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# DCO remediation

A commit that reached `main` without a sign-off cannot be signed after the fact without rewriting history, which this
repository does not do. Instead its author adds the sign-off here, in a commit that is itself signed off, and
`signoff-on-main.yaml` keeps its red run on the original commit as the record of the gap. CONTRIBUTING.md, "Sign your
commits (DCO)", has the rule; [DCO](DCO) has the certificate's text.

## 2026-11-05: two App-lane squashes merged by hand

These two pull requests went through the maintainer's App lane but were squash-merged with GitHub's merge button
instead of by the App, so the maintainer's `Signed-off-by` that the App adds at merge was never written:

- `33ec703808a437446be1e9a84f9f52e533cffcdb` cronexpr: a wall time repeated by a fall-back fires both times, as
  robfig/cron does (#167)
- `e53825ba50049c79c2d1714e6c16e9236ad0c7ad` platform catalog: regenerate the specialists field from the current roles
  file (#166)

The maintainer, jmaaks <jeff@maaks.com>, signs this commit off and states:

"I, jmaaks <jeff@maaks.com>, add my Signed-off-by to commits 33ec703808a437446be1e9a84f9f52e533cffcdb and
e53825ba50049c79c2d1714e6c16e9236ad0c7ad, and certify the Developer Certificate of Origin 1.1 for each of them."

Going forward, App-lane pull requests are approved and left for the App to merge.

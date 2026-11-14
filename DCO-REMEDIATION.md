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

## 2026-11-13: two App-lane pull requests merged as merge commits

These two pull requests went through the maintainer's App lane and were merged with GitHub's merge button as merge
commits, on 2026-11-03 and 2026-11-04. `signoff-on-main.yaml` reads the first-parent, non-merge commits of a push, so
it never read the App's commits behind those merges. They reached `main` with no `Signed-off-by`, and no run went red:

- `6347b7f92fb7e4ed8e6961c40dac0ac37dcc520d` Add a forge dump mode to the off-site copy script (#159)
- `aba2e2fa4a6b2b107a36700bf0bb49f51ea72084` Renovate: open the weekly batch on Friday night instead of Monday
  morning (#163)

The maintainer, jmaaks <jeff@maaks.com>, signs this commit off and states:

"I, jmaaks <jeff@maaks.com>, add my Signed-off-by to commits 6347b7f92fb7e4ed8e6961c40dac0ac37dcc520d and
aba2e2fa4a6b2b107a36700bf0bb49f51ea72084, and certify the Developer Certificate of Origin 1.1 for each of them."

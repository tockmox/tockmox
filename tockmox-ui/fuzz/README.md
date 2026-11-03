<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Fuzz targets

Coverage-guided fuzz targets for the console's input parsers, written for
[atheris](https://github.com/google/atheris) and run by
[ClusterFuzzLite](https://google.github.io/clusterfuzzlite/) in
`.github/workflows/fuzz.yaml` (build setup in `.clusterfuzzlite/`). Each target
asserts properties, so a wrong answer fails as surely as an exception.

| Target | Module | What it asserts |
|---|---|---|
| `redirects_fuzzer.py` | `app/redirects.py`, the short-path redirect | The Location it returns starts with the configured URL plus `/`, is printable ASCII with no space, and has no dot segment in any spelling a browser resolves; anything else is refused with `Refused` |
| `cronexpr_fuzzer.py` | `app/cronexpr.py`, the Platform page's cron evaluator | An expression is evaluated or refused with `ValueError` or `ZoneInfoNotFoundError`; the next and previous fire times are on the right side of the given time, are fire times in the schedule's zone, and no fire time in the following day is skipped |

## Run one locally

Atheris needs a Python with a recent clang; it is a dev-only dependency and is
not in any lockfile.

```bash
python3 -m pip install atheris
python3 tockmox-ui/fuzz/redirects_fuzzer.py -max_total_time=60
```

A failure writes the input that caused it to `crash-<sha1>` in the current
directory. Pass that file as the only argument to replay it.

In CI, a crash fails the pull request's `fuzz` check and ClusterFuzzLite keeps
the input with the run's artifacts; download it and replay it the same way.

## Add a target

Name it `<something>_fuzzer.py` in this directory; `.clusterfuzzlite/build.sh`
packages every file that matches. Import only the standard library and the
module under test: the build image installs nothing else.

# SPDX-License-Identifier: Apache-2.0
"""Loads the Context Analyzer hook the way LiteLLM does, from a flat directory.

Run by tests/context-analyzer/render.sh with the hook files its fixture
render produced (the chart's loader, the chart's settings and the fixture's
stand-in modules, which import each other relatively as the real package does):

    python3 -I tests/context-analyzer/test_loader.py <dir>

LiteLLM resolves hooks.<file>.<object> by loading <config dir>/hooks/<file>.py
by file path under a name of its own choosing; this does the same, under a
name that is not the file's, so the loader cannot lean on its module name.
"""

import importlib.util
import os
import sys


def load(directory):
    path = os.path.join(directory, "tockmox_context_analyzer.py")
    spec = importlib.util.spec_from_file_location("litellm_custom_callback", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(directory):
    errs = []
    for key in list(os.environ):
        if key.startswith("CTXA_"):
            del os.environ[key]
    os.environ["CTXA_GATEWAY_ID"] = "from-the-environment"
    module = load(directory)
    hook = module.analyzer_hook
    if type(hook).__name__ != "AnalyzerHook":
        errs.append(f"analyzer_hook is {type(hook).__name__}")
    if not hook.sink.startswith("http://tockmox-context-analyzer."):
        errs.append(f"settings not applied: sink {hook.sink!r}")
    if os.environ.get("CTXA_GATEWAY_ID") != "from-the-environment":
        errs.append("a setting overrode the gateway's own environment")
    if "tockmox_context_analyzer_pkg.actuation" not in sys.modules:
        errs.append("relative imports did not resolve inside the package")
    # a second load (LiteLLM may resolve the callback more than once) reuses the package
    if load(directory).analyzer_hook is not hook:
        errs.append("a second load built a second hook")
    for e in errs:
        print("   ", e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

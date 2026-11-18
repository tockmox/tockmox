# SPDX-License-Identifier: Apache-2.0
"""Loads the Context Analyzer hook into the stock LiteLLM image.

LiteLLM reads the callback hooks.tockmox_context_analyzer.analyzer_hook from
this file, which sits in the flat hooks directory (/etc/litellm/hooks, one
ConfigMap, no subdirectories). The Context Analyzer is a package whose modules
import each other relatively, so the four module files ride beside this one as
tockmox_context_analyzer_<module>.py and are loaded here, by file path, into a
package of their own. That works whatever LiteLLM version resolves the callback
and whatever PYTHONPATH says, because nothing is imported by name.

The settings file beside this one carries what the chart knows (where the
Analyzer listens, whether Tockmox mode is on and which callback stamps the
class). A variable already set in the gateway's environment wins, so a site can
override any of them without editing this file. The token and the hash salt
come from the gateway's environment only: they are secrets and a ConfigMap is
not the place for them.
"""

import importlib.util
import json
import os
import sys
import types

_DIR = os.path.dirname(os.path.abspath(__file__))
_PACKAGE = "tockmox_context_analyzer_pkg"
_MODULES = ("compat", "segmentation", "actuation", "hooks")


def _apply_settings():
    path = os.path.join(_DIR, "tockmox_context_analyzer.json")
    with open(path, encoding="utf-8") as fh:
        settings = json.load(fh)
    for key, value in (settings.get("env") or {}).items():
        os.environ.setdefault(key, str(value))


def _load():
    if _PACKAGE in sys.modules:
        return sys.modules[_PACKAGE]
    package = types.ModuleType(_PACKAGE)
    package.__path__ = []
    package.__package__ = _PACKAGE
    sys.modules[_PACKAGE] = package
    try:
        for name in _MODULES:
            qualified = f"{_PACKAGE}.{name}"
            path = os.path.join(_DIR, f"tockmox_context_analyzer_{name}.py")
            spec = importlib.util.spec_from_file_location(qualified, path)
            module = importlib.util.module_from_spec(spec)
            module.__package__ = _PACKAGE
            sys.modules[qualified] = module
            spec.loader.exec_module(module)
            setattr(package, name, module)
    except BaseException:
        for name in (_PACKAGE, *(f"{_PACKAGE}.{m}" for m in _MODULES)):
            sys.modules.pop(name, None)
        raise
    return package


_apply_settings()
analyzer_hook = _load().hooks.analyzer_hook

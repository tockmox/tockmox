# SPDX-License-Identifier: Apache-2.0
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
FIX = os.path.join(HERE, "fixtures")
SCHEMA = os.path.join(ROOT, "schema", "report-v0.schema.json")
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Contract-test-only launcher that presents a Linux runtime platform.

The production floe-blender CLI has an unconditional ``sys.platform ==
"linux"`` guard with no environment bypass.  These source tests run on the
macOS development host and must not invoke a native macOS Blender, so they
execute the real CLI in this tiny wrapper after patching ``sys.platform``.
The fake Blender reached by the tests is a text script, never a Mach-O
application.
"""

import runpy
import sys

sys.platform = "linux"
script = sys.argv[1]
sys.argv = sys.argv[1:]
runpy.run_path(script, run_name="__main__")

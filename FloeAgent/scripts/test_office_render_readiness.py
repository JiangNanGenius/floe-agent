#!/usr/bin/env python3
"""Run the deterministic visible-render qualification from the shipped host.

The same checks are executed by `test_office_native_host.py` in CI; this runner
exists so a focused local run and a review can produce the full receipt.
"""
import json

from office_render_readiness import check

if __name__ == '__main__':
    print(json.dumps(check(), indent=2))

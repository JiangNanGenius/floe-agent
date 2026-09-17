#!/usr/bin/env python3
"""Bind the recovery Notes scope to the source tag's own release workflow.

The accepted-SDK recovery must run exactly the UI selector and Office scope that
the source tag requires. If those were dispatch inputs, a caller could narrow
the qualification (for example run one test method, or turn off the Office
scope) while the workflow still reported success. Instead this helper reads the
tagged ``release-unsigned-ipa.yml`` and derives both values from it:

* the single ``FloeAgentUITests/...`` selector used by the Notes steps;
* whether *every* ``verify_notes_ui_xcresult.py`` invocation uses
  ``--simulator-without-office``.

A tag with more than one UI selector, no Notes verifier call, or a mix of Office
scopes is refused outright, so an unknown scope fails loudly rather than running
a weaker suite. The derived values are appended to the file named by
``--github-env`` (``$GITHUB_ENV`` in Actions) as ``NOTES_TEST_SELECTOR`` and
``NOTES_SIMULATOR_WITHOUT_OFFICE``.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

SELECTOR = re.compile(r"-only-testing:(FloeAgentUITests/[A-Za-z0-9_]+)")
VERIFIER = "verify_notes_ui_xcresult.py"
OFFICE_FLAG = "--simulator-without-office"


class ScopeBindingError(ValueError):
    """The source tag's Notes scope is missing, ambiguous or mixed."""


def _require(condition: object, message: str) -> None:
    if not condition:
        raise ScopeBindingError(message)


def derive_scope(workflow_text: str) -> tuple[str, bool]:
    """Return ``(selector, simulator_without_office)`` for the source tag."""
    selectors = sorted(set(SELECTOR.findall(workflow_text)))
    _require(len(selectors) == 1,
             f"expected exactly one source-tag UI selector, found {selectors}")
    verifier_lines = [line for line in workflow_text.splitlines()
                      if VERIFIER in line]
    _require(bool(verifier_lines),
             f"the source tag never invokes {VERIFIER}")
    flags = {OFFICE_FLAG in line for line in verifier_lines}
    _require(len(flags) == 1,
             "the source tag mixes the Office scope across Notes verifier calls")
    return selectors[0], flags.pop()


def _append_env(path: str, selector: str, without_office: bool) -> None:
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"NOTES_TEST_SELECTOR={selector}\n")
        handle.write(f"NOTES_SIMULATOR_WITHOUT_OFFICE="
                     f"{'true' if without_office else 'false'}\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True,
                        help="tagged .github/workflows/release-unsigned-ipa.yml")
    parser.add_argument("--github-env", default="",
                        help="file to append the derived variables to ($GITHUB_ENV)")
    args = parser.parse_args(argv)
    try:
        text = pathlib.Path(args.workflow).read_text(encoding="utf-8")
        selector, without_office = derive_scope(text)
    except (ScopeBindingError, OSError) as error:
        print(f"Notes scope binding failed: {error}", file=sys.stderr)
        return 1
    if args.github_env:
        _append_env(args.github_env, selector, without_office)
    print(f"NOTES_TEST_SELECTOR={selector}")
    print(f"NOTES_SIMULATOR_WITHOUT_OFFICE={'true' if without_office else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

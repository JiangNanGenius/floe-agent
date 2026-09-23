#!/usr/bin/env python3
"""image_id.py — derive and check Floe Linux guest image ids.

Template images are immutable, versioned artifacts: one id must never name
two different byte sets (that collision broke C5 prepare and user upgrades
when run 35923812691 reused the published plain id with a new disk digest).
An id therefore embeds, in order:

    floe-debian13-riscv64-<daily>-<template>-r<recipe-rev>-b<build-id>

  * <daily>      the pinned Debian daily build (informational, from
                 pinned-inputs.json `daily_build`, dashes removed);
  * <template>   the stable user-facing runtime-template id (basic,
                 dev-document) - unchanged by rebuilds;
  * <recipe-rev> first 12 hex of the SHA-512 over the recipe's semantic
                 fields (name/packages/pypi, canonical JSON): changes only
                 when what gets installed changes, so a recipe edit is a new
                 content version while description-only edits keep the id;
  * <build-id>   an immutable build identity (the cloud workflow passes
                 <github.run_id>-<github.run_attempt>, so even an Actions
                 rerun - same run id, new attempt - gets a fresh id): two
                 rebuilds of the same recipe can never share an id even
                 when APT archive state moves under them. Local runs
                 default to local-<unix seconds>-<uuid8> for the same
                 reason: whole-second timestamps alone can collide on
                 rapid reruns.

Usage:

  derive --daily BUILD --template NAME --recipe PATH --build-id ID
      Print the image id. Non-zero exit on invalid input.

  --self-test
      Collision regression proofs (deterministic fixtures): distinct build
      ids and distinct templates never collide, ids never collapse to the
      published plain id of the pre-template image, build ids are
      sanitized, and derivation is deterministic. Exits non-zero on failure.
"""
import argparse
import hashlib
import json
import re
import sys
import time
import uuid

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
SAFE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# The pre-template published artifact this scheme must never reproduce.
PUBLISHED_PLAIN_ID = "floe-debian13-riscv64-202609202607"


def recipe_revision(recipe_path):
    with open(recipe_path, "r", encoding="utf-8") as handle:
        recipe = json.load(handle)
    if not isinstance(recipe, dict) or recipe.get("schema") != 1:
        raise SystemExit("recipe is not a schema-1 object: %s" % recipe_path)
    semantic = {
        "name": recipe.get("name"),
        "packages": recipe.get("packages") or {},
        "pypi": recipe.get("pypi") or {},
    }
    canonical = json.dumps(semantic, sort_keys=True, separators=(",", ":"))
    return hashlib.sha512(canonical.encode("utf-8")).hexdigest()[:12]


def derive(daily, template, recipe_path, build_id):
    daily = (daily or "").replace("-", "")
    for label, value in (("daily", daily), ("template", template),
                         ("build-id", build_id)):
        if not value or not SAFE_RE.match(value):
            raise SystemExit("invalid %s for the image id: %r" % (label, value))
    if not ID_RE.match(template):
        raise SystemExit("invalid template name for the image id: %r" % (template,))
    revision = recipe_revision(recipe_path)
    return "floe-debian13-riscv64-%s-%s-r%s-b%s" % (daily, template, revision,
                                                    build_id)


def local_build_id():
    # Local builds have no run id; seconds alone can collide on rapid
    # reruns, so add a random uuid suffix (python3 is a hard requirement of
    # the build script already).
    return "local-%d-%s" % (int(time.time()), uuid.uuid4().hex[:8])


def self_test():
    fixtures = {
        "basic": {
            "schema": 1, "name": "basic",
            "packages": {"bash": None, "python3": {"min_version": "3.13"}},
            "pypi": {},
        },
        "dev-document": {
            "schema": 1, "name": "dev-document",
            "packages": {"bash": None, "git": None},
            "pypi": {"python-pptx": {
                "version": "1.0.2",
                "wheel": "python_pptx-1.0.2-py3-none-any.whl",
                "url": "https://files.pythonhosted.org/x.whl",
                "sha256": "a" * 64,
            }},
        },
    }
    import os
    import tempfile
    tmp = tempfile.mkdtemp(prefix="floe-image-id-selftest-")
    paths = {}
    for name, recipe in fixtures.items():
        path = os.path.join(tmp, "%s.json" % name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(recipe, handle)
        paths[name] = path
    failures = []

    def check(label, condition):
        print("%s: %s" % ("ok" if condition else "FAIL", label))
        if not condition:
            failures.append(label)

    daily = "202609202607"
    id_a = derive(daily, "basic", paths["basic"], "11111111111")
    id_a2 = derive(daily, "basic", paths["basic"], "11111111111")
    id_b = derive(daily, "basic", paths["basic"], "22222222222")
    id_c = derive(daily, "dev-document", paths["dev-document"], "11111111111")
    id_d = derive(daily, "basic", paths["dev-document"], "11111111111")

    check("deterministic: same inputs give the same id", id_a == id_a2)
    check("distinct build ids never collide (rebuild case)", id_a != id_b)
    check("distinct templates never collide", id_a != id_c)
    check("distinct recipes never collide (content version)", id_a != id_d)
    check("basic and dev-document ids are distinct", id_c != id_d)
    check("id never equals the published plain id", id_a != PUBLISHED_PLAIN_ID)
    check("id never equals the published plain id (dev)",
          id_c != PUBLISHED_PLAIN_ID)
    check("id is not the plain id plus a template suffix",
          id_a != "%s-basic" % PUBLISHED_PLAIN_ID)
    check("id format carries the immutable build identity",
          id_a.endswith("-b11111111111"))
    id_rerun1 = derive(daily, "basic", paths["basic"], "11111111111-1")
    id_rerun2 = derive(daily, "basic", paths["basic"], "11111111111-2")
    check("rerun attempts never collide (run id + attempt)",
          id_rerun1 != id_rerun2)
    check("attempt-qualified build id keeps the contract",
          id_rerun1.endswith("-b11111111111-1"))
    check("generated local build ids are unique",
          local_build_id() != local_build_id())
    for label, fn in (
        ("build-id with path traversal is rejected",
         lambda: derive(daily, "basic", paths["basic"], "../evil")),
        ("build-id with spaces is rejected",
         lambda: derive(daily, "basic", paths["basic"], "a b")),
        ("empty build-id is rejected",
         lambda: derive(daily, "basic", paths["basic"], "")),
    ):
        try:
            fn()
            check(label, False)
        except SystemExit:
            check(label, True)
    os.unlink(paths["basic"])
    os.unlink(paths["dev-document"])
    os.rmdir(tmp)
    if failures:
        print("image-id self-test FAILED: %d check(s)" % len(failures),
              file=sys.stderr)
        return 1
    print("image-id self-test: all collision checks passed")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("local-build-id", help="print a unique local build id")
    derive_parser = sub.add_parser("derive", help="print the image id")
    derive_parser.add_argument("--daily", required=True)
    derive_parser.add_argument("--template", required=True)
    derive_parser.add_argument("--recipe", required=True)
    derive_parser.add_argument("--build-id", required=True)
    parser.add_argument("--self-test", action="store_true",
                        help="collision regression proofs")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.command == "local-build-id":
        print(local_build_id())
        return 0
    if args.command == "derive":
        print(derive(args.daily, args.template, args.recipe, args.build_id))
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

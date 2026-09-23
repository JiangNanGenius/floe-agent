#!/usr/bin/env python3
"""write-image-manifest.py — write or verify the guest image manifest that the
app's LinuxGuestImageStore expects.

The schema is the Codable shape of `LinuxGuestImage` in
FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift (branch
codex/feedback-integration):

    {
      "id": "...",
      "biosPath": "bbl64.bin",
      "kernelPath": "kernel-riscv64.bin",       (optional)
      "initrdPath": "...",                      (optional)
      "diskPath": "disk.img",                   (optional)
      "diskReadWrite": true,
      "cmdline": "console=hvc0 root=/dev/vda rw loglevel=4",
      "qualified": true,
      "qualificationEvidence": "...",
      "qualificationRun": "https://github.com/.../actions/runs/<id>",
      "artifacts": [
        {"role": "bios", "path": "bbl64.bin", "sha512": "<128 hex>", "bytes": 53786},
        {"role": "kernel", "path": "kernel-riscv64.bin", "sha512": "...", "bytes": 3946740},
        {"role": "disk", "path": "disk.img", "sha512": "...", "bytes": 3085959168}
      ],
      "provenance": {
        "sourceURL": "...", "buildConfigurationURL": "...",
        "license": "...", "distributionAllowed": false
      }
    }

`write` refuses to emit `qualified: true` without a qualification run id.
`verify` re-checks the same things LinuxGuestImageVerifier checks: the declared
roles have digests, every digest is 128 hex chars, every artifact exists as a
regular file inside the image directory with the recorded size and SHA-512.
Paths in the manifest are relative, which is the portable form the app's
importer keeps intact inside the image directory.

Preinstalled software templates: when `--template-id NAME` is given, `write`
adds a `template` object next to the existing keys (never reordering them):

    {
      "id": "dev-document",
      "recipeSha512": "<128 hex>",       # digest of the exact recipe bytes
      "recipePath": "FloeAgent/.../templates/dev-document.json",
      "verified": true,                  # only from real stage-2 evidence
      "missingPackages": [],
      "belowMinimum": [{"name", "have", "minimum"}],
      "pypiFailures": [{"name", "detail"}],
      "packages": [{"name","version","arch","source","installedKb"}],
      "checks": ["recipe:sha512", "stage2-verify:present", ...]
    }

`--template-json` is the host-side copy of the guest's `template-verify.json`
and `--template-install-json` the guest's `template-install.json`. `verified`
is true only when the stage-2 evidence exists, parses, names the same
template id and reports verified=true with zero failures; otherwise it is
false with an explicit `reason` (success is never invented). `verify` checks
the template block when present and still accepts manifests without one.

This script never "forces" qualified: the caller passes the flag that the
actual capability run produced.
"""
import argparse
import hashlib
import json
import os
import re
import sys

ROLES = ("bios", "kernel", "initrd", "disk")
HEX512 = re.compile(r"^[0-9a-f]{128}$")


def sha512_and_size(path):
    digest = hashlib.sha512()
    size = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def relative_inside(image_dir, path):
    """Return `path` as a path relative to image_dir, rejecting escapes."""
    absolute = os.path.abspath(path)
    root = os.path.abspath(image_dir)
    if not absolute.startswith(root + os.sep):
        raise SystemExit("artifact %s is outside the image directory %s" % (path, image_dir))
    return os.path.relpath(absolute, root)


TEMPLATE_LIST_KEYS = ("missingPackages", "belowMinimum", "pypiFailures", "checks", "packages")


def display_path(path):
    """Prefer a repository-relative path; keep the argument when it escapes."""
    absolute = os.path.abspath(path)
    try:
        relative = os.path.relpath(absolute, os.getcwd())
    except ValueError:
        return path
    if relative == ".." or relative.startswith(".." + os.sep):
        return path
    return relative


def read_json_object(path, label):
    """Read a JSON object for the template block.

    Returns (payload, status, detail) with status in {"ok", "missing", "invalid"}.
    A missing path/file is not corruption (a caller may project only part of
    the block); malformed content is, and callers fail closed on it.
    """
    if not path:
        return None, "missing", "%s path not provided" % label
    if not os.path.isfile(path):
        return None, "missing", "%s is missing: %s" % (label, path)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        return None, "invalid", "%s is unreadable or invalid JSON: %s" % (label, exc)
    if not isinstance(payload, dict):
        return None, "invalid", "%s is not a JSON object" % label
    return payload, "ok", ""


def validate_template_evidence(payload, template_id):
    """Structure check for the guest's template-verify.json."""
    problems = []
    if payload.get("template") != template_id:
        problems.append("stage-2 evidence template %r does not match --template-id %r"
                        % (payload.get("template"), template_id))
    if not isinstance(payload.get("verified"), bool):
        problems.append("stage-2 evidence verified is not a boolean")
    for key in ("missing", "below_minimum", "pypi_failures"):
        if not isinstance(payload.get(key), list):
            problems.append("stage-2 evidence %s is not a list" % key)
    return problems


def build_template_block(args):
    """Build the manifest `template` object (or None without --template-id).

    The block is a record of what was actually installed and verified. It is
    never optimistic: missing/inconsistent evidence yields verified=false plus
    a reason, and only stage-2 evidence can set verified=true.
    """
    if not args.template_id:
        return None
    if not args.template_recipe:
        raise SystemExit("--template-id requires --template-recipe")
    if os.path.islink(args.template_recipe) or not os.path.isfile(args.template_recipe):
        raise SystemExit("template recipe is not a regular file: %s" % args.template_recipe)

    problems = []
    checks = ["recipe:sha512"]
    block = {
        "id": args.template_id,
        "recipeSha512": sha512_and_size(args.template_recipe)[0],
        "recipePath": display_path(args.template_recipe),
        "verified": False,
        "missingPackages": [],
        "belowMinimum": [],
        "pypiFailures": [],
        "packages": [],
        "checks": checks,
    }

    install, install_status, install_detail = read_json_object(
        args.template_install_json, "stage-1 install evidence")
    if install_status == "missing":
        checks.append("stage1-install:missing")
    elif install_status == "invalid":
        problems.append(install_detail)
        checks.append("stage1-install:invalid")
    else:
        apt = install.get("apt")
        records = apt.get("packages") if isinstance(apt, dict) else None
        if not isinstance(records, list):
            problems.append("stage-1 install evidence has no apt.packages list")
            checks.append("stage1-install:invalid")
        else:
            normalized = []
            malformed = False
            for record in records:
                if not isinstance(record, dict):
                    malformed = True
                    break
                try:
                    normalized.append({
                        "name": str(record["name"]),
                        "version": str(record["version"]),
                        "arch": str(record["arch"]),
                        "source": str(record["source"]),
                        "installedKb": int(record["installed_kb"]),
                    })
                except (KeyError, TypeError, ValueError):
                    malformed = True
                    break
            if malformed:
                problems.append("stage-1 install evidence has malformed package records")
                checks.append("stage1-install:invalid")
            else:
                normalized.sort(key=lambda item: item["name"])
                block["packages"] = normalized
                checks.append("stage1-install:present")
        if isinstance(apt, dict) and isinstance(apt.get("missing"), list):
            checks.append("apt-missing:%d" % len(apt["missing"]))

    verify, verify_status, verify_detail = read_json_object(
        args.template_json, "stage-2 verification evidence")
    if verify_status != "ok":
        checks.append("stage2-verify:%s" % verify_status)
        problems.append(verify_detail)
    else:
        evidence_problems = validate_template_evidence(verify, args.template_id)
        if evidence_problems:
            checks.append("stage2-verify:invalid")
            problems.extend(evidence_problems)
        else:
            checks.append("stage2-verify:present")
            evidence_reason = str(verify.get("reason") or "").strip()
            if evidence_reason and verify["verified"] is not True:
                problems.append(evidence_reason)
            block["missingPackages"] = [str(name) for name in verify["missing"]]
            block["belowMinimum"] = [
                {"name": str(item.get("name")), "have": str(item.get("have")),
                 "minimum": str(item.get("minimum"))}
                for item in verify["below_minimum"] if isinstance(item, dict)
            ]
            block["pypiFailures"] = [
                {"name": str(item.get("name")), "detail": str(item.get("detail"))}
                for item in verify["pypi_failures"] if isinstance(item, dict)
            ]
            if verify["verified"] is True and not (
                    block["missingPackages"] or block["belowMinimum"] or block["pypiFailures"]):
                block["verified"] = True
                checks.append("apt-requirements:verified")
                checks.append("pypi-requirements:verified")
            else:
                if verify["verified"] is True:
                    problems.append("stage-2 evidence claims verified=true but lists failures")
                checks.append("apt-missing:%d" % len(block["missingPackages"]))
                checks.append("pypi-failures:%d" % len(block["pypiFailures"]))

    # Any recorded problem (corrupt/mismatched evidence, claims contradicting
    # their own failure lists) makes the block unverified: never a partial pass.
    if problems:
        block["verified"] = False
    if not block["verified"]:
        block["reason"] = ("; ".join(problems) if problems else
                           "stage-2 template verification did not report a clean pass")
    return block


def build_manifest(args):
    image_dir = os.path.abspath(args.image_dir)
    artifacts = []
    declared = []

    def add(role, path):
        if not path:
            return
        if os.path.islink(path) or not os.path.isfile(path):
            raise SystemExit("%s is not a regular file: %s" % (role, path))
        rel = relative_inside(image_dir, path)
        digest, size = sha512_and_size(path)
        artifacts.append({"role": role, "path": rel, "sha512": digest, "bytes": size})
        declared.append(role)

    add("bios", args.bios)
    add("kernel", args.kernel)
    add("initrd", args.initrd)
    add("disk", args.disk)

    for role in ("bios",):
        if role not in declared:
            raise SystemExit("the manifest needs a %s artifact" % role)

    if args.qualified and not (args.qualification_run or "").strip():
        raise SystemExit("refusing to write qualified=true without a qualification run id")

    manifest = {
        "id": args.id,
        "biosPath": next(a["path"] for a in artifacts if a["role"] == "bios"),
        "diskReadWrite": not args.read_only_disk,
        "qualified": bool(args.qualified),
    }
    for role, key in (("kernel", "kernelPath"), ("initrd", "initrdPath"), ("disk", "diskPath")):
        for artifact in artifacts:
            if artifact["role"] == role:
                manifest[key] = artifact["path"]
    if args.cmdline:
        manifest["cmdline"] = args.cmdline
    if args.qualification_evidence:
        manifest["qualificationEvidence"] = args.qualification_evidence
    if args.qualification_run:
        manifest["qualificationRun"] = args.qualification_run
    manifest["artifacts"] = artifacts
    manifest["provenance"] = {
        "sourceURL": args.source_url or "",
        "buildConfigurationURL": args.build_configuration_url or "",
        "license": args.license or "",
        "distributionAllowed": bool(args.distribution_allowed),
    }
    template_block = build_template_block(args)
    if template_block:
        manifest["template"] = template_block
    return manifest


def verify_manifest(image_dir, manifest_path):
    image_dir = os.path.abspath(image_dir)
    with open(manifest_path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    problems = []

    def fail(message):
        problems.append(message)

    declared = [("bios", manifest.get("biosPath"))]
    for key, role in (("kernelPath", "kernel"), ("initrdPath", "initrd"), ("diskPath", "disk")):
        if manifest.get(key):
            declared.append((role, manifest[key]))
    artifacts = manifest.get("artifacts") or []
    by_role = {artifact.get("role"): artifact for artifact in artifacts}

    if not manifest.get("id"):
        fail("manifest has no id")
    if manifest.get("qualified"):
        if not (manifest.get("qualificationRun") or "").strip():
            fail("qualified=true without qualificationRun")
        if not artifacts:
            fail("qualified=true without artifact digests")
    for role, path in declared:
        artifact = by_role.get(role)
        if not artifact:
            fail("no digest for declared %s" % role)
            continue
        if artifact.get("path") != path:
            fail("%s digest path %r != manifest path %r" % (role, artifact.get("path"), path))
            continue
        digest = str(artifact.get("sha512", "")).strip().lower()
        if not HEX512.match(digest):
            fail("%s sha512 is not 128 hex chars" % role)
            continue
        if int(artifact.get("bytes", 0)) <= 0:
            fail("%s records no size" % role)
            continue
        target = path if os.path.isabs(path) else os.path.join(image_dir, path)
        if os.path.islink(target) or not os.path.isfile(target):
            fail("%s is missing or not a regular file: %s" % (role, target))
            continue
        actual_digest, actual_size = sha512_and_size(target)
        if actual_size != int(artifact["bytes"]):
            fail("%s size mismatch: on disk %d, manifest %d" % (role, actual_size, int(artifact["bytes"])))
        if actual_digest != digest:
            fail("%s SHA-512 mismatch" % role)

    template = manifest.get("template")
    if template is not None:
        if not isinstance(template, dict):
            fail("template block is not an object")
        else:
            if not str(template.get("id") or "").strip():
                fail("template.id is empty")
            digest = str(template.get("recipeSha512", "")).strip().lower()
            if not HEX512.match(digest):
                fail("template.recipeSha512 is not 128 hex chars")
            if not str(template.get("recipePath") or "").strip():
                fail("template.recipePath is empty")
            for key in TEMPLATE_LIST_KEYS:
                if not isinstance(template.get(key), list):
                    fail("template.%s is not a list" % key)
            verified = template.get("verified")
            if not isinstance(verified, bool):
                fail("template.verified is not a boolean")
            elif verified:
                for key in ("missingPackages", "belowMinimum", "pypiFailures"):
                    value = template.get(key)
                    if isinstance(value, list) and value:
                        fail("template.verified=true with non-empty %s" % key)
            elif not str(template.get("reason") or "").strip():
                fail("template.verified=false without a reason")

    if problems:
        for problem in problems:
            print("VERIFY FAIL: %s" % problem, file=sys.stderr)
        return 1
    print("VERIFY OK: %s" % manifest_path)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="write manifest.json from the image artifacts")
    write.add_argument("--image-dir", required=True)
    write.add_argument("--out", default=None, help="defaults to <image-dir>/manifest.json")
    write.add_argument("--id", required=True)
    write.add_argument("--bios", required=True)
    write.add_argument("--kernel", default=None)
    write.add_argument("--initrd", default=None)
    write.add_argument("--disk", default=None)
    write.add_argument("--cmdline", default=None)
    write.add_argument("--qualification-run", default=None)
    write.add_argument("--qualification-evidence", default=None)
    write.add_argument("--source-url", default=None)
    write.add_argument("--build-configuration-url", default=None)
    write.add_argument("--license", default=None)
    write.add_argument("--qualified", action="store_true", help="set only when the capability run really passed")
    write.add_argument("--distribution-allowed", action="store_true",
                       help="set only when corresponding source + license obligations are published")
    write.add_argument("--read-only-disk", action="store_true")
    write.add_argument("--template-id", default=None,
                       help="template id; emits the manifest template block")
    write.add_argument("--template-recipe", default=None,
                       help="the validated recipe file (required with --template-id)")
    write.add_argument("--template-json", default=None,
                       help="host copy of the guest's template-verify.json (stage 2)")
    write.add_argument("--template-install-json", default=None,
                       help="host copy of the guest's template-install.json (stage 1)")

    verify = sub.add_parser("verify", help="re-check a manifest the way LinuxGuestImageVerifier does")
    verify.add_argument("--image-dir", required=True)
    verify.add_argument("--manifest", default=None, help="defaults to <image-dir>/manifest.json")

    args = parser.parse_args(argv)
    if args.command == "write":
        image_dir = os.path.abspath(args.image_dir)
        manifest = build_manifest(args)
        out = args.out or os.path.join(image_dir, "manifest.json")
        with open(out, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=False)
            handle.write("\n")
        print("wrote %s (qualified=%s, artifacts=%d)" % (out, manifest["qualified"], len(manifest["artifacts"])))
        return 0
    manifest_path = args.manifest or os.path.join(os.path.abspath(args.image_dir), "manifest.json")
    return verify_manifest(args.image_dir, manifest_path)


if __name__ == "__main__":
    sys.exit(main())

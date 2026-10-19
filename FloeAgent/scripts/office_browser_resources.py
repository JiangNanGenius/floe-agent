#!/usr/bin/env python3
"""Bind the verified patched Office browser bundle into native components.

The producer (``build_office_browser_resources.py``) owns the real TypeScript
rebuild and its private receipt. This module is the narrow integration seam:

* validate the producer receipt *and* the live adjacent
  ``browser.patch.lock.json`` contract (frontend identity is separate from the
  native ``engine.patch.lock.json`` repair proof);
* stage only the verified ``bundle.js`` bytes into the owned native shadow,
  replacing the source alias path by path without ever writing through it;
* emit a compact, portable ``browserResources`` block for the native manifest.

The raw receipt contains private absolute paths and build logs, so it never
enters a portable manifest. Only the compact block below does::

    {
      "formatVersion": 1,
      "engineCommit": "<40 hex>",
      "browserPatchLockSHA256": "<64 hex>",
      "patches": [{
        "patch": "patches/relative.patch",
        "patchSHA256": "<64 hex>",
        "sourceFile": "browser/src/...",
        "originalSourceSHA256": "<64 hex>",
        "patchedSourceSHA256": "<64 hex>"
      }],
      "originalBundleSHA256": "<64 hex>",
      "bundleSHA256": "<64 hex>"
    }

No capability flag is set here: a rebuilt frontend resource is not an
App/Simulator/device acceptance result.
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile

import build_office_browser_resources as producer
from qualify_office_mobile import materialize

LOCK_NAME = "browser.patch.lock.json"
SHADOW_RELATIVE = "browser/dist/bundle.js"
RUNTIME_RESOURCE_KEY = "bundle.js"
COMPACT_FORMAT_VERSION = 1
EXPECTED_ORIGINAL_BUNDLE_SHA256 = producer.DEFAULT_EXPECTED_ORIGINAL_BUNDLE_SHA256

HEX64 = re.compile(r"^[0-9a-f]{64}$")

PATCH_KEYS = (
    "patch",
    "patchSHA256",
    "sourceFile",
    "originalSourceSHA256",
    "patchedSourceSHA256",
)
COMPACT_KEYS = frozenset(
    {"formatVersion", "engineCommit", "browserPatchLockSHA256", "patches",
     "originalBundleSHA256", "bundleSHA256"}
)
PATCH_BLOCK_KEYS = frozenset(PATCH_KEYS)


class BrowserResourceError(ValueError):
    """Fail-closed browser resource contract violation."""


def digest_file(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def _contained_relative(value, label):
    """Reject absolute/escaping/backslash paths in portable claims."""
    if not isinstance(value, str) or not value:
        raise BrowserResourceError("%s must be a non-empty relative path" % label)
    path = PurePosixPath(value)
    if (path.is_absolute() or ".." in path.parts or "\\" in value
            or str(path) != value):
        raise BrowserResourceError("%s must be a contained relative path" % label)
    return str(path)


def _portable_patch(entry):
    return {
        "patch": _contained_relative(entry["patch"], "patch"),
        "patchSHA256": entry["patchSHA256"],
        "sourceFile": _contained_relative(entry["sourceFile"], "sourceFile"),
        "originalSourceSHA256": entry["originalSourceSHA256"],
        "patchedSourceSHA256": entry["patchedSourceSHA256"],
    }


def live_contract(lock_path, *, engine_commit=None):
    """Return the validated live browser contract, or ``None`` when untracked.

    ``lock_path`` is the selected engine lock (tracked or a verified staging
    copy). The browser lock is the adjacent ``browser.patch.lock.json``. A
    missing file means this custom/fixture lock predates the frontend contract
    and stays compatible; a present but malformed/empty file is rejected so it
    cannot silently disable the requirement.
    """
    lock_path = Path(lock_path).resolve()
    browser_lock = lock_path.parent / LOCK_NAME
    # Check the symlink status before exists(): a dangling symlink reports
    # exists() == False and must not silently disable the contract.
    if browser_lock.is_symlink():
        raise BrowserResourceError(
            "browser patch lock is not a regular file: %s" % browser_lock)
    if not browser_lock.exists():
        return None
    if not browser_lock.is_file():
        raise BrowserResourceError(
            "browser patch lock is not a regular file: %s" % browser_lock)
    try:
        lock_obj = json.loads(browser_lock.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise BrowserResourceError(
            "browser patch lock is unreadable: %s" % error)
    try:
        repository, commit, entries = producer.validate_browser_lock(
            lock_obj, browser_lock.parent)
    except producer.ProducerError as error:
        raise BrowserResourceError(str(error))
    if engine_commit is not None and commit != engine_commit:
        raise BrowserResourceError(
            "browser patch lock engine commit differs from the selected engine lock")
    lock_sha = digest_file(browser_lock)
    return {
        "lockPath": str(browser_lock),
        "lockSHA256": lock_sha,
        "engineRepository": repository,
        "engineCommit": commit,
        "patches": [_portable_patch(entry) for entry in entries],
    }


def compact_block(contract, original_bundle_sha256, bundle_sha256):
    """Build the portable block from a validated live contract."""
    return {
        "formatVersion": COMPACT_FORMAT_VERSION,
        "engineCommit": contract["engineCommit"],
        "browserPatchLockSHA256": contract["lockSHA256"],
        "patches": [dict(patch) for patch in contract["patches"]],
        "originalBundleSHA256": original_bundle_sha256,
        "bundleSHA256": bundle_sha256,
    }


def canonical_block(block):
    """Return a field-exact copy so a manifest block can be pinned verbatim."""
    return {
        "formatVersion": block["formatVersion"],
        "engineCommit": block["engineCommit"],
        "browserPatchLockSHA256": block["browserPatchLockSHA256"],
        "patches": [{key: patch[key] for key in PATCH_KEYS}
                    for patch in block["patches"]],
        "originalBundleSHA256": block["originalBundleSHA256"],
        "bundleSHA256": block["bundleSHA256"],
    }


def compact_block_failures(block, contract, *, actual_bundle_sha256=None,
                           expected_original_bundle_sha256=None):
    """Strictly compare a portable block with the live contract/actual bytes."""
    expected_original = (EXPECTED_ORIGINAL_BUNDLE_SHA256
                         if expected_original_bundle_sha256 is None
                         else expected_original_bundle_sha256)
    if not isinstance(block, dict):
        return ["browserResources is not an object"]
    failures = []
    missing = sorted(COMPACT_KEYS - set(block))
    extra = sorted(set(block) - COMPACT_KEYS)
    if missing:
        failures.append("browserResources omits " + ", ".join(missing))
    if extra:
        failures.append("browserResources carries unexpected fields: "
                        + ", ".join(extra))
        # Never echo a value: an unexpected field may be a private path.
        return failures
    if block.get("formatVersion") != COMPACT_FORMAT_VERSION:
        failures.append("browserResources formatVersion is not 1")
    if block.get("engineCommit") != contract["engineCommit"]:
        failures.append("browserResources engine commit differs from the live browser contract")
    if block.get("browserPatchLockSHA256") != contract["lockSHA256"]:
        failures.append("browserResources browser patch lock hash differs from the live contract")
    patches = block.get("patches")
    if not isinstance(patches, list):
        failures.append("browserResources patches is not a list")
    elif len(patches) != len(contract["patches"]):
        failures.append("browserResources patch count differs from the live contract")
    else:
        for index, (claim, live) in enumerate(zip(patches, contract["patches"])):
            label = "browserResources patches[%d]" % index
            if not isinstance(claim, dict):
                failures.append(label + " is not an object")
                continue
            missing_fields = sorted(PATCH_BLOCK_KEYS - set(claim))
            extra_fields = sorted(set(claim) - PATCH_BLOCK_KEYS)
            if missing_fields:
                failures.append(label + " omits " + ", ".join(missing_fields))
            if extra_fields:
                failures.append(label + " carries unexpected fields: "
                                + ", ".join(extra_fields))
                continue
            for key in PATCH_KEYS:
                if claim.get(key) != live[key]:
                    failures.append(label + " %s differs from the live contract" % key)
            for key in ("patch", "sourceFile"):
                try:
                    _contained_relative(claim.get(key), label + " " + key)
                except BrowserResourceError as error:
                    failures.append(str(error))
    original = block.get("originalBundleSHA256")
    bundle = block.get("bundleSHA256")
    if not isinstance(original, str) or not HEX64.fullmatch(original):
        failures.append("browserResources originalBundleSHA256 is not lowercase sha256")
    elif original != expected_original:
        failures.append("browserResources original bundle differs from the pinned original")
    if not isinstance(bundle, str) or not HEX64.fullmatch(bundle):
        failures.append("browserResources bundleSHA256 is not lowercase sha256")
    elif isinstance(original, str) and bundle == original:
        failures.append("browserResources bundle is not the patched bundle")
    if actual_bundle_sha256 is not None and bundle != actual_bundle_sha256:
        failures.append("browserResources bundle digest differs from the packaged runtime bundle")
    return failures


def _require_dict(value, label):
    if not isinstance(value, dict):
        raise BrowserResourceError("%s is missing or not an object" % label)
    return value


def _require_string(value, label):
    if not isinstance(value, str) or not value:
        raise BrowserResourceError("%s is missing or empty" % label)
    return value


def validate_receipt(receipt_path, *, lock_path, base_bundle, engine_commit=None,
                     expected_original_bundle_sha256=None):
    """Validate a producer receipt against its live contract and the base tree.

    Returns an internal info object; only ``info["block"]`` is portable. The
    producer's own verification is run first, so its staged-source/bundle,
    patch-marker and dist-tree checks stay authoritative.
    """
    receipt_path = Path(receipt_path)
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise BrowserResourceError("browser resource receipt is not a regular file")
    expected_original = (EXPECTED_ORIGINAL_BUNDLE_SHA256
                         if expected_original_bundle_sha256 is None
                         else expected_original_bundle_sha256)
    contract = live_contract(lock_path, engine_commit=engine_commit)
    if contract is None:
        raise BrowserResourceError(
            "no live browser patch contract is tracked beside the selected engine lock")
    try:
        failures = producer.verify_receipt(
            receipt_path,
            lock_path=contract["lockPath"],
            expected_original_bundle_sha256=expected_original)
    except producer.ProducerError as error:
        raise BrowserResourceError("producer receipt verification failed: %s" % error)
    except (OSError, json.JSONDecodeError) as error:
        raise BrowserResourceError("browser resource receipt is unreadable: %s" % error)
    except (KeyError, IndexError, TypeError) as error:
        raise BrowserResourceError(
            "producer receipt verification failed: malformed receipt (%s)" % error)
    if failures:
        raise BrowserResourceError(
            "producer receipt verification failed: " + "; ".join(failures))
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise BrowserResourceError("browser resource receipt is unreadable: %s" % error)

    identity = _require_dict(receipt.get("frontendIdentity"), "frontendIdentity")
    if identity.get("browserPatchLockSHA256") != contract["lockSHA256"]:
        raise BrowserResourceError(
            "receipt browser patch lock identity differs from the live contract")
    if identity.get("engineCommit") != contract["engineCommit"]:
        raise BrowserResourceError(
            "receipt engine commit differs from the live browser contract")
    if identity.get("engineRepository") != contract["engineRepository"]:
        raise BrowserResourceError(
            "receipt engine repository differs from the live browser contract")
    if identity.get("coolVersionOverride") != contract["engineCommit"][:10]:
        raise BrowserResourceError(
            "receipt cool version override differs from the live browser contract")
    receipt_patches = identity.get("patches")
    if not isinstance(receipt_patches, list) or len(receipt_patches) != len(contract["patches"]):
        raise BrowserResourceError(
            "receipt browser patch inventory differs from the live contract")
    for index, (claim, live) in enumerate(zip(receipt_patches, contract["patches"])):
        if not isinstance(claim, dict):
            raise BrowserResourceError("receipt patch %d is not an object" % index)
        for key in PATCH_KEYS:
            if claim.get(key) != live[key]:
                raise BrowserResourceError(
                    "receipt patch %d %s differs from the live contract" % (index, key))
        if claim.get("stagedPatchedSHA256") != live["patchedSourceSHA256"]:
            raise BrowserResourceError(
                "receipt patch %d staged patched source differs from the live contract" % index)
        if claim.get("applied") is not True:
            raise BrowserResourceError("receipt patch %d was not applied" % index)

    base_bundle = Path(base_bundle)
    if base_bundle.is_symlink() or not base_bundle.is_file():
        raise BrowserResourceError("base browser bundle is not a regular file")
    base_sha = digest_file(base_bundle)
    inputs = _require_dict(receipt.get("inputs"), "inputs")
    if inputs.get("restoredOriginalBundleSHA256") != base_sha:
        raise BrowserResourceError(
            "receipt original bundle identity differs from the actual base bundle")
    if base_sha != expected_original:
        raise BrowserResourceError(
            "base browser bundle is not the pinned verified original")

    output = _require_dict(receipt.get("output"), "output")
    output_bundle = Path(_require_string(output.get("bundle"), "output.bundle"))
    if output_bundle.is_symlink() or not output_bundle.is_file():
        raise BrowserResourceError("receipt output bundle is not a regular file")
    if output_bundle.name != "bundle.js":
        raise BrowserResourceError("receipt output bundle is not named bundle.js")
    bundle_sha = digest_file(output_bundle)
    if output.get("bundleSHA256") != bundle_sha:
        raise BrowserResourceError("receipt output bundle digest does not match the file")
    patched = _require_dict(receipt.get("patchedBuild"), "patchedBuild")
    if patched.get("distBundleSHA256") != bundle_sha:
        raise BrowserResourceError(
            "receipt output bundle differs from its patched build digest")
    if bundle_sha == base_sha:
        raise BrowserResourceError("receipt output is the original bundle, not a patched rebuild")

    return {
        "contract": contract,
        "block": compact_block(contract, base_sha, bundle_sha),
        "bundlePath": output_bundle,
        "bundleSHA256": bundle_sha,
        "originalBundleSHA256": base_sha,
    }


def _owned_shadow_path(shadow, base_source):
    shadow = Path(shadow)
    base_source = Path(base_source).resolve()
    if shadow.is_symlink() or not shadow.is_dir():
        raise BrowserResourceError("native shadow source is not an owned directory")
    relative = PurePosixPath(SHADOW_RELATIVE)
    base_bundle = base_source / relative
    if base_bundle.is_symlink() or not base_bundle.is_file():
        raise BrowserResourceError("base browser bundle is not a regular file")
    shadow_bundle = shadow / relative
    try:
        resolved = shadow_bundle.resolve(strict=True)
    except OSError as error:
        raise BrowserResourceError("native shadow browser bundle is missing: %s" % error)
    if resolved != base_bundle.resolve():
        raise BrowserResourceError(
            "native shadow browser bundle is not the verified base alias")
    return shadow, base_source, relative, base_bundle, shadow_bundle


def stage_bundle(shadow, base_source, info):
    """Replace the shadow's alias path with an owned copy of the verified file.

    Every digest/identity check already ran in ``validate_receipt``. This
    function re-checks the actual base bytes immediately before mutation and
    proves the base file is byte-identical afterwards.
    """
    shadow, base_source, relative, base_bundle, shadow_bundle = _owned_shadow_path(
        shadow, base_source)
    if digest_file(base_bundle) != info["originalBundleSHA256"]:
        raise BrowserResourceError("base browser bundle changed before staging")
    before_base = digest_file(base_bundle)

    materialize(shadow, base_source, str(relative))
    if shadow_bundle.is_symlink() or not shadow_bundle.is_file():
        raise BrowserResourceError("materialized browser bundle is not an owned regular file")
    for parent in (shadow_bundle.parent, shadow_bundle.parent.parent):
        if parent.is_symlink():
            raise BrowserResourceError("materialized browser bundle still has an alias parent")
    if not shadow_bundle.is_relative_to(shadow):
        raise BrowserResourceError("materialized browser bundle escapes the native shadow")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".bundle.js.", suffix=".tmp", dir=str(shadow_bundle.parent))
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with info["bundlePath"].open("rb") as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target)
        os.chmod(temporary, 0o644)
        os.replace(temporary, shadow_bundle)
    finally:
        if temporary.exists():
            temporary.unlink()

    if shadow_bundle.is_symlink() or not shadow_bundle.is_file():
        raise BrowserResourceError("staged browser bundle is not an owned regular file")
    staged_sha = digest_file(shadow_bundle)
    if staged_sha != info["bundleSHA256"]:
        raise BrowserResourceError("staged browser bundle digest differs from the receipt")
    if digest_file(base_bundle) != before_base:
        raise BrowserResourceError("staging mutated the verified base browser bundle")
    return shadow_bundle


def stage_for_build(*, lock_path, receipt_path, shadow, base_source, build,
                    engine_commit=None, expected_original_bundle_sha256=None):
    """Apply the browser resource contract for one native component build.

    A nonempty live contract requires a verified receipt for an actual new
    build. Prepare-only diagnostics and custom locks without a contract stay
    backward compatible; a receipt without a live contract is never guessed.
    """
    contract = live_contract(lock_path, engine_commit=engine_commit)
    if contract is None:
        if receipt_path is not None:
            raise BrowserResourceError(
                "a browser resource receipt was supplied but the selected engine "
                "lock has no live browser patch contract")
        return None
    if receipt_path is None:
        if build:
            raise BrowserResourceError(
                "the live browser patch contract requires a verified browser "
                "resource receipt for a new native component build")
        return None
    info = validate_receipt(
        receipt_path,
        lock_path=lock_path,
        base_bundle=Path(base_source) / SHADOW_RELATIVE,
        engine_commit=engine_commit,
        expected_original_bundle_sha256=expected_original_bundle_sha256,
    )
    stage_bundle(shadow, base_source, info)
    return info["block"]


def apply_to_report(report, *, lock_path, receipt_path, shadow, base_source, build,
                    engine_commit=None, expected_original_bundle_sha256=None):
    """Stage and copy only the compact portable block into a build report."""
    block = stage_for_build(
        lock_path=lock_path,
        receipt_path=receipt_path,
        shadow=shadow,
        base_source=base_source,
        build=build,
        engine_commit=engine_commit,
        expected_original_bundle_sha256=expected_original_bundle_sha256,
    )
    if block is not None:
        report["browserResources"] = block
    return block


def runtime_bundle_sha256(runtime_hashes):
    """The packaged runtime bundle digest, or ``None`` when absent/ill-formed."""
    if not isinstance(runtime_hashes, dict):
        return None
    value = runtime_hashes.get(RUNTIME_RESOURCE_KEY)
    return value if isinstance(value, str) and HEX64.fullmatch(value) else None

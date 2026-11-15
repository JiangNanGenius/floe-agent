#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Emit or verify a truthful Linux graphics capability declaration.

The declaration is the bridge between installed artifacts and the App's
optional image-manifest capability block. A capability is only emitted when
every artifact required by CAPABILITY-POLICY.json is present and non-empty at
the supplied install root. Evidence is the exact artifact digest plus the
qualification identifier; it is never inferred from source presence or a
planned build.

This is a packaging-time check. It does not execute a GPU, VM, codec or App.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import NoReturn

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
POLICY = REPO / "LinuxGuest" / "image" / "graphics" / "CAPABILITY-POLICY.json"
SCHEMA_VERSION = 1
FEATURE_KEYS = {"venusVulkan", "openGL", "openCL", "shaderCache"}
VIDEO_KEYS = {"video.hardwareDecode": "hardwareDecode",
              "video.hardwareEncode": "hardwareEncode",
              "video.nativeSoftware": "nativeSoftware"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_policy() -> dict:
    if not POLICY.is_file():
        fail(f"missing {POLICY}")
    policy = json.loads(POLICY.read_text())
    if policy.get("schema") != "floe.linux-graphics.capability-policy.v1":
        fail("unexpected capability policy schema")
    return policy


def artifact_digests(root: Path, capability: str, policy: dict) -> dict[str, str]:
    rule = policy["capabilities"].get(capability)
    if rule is None:
        fail(f"unknown capability {capability}")
    digests: dict[str, str] = {}
    for relative in rule["requires"]:
        path = root / relative
        if not path.is_file():
            fail(f"capability {capability} requires missing artifact {path}")
        if path.stat().st_size == 0:
            fail(f"capability {capability} requires non-empty artifact {path}")
        digests[relative] = sha256(path)
    return digests


def verify_build_receipt(path: Path) -> str:
    if not path.is_file():
        fail(f"shaderCache requires a build receipt, missing {path}")
    receipt = json.loads(path.read_text())
    if receipt.get("schema") != "floe.graphics.build-receipt.v1":
        fail("build receipt has an unexpected schema")
    if "guest-mesa-25.0.7" not in str(receipt.get("series", "")):
        fail("build receipt is not for the guest Mesa 25.0.7 series")
    options = receipt.get("mesonOptions")
    if not isinstance(options, list):
        fail("build receipt has no mesonOptions list")
    required = ["-Dshader-cache=enabled", "-Dshader-cache-max-size=64M"]
    for option in required:
        if option not in options:
            fail(f"build receipt does not record {option}")
    return sha256(path)


def make_feature(root: Path, capability: str, policy: dict, qualification: str,
                 receipt_sha256: str | None = None) -> dict:
    digests = artifact_digests(root, capability, policy)
    evidence = ";".join(f"{name}@sha256:{digest}" for name, digest in sorted(digests.items()))
    if capability == "shaderCache":
        if not receipt_sha256:
            fail("shaderCache requires --build-receipt with the recorded cache options")
        evidence += f";build-receipt@sha256:{receipt_sha256}"
    return {
        "available": True,
        "evidence": f"{qualification}|{evidence}",
        "limitation": None,
    }


def build_declaration(root: Path, declared: list[str], qualification: str, policy: dict,
                      receipt_sha256: str | None = None) -> dict:
    if not qualification or "/" in qualification or "|" in qualification:
        fail("--qualification must be a non-empty identifier without '/' or '|'")
    requested = set(declared)
    for capability in requested:
        if capability not in policy["capabilities"]:
            fail(f"unknown capability {capability}")
    for capability in sorted(requested):
        for gate in policy["capabilities"][capability].get("gates", []):
            if gate not in requested:
                fail(f"capability {capability} requires the declared gate {gate}")

    features = {key: {"available": False, "evidence": None, "limitation": None}
                for key in FEATURE_KEYS}
    for capability in requested & FEATURE_KEYS:
        features[capability] = make_feature(root, capability, policy, qualification, receipt_sha256)

    video = {}
    for policy_key, field in VIDEO_KEYS.items():
        if policy_key in requested:
            video[field] = make_feature(root, policy_key, policy, qualification)
        else:
            video[field] = {"available": False, "evidence": None, "limitation": None}

    declaration = {
        "schemaVersion": SCHEMA_VERSION,
        "venusVulkan": features["venusVulkan"],
        "openGL": features["openGL"],
        "openCL": features["openCL"],
        "shaderCache": features["shaderCache"],
        "video": video,
    }
    if not features["venusVulkan"]["available"]:
        for key in ("openGL", "openCL", "shaderCache"):
            if features[key]["available"]:
                fail(f"{key} cannot be available without venusVulkan")
    return declaration


def verify_declaration(root: Path, declaration: dict, policy: dict) -> list[str]:
    errors: list[str] = []
    if declaration.get("schemaVersion") != SCHEMA_VERSION:
        errors.append("unsupported schemaVersion")

    def check_feature(name: str, feature: dict) -> None:
        if feature.get("available"):
            metric = (feature.get("evidence") or "").strip()
            if not metric:
                errors.append(f"{name}: available without evidence")
            # Re-derive the artifact digests and require each to appear.
            try:
                digests = artifact_digests(root, name, policy)
            except SystemExit:
                errors.append(f"{name}: required artifacts missing")
                return
            for artifact, digest in digests.items():
                if digest not in metric:
                    errors.append(f"{name}: evidence does not bind {artifact}")
            if name == "shaderCache" and "build-receipt@sha256:" not in metric:
                errors.append("shaderCache: evidence does not bind a build receipt")
        elif feature.get("evidence"):
            errors.append(f"{name}: unavailable but carries evidence")

    for key in FEATURE_KEYS:
        check_feature(key, declaration.get(key) or {})
    for policy_key, field in VIDEO_KEYS.items():
        check_feature(policy_key, (declaration.get("video") or {}).get(field) or {})

    if (declaration.get("openGL") or {}).get("available") and \
            not (declaration.get("venusVulkan") or {}).get("available"):
        errors.append("openGL without venusVulkan")
    if (declaration.get("shaderCache") or {}).get("available") and \
            not (declaration.get("openGL") or {}).get("available"):
        errors.append("shaderCache without openGL")
    if (declaration.get("openCL") or {}).get("available") and \
            not (declaration.get("venusVulkan") or {}).get("available"):
        errors.append("openCL without venusVulkan")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True,
                        help="installed root containing the policy's relative artifact paths")
    parser.add_argument("--declare", default="",
                        help="comma-separated capabilities, e.g. venusVulkan,openGL,shaderCache")
    parser.add_argument("--qualification", required=True,
                        help="qualification identifier binding this image/artifact set")
    parser.add_argument("--out", type=Path,
                        help="write the declaration here (default: stdout)")
    parser.add_argument("--verify", type=Path,
                        help="verify an existing declaration against --artifacts instead of emitting")
    parser.add_argument("--build-receipt", type=Path,
                        help="required when declaring shaderCache; records the actual Meson cache options")
    args = parser.parse_args()

    policy = load_policy()
    root = args.artifacts.expanduser().resolve()
    if not root.is_dir():
        fail(f"artifact root is not a directory: {root}")

    if args.verify:
        declaration = json.loads(args.verify.read_text())
        errors = verify_declaration(root, declaration, policy)
        result = {
            "schema": "floe.linux-graphics.capability-verification.v1",
            "status": "passed" if not errors else "failed",
            "errors": errors,
        }
        print(json.dumps(result, indent=2))
        return 0 if not errors else 1

    declared = [item.strip() for item in args.declare.split(",") if item.strip()]
    receipt_sha = None
    if "shaderCache" in declared:
        if not args.build_receipt:
            fail("shaderCache requires --build-receipt")
        receipt_sha = verify_build_receipt(args.build_receipt.expanduser().resolve())
    declaration = build_declaration(root, declared, args.qualification, policy, receipt_sha)
    text = json.dumps(declaration, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

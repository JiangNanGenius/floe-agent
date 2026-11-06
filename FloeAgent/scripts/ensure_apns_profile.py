#!/usr/bin/env python3
"""Resolve a production-push profile for the existing App and certificate.

Runs only in the authenticated signing step. It never creates/revokes a
certificate, edits an App Store submission, sends a push, or prints secrets.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from sign_app_store_extensions import (APP_ID, TEAM, decode_profile,
    production_host_entitlements, read_plist, require, validated_entitlements)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def exact_bundle_id(candidates):
    # Apple's filter can include related identifiers; identity is still exact.
    bundles = [row for row in candidates if row.get("attributes", {}).get("identifier") == APP_ID]
    require(len(bundles) == 1, "Expected one exact registered App identifier")
    return bundles[0]["id"]


class AppleAPI:
    def __init__(self):
        self.token = subprocess.check_output(
            [sys.executable, str(Path(__file__).with_name("generate_asc_jwt.py"))], text=True).strip()

    def call(self, method, path, body=None):
        require(path.startswith("/v1/") and not path.startswith("//"), "Unexpected API path")
        payload = None if body is None else json.dumps(body).encode()
        request = Request("https://api.appstoreconnect.apple.com" + path, data=payload, method=method,
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=45) as response:
                return json.load(response)
        except HTTPError as error:
            raise ValueError("Apple signing API returned HTTP " + str(error.code)) from None

    def rows(self, path):
        rows = []
        while path:
            result = self.call("GET", path)
            rows.extend(result.get("data", []))
            next_link = result.get("links", {}).get("next")
            if next_link:
                prefix = "https://api.appstoreconnect.apple.com"
                require(next_link.startswith(prefix + "/v1/"), "Unexpected pagination host")
                path = next_link[len(prefix):]
            else:
                path = None
        return rows


def ensure_profile(api, profile_path, declared, report):
    original = profile_path.read_bytes()
    old = decode_profile(profile_path)
    # Preserve all existing capability and identity checks before account writes.
    without_push = {key: value for key, value in declared.items() if key != "aps-environment"}
    validated_entitlements(old, without_push, APP_ID)
    report.update(originalSHA256=digest(original), bundleID=APP_ID, created=False, profileReplaced=False)
    if "aps-environment" not in declared:
        report["state"] = "not-requested"
        return
    if old.get("Entitlements", {}).get("aps-environment") == "production":
        validated_entitlements(old, declared, APP_ID)
        report.update(state="existing-profile-verified", profileSHA256=digest(original))
        return

    bundle_id = exact_bundle_id(api.rows("/v1/bundleIds?" + urlencode({"filter[identifier]": APP_ID, "limit": 2})))
    caps_path = "/v1/bundleIds/" + bundle_id + "/bundleIdCapabilities?limit=200"
    caps = api.rows(caps_path)
    if not any(row["attributes"].get("capabilityType") == "PUSH_NOTIFICATIONS" for row in caps):
        api.call("POST", "/v1/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities", "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}}}})
        report["enabledPushCapability"] = True
        require(any(row["attributes"].get("capabilityType") == "PUSH_NOTIFICATIONS"
                    for row in api.rows(caps_path)), "Push capability read-back failed")

    old_certificates = {digest(bytes(value)) for value in old.get("DeveloperCertificates", [])}
    require(bool(old_certificates), "Existing certificate binding missing")
    matching = []
    for certificate in api.rows("/v1/certificates?limit=200"):
        attributes = certificate.get("attributes", {})
        content = attributes.get("certificateContent")
        if not content:
            attributes = api.call("GET", "/v1/certificates/" + certificate["id"])["data"]["attributes"]
            content = attributes.get("certificateContent")
        if content and digest(base64.b64decode(content, validate=True)) in old_certificates:
            matching.append(certificate["id"])
    require(len(matching) == 1, "Expected one existing distribution certificate; no certificate is created")
    # Preserve the account-side state even when later validation fails.
    # A transport failure after this boundary cannot prove no profile was created.
    report.update(profileCreationAttempted=True, created=None)
    result = api.call("POST", "/v1/profiles", {"data": {
        "type": "profiles", "attributes": {
            "name": "Floe Production Push " + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"),
            "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": matching[0]}]}}}})
    require(result.get("data", {}).get("type") == "profiles" and
            isinstance(result["data"].get("id"), str) and bool(result["data"]["id"]),
            "Unexpected profile creation response")
    report["created"] = True
    payload = base64.b64decode(result["data"]["attributes"]["profileContent"], validate=True)
    staged = profile_path.with_suffix(".push-candidate.mobileprovision")
    try:
        with staged.open("xb") as stream:
            os.chmod(staged, 0o600)
            stream.write(payload)
        new = decode_profile(staged)
        validated_entitlements(new, declared, APP_ID)
        require(new.get("TeamIdentifier") == [TEAM] and
                {digest(bytes(value)) for value in new.get("DeveloperCertificates", [])} == old_certificates,
                "Replacement profile changed the existing certificate binding")
        os.replace(staged, profile_path)
        report["profileReplaced"] = True
    finally:
        if staged.exists():
            staged.unlink()
    report.update(state="production-profile-verified", created=True, profileSHA256=digest(payload),
                  expiration=new["ExpirationDate"].isoformat())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path("."))
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = {"state": "started", "noCertificateCreated": True, "noAppStoreSubmissionChanged": True}
    try:
        declared = production_host_entitlements(
            read_plist(args.source_root / "FloeApp/Entitlements/Floe.entitlements"),
            read_plist(args.app / "Info.plist"))
        # API credentials are only loaded when the requested grant is absent.
        old = decode_profile(args.profile)
        api = None if "aps-environment" not in declared or old.get("Entitlements", {}).get("aps-environment") == "production" else AppleAPI()
        ensure_profile(api, args.profile, declared, report)
    except Exception as error:
        report.update(state="failed", error=str(error) if isinstance(error, ValueError) else type(error).__name__)
        raise SystemExit("Production push profile preparation failed; see the redacted signing report.") from None
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        os.chmod(args.report, 0o600)
    print("Production push signing profile verified; no App Store submission changed.")


if __name__ == "__main__":
    main()

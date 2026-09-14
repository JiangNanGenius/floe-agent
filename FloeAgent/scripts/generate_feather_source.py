#!/usr/bin/env python3
"""Generate Floe's Feather/AltStore feed from the actual published unsigned IPA.

The caller verifies publication and provenance before replacing the live feed.
Schema reference: claration/Feather, AltSourceKit/Models/ASRepository.swift.
No signing credentials or third-party implementation code are included.
"""
import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
from pathlib import Path
from urllib.parse import quote
import zipfile

REPOSITORY = "JiangNanGenius/floe-agent"
SOURCE_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/feather.json"
ICON_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/docs/images/floe-agent-icon.png"
DESCRIPTION = (
    "Floe Agent: iPad-first AI tasks, Notes, Canvas and document editing. "
    "This beta IPA requires your own signing certificate and provisioning profile in Feather. "
    "It is separate from the signed TestFlight distribution."
)


def generate(ipa, tag, source_sha, released_at, previous=None):
    ipa = Path(ipa)
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-beta\.[1-9]\d*)?", tag):
        raise ValueError("Expected an immutable Floe release tag")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Expected a full source commit SHA")
    date = dt.datetime.fromisoformat(released_at.replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError("Release timestamp must include a timezone")
    with zipfile.ZipFile(ipa) as archive:
        candidates = [n for n in archive.namelist()
                      if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(candidates) != 1:
            raise ValueError("IPA must contain exactly one top-level application")
        if any("_CodeSignature" in n.split("/") or n.endswith("/embedded.mobileprovision")
               for n in archive.namelist()):
            raise ValueError("Only the unsigned developer IPA belongs in this source")
        if archive.getinfo(candidates[0]).file_size > 1024 * 1024:
            raise ValueError("Unexpected application metadata size")
        info = plistlib.loads(archive.read(candidates[0]))
    bundle = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    minimum_os = info.get("MinimumOSVersion")
    if bundle != "org.floeagent.ios":
        raise ValueError("Unexpected application bundle identifier")
    if not isinstance(version, str) or tag.split("-beta.")[0] != "v" + version:
        raise ValueError("Release tag does not match the IPA version")
    if not isinstance(build, str) or not build.isdecimal():
        raise ValueError("IPA build must be a numeric string")
    if not isinstance(minimum_os, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum_os):
        raise ValueError("IPA must declare its minimum OS")
    expected_name = f"Floe-Agent-{version}-build{build}-unsigned.ipa"
    if ipa.name != expected_name:
        raise ValueError("IPA filename must match its real version and build")
    digest = hashlib.sha256()
    with ipa.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    download = f"https://github.com/{REPOSITORY}/releases/download/{quote(tag, safe='')}/{quote(ipa.name)}"
    entry = {
        "version": version, "buildVersion": build, "date": released_at,
        "localizedDescription": f"Floe Agent {version} (build {build}). " + DESCRIPTION,
        "downloadURL": download, "size": ipa.stat().st_size,
        "minOSVersion": minimum_os, "sha256": digest.hexdigest(),
        "sourceCommit": source_sha,
    }
    history = []
    if previous:
        apps = previous.get("apps", [])
        if len(apps) != 1 or apps[0].get("bundleIdentifier") != bundle:
            raise ValueError("Previous feed belongs to a different application")
        history = apps[0].get("versions", [])
        if any(int(item["buildVersion"]) > int(build) for item in history):
            raise ValueError("Refusing to roll the published source back to an older build")
        history = [item for item in history if item.get("buildVersion") != build]
    app = {
        "name": "Floe Agent", "bundleIdentifier": bundle,
        "developerName": "JiangNanGenius", "iconURL": ICON_URL,
        "localizedDescription": DESCRIPTION, "subtitle": "AI workspace for iPad and iPhone",
        "beta": True, "versions": [entry] + history[:9],
        # Legacy fields remain compatible with older Feather/source readers.
        "version": version, "versionDate": released_at, "size": entry["size"],
        "downloadURL": download,
    }
    return {"name": "Floe Agent Beta", "identifier": "org.floeagent.source",
            "sourceURL": SOURCE_URL, "website": f"https://github.com/{REPOSITORY}",
            "iconURL": ICON_URL, "apps": [app], "news": []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--released-at", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--previous-source", type=Path)
    args = parser.parse_args()
    previous = json.loads(args.previous_source.read_text()) if args.previous_source else None
    payload = generate(args.ipa, args.tag, args.source_sha, args.released_at, previous)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(args.output)
    print(f"Generated {args.output}: {payload['apps'][0]['versions'][0]['buildVersion']}")


if __name__ == "__main__":
    main()

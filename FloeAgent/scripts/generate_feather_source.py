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


IDENTITY_KEYS = ('version', 'buildVersion', 'downloadURL', 'size', 'minOSVersion',
                 'sha256', 'sourceCommit')


def checked_build(entry):
    """Validate preserved feed identity, without claiming a new binary audit."""
    if not isinstance(entry, dict) or not isinstance(entry.get('buildVersion'), str) \
            or not re.fullmatch(r'[1-9][0-9]*', entry['buildVersion']):
        raise ValueError('Previous feed contains an invalid build identity')
    version = entry.get('version')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Previous feed contains an invalid version')
    name = f"Floe-Agent-{version}-build{entry['buildVersion']}-unsigned.ipa"
    base = f'https://github.com/{REPOSITORY}/releases/download/'
    url = entry.get('downloadURL', '')
    if not isinstance(url, str) or not url.startswith(base):
        raise ValueError('Previous feed has a foreign download URL')
    path = url[len(base):].split('/')
    if len(path) != 2 or path[1] != name or not re.fullmatch(
            re.escape('v' + version) + r'(?:-beta\.[1-9][0-9]*)?', path[0]):
        raise ValueError('Previous feed URL does not match its version/build')
    if type(entry.get('size')) is not int or entry['size'] <= 0 \
            or not re.fullmatch(r'[0-9a-f]{64}', str(entry.get('sha256', ''))) \
            or not re.fullmatch(r'[0-9a-f]{40}', str(entry.get('sourceCommit', ''))) \
            or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(entry.get('minOSVersion', ''))):
        raise ValueError('Previous feed has incomplete immutable binary metadata')
    return int(entry['buildVersion'])


def merge_versions(entry, history, *, historical=False, preserve_latest_tag=''):
    build = checked_build(entry)
    if not isinstance(history, list):
        raise ValueError('Previous feed versions must be an array')
    indexed = {}
    for item in history:
        number = checked_build(item)
        if number in indexed and any(indexed[number].get(k) != item.get(k) for k in IDENTITY_KEYS):
            raise ValueError('Previous feed has conflicting duplicate builds')
        indexed.setdefault(number, item)
    if build in indexed and any(indexed[build].get(k) != entry.get(k) for k in IDENTITY_KEYS):
        raise ValueError('Refusing to replace an existing build with different source or bytes')
    newest = max(indexed, default=build)
    if historical:
        if not indexed or build >= newest or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', preserve_latest_tag):
            raise ValueError('Historical insertion needs an older build and an explicit preserved stable tag')
        head = indexed[newest]
        if history[0]['buildVersion'] != head['buildVersion']:
            raise ValueError('Previous feed head is not its newest build')
        if f'/download/{preserve_latest_tag}/' not in head['downloadURL']:
            raise ValueError('Previous feed head does not match the preserved latest tag')
    elif preserve_latest_tag or build < newest:
        raise ValueError('Refusing to roll the published source back to an older build')
    indexed[build] = entry
    return [indexed[number] for number in sorted(indexed, reverse=True)]


def generate(ipa, tag, source_sha, released_at, previous=None, *,
             historical=False, preserve_latest_tag=''):
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
        if historical and history:
            for app_key, version_key in (('version', 'version'), ('versionDate', 'date'),
                                         ('size', 'size'), ('downloadURL', 'downloadURL')):
                if apps[0].get(app_key) != history[0].get(version_key):
                    raise ValueError('Previous feed legacy fields do not match its preserved head')
    versions = merge_versions(entry, history, historical=historical,
                              preserve_latest_tag=preserve_latest_tag)
    head = versions[0]
    app = {
        "name": "Floe Agent", "bundleIdentifier": bundle,
        "developerName": "JiangNanGenius", "iconURL": ICON_URL,
        "localizedDescription": DESCRIPTION, "subtitle": "AI workspace for iPad and iPhone",
        "beta": True, "versions": versions,
        # Legacy fields remain compatible with older Feather/source readers.
        "version": head['version'], "versionDate": head['date'], "size": head['size'],
        "downloadURL": head['downloadURL'],
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
    parser.add_argument("--historical", action='store_true',
                        help='Insert a verified older release without changing the newest/legacy entry')
    parser.add_argument("--preserve-latest-tag", default='')
    args = parser.parse_args()
    previous = json.loads(args.previous_source.read_text()) if args.previous_source else None
    payload = generate(args.ipa, args.tag, args.source_sha, args.released_at, previous,
                       historical=args.historical, preserve_latest_tag=args.preserve_latest_tag)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(args.output)
    print(f"Generated {args.output}: latest build {payload['apps'][0]['versions'][0]['buildVersion']}; included {args.tag}")


if __name__ == "__main__":
    main()

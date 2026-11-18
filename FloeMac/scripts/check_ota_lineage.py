#!/usr/bin/env python3
"""Offline metadata preflight for Bridge -> Floe Mac OTA candidates.

Inputs are Info.plist files extracted from the actual old and new app bundles.
This check does not validate signatures, notarization, OS/architecture
compatibility, data access, updater behavior, or an actual installation.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit
from xml.parsers.expat import ExpatError

EXPECTED_BUNDLE_ID = "org.floeagent.macbridge"
VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}\Z", re.ASCII)
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z", re.ASCII)


class LineageError(ValueError):
    """A candidate failed the conservative metadata contract."""


def field(info: dict, key: str, label: str) -> str:
    value = info.get(key)
    if not isinstance(value, str) or not value or value != value.strip():
        raise LineageError(f"{label}: missing or invalid {key}")
    if "$" in value or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise LineageError(f"{label}: unresolved or invalid {key}")
    return value


def version(info: dict, label: str) -> tuple[int, int, int]:
    value = field(info, "CFBundleVersion", label)
    if not VERSION_PATTERN.fullmatch(value):
        raise LineageError(f"{label}: CFBundleVersion must contain one to three numeric components")
    parts = value.split(".")
    if any(len(part) > 18 for part in parts):
        raise LineageError(f"{label}: CFBundleVersion component is too large")
    numbers = [int(part) for part in parts]
    return tuple(numbers + [0] * (3 - len(numbers)))


def public_key(info: dict, label: str) -> bytes:
    value = field(info, "SUPublicEDKey", label)
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise LineageError(f"{label}: SUPublicEDKey is not valid base64") from None
    if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != value:
        raise LineageError(f"{label}: SUPublicEDKey must be a canonical 32-byte Ed25519 public key")
    return raw


def feed_url(info: dict, label: str) -> str:
    value = field(info, "SUFeedURL", label)
    if any(char.isspace() for char in value):
        raise LineageError(f"{label}: SUFeedURL contains whitespace")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError:
        raise LineageError(f"{label}: SUFeedURL has an invalid authority") from None
    if (parsed.scheme != "https" or not hostname or parsed.username is not None
            or parsed.password is not None or parsed.fragment or port == 0):
        raise LineageError(f"{label}: SUFeedURL must be an HTTPS URL without credentials or fragment")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        try:
            domain = hostname.encode("idna").decode("ascii").lower()
        except UnicodeError:
            raise LineageError(f"{label}: SUFeedURL has an invalid host") from None
        if len(domain) > 253 or any(not DNS_LABEL.fullmatch(part) for part in domain.split(".")):
            raise LineageError(f"{label}: SUFeedURL has an invalid host")
    return value


def read_plist(path: Path, label: str) -> dict:
    try:
        with path.open("rb") as file:
            info = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException, ExpatError, ValueError, TypeError, OverflowError) as error:
        raise LineageError(f"{label}: cannot read Info.plist: {error}") from None
    if not isinstance(info, dict):
        raise LineageError(f"{label}: Info.plist root must be a dictionary")
    return info


def check_lineage(old: dict, new: dict) -> None:
    for label, info in (("old", old), ("new", new)):
        if field(info, "CFBundleIdentifier", label) != EXPECTED_BUNDLE_ID:
            raise LineageError(f"{label}: CFBundleIdentifier must be {EXPECTED_BUNDLE_ID}")
    if version(new, "new") <= version(old, "old"):
        raise LineageError("new: CFBundleVersion must be strictly greater than old")
    if public_key(old, "old") != public_key(new, "new"):
        raise LineageError("new: SUPublicEDKey differs from old")
    if feed_url(old, "old") != feed_url(new, "new"):
        raise LineageError("new: SUFeedURL differs from old")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old_info", type=Path, help="installed Bridge Contents/Info.plist")
    parser.add_argument("new_info", type=Path, help="candidate Mac App Contents/Info.plist")
    args = parser.parse_args()
    try:
        check_lineage(read_plist(args.old_info, "old"), read_plist(args.new_info, "new"))
    except LineageError as error:
        print(f"OTA metadata preflight failed: {error}", file=sys.stderr)
        return 1
    print("OTA lineage metadata compatible (offline check only).")
    print("Not verified: code/update signatures, notarization, system compatibility, user data, or actual OTA installation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

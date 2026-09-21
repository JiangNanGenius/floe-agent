#!/usr/bin/env python3
"""Office release-capability gates.

A framework that compiles and links is not a release-qualified editor. Four
capabilities must be *proven* by an artifact before any release may ship Office:

  embeddedEditorPassed          the actual App embedded the qualified host
  pptxVisibleRenderPassed       a presentation painted a real document tile
  deviceRoundtripPassed         edit, save, close and reopen on a real device
  originalFileWritebackPassed   the saved working copy reached the original file

Each true claim must carry provenance (device model, OS, run identity and the
observed document facts). A claim without provenance is rejected, so device
evidence cannot be manufactured; an absent flag is false, never inferred. The
existing compile/link receipts stay false for all four until such evidence
exists.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
HOST_SOURCES = ROOT / "ThirdParty/Collabora/FloeOfficeNative"

CAPABILITY_FLAGS = (
    "embeddedEditorPassed",
    "pptxVisibleRenderPassed",
    "deviceRoundtripPassed",
    "originalFileWritebackPassed",
)

# Evidence key, the fields it must carry, and the flag it backs.
EVIDENCE = {
    "embeddedEditorPassed": {
        "key": "embeddedEditorEvidence",
        "fields": ("runID", "appBuildVersion", "payloadVerified", "recordedAt"),
        "booleans": ("payloadVerified",),
    },
    "pptxVisibleRenderPassed": {
        "key": "pptxVisibleRenderEvidence",
        "fields": ("runID", "deviceModel", "osVersion", "documentType", "readyTiles",
                   "canvasWidth", "canvasHeight", "elapsedMs", "recordedAt"),
        "positive": ("readyTiles", "canvasWidth", "canvasHeight"),
        "numbers": ("readyTiles", "canvasWidth", "canvasHeight", "elapsedMs"),
    },
    "deviceRoundtripPassed": {
        "key": "deviceRoundtripEvidence",
        "fields": ("runID", "deviceModel", "osVersion", "documentTypes", "recordedAt"),
    },
    "originalFileWritebackPassed": {
        "key": "originalFileWritebackEvidence",
        "fields": ("runID", "deviceModel", "documentType", "savedSHA256", "recordedAt"),
    },
}

HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _evidence_failures(flag, source):
    """The concrete provenance failures for one true capability claim.

    Flags live in `capabilityQualification`; each true flag's evidence sits
    beside it at the top level of the same manifest or pin.
    """
    failures = []
    requirement = EVIDENCE[flag]
    evidence = source.get(requirement["key"]) if isinstance(source, dict) else None
    if not isinstance(evidence, dict):
        return [f"{flag} is claimed without {requirement['key']}"]
    for field in requirement["fields"]:
        value = evidence.get(field)
        if value is None or value == "" or value == [] or value == {}:
            failures.append(f"{requirement['key']} is missing {field}")
    for field in requirement.get("numbers", ()):
        value = evidence.get(field)
        if value is not None and (not isinstance(value, int) or isinstance(value, bool)):
            failures.append(f"{requirement['key']}.{field} must be an integer")
    for field in requirement.get("positive", ()):
        value = evidence.get(field)
        if isinstance(value, int) and not isinstance(value, bool) and value <= 0:
            failures.append(f"{requirement['key']}.{field} must be positive")
    for field in requirement.get("booleans", ()):
        value = evidence.get(field)
        if value is not None and value is not True:
            failures.append(f"{requirement['key']}.{field} must be true")
    document_type = evidence.get("documentType")
    if flag == "pptxVisibleRenderPassed" and document_type not in (None, "presentation"):
        failures.append(f"{requirement['key']}.documentType must be presentation")
    if flag == "originalFileWritebackPassed":
        checksum = evidence.get("savedSHA256")
        if isinstance(checksum, str) and not HEX64.match(checksum):
            failures.append(f"{requirement['key']}.savedSHA256 must be a sha256 hex digest")
    return failures


def capability_claims(source):
    """The capability block of a manifest or pin (never None)."""
    claims = source.get("capabilityQualification") if isinstance(source, dict) else None
    return claims if isinstance(claims, dict) else {}


def validate_capability_claims(source, label="artifact"):
    """Reject true capability claims without their provenance."""
    claims = capability_claims(source)
    failures = []
    for flag in CAPABILITY_FLAGS:
        value = claims.get(flag)
        if value is None:
            continue
        if not isinstance(value, bool):
            failures.append(f"{label}: {flag} must be a boolean, not {type(value).__name__}")
            continue
        if value:
            failures.extend(f"{label}: {failure}" for failure in _evidence_failures(flag, source))
    return failures


def capability_status(source):
    """Every capability as passed/failed/unproven, plus the release verdict."""
    claims = capability_claims(source)
    status = {}
    for flag in CAPABILITY_FLAGS:
        value = claims.get(flag)
        if value is True and not _evidence_failures(flag, source):
            status[flag] = "passed"
        elif value is True:
            # A true claim without provenance is rejected, never passed.
            status[flag] = "rejected"
        elif value is False:
            status[flag] = "failed"
        else:
            status[flag] = "unproven"
    failures = validate_capability_claims(source)
    return {
        "capabilities": status,
        "failures": failures,
        "releaseReady": not failures and all(status[flag] == "passed" for flag in CAPABILITY_FLAGS),
        "unproven": sorted(flag for flag, value in status.items() if value != "passed"),
    }


def false_capabilities():
    """The conservative block a compile/link receipt must carry."""
    return {flag: False for flag in CAPABILITY_FLAGS}


def host_source_matches_pin(pin, digest):
    """True only when every pinned host source hash matches this checkout."""
    expected = pin.get("hostSourceSHA256", {}) if isinstance(pin, dict) else {}
    if not expected:
        return False
    for name, hashed in expected.items():
        path = HOST_SOURCES / name
        if not path.is_file() or digest(path) != hashed:
            return False
    return True

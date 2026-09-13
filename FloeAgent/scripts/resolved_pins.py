"""Read SwiftPM lock schemas without silently dropping dependencies.

SwiftPM's ResolvedPackagesStore supports v1 (object.pins) and v2/v3
(top-level pins). Xcode may serialize an existing resolution using v1.
"""
from urllib.parse import urlsplit
import re


def resolved_pins(document):
    version = document.get("version")
    if version == 1:
        pins = document.get("object", {}).get("pins")
    elif version in (2, 3):
        pins = document.get("pins")
    else:
        raise ValueError(f"Unsupported Package.resolved schema: {version!r}")
    if not isinstance(pins, list) or not pins:
        raise ValueError("Package.resolved must contain a nonempty pins array")
    result = []
    identities = set()
    for pin in pins:
        location = pin.get("repositoryURL") if version == 1 else pin.get("location")
        if not isinstance(location, str) or not location:
            raise ValueError("Resolved pin has no source location")
        identity = (urlsplit(location).path.rstrip("/").rsplit("/", 1)[-1]
                    .removesuffix(".git").lower()) if version == 1 else pin.get("identity")
        state = pin.get("state")
        if not isinstance(identity, str) or not identity or not isinstance(state, dict):
            raise ValueError("Resolved pin has invalid identity or state")
        if identity in identities:
            raise ValueError(f"Duplicate resolved dependency: {identity}")
        identities.add(identity)
        state = {key: value for key, value in state.items() if value is not None}
        if not state.get("revision") and not state.get("version"):
            raise ValueError(f"Unpinned dependency: {identity}")
        if state.get("branch") and not state.get("revision"):
            raise ValueError(f"Mutable branch dependency: {identity}")
        result.append({"identity": identity, "location": location, "state": state})
    return sorted(result, key=lambda pin: pin["identity"])


def application_pins(project):
    """Read immutable remote packages from XcodeGen's packages section.

    The app has WhisperKit; the host Swift package does not. Local packages
    have no remote pin. Reject unsupported remote declarations explicitly.
    """
    section = re.search(r"(?ms)^packages:\n(.*?)(?=^\S|\Z)", project)
    if section is None:
        raise ValueError("XcodeGen packages section missing")
    pins = []
    for name, body in re.findall(r"(?ms)^  ([^ :]+):\n(.*?)(?=^  [^ ]|\Z)", section[1]):
        if re.search(r"^    path:", body, re.M):
            continue
        url = re.search(r"^    url: (\S+)\s*$", body, re.M)
        revision = re.search(r"^    revision: ([0-9a-f]{40})\s*$", body, re.M)
        if url is None or revision is None:
            raise ValueError(f"Xcode package must use an immutable revision: {name}")
        pins.append({"repositoryURL": url[1], "state": {"revision": revision[1]}})
    return resolved_pins({"version": 1, "object": {"pins": pins}}) if pins else []


def verify_resolution(current, committed, app_only):
    expected = {p["identity"]: p for p in committed}
    actual = {p["identity"]: p for p in current}
    app = {p["identity"]: p for p in app_only}
    for identity, pin in app.items():
        if expected.get(identity) != pin:
            raise ValueError(f"Xcode app pin differs from committed lock: {identity}")
    for identity, pin in actual.items():
        if expected.get(identity) != pin:
            raise ValueError(f"Resolved dependency differs from committed lock: {identity}")
    for identity in expected.keys() - actual.keys():
        if identity not in app:
            raise ValueError(f"Committed host dependency missing: {identity}")
    # Include application-only dependencies in the distribution inventory even
    # when swift package resolve removes them from the host lock representation.
    return sorted({**actual, **app}.values(), key=lambda p: p["identity"])

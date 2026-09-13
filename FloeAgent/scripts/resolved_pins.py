"""Read SwiftPM lock schemas without silently dropping dependencies.

SwiftPM's ResolvedPackagesStore supports v1 (object.pins) and v2/v3
(top-level pins). Xcode may serialize an existing resolution using v1.
"""
from urllib.parse import urlsplit


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

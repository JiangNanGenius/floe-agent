"""Read SwiftPM lock schemas without silently dropping dependencies.

SwiftPM's ResolvedPackagesStore supports v1 (object.pins) and v2/v3
(top-level pins). Xcode may serialize an existing resolution using v1.

The host ``Package.resolved`` remains the committed pin authority. XcodeGen may
also declare app-only remote packages and local path packages. A local path
package's own committed ``Package.resolved`` is an independent App-local pin
source: it supplies the transitive closure the host Swift package does not
resolve, without trusting arbitrary extras found only in an Xcode lock.
"""
import json
from pathlib import Path
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


def _package_entries(project):
    """Yield (name, body) for every entry in XcodeGen's packages section."""
    section = re.search(r"(?ms)^packages:\n(.*?)(?=^\S|\Z)", project)
    if section is None:
        raise ValueError("XcodeGen packages section missing")
    return re.findall(r"(?ms)^  ([^ :]+):\n(.*?)(?=^  [^ ]|\Z)", section[1])


def _yaml_path(value):
    """Return a plain path from the simple scalar spellings project.yml uses."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    # XcodeGen permits a trailing comment after an unquoted scalar.
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def application_pins(project):
    """Read immutable remote packages from XcodeGen's packages section.

    The app has WhisperKit; the host Swift package does not. Local packages
    have no remote pin. Reject unsupported remote declarations explicitly.
    """
    pins = []
    for name, body in _package_entries(project):
        if re.search(r"^    path:", body, re.M):
            continue
        url = re.search(r"^    url: (\S+)\s*$", body, re.M)
        revision = re.search(r"^    revision: ([0-9a-f]{40})\s*$", body, re.M)
        if url is None or revision is None:
            raise ValueError(f"Xcode package must use an immutable revision: {name}")
        pins.append({"repositoryURL": url[1], "state": {"revision": revision[1]}})
    return resolved_pins({"version": 1, "object": {"pins": pins}}) if pins else []


def application_local_pins(project, project_dir):
    """Read the committed lock closure of explicitly declared local packages.

    Only a direct ``<path>/Package.resolved`` below ``project_dir`` is read;
    nested packages, the root ``path: .`` (the host lock itself), paths that
    escape the project directory, and local packages without a lock contribute
    nothing. Every lock must be a valid immutable resolution. Two local locks
    may agree on the exact same pin, but a conflicting identity is rejected
    instead of letting one lock silently replace another.
    """
    root = Path(project_dir).resolve()
    pins = []
    seen = {}
    for name, body in _package_entries(project):
        path_match = re.search(r"^    path:\s*(\S.*?)\s*$", body, re.M)
        if path_match is None:
            continue
        if re.search(r"^    url:", body, re.M) or re.search(r"^    revision:", body, re.M):
            raise ValueError(f"Xcode package mixes a local path with a remote pin: {name}")
        raw_path = _yaml_path(path_match.group(1))
        if not raw_path:
            raise ValueError(f"Xcode local package has an empty path: {name}")
        package_dir = (root / raw_path).resolve()
        try:
            package_dir.relative_to(root)
        except ValueError as error:
            raise ValueError(
                f"Xcode local package path escapes the project directory: {name}: {raw_path}"
            ) from error
        if package_dir == root:
            # The root package is the committed host lock handled by
            # application_pins/verify_resolution, not a separate local source.
            continue
        lock_path = package_dir / "Package.resolved"
        resolved_lock = lock_path.resolve()
        try:
            resolved_lock.relative_to(root)
        except ValueError as error:
            raise ValueError(
                f"Xcode local package lock escapes the project directory: {name}: {raw_path}"
            ) from error
        if not resolved_lock.is_file():
            continue
        try:
            document = json.loads(resolved_lock.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError(
                f"Invalid Package.resolved for local Xcode package {name}: {resolved_lock}"
            ) from error
        for pin in resolved_pins(document):
            existing = seen.get(pin["identity"])
            if existing is not None:
                if same_pin(existing, pin):
                    continue
                raise ValueError(
                    "Conflicting resolved dependency across application local packages: "
                    f"{pin['identity']}"
                )
            seen[pin["identity"]] = pin
            pins.append(pin)
    return sorted(pins, key=lambda pin: pin["identity"])


def same_pin(actual, expected):
    if actual is None or expected is None:
        return actual == expected
    # SwiftPM can serialize GitHub's equivalent repository URLs with or
    # without .git. Keep identity, revision, version and every other field
    # exact; do not normalize hosts or non-GitHub source locations.
    def canonical(pin):
        result = dict(pin)
        location = result.get("location", "")
        if location.startswith("https://github.com/"):
            result["location"] = location.removesuffix(".git")
        return result
    return canonical(actual) == canonical(expected)


def app_pin_matches(committed, declared):
    """Compare an Xcode package declaration with its committed lock pin.

    XcodeGen expresses an exact version or a revision, never both, so a
    revision-only declaration cannot repeat the semver display value that
    `resolved_pins` keeps together with its revision. The repository and the
    immutable revision must still match exactly; the committed state (including
    the display version) stays the authority for the distribution inventory.
    A missing committed pin or any other revision never matches.
    """
    if committed is None or declared is None:
        return committed == declared
    if committed.get("state", {}).get("revision") != declared.get("state", {}).get("revision"):
        return False
    return same_pin(
        {**committed, "state": {}},
        {**declared, "state": {}},
    )


def _revision_only_display_omission(actual, expected, declared):
    """Accept only an actual revision-only state for a direct immutable pin.

    Xcode's own lock may omit the semver display value when the package was
    declared by revision, while the committed host lock (and therefore the
    distribution inventory) still carries it. This is intentionally narrower
    than "same revision": the declared state must be exactly the immutable
    revision, the actual state must be exactly that revision with no version,
    branch or unknown field, and the expected state may add only its display
    version. Identity and source must match in all three pins.
    """
    declared_state = declared.get("state", {})
    revision = declared_state.get("revision")
    if set(declared_state) != {"revision"} or not revision:
        return False
    if actual.get("state", {}) != {"revision": revision}:
        return False
    if expected.get("state", {}).get("revision") != revision:
        return False
    if set(expected.get("state", {})) - {"revision", "version"}:
        return False
    return (
        same_pin({**declared, "state": {}}, {**expected, "state": {}})
        and same_pin({**actual, "state": {}}, {**expected, "state": {}})
    )


def verify_resolution(current, committed, app_only, app_local=None):
    """Verify a resolution against the host and declared App-local locks.

    ``current`` may be a host representation (which can omit App-only pins and
    the App-local closure) or a complete Xcode graph. Missing App-only and
    App-local pins are tolerated here so a committed host lock remains a valid
    incomplete seed; callers that require a complete graph check containment of
    the returned merged pins themselves. Missing host pins, unknown extras and
    any changed identity/location/revision/version always fail. A local pin
    that disagrees with the host lock or a direct declaration fails; it can
    never override an existing pin.
    """
    expected = {p["identity"]: p for p in committed}
    host_identities = set(expected)
    actual = {p["identity"]: p for p in current}
    app = {p["identity"]: p for p in app_only}
    local = {p["identity"]: p for p in (app_local or [])}

    for identity, pin in local.items():
        if identity in expected and not same_pin(expected[identity], pin):
            raise ValueError(f"Application local pin conflicts with committed lock: {identity}")
        if identity in app and not app_pin_matches(pin, app[identity]):
            raise ValueError(f"Application local pin conflicts with direct declaration: {identity}")

    for identity, pin in app.items():
        if not app_pin_matches(expected.get(identity), pin):
            raise ValueError(f"Xcode app pin differs from committed lock: {identity}")

    # Local pins are an independent source only for identities the committed
    # host lock does not already carry; an existing pin is never replaced.
    for identity, pin in local.items():
        expected.setdefault(identity, pin)

    for identity, pin in actual.items():
        expected_pin = expected.get(identity)
        if expected_pin is None:
            raise ValueError(f"Resolved dependency differs from any committed lock: {identity}")
        if identity in app:
            if same_pin(expected_pin, pin):
                continue
            if _revision_only_display_omission(pin, expected_pin, app[identity]):
                continue
            raise ValueError(f"Resolved dependency differs from committed lock: {identity}")
        if not same_pin(expected_pin, pin):
            raise ValueError(f"Resolved dependency differs from committed lock: {identity}")

    for identity in expected.keys() - actual.keys():
        # App-only and App-local pins may be absent from a host representation;
        # a host pin is required unless it is exactly the declared App-only pin
        # (the historical host-lock shape).
        if identity in host_identities and identity not in app:
            raise ValueError(f"Committed host dependency missing: {identity}")

    # Include App-only and App-local dependencies in the distribution/Xcode
    # inventory even when the host representation omits them. A declaration or
    # local lock never replaces committed state; it only adds a package the
    # committed host lock does not carry at all. For a directly declared
    # App-only pin, keep the committed state (including its display version)
    # even when Xcode's accepted entry carries only the revision.
    merged = {}
    for identity, pin in actual.items():
        if identity in app and identity in expected:
            merged[identity] = expected[identity]
        else:
            merged[identity] = pin
    for identity, pin in expected.items():
        merged.setdefault(identity, pin)
    return sorted(merged.values(), key=lambda p: p["identity"])

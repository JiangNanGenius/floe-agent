"""Read SwiftPM lock schemas without silently dropping dependencies.

SwiftPM's ResolvedPackagesStore supports v1 (object.pins) and v2/v3
(top-level pins). Xcode may serialize an existing resolution using v1.

The host ``Package.resolved`` remains the committed pin authority. XcodeGen may
also declare app-only remote packages and local path packages. A local path
package's own committed ``Package.resolved`` is an independent App-local pin
source: it supplies the transitive closure the host Swift package does not
resolve, without trusting arbitrary extras found only in an Xcode lock. Two
explicitly reviewed host-graph adapters are an exception: their standalone
lock state is not authoritative when consumed by the App (see policy below).
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
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


# The one local package allowed to sit outside the XcodeGen project directory.
# FloeMacBridge is first-party source in this repository: the App links only its
# FloeMacBridgeProtocol target and the Mac companion app is built from the same
# package. It lives one level above FloeAgent/, so the declaration necessarily
# spells ../FloeMacBridge. This is an exact name-and-path allowlist, not
# permission for ../ in general: another package, sibling directory, absolute
# path, symlink, separate repository, submodule, untracked file or changed
# manifest still fails.
#
# The reviewed Package.swift digest is the dependency guarantee. A missing
# Package.resolved is NOT evidence that a manifest has no package dependencies,
# so the manifest bytes are pinned to a reviewed hash instead: any change
# (including a new dependency, target or resource) requires updating this policy
# and its test, and new package dependencies must be promoted to the host lock
# and the license inventory rather than silently resolved by Xcode. The package
# carries only its explicitly reviewed companion lock, checked against the host.
FIRST_PARTY_SIBLING_PACKAGES = {
    "FloeMacBridge": {
        "path": "../FloeMacBridge",
        # Sparkle 2.10.1 is macOS-only. Its exact companion lock must also
        # occur in the committed host closure; arbitrary sibling locks fail.
        "manifestSHA256": "c7f593b2e8ee27e01a89d7a53f2e6c4945ef892991eee30ba897c47da376c7dc",
        "resolvedSHA256": "1ad9a7512c0851f74e084a70f38c2d1d2e6d97aff133f37625cbf21fceb53ec5",
    },
}

# SwiftPM build state is not source and is never trusted as an input: the walk
# below prunes only these package-root cache directories. A nested directory
# with the same name stays subject to the tracked-file rule.
FIRST_PARTY_PACKAGE_CACHE_DIRS = frozenset({".build", ".swiftpm"})


def _git_checkout_query(repository, *arguments):
    """Run one read-only Git query, converting any failure into a pin error."""
    try:
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ValueError(
            f"Xcode local package Git checkout unreadable: {repository}: {error}"
        ) from error
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"git exited {completed.returncode}"
        raise ValueError(
            f"Xcode local package Git checkout unreadable: {repository}: {detail}"
        )
    return completed.stdout


def _first_party_package_dir(root, name, raw_path):
    """Resolve an allowlisted first-party sibling from the same Git checkout.

    The declaration must be the exact fixed path; the directory must be a real
    directory (never a symlink) and the direct child of the repository root
    that contains the XcodeGen project; it must be part of that Git checkout
    and have no staged, modified or submodule state. Every file the build can
    read must be tracked: the package-root .build/.swiftpm caches are pruned,
    every other untracked, ignored or symlinked entry fails. The manifest bytes
    must equal the reviewed digest in the policy. The package must not carry
    an unreviewed Package.resolved. This binds the linked source and its dependency
    surface to the frozen Git revision instead of trusting a local path.
    """
    policy = FIRST_PARTY_SIBLING_PACKAGES[name]
    expected = policy["path"]
    if raw_path != expected:
        raise ValueError(
            "First-party Xcode package must keep its fixed source path: "
            f"{name}: {raw_path} (expected {expected})"
        )
    repo_root = root.parent
    package_dir = root / raw_path
    if package_dir.is_symlink():
        raise ValueError(
            f"First-party Xcode package must not be a symlink: {name}: {raw_path}"
        )
    if not package_dir.is_dir():
        raise ValueError(
            f"First-party Xcode package is missing from the checkout: {name}: {raw_path}"
        )
    resolved = package_dir.resolve()
    canonical_root = repo_root.resolve()
    if resolved != canonical_root / name:
        raise ValueError(
            "First-party Xcode package path escapes the project directory: "
            f"{name}: {raw_path}"
        )
    top_level = Path(
        _git_checkout_query(package_dir, "rev-parse", "--show-toplevel").strip()
    ).resolve()
    if top_level != canonical_root:
        raise ValueError(
            "First-party Xcode package must belong to the project's Git checkout: "
            f"{name}: {raw_path}"
        )
    entries = [
        entry
        for entry in _git_checkout_query(
            repo_root, "ls-files", "-s", "-z", "--", name
        ).split("\0")
        if entry
    ]
    if not entries:
        raise ValueError(f"First-party Xcode package has no tracked files: {name}")
    if any(entry.split("\t", 1)[0].startswith("160000 ") for entry in entries):
        raise ValueError(f"First-party Xcode package must not be a Git submodule: {name}")
    if not any(entry.split("\t", 1)[-1] == f"{name}/Package.swift" for entry in entries):
        raise ValueError(
            f"First-party Xcode package manifest is not tracked: {name}/Package.swift"
        )
    status = _git_checkout_query(
        repo_root, "status", "--porcelain", "--untracked-files=no", "--", name
    )
    changed = [line for line in status.splitlines() if line.strip()]
    if changed:
        raise ValueError(
            "First-party Xcode package must be committed and clean: "
            f"{name} ({len(changed)} changed path(s))"
        )
    tracked = {entry.split("\t", 1)[1] for entry in entries}
    manifest_digest = None
    for directory, dirnames, filenames in os.walk(resolved):
        if Path(directory) == resolved:
            dirnames[:] = [
                dirname for dirname in dirnames
                if dirname not in FIRST_PARTY_PACKAGE_CACHE_DIRS
            ]
        for dirname in dirnames:
            if (Path(directory) / dirname).is_symlink():
                raise ValueError(
                    "First-party Xcode package must not contain symlinks: "
                    f"{name}: {(Path(directory) / dirname).relative_to(resolved).as_posix()}"
                )
        for filename in filenames:
            entry = Path(directory) / filename
            relative = entry.relative_to(resolved).as_posix()
            if entry.is_symlink():
                raise ValueError(
                    "First-party Xcode package must not contain symlinks: "
                    f"{name}: {relative}"
                )
            if f"{name}/{relative}" not in tracked:
                raise ValueError(
                    "First-party Xcode package contains an untracked or ignored file "
                    f"the build could read: {name}/{relative}"
                )
            if relative == "Package.swift":
                manifest_digest = hashlib.sha256(entry.read_bytes()).hexdigest()
    if manifest_digest is None:
        raise ValueError(f"First-party Xcode package manifest is missing: {name}/Package.swift")
    if manifest_digest != policy["manifestSHA256"]:
        raise ValueError(
            "First-party Xcode package manifest does not match the reviewed SHA-256; "
            f"review the change, promote any new dependencies to the host lock and "
            f"license inventory, then update the policy and its test: {name} "
            f"({manifest_digest})"
        )
    lock_path = resolved / "Package.resolved"
    if (lock_path.is_symlink() or not lock_path.is_file()
            or hashlib.sha256(lock_path.read_bytes()).hexdigest() != policy["resolvedSHA256"]):
        raise ValueError(
            "First-party Xcode package must not add an independent Package.resolved; "
            f"only the reviewed companion lock is allowed: {name}"
        )
    try:
        host = {pin["identity"]: pin for pin in resolved_pins(
            json.loads((root / "Package.resolved").read_text(encoding="utf-8")))}
        for pin in resolved_pins(json.loads(lock_path.read_text(encoding="utf-8"))):
            if not same_pin(host.get(pin["identity"]), pin):
                raise ValueError(f"Companion dependency differs from the committed host lock: {pin['identity']}")
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Companion dependencies need a valid committed host lock: {name}") from error
    return resolved


# These reviewed adapters have ONLY local module + FloeAgent path dependencies.
# Their standalone resolutions are not App pin authorities. SwiftPM explicitly
# ignores a dependency's own Package.resolved in the parent resolution:
# https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/ResolvingPackageVersions.md
# Keep this exact name/path/manifest allowlist; an unknown dependency or source
# in an adapter lock still fails. Other local-package lock policy is unchanged.
HOST_GRAPH_ADAPTERS = {
    "FloeLaTeXHostAdapter": {
        "path": "Modules/FloeLaTeXKit/Integration/FloeLaTeXHostAdapter",
        "manifestSHA256": "c90010ac7a7f5582e21fc200fdfbac159a587bcfe89f430337f8aa28f473a9f6",
    },
    "FloeHeavyEditorsHostAdapter": {
        "path": "Qualification/HeavyEditors/Integration/FloeHeavyEditorsHostAdapter",
        "manifestSHA256": "0cc810acd70f0ad6c8a75852a6cb1c21eb859465931c334d6e94bb7a1b36b796",
    },
}


# Old standalone locks can retain these four remote references after
# the App replaced them with reviewed path packages. They are not active pins.
# Both the vendored manifest and provenance bytes must remain exactly reviewed;
# the remote identity/source/revision/version must also match that provenance.
RETIRED_HOST_GRAPH_PINS = {
    "citadel": {
        "path": "ThirdParty/Citadel",
        "packageName": "Citadel",
        "manifestSHA256": "9f7a1d6c40a6cabfc61c3b0cfb724b3d33a49e00044d89f62b07a5c599959892",
        "provenance": "PROVENANCE.json",
        "provenanceSHA256": "3310a2ffd7eaf1e75561766851071f13fa39b5200bc099264417bbe994fe266b",
    },
    "libgit2": {
        "path": "ThirdParty/FloeNativeGit",
        "manifestSHA256": "a301444085a0abd84e28328a0c084ad8c775b84c19912149cb6f2d2831f7222b",
        "provenance": "upstream.lock.json",
        "provenanceSHA256": "5e20ea634d05dd3ae5195286ef3ab56df1ff5c75658526fb2b911da133d16dd9",
        "upstreamName": "libgit2",
    },
    "swiftgitx": {
        "path": "ThirdParty/FloeNativeGit",
        "manifestSHA256": "a301444085a0abd84e28328a0c084ad8c775b84c19912149cb6f2d2831f7222b",
        "provenance": "upstream.lock.json",
        "provenanceSHA256": "5e20ea634d05dd3ae5195286ef3ab56df1ff5c75658526fb2b911da133d16dd9",
        "upstreamName": "SwiftGitX",
    },
    "swift-crypto": {
        "path": "ThirdParty/swift-crypto",
        "manifestSHA256": "c078b4fd9910aa2229d81955f642e424416c8c4d0afff59db5b150e465b6a439",
        "provenance": "FLOE_UPSTREAM.json",
        "provenanceSHA256": "54113793203593b481dd70620e17f171784456e22ee8a7665fcbb4e74248021d",
    },
}


# MediaExchange also has direct remote dependencies, so its lock remains an
# active App-local authority. Only these four exact, proven vendored references
# are retired; all other entries keep the ordinary merge/conflict checks.
LOCAL_LOCK_RETIRED_REFERENCES = {
    "FloeMediaExchange": {
        "path": "Modules/FloeMediaExchange",
        "manifestSHA256": "303aa0fc036cd0db59c04585767fe28ee93d6c3d1e2d4f441e34a047439673af",
        "identities": frozenset({"citadel", "libgit2", "swift-crypto", "swiftgitx"}),
    },
}


def _retired_host_graph_pin_matches(root, pin):
    policy = RETIRED_HOST_GRAPH_PINS.get(pin["identity"])
    if policy is None:
        return False
    directory = root / policy["path"]
    manifest = directory / "Package.swift"
    provenance = directory / policy["provenance"]
    host_manifest = root / "Package.swift"
    try:
        if directory.resolve() != directory.absolute():
            return False
        for path, digest in ((manifest, policy["manifestSHA256"]),
                             (provenance, policy["provenanceSHA256"])):
            if (path.is_symlink() or not path.is_file()
                    or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
                return False
        if host_manifest.is_symlink() or not host_manifest.is_file():
            return False
        package_name = (r'name:[ \t]*"' + re.escape(policy["packageName"]) + r'"[ \t]*,[ \t]*'
                        if "packageName" in policy else "")
        declaration = (r'(?m)^[ \t]*\.package\([ \t]*' + package_name + r'path:[ \t]*"'
                       + re.escape(policy["path"]) + r'"[ \t]*\)[ \t]*,?[ \t]*$')
        if re.search(declaration, host_manifest.read_text(encoding="utf-8")) is None:
            return False
        record = json.loads(provenance.read_text(encoding="utf-8"))
        if "upstreamName" in policy:
            records = [item for item in record["upstreams"]
                       if item["name"] == policy["upstreamName"]]
            if len(records) != 1:
                return False
            record = records[0]
            source = record["url"]
        else:
            source = record["upstream"]
        state = {"revision": record["revision"]}
        if record.get("version") is not None:
            state["version"] = record["version"]
        expected = {"identity": pin["identity"], "location": source, "state": state}
        return same_pin(pin, expected)
    except (OSError, ValueError, KeyError, TypeError):
        return False


def _verify_host_graph_adapter(root, name, raw_path):
    policy = HOST_GRAPH_ADAPTERS[name]
    directory = root / raw_path
    if raw_path != policy["path"] or directory.resolve() != directory.absolute():
        raise ValueError(f"Host-graph adapter must keep its reviewed non-aliased path: {name}")
    manifest = directory / "Package.swift"
    if (manifest.is_symlink() or not manifest.is_file()
            or hashlib.sha256(manifest.read_bytes()).hexdigest() != policy["manifestSHA256"]):
        raise ValueError(f"Host-graph adapter manifest differs from reviewed local-only dependencies: {name}")
    lock = directory / "Package.resolved"
    if lock.is_symlink():
        raise ValueError(f"Host-graph adapter lock must not be an alias: {name}")
    if not lock.exists():
        return
    host = {pin["identity"]: pin for pin in resolved_pins(json.loads((root / "Package.resolved").read_text(encoding="utf-8")))}
    for pin in resolved_pins(json.loads(lock.read_text(encoding="utf-8"))):
        parent = host.get(pin["identity"])
        if parent is None:
            if _retired_host_graph_pin_matches(root, pin):
                continue
            raise ValueError(f"Host-graph adapter contains an unknown identity or source: {name}: {pin['identity']}")
        if not same_pin({**pin, "state": {}}, {**parent, "state": {}}):
            raise ValueError(f"Host-graph adapter contains an unknown identity or source: {name}: {pin['identity']}")
    # State in this standalone lock is intentionally not merged. The committed
    # parent + actual App root resolution remain checked by verify_resolution.


def application_local_pins(project, project_dir):
    """Read the committed lock closure of explicitly declared local packages.

    Only a direct ``<path>/Package.resolved`` below ``project_dir`` is read;
    nested packages, the root ``path: .`` (the host lock itself), paths that
    escape the project directory, and local packages without a lock contribute
    nothing. Every lock must be a valid immutable resolution. Two local locks
    may agree on the exact same pin, but a conflicting identity is rejected
    instead of letting one lock silently replace another. The two manifest-
    reviewed host-graph adapters above contribute no independent pin state.
    The manifest-reviewed MediaExchange lock retires only its four exact
    provenance-bound vendored references; every other pin remains authoritative.

    One first-party sibling is allowlisted by name and exact path:
    ``FloeMacBridge`` at ``../FloeMacBridge``. It is accepted only as a real,
    tracked and clean directory of the same Git checkout whose manifest matches
    the reviewed digest, with every non-cache file tracked and no symlinks, and
    carries only the reviewed ``Package.resolved`` also pinned in the host.
    It contributes no unreviewed pins; a changed manifest, file or dependency needs an explicit
    policy/test review before it can build. Every other path outside
    ``project_dir`` still fails.
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
        if name in FIRST_PARTY_SIBLING_PACKAGES:
            _first_party_package_dir(root, name, raw_path)
            continue
        if name in HOST_GRAPH_ADAPTERS:
            _verify_host_graph_adapter(root, name, raw_path)
            continue
        retirement = LOCAL_LOCK_RETIRED_REFERENCES.get(name)
        if retirement is not None:
            directory = root / raw_path
            manifest = directory / "Package.swift"
            if (raw_path != retirement["path"] or directory.resolve() != directory.absolute()
                    or manifest.is_symlink() or not manifest.is_file()
                    or hashlib.sha256(manifest.read_bytes()).hexdigest() != retirement["manifestSHA256"]):
                raise ValueError(f"Local retirement package differs from its reviewed path or manifest: {name}")
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
        if retirement is not None and lock_path.is_symlink():
            raise ValueError(f"Local retirement package lock must not be an alias: {name}")
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
            if retirement is not None and pin["identity"] in retirement["identities"]:
                if not _retired_host_graph_pin_matches(root, pin):
                    raise ValueError(f"Local retired reference differs from reviewed vendored proof: {name}: {pin['identity']}")
                continue
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

    # Local pins are an independent source only for identities the committed
    # host lock does not already carry; an existing pin is never replaced.
    for identity, pin in local.items():
        expected.setdefault(identity, pin)

    # A product linked directly by an App target may already be locked only
    # by a reviewed local package. Validate against that same authority after
    # the host/local conflict checks above; do not require a duplicate host pin.
    for identity, pin in app.items():
        if not app_pin_matches(expected.get(identity), pin):
            raise ValueError(f"Xcode app pin differs from committed lock: {identity}")

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

#!/usr/bin/env python3
"""pipeline_contract.py — shared parsers for the runner-update pipeline.

One place for the three contracts the preflight, the guest check and the
packager all need:

  * the runner's own constants (`floe_exec.c`: FLOE_RUNNER_VERSION,
    FLOE_PROTOCOL_VERSION, MAX_CONCURRENT_COMMANDS, MAX_CONCURRENT_SESSIONS)
    and the exact CAPS payload they produce;
  * the engine's guest-image artifact contract
    (`LinuxGuestService.swift`: `runnerArtifact` + `runnerCapabilities`, and the
    `LinuxGuestImageArtifact.Role` enum that constrains the JSON `role` field;
    an unknown role does not decode, so the manifest must stay inside it);
  * the cross-toolchain package record (`toolchain_package <name> <version>`)
    used to decide whether the base release's toolchain-source asset still
    covers a new static link.

Pure parsing, no I/O beyond reading the file the caller points at.
"""
import re

CAPS_PATTERN = re.compile(
    r"^runner=(?P<runner>\S+) protocol=(?P<protocol>\d+) "
    r"maxCommands=(?P<maxCommands>\d+) maxSessions=(?P<maxSessions>\d+)$")

ROLE_ENUM_PATTERN = re.compile(
    r"enum\s+Role\s*:\s*String\s*,\s*Codable\s*,\s*Sendable\s*\{(?P<body>[^}]*)\}",
    re.S)

CONSTANT_PATTERN = re.compile(
    r"^#define\s+(?P<name>FLOE_RUNNER_VERSION|FLOE_PROTOCOL_VERSION|"
    r"MAX_CONCURRENT_COMMANDS|MAX_CONCURRENT_SESSIONS)\s+(?P<value>[^\s/]+)",
    re.M)

TOOLCHAIN_PATTERN = re.compile(r"^toolchain_package\s+(?P<name>\S+)\s+(?P<version>\S+)\s*$", re.M)
BINARY_PATTERN = re.compile(r"^binary\s+(?P<name>\S+)\s+(?P<version>\S+)"
                            r"(?:\s+source\s+(?P<source>\S+)\s+(?P<source_version>\S+))?\s*$", re.M)

RUNNER_CONSTANT_NAMES = ("FLOE_RUNNER_VERSION", "FLOE_PROTOCOL_VERSION",
                         "MAX_CONCURRENT_COMMANDS", "MAX_CONCURRENT_SESSIONS")


def parse_runner_constants(text):
    """Constants from floe_exec.c. Raises ValueError when malformed."""
    raw = {match.group("name"): match.group("value").strip().strip('"')
           for match in CONSTANT_PATTERN.finditer(text)}
    missing = [name for name in RUNNER_CONSTANT_NAMES if name not in raw]
    if missing:
        raise ValueError("runner source is missing %s" % ", ".join(missing))
    try:
        parsed = {
            "runner_version": raw["FLOE_RUNNER_VERSION"],
            "protocol": int(raw["FLOE_PROTOCOL_VERSION"], 10),
            "max_commands": int(raw["MAX_CONCURRENT_COMMANDS"], 10),
            "max_sessions": int(raw["MAX_CONCURRENT_SESSIONS"], 10),
        }
    except ValueError as error:
        raise ValueError("runner constants are not numeric where required: %s" % error)
    if not parsed["runner_version"]:
        raise ValueError("runner version is empty")
    return parsed


def expected_caps(constants):
    """The exact CAPS payload the runner answers for these constants."""
    return "runner=%s protocol=%d maxCommands=%d maxSessions=%d" % (
        constants["runner_version"], constants["protocol"],
        constants["max_commands"], constants["max_sessions"])


def parse_caps(payload):
    """Parse a verbatim CAPS payload, or None when it is not one."""
    if payload is None:
        return None
    match = CAPS_PATTERN.match(payload.strip())
    if not match:
        return None
    return {"runner": match.group("runner"), "protocol": int(match.group("protocol")),
            "maxCommands": int(match.group("maxCommands")),
            "maxSessions": int(match.group("maxSessions")), "payload": payload.strip()}


def artifact_roles(swift_source):
    """The `LinuxGuestImageArtifact.Role` cases, or None when not found."""
    match = ROLE_ENUM_PATTERN.search(swift_source)
    if not match:
        return None
    return sorted(set(re.findall(r"case\s+([A-Za-z][A-Za-z0-9]*)", match.group("body"))))


def engine_runner_contract(swift_source):
    """(roles, has_fields) for the engine's LinuxGuestImage source."""
    roles = artifact_roles(swift_source)
    has_fields = ("runnerArtifact" in swift_source and "runnerCapabilities" in swift_source)
    return roles, has_fields


def choose_runner_role(roles, override=None):
    """Pick the JSON role for runnerArtifact from the engine's enum.

    Returns (role, policy, reason) or raises ValueError when no role works.
    `runner` is the exact role; `disk` is the recorded compatibility fallback
    for engine revisions whose Role enum has no runner case (the registry
    upgrade path reads path/sha512/bytes and never the role, and the artifact
    is not part of `declaredArtifacts`). Nothing is written silently: the
    caller records `policy` in the distribution record.
    """
    if roles is None:
        raise ValueError("could not find LinuxGuestImageArtifact.Role in the engine source")
    override = (override or "").strip()
    if override:
        if override not in roles:
            raise ValueError("RUNNER_ARTIFACT_ROLE=%r is not in the engine's Role enum %s"
                             % (override, roles))
        return override, "explicit-override", "RUNNER_ARTIFACT_ROLE was set explicitly"
    if "runner" in roles:
        return "runner", "engine-runner-role", "engine Role enum has an exact runner case"
    if "disk" in roles:
        return "disk", "compat-disk-role", (
            "engine Role enum %s has no runner case; the fallback role is unused by the "
            "registry upgrade path and only has to remain decodable" % roles)
    raise ValueError("engine Role enum %s has neither a runner nor a disk case" % roles)


def toolchain_packages(text):
    """{package: version} from a `toolchain_package` record."""
    return {match.group("name"): match.group("version")
            for match in TOOLCHAIN_PATTERN.finditer(text or "")}


def toolchain_gaps(base_record, new_record):
    """Base packages that are missing or version-different in the new record."""
    base = toolchain_packages(base_record)
    new = toolchain_packages(new_record)
    gaps = []
    for name, version in sorted(base.items()):
        if name not in new:
            gaps.append("%s: base %s, new run has no record" % (name, version))
        elif new[name] != version:
            gaps.append("%s: base %s, new run %s" % (name, version, new[name]))
    return gaps


def binary_packages(text):
    """{binary package: {version, source, source_version}} from `binary` lines."""
    return {match.group("name"): {"version": match.group("version"),
                                  "source": match.group("source"),
                                  "source_version": match.group("source_version")}
            for match in BINARY_PATTERN.finditer(text or "")}


def toolchain_record_gaps(base_record, new_record):
    """Gaps between two `binary`-line records.

    `binary <pkg> <ver> source <src> <srcver>` is the shape of the base
    toolchain-source bundle's toolchain-versions.txt and of this pipeline's own
    toolchain-versions.txt: one line per package that owns the actual compiler,
    libc.a, libgcc.a or cross libc. A package in the base record must exist with
    the same version (and source name/version) in the new record. Metapackage
    `toolchain_package` lines are compared separately with `toolchain_gaps`.
    """
    gaps = []
    base_binaries = binary_packages(base_record)
    new_binaries = binary_packages(new_record)
    for name, record in sorted(base_binaries.items()):
        current = new_binaries.get(name)
        if current is None:
            gaps.append("%s: base %s, new run records no owning package" % (name, record["version"]))
            continue
        if current["version"] != record["version"]:
            gaps.append("%s: base %s, new run %s" % (name, record["version"], current["version"]))
        if record["source"] and current["source"] != record["source"]:
            gaps.append("%s: base source %s, new run %s" % (name, record["source"], current["source"]))
        if record["source_version"] and current["source_version"] != record["source_version"]:
            gaps.append("%s: base source version %s, new run %s"
                        % (name, record["source_version"], current["source_version"]))
    return gaps

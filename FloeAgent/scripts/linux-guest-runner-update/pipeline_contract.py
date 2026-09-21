#!/usr/bin/env python3
"""pipeline_contract.py — shared parsers for the runner-update pipeline.

One place for the three contracts the preflight, the guest check and the
packager all need:

  * the runner's own constants (`floe_exec.c`: FLOE_RUNNER_VERSION,
    FLOE_PROTOCOL_VERSION, MAX_CONCURRENT_COMMANDS, MAX_CONCURRENT_SESSIONS)
    and the exact CAPS payload they produce, including the first-boot
    `net=up|partial|down` field the runner appends when its source emits it;
  * the engine's guest-image artifact contract
    (`LinuxGuestService.swift`: `runnerArtifact` + `runnerCapabilities`, and the
    `LinuxGuestImageArtifact.Role` enum that constrains the JSON `role` field;
    an unknown role does not decode, so the manifest must stay inside it);
  * the cross-toolchain package record (`toolchain_package <name> <version>`)
    used to decide whether the base release's toolchain-source asset still
    covers a new static link.

Pure parsing, no I/O beyond reading the file the caller points at.
"""
import os
import re

CAPS_PATTERN = re.compile(
    r"^runner=(?P<runner>\S+) protocol=(?P<protocol>\d+) "
    r"maxCommands=(?P<maxCommands>\d+) maxSessions=(?P<maxSessions>\d+)"
    r"(?: net=(?P<net>up|partial|down))?$")

# The first-boot network vocabulary the runner answers (floe_net.h). The
# field is optional in the pattern so a pre-network runner still parses, but
# the pipeline requires it whenever the runner source emits it, and requires
# `up` for the boot contract (see guest_protocol_check and package_component).
CAPS_NET_STATUSES = ("up", "partial", "down")

# The runner's FLOE-CAPS emission carries a `net=%s` slot when it reports the
# first-boot network state. Read from the source instead of assuming the
# field, so a runner that stopped reporting it cannot pass the boot gate with
# a payload shape the pipeline never verified. The match requires the string
# conversion slot (`%s`) that follows `net=`, so a comment or prose mentioning
# "net=" on the same source line is not mistaken for the emission.
CAPS_NET_FIELD_PATTERN = re.compile(
    r"FLOE-CAPS[^\n\"]*maxSessions=(?:%d|[0-9]+)[^\n\"]*net=%s")

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

# A local (quoted) `#include "..."` names a runner-owned header that is part of
# the static build: the cross compile uses `-I<runner dir>`, so every such
# header is compile input and therefore corresponding source that must travel
# in the relink archive and in runner-source-sha256.txt. System includes
# (`<...>`) are deliberately excluded.
LOCAL_INCLUDE_PATTERN = re.compile(r'^[ \t]*#[ \t]*include[ \t]*"(?P<name>[^"]+)"', re.M)

# The complete runner source set, in the deterministic order used by every
# digest/archive step: the translation unit, every runner-owned header it
# includes (sorted), and the Makefile that drives the static build.
RUNNER_SOURCE_BASE = "FloeAgent/LinuxGuest/runner"


def local_includes(floe_exec_text):
    """Sorted runner-owned header names quoted-included by floe_exec.c."""
    return sorted(set(LOCAL_INCLUDE_PATTERN.findall(floe_exec_text or "")))


def runner_source_set(floe_exec_text):
    """All runner source files for floe_exec.c (names relative to runner dir).

    Derived from the source's own quoted includes instead of a hand-maintained
    list, so adding a new runner-owned header (e.g. floe_net.h) extends the
    exact-source digest, the LGPL relink archive and every gate together.
    """
    return ("floe_exec.c",) + tuple(local_includes(floe_exec_text)) + ("Makefile",)


# A `--net` shell flag token rather than prose: it must be followed only by
# an optional line-continuation backslash/end-of-line, or by whitespace and
# another `-`/`--` option. "floe_vm_host --net appears in docs" does not
# match. This is the CLI form of the App's
# LinuxGuestEnvironmentDescriptor.networkEnabled -> FloeVMConfig.net_enable
# wiring; without the flag the adapter creates no slirp backend and TinyEMU
# registers no virtio-net device, so the guest boots without eth0 (run
# 35645930554).
NET_FLAG_TOKEN_PATTERN = re.compile(
    r"(?<![\w-])--net(?:\s*\\?\s*$|\s+(?=-))", re.M)


def _shell_statements(text):
    """Active (non-comment) shell text joined on backslash continuations.

    A boot invocation is split across continuation lines in the workflow, so
    the flag can sit on a line that does not itself name floe_vm_host.
    """
    active = []
    for line in (text or "").splitlines():
        if line.lstrip().startswith("#"):
            continue
        active.append(line)
    joined = "\n".join(active)
    return re.split(r"(?<!\\)\n", joined)


def workflow_enables_guest_network(workflow_text):
    """True when the workflow boots floe_vm_host with the --net switch.

    Comments are ignored, continuation lines are joined to the invocation,
    and the flag must be a real shell token (its own continuation line or
    inline before another option), so a documentation sentence naming
    `floe_vm_host --net` is not enough.
    """
    for statement in _shell_statements(workflow_text):
        collapsed = statement.replace("\\\n", " ")
        if "floe_vm_host" in collapsed and NET_FLAG_TOKEN_PATTERN.search(collapsed):
            return True
    return False


# The per-VM MAC the adapter assigns the virtio-net device
# (ThirdParty/TinyEMU/adapter/floe_vm.c: net->mac_addr[0..5]). The boot gate
# reads the guest kernel's view of eth0 and compares it to this, so it is
# derived from the adapter source instead of being trusted as a constant.
ADAPTER_MAC_PATTERN = re.compile(
    r"mac_addr\[0\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;\s*"
    r"(?:[A-Za-z_][\w>.-]*\s*)?mac_addr\[1\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;\s*"
    r"(?:[A-Za-z_][\w>.-]*\s*)?mac_addr\[2\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;\s*"
    r"(?:[A-Za-z_][\w>.-]*\s*)?mac_addr\[3\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;\s*"
    r"(?:[A-Za-z_][\w>.-]*\s*)?mac_addr\[4\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;\s*"
    r"(?:[A-Za-z_][\w>.-]*\s*)?mac_addr\[5\]\s*=\s*0x([0-9A-Fa-f]{2})\s*;")


def adapter_guest_mac(adapter_source):
    """The adapter's per-VM guest MAC as colon-separated lowercase hex, or None.

    Parsed out of the six `net->mac_addr[i] = 0x..;` assignments in
    adapter/floe_vm.c, so a changed adapter MAC fails the boot-gate coupling
    instead of the guest's real eth0 being compared against a stale string.
    """
    match = ADAPTER_MAC_PATTERN.search(adapter_source or "")
    if match is None:
        return None
    return ":".join(group.lower() for group in match.groups())


def parse_source_sha256_record(text):
    """{basename: sha256} from a sha256sum-style runner-source-sha256 record.

    sha256sum writes the path it was given (often absolute); only the basename
    matters because every member lives in the one runner directory.
    """
    record = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        digest, _, name = line.partition("  ")
        if not name:
            digest, _, name = line.partition(" ")
        name = os.path.basename(name.strip())
        if re.fullmatch(r"[0-9a-f]{64}", digest.strip()):
            record[name] = digest.strip()
    return record


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


def expected_caps(constants, net_status=None):
    """The exact CAPS payload the runner answers for these constants.

    `net_status` is the first-boot network state the runner reports at
    runtime (`up`/`partial`/`down`); None renders a pre-network payload so a
    legacy runner can still be compared against its own source.
    """
    if net_status is not None and net_status not in CAPS_NET_STATUSES:
        raise ValueError("unknown net status %r (expected one of %s)"
                         % (net_status, ", ".join(CAPS_NET_STATUSES)))
    payload = "runner=%s protocol=%d maxCommands=%d maxSessions=%d" % (
        constants["runner_version"], constants["protocol"],
        constants["max_commands"], constants["max_sessions"])
    if net_status is not None:
        payload += " net=%s" % net_status
    return payload


def caps_net_field(runner_source):
    """True when the runner source emits the `net=` capability field."""
    return CAPS_NET_FIELD_PATTERN.search(runner_source or "") is not None


def parse_caps(payload):
    """Parse a verbatim CAPS payload, or None when it is not one.

    The `net=` field is optional so payloads from a pre-network runner still
    parse; callers that require the field (the boot gate) check `caps["net"]`
    and use `caps_net_field(source)` to know whether the source emits it.
    """
    if payload is None:
        return None
    match = CAPS_PATTERN.match(payload.strip())
    if not match:
        return None
    return {"runner": match.group("runner"), "protocol": int(match.group("protocol")),
            "maxCommands": int(match.group("maxCommands")),
            "maxSessions": int(match.group("maxSessions")),
            "net": match.group("net"), "payload": payload.strip()}


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

    Returns (role, policy, reason) or raises ValueError. The engine ships a
    distinct `runner` case for the runner artifact; the runner-only update must
    not reuse the `disk` role (the disk artifact already owns it and a verifier
    keyed by role would collide), so a missing `runner` case fails closed with
    an actionable message. RUNNER_ARTIFACT_ROLE stays as an explicit override
    validated against the same enum.
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
        return "runner", "engine-runner-role", "engine Role enum has a distinct runner case"
    raise ValueError(
        "engine Role enum %s has no distinct runner case; the runnerArtifact must not reuse "
        "the disk role (verifier collision). Add `case runner` to LinuxGuestImageArtifact.Role, "
        "or set RUNNER_ARTIFACT_ROLE explicitly after reviewing the verifier." % roles)


# --- compatible-origin (runner-only predecessor) contract -------------------

ORIGIN_FIELD_CANDIDATES = ("compatibleOrigins", "compatibleOrigin", "acceptedOrigins",
                           "predecessorOrigins", "supersedesOrigins")

STORED_PROPERTY_PATTERN = re.compile(
    r"^\s*(?:public\s+|internal\s+|package\s+|private\s+)?(?:var|let)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?P<type>[\[\]A-Za-z_][A-Za-z0-9_.\[\]<>,?! ]*?)\s*(?P<tail>[={].*)?$", re.M)


def swift_struct_properties(source, type_name):
    """Stored (non-computed) properties of one Swift struct."""
    match = re.search(r"(?:public\s+)?struct\s+%s\b[^{]*\{" % re.escape(type_name), source)
    if not match:
        return None
    body = source[match.end():]
    depth = 1
    out = []
    for line in body.splitlines():
        if depth == 0:
            break
        stripped = line.strip()
        if stripped and "static" not in stripped:
            property_match = STORED_PROPERTY_PATTERN.match(line)
            if property_match and not (property_match.group("tail") or "").startswith("{"):
                out.append((property_match.group("name"), property_match.group("type").strip()))
        depth += line.count("{") - line.count("}")
    return out


def compatible_origin_contract(service_source, runtime_source, override=None):
    """The engine's compatible-origin manifest field and its entry keys.

    A runner-only update replaces the runner inside the pinned base disk: the
    new disk digest differs, so an existing environment disk (created from the
    published base image) is only accepted when the manifest explicitly
    declares that verified predecessor. The engine owns that schema; this
    reads it from the target commit's Swift sources instead of assuming a
    field name:

      1. COMPATIBLE_ORIGIN_FIELD (or the `override` argument) wins after
         validation;
      2. the preferred names below are tried first;
      3. otherwise any array-of-struct property on LinuxGuestImage is accepted
         when the element struct has stored properties for the image id, the
         SHA-512 and the byte size.

    Returns {"field", "elementType", "keys", "required"} or raises ValueError
    listing the arrays it inspected and the semantic each one lacked, so a
    schema change fails the preflight with an actionable message instead of
    writing a field the app cannot decode.
    """
    sources = [source for source in (service_source, runtime_source) if source]
    properties = None
    for source in sources:
        properties = swift_struct_properties(source, "LinuxGuestImage")
        if properties:
            break
    if not properties:
        raise ValueError("could not find LinuxGuestImage in the engine sources")

    candidates = []
    override = (override or "").strip()
    if override:
        candidates.append(override)
    candidates += [name for name in ORIGIN_FIELD_CANDIDATES
                   if name not in candidates]
    candidates += [name for name, _type in properties if name not in candidates]

    inspected = []
    for name in candidates:
        declared = next((type_text for property_name, type_text in properties
                         if property_name == name), None)
        if declared is None:
            continue
        element_match = re.fullmatch(r"\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*\]\??", declared.strip())
        if not element_match:
            if name == override:
                raise ValueError("COMPATIBLE_ORIGIN_FIELD=%r is not an array of a struct (%s)"
                                 % (name, declared))
            continue
        element = element_match.group(1)
        element_properties = None
        for source in sources:
            element_properties = swift_struct_properties(source, element)
            if element_properties:
                break
        if not element_properties:
            if name == override:
                raise ValueError("COMPATIBLE_ORIGIN_FIELD=%r references %s, whose stored properties "
                                 "were not found" % (name, element))
            continue
        keys = {}
        for property_name, _type in element_properties:
            lowered = property_name.lower()
            if "image" in lowered and "id" in lowered:
                keys["image_id"] = property_name
            elif "sha512" in lowered or "digest" in lowered:
                keys["sha512"] = property_name
            elif "byte" in lowered or "size" in lowered:
                keys["bytes"] = property_name
        missing = [semantic for semantic in ("image_id", "sha512", "bytes") if semantic not in keys]
        inspected.append((name, element, missing))
        if missing:
            continue
        return {"field": name, "elementType": element, "keys": keys,
                "required": [property_name for property_name, _ in element_properties]}
    detail = "; ".join("%s[%s] lacks %s" % (name, element, ",".join(missing))
                       for name, element, missing in inspected) or "no array-of-struct property"
    raise ValueError(
        "engine has no recognizable compatible-origin array on LinuxGuestImage (%s); a runner-only "
        "update must declare the verified predecessor image so existing environment disks can "
        "upgrade instead of being rejected. Set COMPATIBLE_ORIGIN_FIELD only after reviewing the "
        "engine decoder." % detail)


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

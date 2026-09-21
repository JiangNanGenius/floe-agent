#!/usr/bin/env python3
"""selfcheck.py — offline contract checks for the runner-update pipeline.

Runs in a few seconds on any machine with python3 and no network, so the cloud
dispatch fails on a broken script rather than halfway through a 572 MB download
or a guest boot. It exercises the real scripts with synthetic fixtures:

  1. pipeline_contract: runner constants, the CAPS payload with and without
     the first-boot net= field, Role-enum parsing and the role policy
     (`runner` when the engine has it, recorded `disk` fallback otherwise),
     plus the workflow guard that the qualification boot passes --net;
  2. guest_protocol_check: generate a timed script that the real
     `floe_vm_host` parser can read (line format + length limit), then assert
     a synthetic protocol-3 transcript with the guest-side device/DNS probes
     passes and broken, degraded (net=down/partial) and probe-failed ones
     fail;
  3. package_component end-to-end on tiny fixtures: standalone runner artifact,
     `runnerArtifact`/`runnerCapabilities` in the manifest, ZIP member digests,
     sums, relink + reused-source archives, plus the fail-closed cases
     (caps/source mismatch, missing or degraded net= state, toolchain version
     drift, engine without the artifact fields).

Usage: python3 selfcheck.py [--repo DIR] [--out DIR] [--keep]
`--repo` is the checkout that provides write-image-manifest.py; the engine
source and every image artifact are synthesized, so the check never depends on
uncommitted engine work.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
import pipeline_contract  # noqa: E402
import guest_protocol_check  # noqa: E402

# Set by main() to the checkout's write-image-manifest.py (the only file the
# synthetic fixture copies from the real repository).
_MANIFEST_WRITER = None

RUNNER_SOURCE = """\
/* synthetic runner source for the pipeline self-check */
#include "floe_clock.h"
#include "floe_net.h"
#define FLOE_MARK 0x1e
#define FLOE_CANCEL 0x03
#define FLOE_PROTOCOL_VERSION 3
#define FLOE_RUNNER_VERSION "2.0.0"
#define MAX_CONCURRENT_COMMANDS 8
#define MAX_CONCURRENT_SESSIONS 4
static const char *caps_format =
    "\\x1e" "FLOE-CAPS %s runner=%s protocol=%d maxCommands=%d maxSessions=%d net=%s\\x1e";
"""
# The same runner without the first-boot network field: the packaging gate
# must fail closed when the guest answers net=up but the source cannot emit it.
RUNNER_SOURCE_NO_NET = RUNNER_SOURCE.replace("maxSessions=%d net=%s", "maxSessions=%d")
RUNNER_NET_HEADER = "/* synthetic first-boot networking header for the pipeline self-check */\n"
ENGINE_SOURCE = """\
public enum LinuxGuestImageArtifact {
    public enum Role: String, Codable, Sendable {
        case bios
        case kernel
        case initrd
        case disk
        case runner
    }
}
public struct LinuxGuestImageCompatibleOrigin: Codable {
    public var imageID: String
    public var sha512: String
    public var bytes: Int64
}
public struct LinuxGuestImage {
    public var runnerArtifact: LinuxGuestImageArtifact?
    public var runnerCapabilities: String?
    public var compatibleOrigins: [LinuxGuestImageCompatibleOrigin]?
}
"""
# The engine may name the origin keys after the disk-origin sidecar
# (artifactSHA512/artifactBytes); the packaging must follow the engine.
ENGINE_SOURCE_ALIAS_ORIGIN = ENGINE_SOURCE.replace(
    """public struct LinuxGuestImageCompatibleOrigin: Codable {
    public var imageID: String
    public var sha512: String
    public var bytes: Int64
}""",
    """public struct LinuxGuestImageCompatibleOrigin: Codable {
    public var imageID: String
    public var artifactSHA512: String
    public var artifactBytes: Int64
}""")
# An engine field with an arbitrary name must still be found and followed.
ENGINE_SOURCE_ODD_ORIGIN_NAME = ENGINE_SOURCE.replace(
    "compatibleOrigins: [LinuxGuestImageCompatibleOrigin]?",
    "runnerCompatibleDiskOrigins: [LinuxGuestImageCompatibleOrigin]?").replace(
    "    public var compatibleOrigins: [LinuxGuestImageCompatibleOrigin]?\n", "")
ENGINE_SOURCE_ODD_ORIGIN_NAME = ENGINE_SOURCE_ODD_ORIGIN_NAME.replace(
    "    public var runnerCapabilities: String?\n",
    "    public var runnerCapabilities: String?\n"
    "    public var runnerCompatibleDiskOrigins: [LinuxGuestImageCompatibleOrigin]?\n")
ENGINE_SOURCE_NO_ORIGIN = ENGINE_SOURCE.replace(
    "    public var compatibleOrigins: [LinuxGuestImageCompatibleOrigin]?\n", "")
ENGINE_SOURCE_NO_RUNNER_ROLE = ENGINE_SOURCE.replace("        case runner\n", "")
ENGINE_SOURCE_NO_CONTRACT = """\
public enum LinuxGuestImageArtifact {
    public enum Role: String, Codable, Sendable {
        case bios
        case kernel
        case disk
    }
}
public struct LinuxGuestImage {
    public var qualified: Bool
}
"""
VERDICT_CHECKS = ["boot clock applied", "HELLO answered", "final marker"]
# The runner's CAPS payload with the first-boot network field: the update's
# boot gate requires net=up (the runner's bounded DNS probe answered).
CAPS_WITH_NET = "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=up"
CAPS_LEGACY = "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4"
# Pinned predecessor identity for the synthetic base manifest (the package
# must read these from the manifest bytes, not from notes).
BASE_IMAGE_ID = "floe-debian13-riscv64-base-selfcheck"
BASE_DISK_SHA512 = "c" * 128
BASE_DISK_BYTES = 4096


def sha(path, algo="sha512"):
    digest = hashlib.new(algo)
    with open(path, "rb") as handle:
        digest.update(handle.read())
    return digest.hexdigest()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(path, mode) as handle:
        handle.write(data)
    return path


class _QuietSink(io.StringIO):
    """StringIO that also accepts the bytes some checks write to binary stderr."""

    def __init__(self):
        super().__init__()
        self.buffer = self

    def write(self, data):
        if isinstance(data, bytes):
            data = data.decode("utf-8", "replace")
        return super().write(data)


def quiet(function, *args):
    """Run a check that is expected to print failures, keeping the log clean."""
    sink = _QuietSink()
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        return function(*args)


def expect(condition, label):
    if condition:
        print("selfcheck OK: %s" % label, flush=True)
    else:
        raise SystemExit("selfcheck FAIL: %s" % label)
    return condition


def transcript_for(caps, broken=False, net="up", device=True):
    """A synthetic protocol-3 transcript with the frames the guest emits.

    `net`/`device` model the first-boot network contract: the runner's own
    status line, the guest-side device/DNS markers, and a `down` mode that
    reproduces run 35645930554 (no device, net=down).
    """
    blob = bytearray()
    blob += b"floe-exec: clock set from floe.epoch=1760000000\n"
    if net == "up":
        blob += (b"floe-exec: net eth0=10.0.2.15/24 gw=10.0.2.2 "
                 b"dns=10.0.2.3 status=up\n")
    elif net == "partial":
        blob += (b"floe-exec: net eth0=10.0.2.15/24 gw=10.0.2.2 "
                 b"status=partial (no resolver answered in 8s)\n")
    else:
        blob += b"floe-exec: net eth0: interface configuration failed: No such device\n"
    blob += b"\x1eFLOE-CAPS hello1 %s\x1e" % caps.encode()
    blob += b"\x1eFLOE-END hello1 0\x1e"
    if device:
        blob += b"\x1eFLOE-BEGIN netdev\x1eFLOE_NET_DEVICE_OK_"
        blob += guest_protocol_check.DEVICE_MAC.encode()
        blob += b"\n\x1eFLOE-END netdev 0\x1e"
        blob += b"\x1eFLOE-BEGIN netdns\x1eFLOE_NET_DNS_OK\n\x1eFLOE-END netdns 0\x1e"
    else:
        blob += b"\x1eFLOE-BEGIN netdev\x1eFLOE_NET_DEVICE_MISSING\n\x1eFLOE-END netdev 9\x1e"
        blob += b"\x1eFLOE-BEGIN netdns\x1eFLOE_NET_DNS_FAIL\n\x1eFLOE-END netdns 9\x1e"
    for n in (1, 2, 3, 4):
        blob += b"\x1eFLOE-BEGIN cc%d\x1e" % n
        blob += b"FLOE_CC%d_OF_4\n" % n
        blob += b"\x1eFLOE-END cc%d 0\x1e" % n
    blob += b"\x1eFLOE-BEGIN cancelme\x1e\x1eFLOE-END cancelme 143\x1e"
    blob += b"\x1eFLOE-BEGIN legacy1\x1e\x1eFLOE-END legacy1 130\x1e"
    blob += b"\x1eFLOE-BEGIN legacy2\x1e\x1eFLOE-END legacy2 130\x1e"
    blob += b"\x1eFLOE-BEGIN recovery\x1eFLOE_RECOVERY_OK\n\x1eFLOE-END recovery 0\x1e"
    for sess in ("ptyA", "ptyB"):
        blob += b"\x1eFLOE-BEGIN %s\x1e" % sess.encode()
        blob += b"FLOE_%s_OK\n" % sess.upper().encode()
        blob += b"\x1eFLOE-END %s 0\x1e" % sess.encode()
    blob += b"\x1eFLOE-PID svc1 4242\x1e\x1eFLOE-END svc1 0\x1e"
    blob += b"\x1eFLOE-END alivebad 3\x1e\x1eFLOE-END killbad 3\x1e"
    blob += b"\x1eFLOE-BEGIN p3done\x1eFLOE_P3_DONE\n\x1eFLOE-END p3done 0\x1e"
    if broken:
        return bytes(blob).replace(b"FLOE_RECOVERY_OK", b"recovery-never-ran")
    return bytes(blob)


def check_contract(out, repo):
    constants = pipeline_contract.parse_runner_constants(RUNNER_SOURCE)
    expect(constants == {"runner_version": "2.0.0", "protocol": 3, "max_commands": 8, "max_sessions": 4},
           "runner constants parse")
    caps = pipeline_contract.expected_caps(constants)
    expect(caps == CAPS_LEGACY, "CAPS payload format without the network field")
    expect(pipeline_contract.expected_caps(constants, net_status="up") == CAPS_WITH_NET,
           "CAPS payload format with the network field")
    try:
        pipeline_contract.expected_caps(constants, net_status="degraded")
        raise SystemExit("selfcheck FAIL: an unknown net status must fail closed")
    except ValueError:
        print("selfcheck OK: an unknown net status fails closed", flush=True)
    parsed = pipeline_contract.parse_caps(CAPS_WITH_NET)
    expect(parsed is not None and parsed["protocol"] == 3 and parsed["net"] == "up",
           "CAPS payload with the network field parses back")
    expect(parsed is not None and parsed["maxCommands"] == 8 and parsed["maxSessions"] == 4,
           "CAPS fields before the network field still parse")
    legacy_parsed = pipeline_contract.parse_caps(CAPS_LEGACY)
    expect(legacy_parsed is not None and legacy_parsed["net"] is None,
           "a pre-network CAPS payload still parses, with no network claim")
    expect(pipeline_contract.parse_caps(CAPS_WITH_NET.replace("net=up", "net=degraded")) is None,
           "an unknown network value does not parse")
    expect(pipeline_contract.parse_caps("runner=1.0 protocol=3 maxCommands=8 maxSessions=4 net=up extra") is None,
           "a CAPS payload with a trailing field does not parse")
    expect(pipeline_contract.caps_net_field(RUNNER_SOURCE),
           "the runner source's net= capability slot is discovered")
    expect(not pipeline_contract.caps_net_field(RUNNER_SOURCE_NO_NET),
           "a runner source without the net= slot is reported as such")
    # The workflow must hand the host the App's network switch; a missing
    # --net is exactly how run 35645930554 booted a guest with no eth0.
    workflow_path = os.path.join(repo, ".github/workflows/linux-guest-runner-update.yml")
    expect(os.path.isfile(workflow_path), "component workflow is in the checkout")
    workflow = open(workflow_path, encoding="utf-8").read()
    expect(pipeline_contract.workflow_enables_guest_network(workflow),
           "component workflow boots floe_vm_host with --net")
    stripped = re.sub(r"(?m)^\s*--net\s*\\?\s*$\n?", "", workflow)
    expect(not pipeline_contract.workflow_enables_guest_network(stripped),
           "a boot command without --net fails the workflow guard")
    expect(pipeline_contract.workflow_enables_guest_network(
        'run: timeout 60 floe_vm_host --bios b --kernel k --net \\\n'),
        "an inline --net after floe_vm_host is accepted")
    # The boot gate's required eth0 MAC must be the one the adapter really
    # assigns (adapter/floe_vm.c net->mac_addr[0..5]); deriving it here keeps
    # the guest-device assertion coupled to the engine instead of a string.
    adapter_path = os.path.join(
        repo, "FloeAgent/ThirdParty/TinyEMU/adapter/floe_vm.c")
    expect(os.path.isfile(adapter_path), "adapter source is in the checkout")
    adapter = open(adapter_path, encoding="utf-8").read()
    expect(pipeline_contract.adapter_guest_mac(adapter)
           == guest_protocol_check.DEVICE_MAC,
           "guest eth0 device MAC is re-derived from adapter/floe_vm.c (%s)"
           % guest_protocol_check.DEVICE_MAC)
    expect(pipeline_contract.adapter_guest_mac(
        adapter.replace("mac_addr[5] = 0x01;", "mac_addr[5] = 0x02;"))
        == "02:00:00:00:00:02",
        "an adapter MAC change is visible to the boot-gate coupling")
    expect(pipeline_contract.adapter_guest_mac("no mac here") is None,
           "a missing adapter MAC fails the coupling instead of guessing")
    roles, has_fields = pipeline_contract.engine_runner_contract(ENGINE_SOURCE)
    expect(has_fields and roles == ["bios", "disk", "initrd", "kernel", "runner"],
           "engine contract + Role enum parse")
    role, policy, _ = pipeline_contract.choose_runner_role(roles)
    expect(role == "runner" and policy == "engine-runner-role",
           "engine with a distinct runner role uses it")
    try:
        pipeline_contract.choose_runner_role([name for name in roles if name != "runner"])
        raise SystemExit("selfcheck FAIL: a Role enum without a runner case must fail closed")
    except ValueError:
        print("selfcheck OK: a Role enum without a distinct runner case fails closed", flush=True)
    origin = pipeline_contract.compatible_origin_contract(ENGINE_SOURCE, "")
    expect(origin["field"] == "compatibleOrigins"
           and origin["keys"] == {"image_id": "imageID", "sha512": "sha512", "bytes": "bytes"},
           "compatible-origin field and keys derive from the engine source")
    alias = pipeline_contract.compatible_origin_contract(ENGINE_SOURCE_ALIAS_ORIGIN, "")
    expect(alias["keys"] == {"image_id": "imageID", "sha512": "artifactSHA512",
                             "bytes": "artifactBytes"},
           "engine-side origin key names are followed, not guessed")
    odd = pipeline_contract.compatible_origin_contract(ENGINE_SOURCE_ODD_ORIGIN_NAME, "")
    expect(odd["field"] == "runnerCompatibleDiskOrigins",
           "an arbitrary engine field name is detected without a hardcoded list")
    for source, label in ((ENGINE_SOURCE_NO_ORIGIN, "no compatible-origin field"),
                          (ENGINE_SOURCE_NO_CONTRACT, "no engine artifact contract")):
        try:
            pipeline_contract.compatible_origin_contract(source, "")
            raise SystemExit("selfcheck FAIL: %s must fail closed" % label)
        except ValueError:
            print("selfcheck OK: %s fails closed" % label, flush=True)
    base = "binary gcc-riscv64-linux-gnu 4:13.2.0-7ubuntu1 source gcc-defaults 1.209\n"
    expect(not pipeline_contract.toolchain_record_gaps(base, base), "identical toolchain records have no gaps")
    expect(pipeline_contract.toolchain_record_gaps(base, base.replace("4:13.2.0", "4:13.3.0")),
           "toolchain version drift is reported")
    framed = b"\x1eFLOE-CAPS t runner=1.0 protocol=3 maxCommands=8 maxSessions=4\x1e"
    expect(guest_protocol_check.CAPS_FRAME.search(framed) is not None,
           "guest check matches a framed CAPS payload")
    expect(guest_protocol_check.CAPS_FRAME.search(b"echo FLOE-CAPS t runner=1.0 protocol=3") is None,
           "guest check ignores an unframed echo")

    # The runner source set is derived from floe_exec.c's own quoted includes,
    # so a new participating header (floe_net.h) can never be silently dropped
    # from the digest/relink contract.
    expect(pipeline_contract.local_includes(RUNNER_SOURCE) == ["floe_clock.h", "floe_net.h"],
           "local quoted includes are discovered (floe_clock.h, floe_net.h)")
    expect(pipeline_contract.runner_source_set(RUNNER_SOURCE)
           == ("floe_exec.c", "floe_clock.h", "floe_net.h", "Makefile"),
           "runner source set is floe_exec.c + every quoted header + Makefile")
    expect(pipeline_contract.local_includes('#  include <stdio.h>\n#include "a.h"\n') == ["a.h"],
           "system <> includes are not treated as runner sources")
    digest_record = ("%s  floe_exec.c\n%s  /build/floe_net.h\n"
                     % (hashlib.sha256(RUNNER_SOURCE.encode()).hexdigest(),
                        hashlib.sha256(RUNNER_NET_HEADER.encode()).hexdigest()))
    parsed_record = pipeline_contract.parse_source_sha256_record(digest_record)
    expect(parsed_record == {"floe_exec.c": hashlib.sha256(RUNNER_SOURCE.encode()).hexdigest(),
                             "floe_net.h": hashlib.sha256(RUNNER_NET_HEADER.encode()).hexdigest()},
           "runner-source-sha256 record parses with absolute paths reduced to basenames")


def check_guest_protocol(out):
    script_path = os.path.join(out, "p3-script.txt")
    terminal_path = os.path.join(out, "p3-terminal.txt")
    guest_protocol_check.generate(script_path, terminal_path)
    expect(open(terminal_path, encoding="utf-8").read().strip() == guest_protocol_check.TERMINAL_MARKER
           == "FLOE-END p3done 0",
           "generated terminal marker is the runner's terminal END frame")
    lines = open(script_path, "rb").read().splitlines()
    expect(0 < len(lines) <= 128, "generated script has a bounded number of commands")
    seen_tokens = set()
    well_formed = True
    for line in lines:
        if not line.startswith(b"@"):
            well_formed = False
            continue
        delay, text = line[1:].split(b" ", 1)
        float(delay)
        if len(text) >= 1024:
            well_formed = False
        seen_tokens.add(text)
    expect(well_formed, "every generated command is timed and fits floe_vm_host's 1024-byte buffer")
    expect(any(t.startswith(b"\x1eFLOE-HELLO") for t in seen_tokens), "script negotiates capabilities")
    expect(any(b"\x1eFLOE-OPEN" in t for t in seen_tokens), "script opens PTY sessions")
    expect(any(b"\x1eFLOE-SPAWN" in t for t in seen_tokens), "script spawns the background service")
    expect(any(t == b"\x03" for t in seen_tokens), "script exercises the legacy 0x03 cancel")
    expect(any(t.startswith(b"\x1eFLOE-EXEC p3done ") for t in seen_tokens),
           "script ends with the terminal END token")
    expect(any(t.startswith(b"\x1eFLOE-EXEC netdev ") for t in seen_tokens),
           "script probes the kernel's eth0 before the protocol matrix")
    expect(any(t.startswith(b"\x1eFLOE-EXEC netdns ") for t in seen_tokens),
           "script resolves a name from the guest userland")
    expect(all(("echo s >/floe/cc%d.start" % n) in guest_protocol_check.CC_CMD.format(n)
               and ("\\n' %d $n" % n) in guest_protocol_check.CC_CMD.format(n)
               for n in (1, 2, 3, 4)),
           "each concurrent command owns its distinct barrier file and output marker")
    expect(b"NO_OVERLAP" in guest_protocol_check.CC_CMD.format(1).encode()
           and b"exit 7" in guest_protocol_check.CC_CMD.format(1).encode(),
           "overlap barrier fails closed on timeout (marker + exit 7)")

    share = os.path.join(out, "share9p")
    os.makedirs(share, exist_ok=True)
    write(os.path.join(share, "svc1.log"), "tick0\ntick1\ntick2\ntick3\n")
    good = write(os.path.join(out, "good-transcript.txt"), transcript_for(CAPS_WITH_NET))
    verdict_path = os.path.join(out, "protocol-check.json")
    rc = guest_protocol_check.run_assert(good, share, verdict_path)
    expect(rc == 0, "a complete protocol-3 transcript with net=up passes")
    verdict = json.load(open(verdict_path))
    expect(verdict["capsPayload"] == CAPS_WITH_NET,
           "verdict records the verbatim CAPS payload with the network field")
    expect(verdict["netStatus"] == "up", "verdict records the network state")
    expect(verdict["serviceTicks"] == 4 and verdict["failures"] == 0, "verdict records service ticks")

    bad = write(os.path.join(out, "bad-transcript.txt"),
                transcript_for(CAPS_WITH_NET, broken=True))
    expect(quiet(guest_protocol_check.run_assert, bad, share, os.path.join(out, "bad-verdict.json")) == 1,
           "a transcript without the recovery marker fails closed")
    no_overlap = write(os.path.join(out, "no-overlap-transcript.txt"),
                       transcript_for(CAPS_WITH_NET)
                       .replace(b"FLOE_CC1_OF_4", b"FLOE_CC1_NO_OVERLAP")
                       .replace(b"FLOE-END cc1 0", b"FLOE-END cc1 7"))
    expect(quiet(guest_protocol_check.run_assert, no_overlap, share,
                 os.path.join(out, "no-overlap-verdict.json")) == 1,
           "a barrier-timeout (sequential) transcript fails closed")
    legacy = write(os.path.join(out, "legacy-transcript.txt"),
                   transcript_for("runner=1.0.0 protocol=2 maxCommands=1 maxSessions=1"))
    expect(quiet(guest_protocol_check.run_assert, legacy, share,
                 os.path.join(out, "legacy-verdict.json")) == 1,
           "a protocol-2 transcript fails closed")
    # The network contract fails closed: a guest with no device (net=down,
    # the run 35645930554 state), a configured interface whose DNS never
    # answered (net=partial), and a transcript whose userland probes failed
    # must all fail the boot gate instead of shipping a degraded component.
    no_device = write(os.path.join(out, "net-down-transcript.txt"),
                      transcript_for("runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=down",
                                     net="down", device=False))
    expect(quiet(guest_protocol_check.run_assert, no_device, share,
                 os.path.join(out, "net-down-verdict.json")) == 1,
           "a guest without eth0 (net=down) fails the boot gate")
    partial = write(os.path.join(out, "net-partial-transcript.txt"),
                    transcript_for("runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=partial",
                                   net="partial", device=False))
    expect(quiet(guest_protocol_check.run_assert, partial, share,
                 os.path.join(out, "net-partial-verdict.json")) == 1,
           "a configured interface without a DNS answer (net=partial) fails the boot gate")
    probe_failed = write(os.path.join(out, "net-probe-failed-transcript.txt"),
                         transcript_for(CAPS_WITH_NET, device=False))
    expect(quiet(guest_protocol_check.run_assert, probe_failed, share,
                 os.path.join(out, "net-probe-failed-verdict.json")) == 1,
           "a failed guest device/DNS probe fails the boot gate even if CAPS says net=up")


def make_fixture(root, writer_path=None, engine_source=None, toolchain_version="4:13.2.0-7ubuntu1",
                 runner_source=None):
    """Tiny but real files for a package_component round trip."""
    paths = {}
    runner_source = RUNNER_SOURCE if runner_source is None else runner_source
    writer_path = writer_path or _MANIFEST_WRITER
    fixture = os.path.join(root, "fixture")
    image_dir = os.path.join(fixture, "image")
    runner_out = os.path.join(fixture, "runner-build")
    os.makedirs(image_dir, exist_ok=True)
    os.makedirs(runner_out, exist_ok=True)

    paths["bbl"] = write(os.path.join(image_dir, "bbl64.bin"), b"bbl-bytes" * 64)
    paths["kernel"] = write(os.path.join(image_dir, "kernel-riscv64.bin"), b"kernel-bytes" * 128)
    paths["manifest-base"] = write(os.path.join(image_dir, "manifest-base.json"),
                                   json.dumps({
                                       "id": BASE_IMAGE_ID,
                                       "biosPath": "bbl64.bin",
                                       "kernelPath": "kernel-riscv64.bin",
                                       "diskPath": "disk.img",
                                       "diskReadWrite": True,
                                       "qualified": True,
                                       "artifacts": [{"role": "disk", "path": "disk.img",
                                                      "sha512": BASE_DISK_SHA512,
                                                      "bytes": BASE_DISK_BYTES}],
                                   }, indent=1) + "\n")
    paths["disk"] = write(os.path.join(image_dir, "disk.img"), b"disk-with-protocol-3-runner" * 256)

    runner_bin = write(os.path.join(runner_out, "floe-exec-riscv64"),
                       b"\x7fELF" + b"static runner FLOE-CAPS 2.0.0" * 16)
    runner_obj = write(os.path.join(runner_out, "floe-exec-riscv64.o"),
                       b"\x7fELF relocatable object" * 8)
    paths["runner_bin"] = runner_bin
    paths["runner_obj"] = runner_obj
    runner_sha256 = sha(runner_bin, "sha256")
    write(os.path.join(runner_out, "runner-sha256.txt"), "%s  floe-exec-riscv64\n" % runner_sha256)
    # Exact-source digest manifest for the complete derived source set.
    clock_header = "/* synthetic clock */\n"
    makefile = "riscv64:\n\t@true\n"
    source_fixture = {"floe_exec.c": runner_source, "floe_clock.h": clock_header,
                      "floe_net.h": RUNNER_NET_HEADER, "Makefile": makefile}
    write(os.path.join(runner_out, "runner-source-sha256.txt"),
           "".join("%s  %s\n" % (hashlib.sha256(payload.encode()).hexdigest(), name)
                   for name, payload in source_fixture.items()))
    write(os.path.join(runner_out, "runner-constants.txt"),
          json.dumps({"runner_version": "2.0.0", "protocol": 3, "max_commands": 8,
                      "max_sessions": 4}, indent=2) + "\n")
    write(os.path.join(runner_out, "toolchain.txt"),
          "cross_cc=riscv64-linux-gnu-gcc (Ubuntu 13.2.0) 13.2.0\n"
          "link_command=riscv64-linux-gnu-gcc -static -o floe-exec-riscv64 floe_exec.c\n"
          "toolchain_package gcc-riscv64-linux-gnu %s\n" % toolchain_version)
    write(os.path.join(runner_out, "toolchain-versions.txt"),
          "binary gcc-riscv64-linux-gnu %s source gcc-defaults 1.209\n"
          "binary libc6-dev-riscv64-cross 2.39-0ubuntu8cross1 source cross-toolchain-base 68ubuntu1\n"
          "riscv64-linux-gnu-gcc (Ubuntu 13.2.0) 13.2.0\n" % toolchain_version)
    paths["runner_sha256"] = runner_sha256

    repo = os.path.join(fixture, "repo")
    shutil.copyfile(writer_path, write(os.path.join(repo, "FloeAgent/LinuxGuest/image/write-image-manifest.py"), ""))
    write(os.path.join(repo, "FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift"),
          engine_source if engine_source else ENGINE_SOURCE)
    write(os.path.join(repo, "FloeAgent/Sources/FloeExecution/Linux/LinuxGuestRuntimeImage.swift"),
          "// synthetic runtime-image source for the pipeline self-check\n"
          "struct LinuxGuestRuntimeDiskOrigin {\n"
          "    var version: Int\n"
          "    var imageID: String\n"
          "    var artifactSHA512: String\n"
          "    var artifactBytes: Int64\n"
          "}\n")
    for name, payload in source_fixture.items():
        write(os.path.join(repo, "FloeAgent/LinuxGuest/runner", name), payload)
    paths["repo"] = repo
    paths["image_dir"] = image_dir
    paths["runner_out"] = runner_out
    paths["out"] = os.path.join(fixture, "package")
    paths["fixture"] = fixture
    return paths


def package_env(paths, base_toolchain, caps=CAPS_WITH_NET):
    verdict = {
        "schema": "floe-linux-guest-runner-update-check/v1",
        "transcriptBytes": 4096, "serviceTicks": 4, "capsPayload": caps,
        "checks": [{"check": name, "expected": True, "seen": True} for name in VERDICT_CHECKS],
        "failures": 0,
    }
    verdict_path = write(os.path.join(paths["fixture"], "verdict.json"), json.dumps(verdict) + "\n")
    injection_log = write(os.path.join(paths["fixture"], "runner-injection.log"),
                          "installed:\n/usr/local/bin/floe-exec\n%s\n" % paths["runner_sha256"])
    env = {
        "COMPONENT_TAG": "floe-linux-guest-selfcheck-1", "IMAGE_ID": "floe-debian13-riscv64-selfcheck",
        "TARGET_COMMIT": "0" * 40, "GITHUB_RUN_ID": "1",
        "RUNNER_VERSION_QUAL": "https://github.com/example/floe-agent/actions/runs/1",
        "RUN_URL": "https://github.com/example/floe-agent/actions/runs/1",
        "REPO": "example/floe-agent", "SERVER": "https://github.com",
        "BASE_TAG": "floe-linux-guest-base", "BASE_ZIP": "base.zip",
        "BASE_ZIP_BYTES": "123", "BASE_ZIP_SHA512": "a" * 128, "BASE_ZIP_SHA256": "b" * 64,
        "BASE_MANIFEST_SHA512": sha(paths["manifest-base"]),
        "BASE_BBL_SHA512": sha(paths["bbl"]), "BASE_KERNEL_SHA512": sha(paths["kernel"]),
        "BASE_IMAGE_ID": BASE_IMAGE_ID, "BASE_DISK_SHA512": BASE_DISK_SHA512,
        "BASE_DISK_BYTES": str(BASE_DISK_BYTES),
        "BASE_RELEASE_URL": "https://github.com/example/floe-agent/releases/tag/floe-linux-guest-base",
        "BASE_SOURCE_OFFER_URL": "https://github.com/example/floe-agent/releases/download/floe-linux-guest-base/SOURCE-OFFER.md",
        "BASE_ASSET_DIGESTS_JSON": json.dumps({
            "linux-guest-toolchain-source-fake.tar": {"bytes": 47, "sha256": "d" * 64},
            "linux-guest-sources-upstream-fake.tar": {"bytes": 11, "sha256": "e" * 64}}),
        "REUSED_ASSETS": "linux-guest-toolchain-source-fake.tar linux-guest-sources-upstream-fake.tar",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    args = [sys.executable, os.path.join(script_dir, "package_component.py"),
            "--image-dir", paths["image_dir"], "--runner-out", paths["runner_out"],
            "--protocol-verdict", verdict_path, "--injection-log", injection_log,
            "--repo", paths["repo"], "--out", paths["out"]]
    if base_toolchain:
        args += ["--base-toolchain-file", base_toolchain]
    return args, env


def run_package(args, env):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    return result


def check_package(out):
    base_toolchain = write(os.path.join(out, "base-toolchain.txt"),
                           "binary gcc-riscv64-linux-gnu 4:13.2.0-7ubuntu1 source gcc-defaults 1.209\n"
                           "binary libc6-dev-riscv64-cross 2.39-0ubuntu8cross1 source cross-toolchain-base 68ubuntu1\n"
                           "toolchain_package gcc-riscv64-linux-gnu 4:13.2.0-7ubuntu1\n")
    paths = make_fixture(os.path.join(out, "complete"))
    args, env = package_env(paths, base_toolchain)
    result = run_package(args, env)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit("selfcheck FAIL: package_component rejected a complete fixture")
    print("selfcheck OK: package_component produced the package", flush=True)

    manifest = json.load(open(os.path.join(paths["out"], "manifest.json")))
    artifact = manifest.get("runnerArtifact") or {}
    expect(artifact.get("path") == "floe-exec-riscv64" and artifact.get("role") == "runner",
           "manifest runnerArtifact uses the standalone path and the distinct runner role")
    expect(artifact.get("sha512") == sha(paths["runner_bin"]) and artifact.get("bytes") ==
           os.path.getsize(paths["runner_bin"]), "manifest runnerArtifact digest/size match the built runner")
    expect(manifest.get("runnerCapabilities") == CAPS_WITH_NET,
           "manifest runnerCapabilities is the verbatim CAPS payload (with net=up)")
    expect(manifest.get("compatibleOrigins") == [{"imageID": BASE_IMAGE_ID,
                                                  "sha512": BASE_DISK_SHA512,
                                                  "bytes": BASE_DISK_BYTES}],
           "manifest declares the verified predecessor as a compatible origin")

    zip_name = "floe-linux-guest-%s.zip" % env["IMAGE_ID"]
    zip_path = os.path.join(paths["out"], zip_name)
    with zipfile.ZipFile(zip_path) as archive:
        expect(archive.namelist() == ["manifest.json", "bbl64.bin", "kernel-riscv64.bin", "disk.img",
                                      "floe-exec-riscv64"], "archive carries the standalone runner member")
        expect(archive.read("manifest.json") == open(os.path.join(paths["out"], "manifest.json"), "rb").read(),
               "archive manifest equals the release manifest")
        with archive.open("floe-exec-riscv64") as handle:
            runner_bytes = handle.read()
        expect(hashlib.sha512(runner_bytes).hexdigest() == artifact["sha512"],
               "archive runner bytes match runnerArtifact.sha512")

    distribution = json.load(open(os.path.join(paths["out"], "distribution.json")))
    expect(distribution["runnerArtifact"]["role"] == "runner"
           and distribution["runnerArtifact"]["rolePolicy"] == "engine-runner-role",
           "distribution records the runner role policy")
    expect(distribution["predecessorOrigin"]["entry"]["imageID"] == BASE_IMAGE_ID,
           "distribution records the verified predecessor origin")
    expect(distribution["runnerCapabilities"] == manifest["runnerCapabilities"],
           "distribution records the CAPS payload")
    expect(distribution["toolchainComparison"] and not distribution["toolchainComparison"]["gaps"],
           "distribution records the toolchain comparison")

    sums = {}
    for line in open(os.path.join(paths["out"], "SHA256SUMS")):
        digest, name = line.split()
        sums[name] = digest
    for name, digest in sums.items():
        if name == "SHA256SUMS":
            continue
        expect(sha(os.path.join(paths["out"], name), "sha256") == digest, "SHA256SUMS covers %s" % name)
    expect("SHA512SUMS" in sums, "SHA256SUMS covers SHA512SUMS")

    import tarfile
    relink = os.path.join(paths["out"], "linux-guest-runner-relink-floe-linux-guest-selfcheck-1.tar")
    with tarfile.open(relink) as tar:
        members = {member.name: member for member in tar.getmembers()}
        names = sorted(members)
        # The relink header is byte-identical to the target-commit checkout.
        relink_net_bytes = tar.extractfile(members["floe_net.h"]).read() if "floe_net.h" in members else None
        relink_md_bytes = tar.extractfile(members["RELINK.md"]).read() if "RELINK.md" in members else b""
    for name in ("floe_exec.c", "floe_clock.h", "floe_net.h", "Makefile", "floe-exec-riscv64.o",
                 "toolchain.txt", "runner-constants.txt", "runner-source-sha256.txt", "RELINK.md"):
        expect(name in names, "relink archive carries %s" % name)
    expect(relink_net_bytes == open(os.path.join(paths["repo"], "FloeAgent/LinuxGuest/runner/floe_net.h"),
                                    "rb").read(),
           "relink floe_net.h is byte-identical to the target commit")
    offer_text = open(os.path.join(paths["out"], "SOURCE-OFFER.md"), encoding="utf-8").read()
    expect("floe_net.h" in offer_text and "runner-source-sha256.txt" in offer_text,
           "SOURCE-OFFER names floe_net.h and the exact-source digest manifest")
    expect("floe_net.h" in relink_md_bytes.decode(),
           "RELINK.md names the complete source set including floe_net.h")
    source_members = distribution.get("runnerSource", {}).get("members", [])
    expect([entry["name"] for entry in source_members]
           == ["floe_exec.c", "floe_clock.h", "floe_net.h", "Makefile"],
           "distribution.runnerSource records the complete source set")
    for entry in source_members:
        expect(len(entry.get("sha256", "")) == 64, "distribution.runnerSource records a sha256 per member")
    ref = os.path.join(paths["out"], "linux-guest-reused-source-references-floe-linux-guest-selfcheck-1.tar")
    with tarfile.open(ref) as tar:
        ref_names = sorted(tar.getnames())
    expect("REUSED-SOURCES.json" in ref_names and "toolchain-comparison.txt" in ref_names,
           "reused-source archive records the toolchain comparison")

    # --- fail-closed cases --------------------------------------------------
    bad_paths = make_fixture(os.path.join(out, "mismatch"))
    args, env = package_env(bad_paths, base_toolchain,
                            caps="runner=2.0.0 protocol=3 maxCommands=1 maxSessions=1 net=up")
    expect(run_package(args, env).returncode != 0, "CAPS/source mismatch fails closed")

    # A guest that answered net=down/partial must never be packaged: the
    # component exists to give the App a usable network (apt/pip/npm).
    degraded_paths = make_fixture(os.path.join(out, "netdown"))
    args, env = package_env(degraded_paths, base_toolchain,
                            caps="runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=down")
    expect(run_package(args, env).returncode != 0, "a net=down guest verdict fails closed")
    partial_paths = make_fixture(os.path.join(out, "netpartial"))
    args, env = package_env(partial_paths, base_toolchain,
                            caps="runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=partial")
    expect(run_package(args, env).returncode != 0, "a net=partial guest verdict fails closed")
    missing_field_paths = make_fixture(os.path.join(out, "netabsent"))
    args, env = package_env(missing_field_paths, base_toolchain, caps=CAPS_LEGACY)
    expect(run_package(args, env).returncode != 0,
           "a CAPS payload without the net= field fails closed when the source emits it")
    # A runner source that does not emit the net field cannot back the
    # manifest's runnerCapabilities claim, even with a matching payload.
    no_field_paths = make_fixture(os.path.join(out, "nosourcefield"),
                                  runner_source=RUNNER_SOURCE_NO_NET)
    args, env = package_env(no_field_paths, base_toolchain, caps=CAPS_LEGACY)
    expect(run_package(args, env).returncode != 0,
           "a runner source without the net= slot cannot package a network claim")

    drifted = write(os.path.join(out, "base-toolchain-drift.txt"),
                    "binary gcc-riscv64-linux-gnu 4:13.3.0-9ubuntu1 source gcc-defaults 1.209\n"
                    "toolchain_package gcc-riscv64-linux-gnu 4:13.3.0-9ubuntu1\n")
    drift_paths = make_fixture(os.path.join(out, "drift"))
    args, env = package_env(drift_paths, drifted)
    expect(run_package(args, env).returncode != 0, "cross-toolchain drift fails closed")

    no_contract = make_fixture(os.path.join(out, "nocontract"),
                               engine_source=ENGINE_SOURCE_NO_CONTRACT)
    args, env = package_env(no_contract, base_toolchain)
    expect(run_package(args, env).returncode != 0, "engine without the artifact contract fails closed")

    alias_paths = make_fixture(os.path.join(out, "aliasorigin"),
                               engine_source=ENGINE_SOURCE_ALIAS_ORIGIN)
    args, env = package_env(alias_paths, base_toolchain)
    expect(run_package(args, env).returncode == 0, "engine with sidecar-style origin keys packages")
    alias_manifest = json.load(open(os.path.join(alias_paths["out"], "manifest.json")))
    expect(alias_manifest["compatibleOrigins"] == [{"imageID": BASE_IMAGE_ID,
                                                    "artifactSHA512": BASE_DISK_SHA512,
                                                    "artifactBytes": BASE_DISK_BYTES}],
           "manifest origin entry uses the engine's own key names")

    no_role = make_fixture(os.path.join(out, "norole"), engine_source=ENGINE_SOURCE_NO_RUNNER_ROLE)
    args, env = package_env(no_role, base_toolchain)
    expect(run_package(args, env).returncode != 0, "engine without a distinct runner role fails closed")

    no_origin = make_fixture(os.path.join(out, "noorigin"), engine_source=ENGINE_SOURCE_NO_ORIGIN)
    args, env = package_env(no_origin, base_toolchain)
    expect(run_package(args, env).returncode != 0, "engine without a compatible-origin field fails closed")

    # --- floe_net.h exact-source contract fail-closed cases -----------------
    # (a) runner-source-sha256.txt that omits floe_net.h must fail.
    omitted_paths = make_fixture(os.path.join(out, "netomitted"))
    omitted_record = "".join(
        "%s  %s\n" % (hashlib.sha256(payload.encode()).hexdigest(), name)
        for name, payload in (("floe_exec.c", RUNNER_SOURCE), ("floe_clock.h", "/* synthetic clock */\n"),
                              ("Makefile", "riscv64:\n\t@true\n")))
    write(os.path.join(omitted_paths["runner_out"], "runner-source-sha256.txt"), omitted_record)
    args, env = package_env(omitted_paths, base_toolchain)
    expect(run_package(args, env).returncode != 0,
           "runner-source-sha256 that omits floe_net.h fails closed")

    # (b) a digest that does not match the target-commit file must fail.
    digest_drift_paths = make_fixture(os.path.join(out, "netdrift"))
    drift_record = "".join(
        "%s  %s\n" % (hashlib.sha256(payload.encode()).hexdigest(), name)
        for name, payload in (("floe_exec.c", RUNNER_SOURCE),
                              ("floe_clock.h", "/* synthetic clock */\n"),
                              ("floe_net.h", "/* synthetic clock */\n"),
                              ("Makefile", "riscv64:\n\t@true\n")))
    write(os.path.join(digest_drift_paths["runner_out"], "runner-source-sha256.txt"), drift_record)
    args, env = package_env(digest_drift_paths, base_toolchain)
    expect(run_package(args, env).returncode != 0,
           "a wrong floe_net.h digest in runner-source-sha256 fails closed")

    # (c) floe_net.h missing from the checked-out runner dir must fail even if
    # the digest record names it.
    missing_paths = make_fixture(os.path.join(out, "netmissing"))
    os.remove(os.path.join(missing_paths["repo"], "FloeAgent/LinuxGuest/runner/floe_net.h"))
    args, env = package_env(missing_paths, base_toolchain)
    expect(run_package(args, env).returncode != 0,
           "floe_net.h absent from the target checkout fails closed")

    odd_paths = make_fixture(os.path.join(out, "oddorigin"),
                             engine_source=ENGINE_SOURCE_ODD_ORIGIN_NAME)
    args, env = package_env(odd_paths, base_toolchain)
    expect(run_package(args, env).returncode == 0, "engine with an unusual origin field name packages")
    odd_manifest = json.load(open(os.path.join(odd_paths["out"], "manifest.json")))
    expect(odd_manifest.get("runnerCompatibleDiskOrigins") == [{"imageID": BASE_IMAGE_ID,
                                                                "sha512": BASE_DISK_SHA512,
                                                                "bytes": BASE_DISK_BYTES}],
           "manifest writes the engine's actual origin field name")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=os.path.abspath(os.path.join(script_dir, "..", "..", "..")),
                        help="checkout providing write-image-manifest.py")
    parser.add_argument("--out", default=None, help="evidence dir (default: a temp dir, removed unless --keep)")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    manifest_writer = os.path.join(args.repo, "FloeAgent/LinuxGuest/image/write-image-manifest.py")
    expect(os.path.isfile(manifest_writer), "checkout provides write-image-manifest.py: %s" % manifest_writer)

    out = args.out or tempfile.mkdtemp(prefix="floe-runner-selfcheck-")
    os.makedirs(out, exist_ok=True)
    print("selfcheck: evidence in %s" % out, flush=True)
    global _MANIFEST_WRITER
    _MANIFEST_WRITER = manifest_writer

    try:
        check_contract(out, args.repo)
        check_guest_protocol(out)
        check_package(out)
        write(os.path.join(out, "selfcheck-passed.json"),
              json.dumps({"schema": "floe-linux-guest-runner-update-selfcheck/v1",
                          "result": "passed", "checks": ["contract", "guest-protocol", "package"]},
                         indent=2) + "\n")
        print("selfcheck: PASSED", flush=True)
    finally:
        if not args.keep and not args.out:
            shutil.rmtree(out, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

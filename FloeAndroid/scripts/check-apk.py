#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only distribution-boundary checker for the G01 full/play debug APKs.

The checker never modifies its inputs. It reads the APK zip container, the DEX
class tables and the packaged ELF headers directly, and asks the Android SDK's
``aapt2`` for the merged manifest. It verifies that:

* the full APK contains the full-only marker classes (a positive control, so a
  play-only negative result cannot be vacuous);
* the play APK contains no class from the full-only ``phonecontrol`` or
  ``rootsystem`` packages;
* the play APK declares no AccessibilityService, root/daemon component or
  forbidden elevated permission;
* the full APK admits only the two exact, reviewed G08 protected components
  (the PhoneControl AccessibilityService and the Floe system provider), each
  with its exact class, permission, export, authority, action/meta or
  multiprocess/URI-grant shape, and rejects every other accessibility, root or
  Shizuku declaration. The explicit ``legacy`` Full profile keeps the pre-G08
  strict boundary and admits neither component;
* both APKs carry the Swift core, the JNI bridge and the Swift runtime;
* the Full channel requires package-manager extraction
  (``extractNativeLibs=true``) for its embedded starter, allows deflated ZIP
  entries, and still requires every stored entry to be 16 KiB zip-aligned;
  the Play channel requires ``extractNativeLibs=false`` with every native
  entry stored and 16 KiB zip-aligned for direct mmap;
* every ELF ``PT_LOAD`` segment declares at least 16 KiB alignment in both
  channels;
* every ELF ``DT_NEEDED`` entry is a basename (no path separator) and resolves
  either to a packaged ``lib/arm64-v8a`` library or to a public Android system
  library;
* when the repository native manifest is available, every recorded JNI/Swift
  library hash matches the packaged bytes exactly.

Usage:
    python3 scripts/check-apk.py APP-FULL-DEBUG.apk APP-PLAY-DEBUG.apk

Optional:
    --aapt2 PATH            aapt2 executable (default: newest SDK build-tools)
    --native-manifest PATH  native-manifest.json recorded by native-manifest.py
    --full-manifest-profile {g08,legacy}
                            Full protected-component contract (default: g08)
    --compact               emit single-line JSON

Signing continuity is opt-in (the default boundary report keeps signatures out
of scope). When requested, the checker also reads each APK's V2/V3 signer
certificate SHA-256 digest via the SDK's read-only ``apksigner verify
--print-certs``:
    --apksigner PATH        apksigner executable (default: newest SDK build-tools)
    --test-apk PATH         extra APK (androidTest) to include in signing checks
                            (repeatable; distribution boundaries are not re-run
                            on test APKs)
    --require-identical-signer
                          fail unless every listed APK shares one signer digest
    --expect-cert-sha256 HEX
                          additionally require that shared digest to equal the
                          pinned development certificate digest

Exit status is 0 only when every check passes; otherwise 1 with failures listed.
The report is written to stdout only. Limitations are reported explicitly.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

FULL_ONLY_PACKAGES = (
    "Lcom/floe/android/phonecontrol/",
    "Lcom/floe/android/rootsystem/",
)
FULL_ONLY_MARKERS = (
    "Lcom/floe/android/phonecontrol/PhoneControlModule;",
    "Lcom/floe/android/rootsystem/RootSystemModule;",
)
REQUIRED_NATIVE = (
    "lib/arm64-v8a/libFloeAndroidCore.so",
    "lib/arm64-v8a/libfloe_jni.so",
    "lib/arm64-v8a/libswiftCore.so",
)
FORBIDDEN_PERMISSIONS = {
    "android.permission.BIND_ACCESSIBILITY_SERVICE",
    "android.permission.MANAGE_ACCESSIBILITY",
    "android.permission.WRITE_SECURE_SETTINGS",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.REBOOT",
    "android.permission.ACCESS_SUPERUSER",
    "android.permission.MOUNT_UNMOUNT_FILESYSTEMS",
}
FORBIDDEN_PERMISSION_PATTERNS = (
    re.compile(r"ACCESSIBILITY", re.IGNORECASE),
    re.compile(r"SUPERUSER", re.IGNORECASE),
)
FORBIDDEN_SERVICE_NAME = re.compile(
    r"(accessibility|rootsystem|rootdaemon|root_daemon|superuser|shizuku)",
    re.IGNORECASE,
)
ACCESSIBILITY_ACTION = "android.accessibilityservice.AccessibilityService"
ACCESSIBILITY_META = "android.accessibilityservice"
# The only two protected components admitted to the current G08 Full channel.
# Each exception is bound to the exact reviewed class and manifest shape below;
# there is no package-, filename- or label-wide bypass.
G08_FULL_ACCESSIBILITY_SERVICE = (
    "com.floe.android.phonecontrol.PhoneControlAccessibilityService"
)
G08_FULL_ACCESSIBILITY_PERMISSION = "android.permission.BIND_ACCESSIBILITY_SERVICE"
G08_FULL_PROVIDER = "com.floe.android.rootsystem.ipc.FloeSystemProvider"
G08_FULL_PROVIDER_PERMISSION = "android.permission.INTERACT_ACROSS_USERS_FULL"
G08_FULL_PROVIDER_AUTHORITY_SUFFIX = ".floe.system"
FORBIDDEN_COMPONENT_PERMISSIONS = {
    G08_FULL_ACCESSIBILITY_PERMISSION,
    G08_FULL_PROVIDER_PERMISSION,
}
# Exact application identities produced by the real "distribution" flavor and
# the debug applicationIdSuffix. Channel decisions use the merged manifest's
# actual package, never the APK filename or a display label.
CHANNEL_PACKAGES = {
    "full": ("com.floe.agent.full", "com.floe.agent.full.dev"),
    "play": ("com.floe.agent", "com.floe.agent.dev"),
}
FULL_MANIFEST_PROFILES = ("g08", "legacy")
PAGE_16K = 16384
ELF_PT_LOAD = 1
ELF_PT_DYNAMIC = 2
ELF_EM_AARCH64 = 183
ELF_DT_NULL = 0
ELF_DT_NEEDED = 1
ELF_DT_STRTAB = 5
ELF_DT_STRSZ = 10

# Public Android NDK system libraries (API 28+). A packaged library may depend
# on these by basename without shipping a copy; everything else must resolve to
# another packaged lib/arm64-v8a entry.
ANDROID_PUBLIC_LIBRARIES = {
    "libEGL.so",
    "libGLESv1_CM.so",
    "libGLESv2.so",
    "libGLESv3.so",
    "libOpenMAXAL.so",
    "libOpenSLES.so",
    "libaaudio.so",
    "libamidi.so",
    "libandroid.so",
    "libc.so",
    "libcamera2ndk.so",
    "libdl.so",
    "libjnigraphics.so",
    "liblog.so",
    "libm.so",
    "libmediandk.so",
    "libnativewindow.so",
    "libneuralnetworks.so",
    "libsync.so",
    "libvulkan.so",
    "libz.so",
}


class CheckError(Exception):
    """A check failed; the message is user-facing evidence."""


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


TRUE_BOOLEAN_LITERALS = frozenset({"true", "1", "0x1"})
FALSE_BOOLEAN_LITERALS = frozenset({"false", "0", "0x0"})


def typed_boolean(value):
    """Return the literal boolean for an aapt2 typed value, else ``None``.

    ``aapt2 dump xmltree`` renders literal booleans as ``true``/``false`` and
    leaves resource references unresolved. ``bool("false")`` is true, so the
    contract never relies on Python truthiness for these attributes: an absent,
    referenced or otherwise non-literal value stays ``None`` and fails an exact
    boolean requirement.
    """
    if isinstance(value, bool):
        return value
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if normalized in TRUE_BOOLEAN_LITERALS:
        return True
    if normalized in FALSE_BOOLEAN_LITERALS:
        return False
    return None


def package_channel(package):
    """Return the channel whose exact application ID matches ``package``."""
    for channel, packages in CHANNEL_PACKAGES.items():
        if package in packages:
            return channel
    return None


def channel_identity_problems(channel, facts):
    """Check that the merged manifest package is the exact requested channel."""
    if channel not in CHANNEL_PACKAGES:
        raise CheckError("unknown application channel: {}".format(channel))
    package = facts.get("package") or ""
    actual = package_channel(package)
    if actual is None:
        return [
            "manifest package {!r} is not a known Floe {} channel identity "
            "(expected one of {})".format(
                package, channel, ", ".join(CHANNEL_PACKAGES[channel])
            )
        ]
    if actual != channel:
        return [
            "manifest package {!r} is the {} channel identity but the {} slot "
            "was checked".format(package, actual, channel)
        ]
    return []


def find_aapt2(explicit):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise CheckError("aapt2 not found: {}".format(path))
        return str(path)
    sdk = os.environ.get("ANDROID_HOME")
    if sdk:
        build_tools = Path(sdk) / "build-tools"
        if build_tools.is_dir():
            candidates = []
            for child in build_tools.iterdir():
                binary = child / "aapt2"
                if binary.is_file():
                    numbers = tuple(
                        int(part) if part.isdigit() else 0
                        for part in re.split(r"[.\-]", child.name)
                    )
                    candidates.append((numbers, str(binary)))
            if candidates:
                candidates.sort()
                return candidates[-1][1]
    found = shutil.which("aapt2")
    if found:
        return found
    raise CheckError(
        "aapt2 was not found; set ANDROID_HOME or pass --aapt2 (manifest checks "
        "fail closed rather than being skipped)"
    )


def find_build_tools_binary(name, explicit, flag):
    """Locate an SDK build-tools binary (aapt2/apksigner style resolution)."""
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise CheckError("{} not found: {}".format(name, path))
        return str(path)
    sdk = os.environ.get("ANDROID_HOME")
    if sdk:
        build_tools = Path(sdk) / "build-tools"
        if build_tools.is_dir():
            candidates = []
            for child in build_tools.iterdir():
                binary = child / name
                if binary.is_file():
                    numbers = tuple(
                        int(part) if part.isdigit() else 0
                        for part in re.split(r"[.\-]", child.name)
                    )
                    candidates.append((numbers, str(binary)))
            if candidates:
                candidates.sort()
                return candidates[-1][1]
    found = shutil.which(name)
    if found:
        return found
    raise CheckError(
        "{} was not found; set ANDROID_HOME or pass {}".format(name, flag)
    )


CERT_DIGEST_LINE = re.compile(r"certificate SHA-256 digest:\s*([0-9a-fA-F]{64})")


def signer_certificate_digests(apksigner, apk):
    """Return every signer certificate SHA-256 digest reported for one APK."""
    proc = subprocess.run(
        [apksigner, "verify", "--print-certs", str(apk)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=180,
    )
    if proc.returncode != 0:
        raise CheckError(
            "apksigner failed on {} ({}): {}".format(
                apk, proc.returncode, proc.stderr.strip()
            )
        )
    digests = [match.lower() for match in CERT_DIGEST_LINE.findall(proc.stdout)]
    if not digests:
        raise CheckError("apksigner reported no signer certificate for {}".format(apk))
    return digests


def uleb128(data, offset):
    result = 0
    shift = 0
    while True:
        if offset >= len(data):
            raise CheckError("truncated uleb128 in DEX")
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, offset
        shift += 7
        if shift > 35:
            raise CheckError("invalid uleb128 in DEX")


def u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise CheckError("DEX offset outside file")
    return struct.unpack_from("<I", data, offset)[0]


def dex_class_descriptors(data):
    """Return the class descriptors defined by one DEX file."""
    if len(data) < 0x70 or data[:4] != b"dex\n":
        raise CheckError("not a DEX file")
    if u32(data, 40) not in (0x12345678, 0x78563412):
        raise CheckError("unsupported DEX endian tag")
    if u32(data, 36) < 0x70:
        raise CheckError("DEX header too small")
    string_ids_size = u32(data, 56)
    string_ids_off = u32(data, 60)
    type_ids_size = u32(data, 64)
    type_ids_off = u32(data, 68)
    class_defs_size = u32(data, 96)
    class_defs_off = u32(data, 100)
    for size, off, item in (
        (string_ids_size, string_ids_off, 4),
        (type_ids_size, type_ids_off, 4),
        (class_defs_size, class_defs_off, 32),
    ):
        if size and (off < 0x70 or off + size * item > len(data)):
            raise CheckError("DEX table outside file")

    descriptor_cache = {}

    def descriptor_for_type(type_idx):
        if type_idx >= type_ids_size:
            raise CheckError("DEX type index out of range")
        if type_idx in descriptor_cache:
            return descriptor_cache[type_idx]
        string_idx = u32(data, type_ids_off + type_idx * 4)
        if string_idx >= string_ids_size:
            raise CheckError("DEX string index out of range")
        string_off = u32(data, string_ids_off + string_idx * 4)
        _, position = uleb128(data, string_off)
        end = data.find(b"\x00", position)
        if end < 0:
            raise CheckError("unterminated DEX string")
        value = data[position:end].decode("utf-8", "replace")
        descriptor_cache[type_idx] = value
        return value

    classes = []
    for index in range(class_defs_size):
        class_idx = u32(data, class_defs_off + index * 32)
        classes.append(descriptor_for_type(class_idx))
    return classes


def read_dex_classes(archive):
    dex_names = sorted(
        (name for name in archive.namelist() if re.fullmatch(r"classes\d*\.dex", name)),
        key=lambda name: (len(name), name),
    )
    if not dex_names:
        raise CheckError("APK has no classes*.dex")
    classes = set()
    for name in dex_names:
        classes.update(dex_class_descriptors(archive.read(name)))
    return dex_names, classes


def elf_metadata(data):
    """Return (machine, [(p_align, p_offset), ...], [DT_NEEDED, ...]).

    A malformed or path-qualified DT_NEEDED entry is reported by the caller as
    a check failure; this parser only fails closed on structural corruption.
    """
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise CheckError("not an ELF file")
    if data[4] != 2:
        raise CheckError("not a 64-bit ELF")
    if data[5] != 1:
        raise CheckError("not a little-endian ELF")
    machine = struct.unpack_from("<H", data, 18)[0]
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize = struct.unpack_from("<H", data, 54)[0]
    phnum = struct.unpack_from("<H", data, 56)[0]
    if phentsize < 56:
        raise CheckError("ELF program header entry too small")
    if phnum and phoff + phnum * phentsize > len(data):
        raise CheckError("ELF program header table outside file")
    loads = []
    dynamic = None
    for index in range(phnum):
        base = phoff + index * phentsize
        p_type = struct.unpack_from("<I", data, base)[0]
        p_offset = struct.unpack_from("<Q", data, base + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, base + 32)[0]
        if p_type == ELF_PT_LOAD:
            p_vaddr = struct.unpack_from("<Q", data, base + 16)[0]
            p_align = struct.unpack_from("<Q", data, base + 48)[0]
            loads.append((p_align, p_offset, p_vaddr, p_filesz))
        elif p_type == ELF_PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)
    if not loads:
        raise CheckError("ELF has no PT_LOAD segment")

    def virtual_to_offset(address):
        for _, offset, vaddr, filesz in loads:
            if vaddr <= address < vaddr + filesz:
                return offset + (address - vaddr)
        raise CheckError(
            "ELF dynamic string table address {:#x} is outside PT_LOAD".format(address)
        )

    needed = []
    if dynamic:
        offset, filesz = dynamic
        if offset + filesz > len(data):
            raise CheckError("ELF PT_DYNAMIC outside file")
        strtab = None
        strsz = None
        entries = []
        position = offset
        while position + 16 <= offset + filesz:
            tag, value = struct.unpack_from("<qQ", data, position)
            position += 16
            if tag == ELF_DT_NULL:
                break
            if tag == ELF_DT_NEEDED:
                entries.append(value)
            elif tag == ELF_DT_STRTAB:
                strtab = value
            elif tag == ELF_DT_STRSZ:
                strsz = value
        if entries and strtab is None:
            raise CheckError("ELF has DT_NEEDED but no DT_STRTAB")
        if entries:
            table = virtual_to_offset(strtab)
            limit = len(data) if strsz is None else min(len(data), table + strsz)
            for name_offset in entries:
                start = table + name_offset
                if start >= limit:
                    raise CheckError("ELF DT_NEEDED offset outside string table")
                end = data.find(b"\x00", start, limit)
                if end < 0:
                    raise CheckError("unterminated ELF DT_NEEDED string")
                needed.append(data[start:end].decode("utf-8", "replace"))
    return machine, [(align, offset) for align, offset, _, _ in loads], needed


def zip_data_offset(archive, info):
    if info.header_offset < 0:
        raise CheckError("invalid zip local header offset")
    archive.fp.seek(info.header_offset)
    header = archive.fp.read(30)
    if len(header) != 30:
        raise CheckError("truncated zip local header")
    signature, _, _, _, _, _, _, _, _, name_len, extra_len = struct.unpack(
        "<IHHHHHIIIHH", header
    )
    if signature != 0x04034B50:
        raise CheckError("bad zip local header signature")
    return info.header_offset + 30 + name_len + extra_len


def parse_xmltree(text):
    """Build a minimal element tree from ``aapt2 dump xmltree`` output."""
    root = {"tag": None, "attrs": {}, "children": [], "depth": -1}
    stack = [root]
    attribute = re.compile(r'^\s*A: (.*?)=(?:"(.*?)"|([^\s"]+))')
    element = re.compile(r"^(\s*)E: (\S+)")
    for line in text.splitlines():
        match = element.match(line)
        if match:
            depth = len(match.group(1))
            node = {
                "tag": match.group(2),
                "attrs": {},
                "children": [],
                "depth": depth,
            }
            while stack and stack[-1]["depth"] >= depth:
                stack.pop()
            stack[-1]["children"].append(node)
            stack.append(node)
            continue
        match = attribute.match(line)
        if match and len(stack) > 1:
            key = re.sub(r"\(0x[0-9a-fA-F]+\)$", "", match.group(1))
            if ":" in key:
                key = key.rsplit(":", 1)[1]
            value = match.group(2) if match.group(2) is not None else match.group(3)
            stack[-1]["attrs"][key] = value
    if not root["children"]:
        raise CheckError("aapt2 returned no manifest elements")
    return root["children"][0]


def walk(node):
    yield node
    for child in node["children"]:
        for descendant in walk(child):
            yield descendant


def intent_filter_facts(node):
    """Describe one ``<intent-filter>`` and its direct children."""
    actions = []
    categories = []
    data_count = 0
    other_children = []
    for child in node["children"]:
        if child["tag"] == "action":
            action = child["attrs"].get("name")
            if action:
                actions.append(action)
        elif child["tag"] == "category":
            category = child["attrs"].get("name")
            if category:
                categories.append(category)
        elif child["tag"] == "data":
            data_count += 1
        else:
            other_children.append(child["tag"])
    return {
        "actions": actions,
        "categories": categories,
        "dataCount": data_count,
        "otherChildren": other_children,
    }


def meta_data_facts(node):
    attrs = node["attrs"]
    return {
        "name": attrs.get("name") or "",
        "resource": attrs.get("resource"),
        "value": attrs.get("value"),
    }


def component_facts(node):
    """Retain the manifest shape needed by the exact component contract."""
    attrs = node["attrs"]
    details = {
        "tag": node["tag"],
        "name": attrs.get("name") or "",
        "permission": attrs.get("permission"),
        "exported": attrs.get("exported"),
        "enabled": attrs.get("enabled"),
        "childTags": [child["tag"] for child in node["children"]],
        "intentFilters": [
            intent_filter_facts(child)
            for child in node["children"]
            if child["tag"] == "intent-filter"
        ],
        "metaData": [
            meta_data_facts(child)
            for child in node["children"]
            if child["tag"] == "meta-data"
        ],
    }
    if node["tag"] == "provider":
        authorities = attrs.get("authorities") or ""
        details["authorities"] = [
            authority.strip()
            for authority in authorities.split(";")
            if authority.strip()
        ]
        details["multiprocess"] = attrs.get("multiprocess")
        details["grantUriPermissions"] = attrs.get("grantUriPermissions")
        details["readPermission"] = attrs.get("readPermission")
        details["writePermission"] = attrs.get("writePermission")
    return details


def manifest_facts(aapt2, apk):
    proc = subprocess.run(
        [aapt2, "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=180,
    )
    if proc.returncode != 0:
        raise CheckError(
            "aapt2 failed ({}): {}".format(proc.returncode, proc.stderr.strip())
        )
    manifest = parse_xmltree(proc.stdout)
    nodes = list(walk(manifest))
    permissions = []
    declared_permissions = []
    services = []
    activities = []
    providers = []
    receivers = []
    components = []
    actions = []
    meta_data = []
    accessibility_action_count = 0
    accessibility_meta_count = 0
    for node in nodes:
        tag = node["tag"]
        name = node["attrs"].get("name")
        if tag == "uses-permission" and name:
            permissions.append(name)
        elif tag == "uses-permission-sdk-23" and name:
            permissions.append(name)
        elif tag == "permission" and name:
            declared_permissions.append(name)
        elif tag in ("service", "activity", "provider", "receiver"):
            details = component_facts(node)
            components.append(details)
            if tag == "service":
                services.append(details)
            elif tag == "activity":
                activities.append(details)
            elif tag == "provider":
                providers.append(details)
            else:
                receivers.append(details)
        elif tag == "action" and name:
            actions.append(name)
            if name == ACCESSIBILITY_ACTION:
                accessibility_action_count += 1
        elif tag == "meta-data" and name:
            meta_data.append(name)
            if name == ACCESSIBILITY_META:
                accessibility_meta_count += 1
    application = next((n for n in nodes if n["tag"] == "application"), None)
    uses_sdk = next((n for n in nodes if n["tag"] == "uses-sdk"), None)
    return {
        "package": manifest["attrs"].get("package"),
        "versionCode": manifest["attrs"].get("versionCode"),
        "versionName": manifest["attrs"].get("versionName"),
        "minSdk": uses_sdk["attrs"].get("minSdkVersion") if uses_sdk else None,
        "targetSdk": uses_sdk["attrs"].get("targetSdkVersion") if uses_sdk else None,
        "extractNativeLibs": application["attrs"].get("extractNativeLibs")
        if application
        else None,
        "permissions": sorted(set(permissions)),
        "declaredPermissions": sorted(set(declared_permissions)),
        "services": services,
        "activities": activities,
        "providers": providers,
        "receivers": receivers,
        "components": components,
        "actions": sorted(set(actions)),
        "metaData": sorted(set(meta_data)),
        "accessibilityActionCount": accessibility_action_count,
        "accessibilityMetaCount": accessibility_meta_count,
    }


def forbidden_permissions(facts):
    found = []
    for permission in facts["permissions"] + facts["declaredPermissions"]:
        if permission in FORBIDDEN_PERMISSIONS or any(
            pattern.search(permission) for pattern in FORBIDDEN_PERMISSION_PATTERNS
        ):
            found.append(permission)
    return sorted(set(found))


def _accessibility_occurrence_count(facts, count_key, list_key, name):
    """Return the parsed occurrence count, falling back to a manual facts set."""
    if facts.get(count_key) is not None:
        try:
            parsed = int(facts[count_key])
        except (TypeError, ValueError):
            parsed = 1
    else:
        parsed = 0
    # A manually built facts dict may only expose the name set; never let an
    # inconsistent zero count hide a declared accessibility name.
    return max(parsed, 1 if name in (facts.get(list_key) or []) else 0)


def _protected_service_problems(service, package):
    """Validate the exact reviewed G08 PhoneControl AccessibilityService."""
    problems = []
    name = service.get("name") or ""
    prefix = "protected AccessibilityService {}".format(name)
    if service.get("permission") != G08_FULL_ACCESSIBILITY_PERMISSION:
        problems.append(
            "{} must declare android:permission={} (found {!r})".format(
                prefix, G08_FULL_ACCESSIBILITY_PERMISSION, service.get("permission")
            )
        )
    if typed_boolean(service.get("exported")) is not True:
        problems.append(
            "{} must declare android:exported=true (found {!r})".format(
                prefix, service.get("exported")
            )
        )
    filters = service.get("intentFilters") or []
    if len(filters) != 1:
        problems.append(
            "{} must declare exactly one intent-filter (found {})".format(
                prefix, len(filters)
            )
        )
    else:
        intent_filter = filters[0]
        if intent_filter.get("actions") != [ACCESSIBILITY_ACTION]:
            problems.append(
                "{} intent-filter actions must be exactly ['{}'] (found {})".format(
                    prefix, ACCESSIBILITY_ACTION, intent_filter.get("actions")
                )
            )
        if intent_filter.get("categories"):
            problems.append(
                "{} intent-filter must not declare categories (found {})".format(
                    prefix, intent_filter.get("categories")
                )
            )
        if intent_filter.get("dataCount"):
            problems.append(
                "{} intent-filter must not declare data elements (found {})".format(
                    prefix, intent_filter.get("dataCount")
                )
            )
        if intent_filter.get("otherChildren"):
            problems.append(
                "{} intent-filter has unexpected child elements: {}".format(
                    prefix, intent_filter.get("otherChildren")
                )
            )
    meta_data = service.get("metaData") or []
    if len(meta_data) != 1:
        problems.append(
            "{} must declare exactly one meta-data (found {})".format(
                prefix, len(meta_data)
            )
        )
    else:
        meta = meta_data[0]
        if meta.get("name") != ACCESSIBILITY_META:
            problems.append(
                "{} meta-data name must be exactly {} (found {!r})".format(
                    prefix, ACCESSIBILITY_META, meta.get("name")
                )
            )
        resource = meta.get("resource")
        if (
            not isinstance(resource, str)
            or not resource.startswith("@")
            or resource in ("@null", "@empty")
        ):
            problems.append(
                "{} meta-data must declare a non-null android:resource reference "
                "(found {!r})".format(prefix, resource)
            )
    expected_children = ["intent-filter", "meta-data"]
    if sorted(service.get("childTags") or []) != sorted(expected_children):
        problems.append(
            "{} must declare exactly one intent-filter and one meta-data; "
            "child elements: {}".format(prefix, service.get("childTags") or [])
        )
    return problems


def _protected_provider_problems(provider, package):
    """Validate the exact reviewed G08 Floe system provider."""
    problems = []
    name = provider.get("name") or ""
    prefix = "protected provider {}".format(name)
    if provider.get("permission") != G08_FULL_PROVIDER_PERMISSION:
        problems.append(
            "{} must declare android:permission={} (found {!r})".format(
                prefix, G08_FULL_PROVIDER_PERMISSION, provider.get("permission")
            )
        )
    if typed_boolean(provider.get("exported")) is not True:
        problems.append(
            "{} must declare android:exported=true (found {!r})".format(
                prefix, provider.get("exported")
            )
        )
    if typed_boolean(provider.get("multiprocess")) is not False:
        problems.append(
            "{} must explicitly declare android:multiprocess=false "
            "(found {!r})".format(prefix, provider.get("multiprocess"))
        )
    expected_authority = "{}{}".format(package, G08_FULL_PROVIDER_AUTHORITY_SUFFIX)
    authorities = provider.get("authorities") or []
    if authorities != [expected_authority]:
        problems.append(
            "{} authorities must be exactly ['{}'] (found {})".format(
                prefix, expected_authority, authorities
            )
        )
    # Per-operation overrides can replace the protected provider permission.
    # The reviewed Full provider declares neither override; admit no looser
    # shape merely because android:permission itself still looks correct.
    for attribute in ("readPermission", "writePermission"):
        if provider.get(attribute) is not None:
            problems.append(
                "{} must not override android:{} (found {!r})".format(
                    prefix, attribute, provider.get(attribute)
                )
            )
    grant_uri_permissions = provider.get("grantUriPermissions")
    if typed_boolean(grant_uri_permissions) is True:
        problems.append(
            "{} must not grant URI permissions "
            "(android:grantUriPermissions={!r})".format(
                prefix, grant_uri_permissions
            )
        )
    elif grant_uri_permissions is not None and typed_boolean(grant_uri_permissions) is None:
        problems.append(
            "{} android:grantUriPermissions must be a literal boolean "
            "(found {!r})".format(prefix, grant_uri_permissions)
        )
    if provider.get("childTags"):
        problems.append(
            "{} must not declare child elements: {}".format(
                prefix, provider.get("childTags")
            )
        )
    return problems


def protected_components_problems(facts, profile="g08"):
    """Return the exact-shape problems for the current Full protected contract.

    The ``legacy`` profile preserves the pre-G08 strict Full boundary: these
    components are not required there, and ``forbidden_components`` never
    admits them. There is no implicit broad-allow profile.
    """
    if profile not in FULL_MANIFEST_PROFILES:
        raise CheckError("unknown Full manifest profile: {}".format(profile))
    if profile == "legacy":
        return []
    package = facts.get("package") or ""
    problems = list(channel_identity_problems("full", facts))
    services = [
        service
        for service in facts.get("services") or []
        if (service.get("name") or "") == G08_FULL_ACCESSIBILITY_SERVICE
    ]
    if len(services) != 1:
        problems.append(
            "G08 Full contract requires exactly one protected AccessibilityService "
            "{} (found {})".format(G08_FULL_ACCESSIBILITY_SERVICE, len(services))
        )
    else:
        problems.extend(_protected_service_problems(services[0], package))
    providers = [
        provider
        for provider in facts.get("providers") or []
        if (provider.get("name") or "") == G08_FULL_PROVIDER
    ]
    if len(providers) != 1:
        problems.append(
            "G08 Full contract requires exactly one protected provider {} "
            "(found {})".format(G08_FULL_PROVIDER, len(providers))
        )
    else:
        problems.extend(_protected_provider_problems(providers[0], package))
    return problems


def forbidden_components(facts, channel="play", full_profile="g08"):
    """Return every forbidden component/permission-definition problem.

    Play is always strict. Full admits only the two reviewed protected
    components when ``channel`` is ``full``, the merged manifest package is the
    exact full application ID, the ``g08`` profile is active and each component
    matches its complete reviewed shape. The exemption is per exact component,
    never a package-wide skip. Any extra accessibility action/meta-data
    occurrence (including on another unprotected service) keeps failing.
    """
    if channel not in CHANNEL_PACKAGES:
        raise CheckError("unknown application channel: {}".format(channel))
    if full_profile not in FULL_MANIFEST_PROFILES:
        raise CheckError("unknown Full manifest profile: {}".format(full_profile))
    problems = []
    package = facts.get("package") or ""
    exact_service_name = None
    exact_provider_name = None
    if (
        channel == "full"
        and full_profile == "g08"
        and package_channel(package) == "full"
    ):
        services = facts.get("services") or []
        candidates = [
            service
            for service in services
            if (service.get("name") or "") == G08_FULL_ACCESSIBILITY_SERVICE
        ]
        if len(candidates) == 1 and not _protected_service_problems(
            candidates[0], package
        ):
            exact_service_name = G08_FULL_ACCESSIBILITY_SERVICE
        providers = facts.get("providers") or []
        candidates = [
            provider
            for provider in providers
            if (provider.get("name") or "") == G08_FULL_PROVIDER
        ]
        if len(candidates) == 1 and not _protected_provider_problems(
            candidates[0], package
        ):
            exact_provider_name = G08_FULL_PROVIDER

    for service in facts.get("services") or []:
        name = service.get("name") or ""
        if name == exact_service_name:
            continue
        if FORBIDDEN_SERVICE_NAME.search(name):
            problems.append("forbidden service name: {}".format(name))
        permission = service.get("permission")
        if permission in FORBIDDEN_COMPONENT_PERMISSIONS:
            problems.append(
                "protected component permission {} on service {}".format(
                    permission, name
                )
            )

    reserved_authority = (
        package + G08_FULL_PROVIDER_AUTHORITY_SUFFIX if package else None
    )
    for provider in facts.get("providers") or []:
        name = provider.get("name") or ""
        if name == exact_provider_name:
            continue
        if FORBIDDEN_SERVICE_NAME.search(name):
            problems.append("forbidden platform component: {}".format(name))
        permission = provider.get("permission")
        if permission in FORBIDDEN_COMPONENT_PERMISSIONS:
            problems.append(
                "protected component permission {} on provider {}".format(
                    permission, name
                )
            )
        if reserved_authority and reserved_authority in (
            provider.get("authorities") or []
        ):
            problems.append(
                "authority {} is reserved for the exact Full provider; "
                "declared by {}".format(reserved_authority, name)
            )

    for kind, components in (
        ("activity", facts.get("activities") or []),
        ("receiver", facts.get("receivers") or []),
    ):
        for component in components:
            name = component.get("name") or ""
            if FORBIDDEN_SERVICE_NAME.search(name):
                problems.append("forbidden platform component: {}".format(name))
            permission = component.get("permission")
            if permission in FORBIDDEN_COMPONENT_PERMISSIONS:
                problems.append(
                    "protected component permission {} on {} {}".format(
                        permission, kind, name
                    )
                )

    allowed_accessibility_actions = 1 if exact_service_name else 0
    accessibility_actions = _accessibility_occurrence_count(
        facts, "accessibilityActionCount", "actions", ACCESSIBILITY_ACTION
    )
    if accessibility_actions != allowed_accessibility_actions:
        problems.append(
            "manifest declares {} {} occurrence(s); only the exact protected "
            "Full service may declare one".format(
                accessibility_actions, ACCESSIBILITY_ACTION
            )
        )
    allowed_accessibility_meta = 1 if exact_service_name else 0
    accessibility_meta = _accessibility_occurrence_count(
        facts, "accessibilityMetaCount", "metaData", ACCESSIBILITY_META
    )
    if accessibility_meta != allowed_accessibility_meta:
        problems.append(
            "manifest declares {} accessibilityservice meta-data occurrence(s); "
            "only the exact protected Full service may declare one".format(
                accessibility_meta
            )
        )
    return problems


def inspect_apk(path, aapt2, native_manifest):
    path = Path(path)
    if not path.is_file():
        raise CheckError("APK not found: {}".format(path))
    result = {
        "path": str(path),
        "sizeBytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }
    with zipfile.ZipFile(str(path), "r") as archive:
        names = archive.namelist()
        dex_names, classes = read_dex_classes(archive)
        native_names = sorted(
            name for name in names if name.startswith("lib/") and name.endswith(".so")
        )
        alignments = []
        native_hashes = {}
        for name in native_names:
            info = archive.getinfo(name)
            data = archive.read(name)
            native_hashes[name] = hashlib.sha256(data).hexdigest()
            machine, loads, needed = elf_metadata(data)
            alignments.append(
                {
                    "name": name,
                    "entry": name.rsplit("/", 1)[-1],
                    "compressionMethod": info.compress_type,
                    "zipDataOffset": zip_data_offset(archive, info),
                    "zipAlignment": PAGE_16K,
                    "zipAligned": zip_data_offset(archive, info) % PAGE_16K == 0,
                    "stored": info.compress_type == 0,
                    "elfMachine": machine,
                    "loadSegmentAlignments": [align for align, _ in loads],
                    "needed": needed,
                }
            )
    result.update(
        {
            "dexFiles": dex_names,
            "classCount": len(classes),
            "classes": classes,
            "nativeLibraryCount": len(native_names),
            "nativeLibraries": alignments,
            "nativeHashes": native_hashes,
        }
    )
    result["manifest"] = manifest_facts(aapt2, path)
    if native_manifest:
        for library, expected in native_manifest["libraries"].items():
            entry = "lib/arm64-v8a/" + library
            result.setdefault("nativeManifestMismatches", [])
            actual = native_hashes.get(entry)
            if actual is None:
                result["nativeManifestMismatches"].append(
                    {"library": library, "reason": "missing from APK"}
                )
            elif actual != expected:
                result["nativeManifestMismatches"].append(
                    {
                        "library": library,
                        "reason": "sha256 mismatch",
                        "expected": expected,
                        "actual": actual,
                    }
                )
    return result


def add_check(checks, identifier, ok, detail):
    checks.append({"id": identifier, "ok": bool(ok), "detail": detail})


# Exact packaging contract per application channel. Full executes the embedded
# starter from nativeLibraryDir, so PackageManager must extract its libraries;
# AGP then deflates the ZIP entries. Play loads mapped libraries directly from
# stored, 16 KiB-aligned ZIP entries. The values are channel identities, not
# interchangeable accepted alternatives.
CHANNEL_PACKAGING = {
    "full": {"extractNativeLibs": "true", "requireStored": False},
    "play": {"extractNativeLibs": "false", "requireStored": True},
}
STARTER_ENTRY = "lib/arm64-v8a/libfloe_starter.so"


def native_packaging_checks(variant, native_libraries, extract_native_libs):
    """Return the exact extraction/ZIP/ELF checks for one app channel.

    Full: extraction must be enabled and deflated entries are expected; any
    entry that is still stored must be 16 KiB zip-aligned, every ELF PT_LOAD
    segment must remain 16 KiB-aligned, and the extracted starter must be
    packaged. Play: extraction must be disabled, and every native entry must
    be stored and 16 KiB zip-aligned for direct mmap. ELF alignment is never
    waived.
    """
    policy = CHANNEL_PACKAGING[variant]
    checks = []
    if policy["requireStored"]:
        bad_zip = [
            item["entry"]
            for item in native_libraries
            if not item["stored"] or not item["zipAligned"]
        ]
        detail = "all {} native libraries stored and 16 KiB-aligned".format(
            len(native_libraries)
        )
    else:
        bad_zip = [
            item["entry"]
            for item in native_libraries
            if item["stored"] and not item["zipAligned"]
        ]
        stored_count = sum(1 for item in native_libraries if item["stored"])
        detail = (
            "{} native libraries package-manager extracted; "
            "{} stored entries checked for 16 KiB alignment".format(
                len(native_libraries), stored_count
            )
        )
    add_check(
        checks,
        "{}.native.zip16k".format(variant),
        not bad_zip,
        detail
        if not bad_zip
        else "native ZIP storage/alignment violations: " + ", ".join(bad_zip),
    )
    bad_elf = [
        "{} (align {})".format(
            item["entry"], ",".join(hex(value) for value in item["loadSegmentAlignments"])
        )
        for item in native_libraries
        if item["elfMachine"] != ELF_EM_AARCH64
        or any(value < PAGE_16K for value in item["loadSegmentAlignments"])
    ]
    add_check(
        checks,
        "{}.native.elf16k".format(variant),
        not bad_elf,
        "all {} ELF PT_LOAD segments >= 16 KiB".format(
            sum(len(item["loadSegmentAlignments"]) for item in native_libraries)
        )
        if not bad_elf
        else "non-16 KiB ELF LOAD segments: " + "; ".join(bad_elf),
    )
    expected_extraction = policy["extractNativeLibs"] == "true"
    actual_extraction = typed_boolean(extract_native_libs)
    add_check(
        checks,
        "{}.native.extractNativeLibs{}".format(
            variant, "True" if expected_extraction else "False"
        ),
        actual_extraction is expected_extraction,
        "android:extractNativeLibs={} (expected {})".format(
            extract_native_libs, str(expected_extraction).lower()
        ),
    )
    if variant == "full":
        packaged = {item["name"] for item in native_libraries}
        add_check(
            checks,
            "full.native.extractedStarter",
            STARTER_ENTRY in packaged,
            "embedded starter {} is packaged for nativeLibraryDir".format(
                STARTER_ENTRY
            )
            if STARTER_ENTRY in packaged
            else "{} is missing; extraction=true cannot make the starter run".format(
                STARTER_ENTRY
            ),
        )
    return checks


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only full/play APK distribution-boundary checker"
    )
    parser.add_argument("full", help="full distribution debug APK")
    parser.add_argument("play", help="play distribution debug APK")
    parser.add_argument("--aapt2", help="aapt2 executable")
    parser.add_argument(
        "--native-manifest",
        help="native-manifest.json recording packaged library hashes",
    )
    parser.add_argument(
        "--full-manifest-profile",
        choices=FULL_MANIFEST_PROFILES,
        default="g08",
        help="Full protected-component contract (default: g08; legacy keeps the "
        "pre-G08 strict Full boundary and admits neither protected component)",
    )
    parser.add_argument("--compact", action="store_true", help="single-line JSON")
    parser.add_argument(
        "--apksigner",
        help="apksigner executable (only used by the opt-in signing checks)",
    )
    parser.add_argument(
        "--test-apk",
        action="append",
        default=[],
        metavar="PATH",
        help="extra (androidTest) APK included in signing continuity checks only",
    )
    parser.add_argument(
        "--require-identical-signer",
        action="store_true",
        help="fail unless every listed APK shares one signer certificate digest",
    )
    parser.add_argument(
        "--expect-cert-sha256",
        metavar="HEX",
        help="require the shared signer digest to equal this pinned value",
    )
    args = parser.parse_args(argv)

    checks = []
    signing_requested = bool(args.require_identical_signer or args.expect_cert_sha256)
    limitations = [
        "Static inspection only: it does not install, launch or run instrumented "
        "tests, so runtime class loading and JNI execution remain device gates.",
        "ELF PT_LOAD p_align and applicable 16 KiB zip alignment demonstrate "
        "packaging, not execution on a 16 KiB-page kernel/device.",
        "aapt2's merged manifest is inspected; runtime permission state, component "
        "enablement and behaviour are not evaluated.",
        "The Full protected-component contract is a static manifest-shape check. "
        "Binder caller UID/signature/nonce verification and actual provider "
        "authority remain runtime/device gates and are not proven here.",
        "Full protected components are admitted only under the explicit g08 profile "
        "with the exact full application ID; the legacy Full profile rejects them.",
        "Dependency lockfiles and verification metadata are Gradle inputs and are "
        "not derivable from the APK; they are checked by the Gradle build, not here.",
        (
            "Signing checks here cover only V2/V3 signer certificate SHA-256 "
            "digests read via apksigner; installability, key rotation and Play/"
            "App Store policy acceptance remain outside this check."
            if signing_requested
            else "APK signatures, installability and Play/App Store policy "
            "acceptance are outside this check."
        ),
        "Native hash comparison requires the repository native manifest; when it is "
        "absent the check is reported as a limitation.",
    ]
    try:
        aapt2 = find_aapt2(args.aapt2)
        manifest_path = args.native_manifest
        if manifest_path is None:
            candidate = (
                Path(__file__).resolve().parents[1]
                / "core/swiftbridge/src/main/jniLibs/native-manifest.json"
            )
            if candidate.is_file():
                manifest_path = str(candidate)
        native_manifest = None
        if manifest_path:
            native_manifest = json.loads(Path(manifest_path).read_text())
            native_manifest["_path"] = manifest_path
        else:
            limitations.append(
                "native-manifest.json was not found; packaged Swift/JNI hashes were "
                "not compared with the recorded build output."
            )

        full = inspect_apk(args.full, aapt2, native_manifest)
        play = inspect_apk(args.play, aapt2, native_manifest)
    except (CheckError, OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        report = {
            "ok": False,
            "checker": "FloeAndroid G01 APK boundary checker",
            "error": str(exc),
            "limitations": limitations,
        }
        print(json.dumps(report, indent=None if args.compact else 2))
        return 1

    full_classes = full["classes"]
    play_classes = play["classes"]
    full_manifest = full["manifest"]
    play_manifest = play["manifest"]

    add_check(
        checks,
        "full.markers.present",
        all(marker in full_classes for marker in FULL_ONLY_MARKERS),
        "full marker classes present: "
        + ", ".join(
            marker for marker in FULL_ONLY_MARKERS if marker in full_classes
        ),
    )
    full_only_in_full = sorted(
        name for name in full_classes if name.startswith(FULL_ONLY_PACKAGES)
    )
    add_check(
        checks,
        "full.nonvacuous",
        len(full_only_in_full) >= len(FULL_ONLY_MARKERS),
        "full-only package classes in full: {}".format(
            ", ".join(full_only_in_full) if full_only_in_full else "none"
        ),
    )
    play_full_only = sorted(
        name for name in play_classes if name.startswith(FULL_ONLY_PACKAGES)
    )
    add_check(
        checks,
        "play.fullOnlyClasses.absent",
        not play_full_only,
        "full-only package classes in play: "
        + (", ".join(play_full_only) if play_full_only else "none"),
    )
    difference = sorted(full_classes - play_classes)
    add_check(
        checks,
        "play.markers.absent",
        not any(marker in play_classes for marker in FULL_ONLY_MARKERS),
        "full-only markers absent from play; {} full-only class(es) removed".format(
            len(difference)
        ),
    )

    full_native_names = {item["name"] for item in full["nativeLibraries"]}
    play_native_names = {item["name"] for item in play["nativeLibraries"]}
    for variant, data, native_names in (
        ("full", full, full_native_names),
        ("play", play, play_native_names),
    ):
        missing = [name for name in REQUIRED_NATIVE if name not in native_names]
        add_check(
            checks,
            "{}.swiftJni.present".format(variant),
            not missing,
            "required Swift/JNI libraries "
            + ("missing: " + ", ".join(missing) if missing else "present"),
        )
        foreign_abi = sorted(
            name
            for name in native_names
            if not name.startswith("lib/arm64-v8a/")
        )
        add_check(
            checks,
            "{}.abi.arm64Only".format(variant),
            not foreign_abi,
            "native ABIs: arm64-v8a only"
            if not foreign_abi
            else "unexpected native ABI paths: " + ", ".join(foreign_abi),
        )
        checks.extend(
            native_packaging_checks(
                variant,
                data["nativeLibraries"],
                data["manifest"]["extractNativeLibs"],
            )
        )
        packaged_entries = {item["entry"] for item in data["nativeLibraries"]}
        needed_entries = [
            (item["entry"], needed)
            for item in data["nativeLibraries"]
            for needed in item["needed"]
        ]
        basename_problems = [
            "{} -> {}".format(owner, needed)
            for owner, needed in needed_entries
            if "/" in needed
        ]
        add_check(
            checks,
            "{}.native.dtNeededBasenames".format(variant),
            not basename_problems,
            "all {} DT_NEEDED entries are basenames".format(len(needed_entries))
            if not basename_problems
            else "path-qualified DT_NEEDED: " + "; ".join(basename_problems),
        )
        unresolved = []
        for owner, needed in needed_entries:
            if "/" in needed:
                unresolved.append("{} -> {} (path-qualified)".format(owner, needed))
            elif needed in packaged_entries or needed in ANDROID_PUBLIC_LIBRARIES:
                continue
            else:
                unresolved.append("{} -> {} (not packaged or public)".format(owner, needed))
        add_check(
            checks,
            "{}.native.dtNeededResolved".format(variant),
            not unresolved,
            "all {} DT_NEEDED entries resolve to packaged arm64 libs or public "
            "Android system libs".format(len(needed_entries))
            if not unresolved
            else "; ".join(unresolved),
        )
        if native_manifest:
            mismatches = data.get("nativeManifestMismatches", [])
            add_check(
                checks,
                "{}.native.hashes".format(variant),
                not mismatches,
                "all {} recorded native library hashes match".format(
                    len(native_manifest["libraries"])
                )
                if not mismatches
                else "native manifest mismatches: "
                + json.dumps(mismatches, sort_keys=True),
            )
        forbidden_permission = forbidden_permissions(data["manifest"])
        add_check(
            checks,
            "{}.manifest.forbiddenPermissions".format(variant),
            not forbidden_permission,
            "no accessibility/root/elevated permissions"
            if not forbidden_permission
            else "forbidden permissions: " + ", ".join(forbidden_permission),
        )
        component_problems = forbidden_components(
            data["manifest"], variant, args.full_manifest_profile
        )
        add_check(
            checks,
            "{}.manifest.forbiddenComponents".format(variant),
            not component_problems,
            "no forbidden accessibility/root/Shizuku components; services "
            "declared: {}".format(len(data["manifest"]["services"]))
            if not component_problems
            else "; ".join(component_problems),
        )
        if variant == "full" and args.full_manifest_profile == "g08":
            protected_problems = protected_components_problems(data["manifest"])
            add_check(
                checks,
                "full.manifest.protectedComponents",
                not protected_problems,
                "exact reviewed G08 protected components present: {} and {}".format(
                    G08_FULL_ACCESSIBILITY_SERVICE, G08_FULL_PROVIDER
                )
                if not protected_problems
                else "; ".join(protected_problems),
            )
        package = data["manifest"]["package"] or ""
        add_check(
            checks,
            "{}.package.present".format(variant),
            bool(package),
            "package={} versionCode={} versionName={}".format(
                package,
                data["manifest"]["versionCode"],
                data["manifest"]["versionName"],
            ),
        )
        identity_problems = channel_identity_problems(
            variant, data["manifest"]
        )
        add_check(
            checks,
            "{}.package.channelIdentity".format(variant),
            not identity_problems,
            "package={} matches the {} flavor identity".format(package, variant)
            if not identity_problems
            else "; ".join(identity_problems),
        )

    add_check(
        checks,
        "variants.package.distinct",
        full_manifest["package"] != play_manifest["package"]
        and bool(full_manifest["package"])
        and bool(play_manifest["package"]),
        "full={} play={}".format(
            full_manifest["package"], play_manifest["package"]
        ),
    )
    add_check(
        checks,
        "variants.version.aligned",
        full_manifest["versionCode"] == play_manifest["versionCode"]
        and full_manifest["versionName"] == play_manifest["versionName"],
        "versionCode={} versionName={}".format(
            full_manifest["versionCode"], full_manifest["versionName"]
        ),
    )

    signing_report = None
    if signing_requested:
        try:
            apksigner = find_build_tools_binary(
                "apksigner", args.apksigner, "--apksigner"
            )
            expected = None
            if args.expect_cert_sha256:
                expected = args.expect_cert_sha256.lower()
                if not re.fullmatch(r"[0-9a-f]{64}", expected):
                    raise CheckError("--expect-cert-sha256 must be 64 hex digits")
            digests = {}
            for apk in [args.full, args.play] + list(args.test_apk):
                digests[str(apk)] = signer_certificate_digests(apksigner, apk)
            single = {tuple(digest) for digest in digests.values()}
            add_check(
                checks,
                "signing.identical",
                len(digests) >= 2 and len(single) == 1,
                "signer certificate digests: "
                + json.dumps(digests, sort_keys=True),
            )
            if expected is not None:
                mismatched = sorted(
                    name
                    for name, digest in digests.items()
                    if list(digest) != [expected]
                )
                add_check(
                    checks,
                    "signing.expected",
                    not mismatched,
                    "all {} APKs share the pinned signer certificate digest {}".format(
                        len(digests), expected
                    )
                    if not mismatched
                    else "APKs not signed with the pinned digest: "
                    + ", ".join(mismatched),
                )
            signing_report = {
                "apksigner": apksigner,
                "expectedCertSha256": expected,
                "digests": digests,
            }
        except CheckError as exc:
            add_check(checks, "signing.digests", False, str(exc))

    failures = [check for check in checks if not check["ok"]]
    report = {
        "ok": not failures,
        "checker": "FloeAndroid G01 APK boundary checker",
        "aapt2": aapt2,
        "fullManifestProfile": args.full_manifest_profile,
        "nativeManifest": manifest_path,
        "signing": signing_report,
        "full": {
            "path": full["path"],
            "sizeBytes": full["sizeBytes"],
            "sha256": full["sha256"],
            "dexFiles": full["dexFiles"],
            "classCount": full["classCount"],
            "fullOnlyPackageClasses": full_only_in_full,
            "manifest": full_manifest,
            "nativeLibraries": full["nativeLibraries"],
        },
        "play": {
            "path": play["path"],
            "sizeBytes": play["sizeBytes"],
            "sha256": play["sha256"],
            "dexFiles": play["dexFiles"],
            "classCount": play["classCount"],
            "fullOnlyPackageClasses": play_full_only,
            "manifest": play_manifest,
            "nativeLibraries": play["nativeLibraries"],
        },
        "fullOnlyClassDifferenceCount": len(difference),
        "checks": checks,
        "failures": failures,
        "limitations": limitations,
    }
    print(json.dumps(report, indent=None if args.compact else 2, sort_keys=False))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

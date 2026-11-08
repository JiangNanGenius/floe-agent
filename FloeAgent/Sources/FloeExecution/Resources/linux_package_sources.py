# SPDX-License-Identifier: MPL-2.0
"""Floe-owned Debian source selection. Never installs/updates packages.

APT's documented Dir::Etc override keeps original/custom source files intact.
Only explicit selection creates an override; removing it restores the system.
See https://manpages.debian.org/trixie/apt/apt.conf.5.en.html and apt-config(8).
The App and clean-image recipe supply the same reviewed catalog.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile

PROFILE_DIR = "etc/floe/package-sources"
EMPTY_DIR = PROFILE_DIR + "/empty.d"
CONF = "etc/apt/apt.conf.d/99zz-floe-package-sources"
CONF_MARKER = "// Floe package source selection v1\n"
SOURCE_MARKER = "# Floe Debian source preset v1\n"
CATALOG_FILE = "usr/share/floe/package-sources.json"
KEYRING = "/usr/share/keyrings/debian-archive-keyring.gpg"


class SourceError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def validate_catalog(value):
    if (value.get("schemaVersion") != 1 or value.get("distribution") != "debian"
            or value.get("suite") != "trixie"):
        raise SourceError("invalidCatalog")
    apt = value.get("apt", [])
    python = value.get("python", [])
    if len(apt) != 2 or {p.get("id") for p in apt} != {"official", "tuna"}:
        raise SourceError("invalidCatalog")
    if len(python) != 2 or {p.get("id") for p in python} != {"official", "tuna"}:
        raise SourceError("invalidCatalog")
    from urllib.parse import urlsplit
    def https(text):
        parts = urlsplit(text)
        return (parts.scheme == "https" and parts.hostname and not parts.username
                and not parts.password and not parts.query and not parts.fragment
                and not any(c.isspace() for c in text))
    for preset in apt:
        if (not https(preset["uri"]) or preset.get("suites") != ["trixie", "trixie-updates"]
                or preset.get("components") != ["main"]
                or preset.get("securityURI") != "https://security.debian.org/debian-security"
                or preset.get("securitySuite") != "trixie-security"
                or preset.get("signedBy") != KEYRING):
            raise SourceError("invalidCatalog")
    for preset in python:
        if not https(preset["indexURL"]) or not preset["indexURL"].endswith("/simple/"):
            raise SourceError("invalidCatalog")
    return value


def path(root, relative):
    root = Path(root).resolve(strict=True)
    target = root
    for component in Path(relative).parts:
        if component in ("", ".", "..") or component.startswith("/"):
            raise SourceError("unsafePath")
        target = target / component
        if target.is_symlink():
            raise SourceError("unsafePath")
        if target.exists() and target.is_file() and target.stat().st_nlink != 1:
            raise SourceError("unsafePath")
    return target


def read_file(root, relative):
    target = path(root, relative)
    if not target.exists():
        return None
    info = target.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 32 * 1024:
        raise SourceError("configurationChanged")
    return target.read_bytes()


def atomic_write(root, relative, data):
    target = path(root, relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    # Recheck newly created parents before creating a same-directory stage.
    target = path(root, relative)
    fd, temporary = tempfile.mkstemp(prefix=".floe-source-", dir=target.parent)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        path(root, relative)
        os.replace(temporary, target)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def source_text(preset):
    return (SOURCE_MARKER + "Types: deb\nURIs: " + preset["uri"]
            + "\nSuites: " + " ".join(preset["suites"])
            + "\nComponents: " + " ".join(preset["components"])
            + "\nSigned-By: " + KEYRING
            + "\n\nTypes: deb\nURIs: " + preset["securityURI"]
            + "\nSuites: " + preset["securitySuite"]
            + "\nComponents: " + " ".join(preset["components"])
            + "\nSigned-By: " + KEYRING + "\n").encode()


def require_debian_keyring(root):
    # Debian archive-keyring 2025.1 uses this exact read-only .gpg alias.
    # It is not a write destination: keep the alias and its target intact.
    # Every Floe config/profile write continues through strict path().
    directory = path(root, "usr/share/keyrings")
    keyring = directory / "debian-archive-keyring.gpg"
    if keyring.is_symlink():
        if os.readlink(keyring) != "debian-archive-keyring.pgp":
            raise SourceError("unsafePath")
        keyring = path(root, "usr/share/keyrings/debian-archive-keyring.pgp")
    else:
        keyring = path(root, KEYRING.lstrip("/"))
    if not keyring.is_file() or not 0 < keyring.stat().st_size <= 4 * 1024 * 1024:
        raise SourceError("missingKeyring")


def conf_text(preset_id):
    return (CONF_MARKER + 'Dir::Etc::sourcelist "/' + PROFILE_DIR + "/" + preset_id + '.sources";\n'
            + 'Dir::Etc::sourceparts "/' + EMPTY_DIR + '";\n').encode()


def existing_selection(root, catalog):
    contents = read_file(root, CONF)
    if contents is None:
        return "system"
    for preset in catalog["apt"]:
        if contents == conf_text(preset["id"]):
            return preset["id"]
    # Never overwrite or remove a user's modified fragment on their behalf.
    raise SourceError("configurationChanged")


def apt_probe():
    arguments = ["/usr/bin/apt-config", "shell",
                 "FLOE_LIST", "Dir::Etc::sourcelist/f",
                 "FLOE_PARTS", "Dir::Etc::sourceparts/d"]
    for binary in ("apt", "apt-get", "apt-cache"):
        for key in ("sourcelist", "sourceparts"):
            arguments += ["FLOE_OVERRIDE_" + binary.replace("-", "_") + "_" + key,
                          "Binary::" + binary + "::Dir::Etc::" + key]
    # Query fixed metadata only. Do not dump APT config/authentication data,
    # eval shell text, run apt-get, or take a dpkg/install lock.
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=5, check=False)
    if result.returncode != 0 or len(result.stdout) > 32 * 1024:
        raise SourceError("verificationFailed")
    values = {}
    for token in shlex.split(result.stdout.decode("utf-8", errors="strict")):
        key, separator, value = token.partition("=")
        if not separator or not key.startswith("FLOE_") or key in values:
            raise SourceError("verificationFailed")
        values[key] = value
    if not values.get("FLOE_LIST") or not values.get("FLOE_PARTS"):
        raise SourceError("verificationFailed")
    custom = any(value for key, value in values.items() if key.startswith("FLOE_OVERRIDE_"))
    # APT also admits explicitly configured volatile source files. Query
    # this one subtree, never a full/auth configuration dump. Preserve such
    # user configuration and refuse to misreport an exclusive preset.
    extra = subprocess.run(["/usr/bin/apt-config", "--format", "%v%n", "dump", "APT::Sources::With"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=False)
    if extra.returncode != 0 or len(extra.stdout) > 8192:
        raise SourceError("verificationFailed")
    custom = custom or bool(extra.stdout.strip())
    return values["FLOE_LIST"], values["FLOE_PARTS"], custom


def inspect(root, catalog, probe=apt_probe):
    validate_catalog(catalog)
    selected = existing_selection(root, catalog)
    source_list, source_parts, custom_override = probe()
    uri = None
    if selected != "system":
        if custom_override:
            raise SourceError("customOverride")
        preset = next(p for p in catalog["apt"] if p["id"] == selected)
        if (source_list != "/" + PROFILE_DIR + "/" + selected + ".sources"
                or source_parts.rstrip("/") != "/" + EMPTY_DIR
                or read_file(root, PROFILE_DIR + "/" + selected + ".sources") != source_text(preset)):
            raise SourceError("verificationFailed")
        empty = path(root, EMPTY_DIR)
        if not empty.is_dir() or any(empty.iterdir()):
            raise SourceError("configurationChanged")
        uri = preset["uri"]
    return {"selection": selected, "sourceList": source_list,
            "sourceParts": source_parts, "uri": uri, "verified": True}


def seed_profiles(root, catalog):
    validate_catalog(catalog)
    require_debian_keyring(root)
    empty = path(root, EMPTY_DIR)
    empty.mkdir(parents=True, exist_ok=True)
    if any(empty.iterdir()):
        raise SourceError("configurationChanged")
    for preset in catalog["apt"]:
        relative = PROFILE_DIR + "/" + preset["id"] + ".sources"
        expected = source_text(preset)
        previous = read_file(root, relative)
        if previous is not None and previous != expected:
            raise SourceError("configurationChanged")
        if previous is None:
            atomic_write(root, relative, expected)


def select(root, catalog, selection, probe=apt_probe, check_cancelled=lambda: None):
    validate_catalog(catalog)
    if selection not in {"system"} | {p["id"] for p in catalog["apt"]}:
        raise SourceError("unknownPreset")
    existing_selection(root, catalog)
    previous = read_file(root, CONF)
    check_cancelled()
    if selection != "system":
        seed_profiles(root, catalog)
    check_cancelled()
    committed = False
    try:
        if selection == "system":
            if previous is not None:
                committed = True
                path(root, CONF).unlink()
        else:
            wanted = conf_text(selection)
            if previous != wanted:
                committed = True
                atomic_write(root, CONF, wanted)
        state = inspect(root, catalog, probe)
        check_cancelled()
        return state
    except BaseException:
        # Cancellation/verification failures roll back our single commit
        # fragment only. User sources and the system's previous bytes stay.
        if committed:
            if previous is None:
                path(root, CONF).unlink(missing_ok=True)
            else:
                atomic_write(root, CONF, previous)
        raise


def prepare_image(root, catalog, check=False):
    root = Path(root).resolve(strict=True)
    if root == Path("/"):
        raise SourceError("unsafeImageRoot")
    validate_catalog(catalog)
    release_path = root / "etc/os-release"
    if release_path.is_symlink():
        link = Path(os.readlink(release_path))
        release_path = root / str(link).lstrip("/") if link.is_absolute() else release_path.parent / link
    release_path = release_path.resolve(strict=True)
    if not release_path.is_relative_to(root) or not release_path.is_file() or release_path.stat().st_size > 8192:
        raise SourceError("unsupportedImage")
    release = {}
    for line in release_path.read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key in ("ID", "VERSION_CODENAME"):
            words = shlex.split(value)
            release[key] = words[0] if len(words) == 1 else ""
    if release != {"ID": "debian", "VERSION_CODENAME": "trixie"}:
        raise SourceError("unsupportedImage")
    encoded = (json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode()
    if check:
        require_debian_keyring(root)
        if read_file(root, CATALOG_FILE) != encoded or read_file(root, CONF) != conf_text("official"):
            raise SourceError("imageNotPrepared")
        for preset in catalog["apt"]:
            if read_file(root, PROFILE_DIR + "/" + preset["id"] + ".sources") != source_text(preset):
                raise SourceError("imageNotPrepared")
        if any(path(root, EMPTY_DIR).iterdir()):
            raise SourceError("configurationChanged")
        return
    # Clean image preparation deliberately chooses the official profile.
    # It never edits inherited/custom sources; the controlled APT path makes
    # this selection effective, and removing our fragment restores them.
    existing_selection(root, catalog)
    previous_catalog = read_file(root, CATALOG_FILE)
    if previous_catalog is not None and previous_catalog != encoded:
        raise SourceError("configurationChanged")
    seed_profiles(root, catalog)
    if previous_catalog is None:
        atomic_write(root, CATALOG_FILE, encoded)
    atomic_write(root, CONF, conf_text("official"))


def main():
    def cancelled(signum, frame):
        raise SourceError("cancelled")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    try:
        encoded = sys.stdin.buffer.read(32 * 1024 + 1)
        if len(encoded) > 32 * 1024:
            raise SourceError("invalidCatalog")
        request = json.loads(encoded)
        catalog = validate_catalog(request["catalog"])
        if request.get("operation") == "inspect":
            state = inspect(Path("/"), catalog)
        elif request.get("operation") == "select":
            state = select(Path("/"), catalog, request["selection"])
        else:
            raise SourceError("unknownOperation")
        print(json.dumps(state, ensure_ascii=False))
    except SourceError as error:
        print(json.dumps({"error": error.code}))
        return 130 if error.code == "cancelled" else 1
    except Exception:
        # No paths, APT auth config, subprocess output or credentials leak.
        print(json.dumps({"error": "configurationUnavailable"}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

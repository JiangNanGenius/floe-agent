# SPDX-License-Identifier: MPL-2.0
"""Floe-owned Debian source selection. Never installs/updates packages.

APT keeps its normal sources.list and sources.list.d paths. Presets only
manage a recognized Debian file and keep a byte-exact restoration record.
Other repositories and ordinary CLI source editing remain effective.
See https://manpages.debian.org/trixie/apt/apt.conf.5.en.html and apt-config(8).
The App and clean-image recipe supply the same reviewed catalog.
"""
import base64
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
MANAGED_SOURCE = "etc/apt/sources.list.d/debian.sources"
STATE = PROFILE_DIR + "/source-original-v2.json"
NORMAL_LIST = "/etc/apt/sources.list"
NORMAL_PARTS = "/etc/apt/sources.list.d"


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
        os.fchmod(fd, stat.S_IMODE(target.stat().st_mode) if target.is_file() else 0o644)
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


def recognized_debian_source(contents):
    # Only a whole, simple Debian distribution file can be managed by this
    # convenience UI. Unknown/mixed user content remains exclusively theirs.
    # This does not restrict ordinary exec.shell edits or additional repos.
    if contents is None:
        return True
    if len(contents) > 16 * 1024:
        return False
    try:
        paragraphs = []
        fields = {}
        for line in contents.decode("utf-8").splitlines() + [""]:
            if line.lstrip().startswith("#"):
                continue
            if not line.strip():
                if fields:
                    paragraphs.append(fields)
                    fields = {}
                continue
            if line[0].isspace():
                return False
            key, separator, value = line.partition(":")
            key = key.lower()
            if (not separator or key in fields or key not in
                    {"types", "uris", "suites", "components", "signed-by"}):
                return False
            fields[key] = " ".join(value.split())
        if len(paragraphs) != 2:
            return False
        main = [p for p in paragraphs if set(p.get("suites", "").split()) == {"trixie", "trixie-updates"}]
        security = [p for p in paragraphs if p.get("suites") == "trixie-security"]
        if len(main) != 1 or len(security) != 1:
            return False
        allowed_keys = {"types", "uris", "suites", "components", "signed-by"}
        for p in paragraphs:
            if (set(p) != allowed_keys or p["types"] != "deb" or p["components"] != "main"
                    or p["signed-by"] not in {KEYRING, "/usr/share/keyrings/debian-archive-keyring.pgp"}):
                return False
        return (main[0]["uris"] in {"https://deb.debian.org/debian", "http://deb.debian.org/debian",
                                    "https://mirrors.tuna.tsinghua.edu.cn/debian"}
                and security[0]["uris"] in {"https://security.debian.org/debian-security",
                                             "http://security.debian.org/debian-security",
                                             "https://deb.debian.org/debian-security",
                                             "http://deb.debian.org/debian-security"})
    except (ValueError, UnicodeError):
        return False


def legacy_selection(root, catalog):
    contents = read_file(root, CONF)
    if contents is None:
        return None
    for preset in catalog["apt"]:
        if contents == conf_text(preset["id"]):
            return preset["id"]
    raise SourceError("configurationChanged")


def original_record(root):
    contents = read_file(root, STATE)
    if contents is None:
        return None
    try:
        value = json.loads(contents)
        if set(value) != {"version", "managedFile", "original"} or value["version"] != 2 or value["managedFile"] != MANAGED_SOURCE:
            raise ValueError()
        original = None if value["original"] is None else base64.b64decode(value["original"], validate=True)
        if not recognized_debian_source(original):
            raise ValueError()
        return {"bytes": contents, "original": original}
    except (ValueError, TypeError, KeyError):
        raise SourceError("configurationChanged")


def managed_selection(root, catalog, record):
    if record is None:
        return "system"
    contents = read_file(root, MANAGED_SOURCE)
    for preset in catalog["apt"]:
        if contents == source_text(preset):
            return preset["id"]
    # A staged record before commit, an interrupted restore, or the user
    # manually restoring exact original bytes is safe to inspect/recover.
    if contents == record["original"]:
        return "system"
    raise SourceError("configurationChanged")


def apt_probe():
    arguments = ["/usr/bin/apt-config", "shell", "FLOE_LIST", "Dir::Etc::sourcelist/f",
                 "FLOE_PARTS", "Dir::Etc::sourceparts/d"]
    for binary in ("apt", "apt-get", "apt-cache"):
        for key in ("sourcelist", "sourceparts"):
            arguments += ["FLOE_OVERRIDE_" + binary.replace("-", "_") + "_" + key,
                          "Binary::" + binary + "::Dir::Etc::" + key]
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
    # Additional repositories (including APT::Sources::With) remain usable.
    # Only binary-specific path replacement can make this one managed file
    # inactive, so never report a managed selection as active in that case.
    custom = any(value and value.rstrip("/") != (NORMAL_LIST if key.endswith("_sourcelist") else NORMAL_PARTS)
                 for key, value in values.items() if key.startswith("FLOE_OVERRIDE_"))
    return values["FLOE_LIST"], values["FLOE_PARTS"], custom


def inspect(root, catalog, probe=apt_probe):
    validate_catalog(catalog)
    legacy = legacy_selection(root, catalog)
    record = original_record(root)
    selected = legacy if legacy is not None else managed_selection(root, catalog, record)
    source_list, source_parts, custom_override = probe()
    uri = None
    if selected != "system":
        if custom_override:
            raise SourceError("customOverride")
        preset = next(p for p in catalog["apt"] if p["id"] == selected)
        if legacy is not None:
            if (source_list != "/" + PROFILE_DIR + "/" + selected + ".sources"
                    or source_parts.rstrip("/") != "/" + EMPTY_DIR
                    or read_file(root, PROFILE_DIR + "/" + selected + ".sources") != source_text(preset)):
                raise SourceError("verificationFailed")
        elif source_list != NORMAL_LIST or source_parts.rstrip("/") != NORMAL_PARTS:
            raise SourceError("verificationFailed")
        uri = preset["uri"]
    return {"selection": selected, "sourceList": source_list, "sourceParts": source_parts,
            "uri": uri, "verified": True, "legacyOverride": legacy is not None}


def seed_profiles(root, catalog):
    validate_catalog(catalog)
    require_debian_keyring(root)
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
    legacy_selection(root, catalog)  # Never remove a user-modified fragment.
    record = original_record(root)
    managed_selection(root, catalog, record)
    previous = {name: read_file(root, name) for name in (STATE, MANAGED_SOURCE, CONF)}
    if selection != "system" and record is None and not recognized_debian_source(previous[MANAGED_SOURCE]):
        raise SourceError("configurationChanged")
    check_cancelled()
    if selection != "system":
        seed_profiles(root, catalog)
    check_cancelled()
    changed = []
    def commit(relative, contents):
        if read_file(root, relative) == contents:
            return
        # Mark BEFORE the atomic write: cancellation may arrive just after
        # os.replace succeeds. Roll back only these three fixed owned paths.
        changed.append(relative)
        if contents is None:
            path(root, relative).unlink()
        else:
            atomic_write(root, relative, contents)
    try:
        if selection == "system":
            if record is not None:
                commit(MANAGED_SOURCE, record["original"])
                commit(STATE, None)
        else:
            if record is None:
                original = previous[MANAGED_SOURCE]
                contents = {"version": 2, "managedFile": MANAGED_SOURCE,
                            "original": None if original is None else base64.b64encode(original).decode("ascii")}
                commit(STATE, (json.dumps(contents, sort_keys=True) + "\n").encode())
            preset = next(p for p in catalog["apt"] if p["id"] == selection)
            commit(MANAGED_SOURCE, source_text(preset))
        # This migration is only an explicit selection/new-image action.
        # Neither inspect nor opening/updating the App writes guest config.
        commit(CONF, None)
        state = inspect(root, catalog, probe)
        check_cancelled()
        return state
    except BaseException:
        for relative in reversed(changed):
            contents = previous[relative]
            if contents is None:
                target = path(root, relative)
                if target.exists():
                    target.unlink()
            else:
                atomic_write(root, relative, contents)
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
    pypi = {PROFILE_DIR + "/pypi-" + p["id"] + ".conf":
            ("[global]\nindex-url = " + p["indexURL"] + "\n").encode() for p in catalog["python"]}
    if check:
        require_debian_keyring(root)
        record = original_record(root)
        if (read_file(root, CATALOG_FILE) != encoded or legacy_selection(root, catalog) is not None
                or managed_selection(root, catalog, record) != "official"):
            raise SourceError("imageNotPrepared")
        for preset in catalog["apt"]:
            if read_file(root, PROFILE_DIR + "/" + preset["id"] + ".sources") != source_text(preset):
                raise SourceError("imageNotPrepared")
        if any(read_file(root, name) != data for name, data in pypi.items()):
            raise SourceError("imageNotPrepared")
        return
    previous_catalog = read_file(root, CATALOG_FILE)
    if previous_catalog is not None and previous_catalog != encoded:
        raise SourceError("configurationChanged")
    # Offline structure only: the later real guest probe verifies apt-config.
    # No host apt-config command is run against a disposable image root.
    select(root, catalog, "official", probe=lambda: (NORMAL_LIST, NORMAL_PARTS, False))
    if previous_catalog is None:
        atomic_write(root, CATALOG_FILE, encoded)
    for name, data in pypi.items():
        previous = read_file(root, name)
        if previous is not None and previous != data:
            raise SourceError("configurationChanged")
        if previous is None:
            atomic_write(root, name, data)


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
        print(json.dumps({"error": "configurationUnavailable"}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

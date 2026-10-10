#!/usr/bin/env python3
"""
bootstrap.py - deterministic, content-addressed installer for FloeCADKit's
pinned native OCCT static slices.

Why this exists
---------------
The two OCCT .a slices are ~149 MB / ~147 MB and exceed the ordinary Git
block-push limit, so they are not meant to be committed as Git blobs. Headers
and the xcframework Info.plist remain Git-tracked. This script fetches the
*exact* objects recorded in DEPENDENCIES.json from the pinned upstream Git-LFS
repository and installs them only after verifying size and SHA-256.

Safety guarantees
-----------------
* The Git-tracked working tree is never partially overwritten: every download
  lands in a temporary sibling file and is atomically renamed into place only
  after the full content verifies. A partial or wrong-hash download is deleted
  and the pre-existing file is left byte-for-byte untouched.
* An existing file whose size and SHA-256 already match the manifest is kept
  (no re-download, no rewrite).
* Deliberate local rebuild/replacement is an explicit opt-in
  (`FLOECAD_LOCAL_RELINK=1` or `--local-relink`): existing bytes that differ
  from the pin are then never overwritten and are reported as `LOCAL`. Without
  the opt-in (official path) a mismatching slice is repaired to the pinned
  bytes, with an explicit `replace` log line.
* installPath entries are confined to the package directory; absolute paths
  and ".." escapes are refused.
* `--check` is strictly read-only: it performs no network access and no
  writes, and exits non-zero if any artifact is absent or invalid. With
  `--local-relink` a present-but-unpinned slice is reported `LOCAL` (exit 0).
* All network calls use explicit connect/read timeouts and an overall deadline.
  The Git-LFS batch response is size-bounded. Redirects are followed only
  under the same URL policy: an HTTPS request never downgrades to plain HTTP.
* Remote error text is redacted (URL query strings and token-like parameters
  removed, length-capped) so short-lived pre-signed download URLs cannot leak
  into logs or exception messages.

Run `python3 bootstrap.py --help` for usage. Exit code 0 means every required
artifact is present (and verified, unless the local-relink opt-in is set).
Standard library only (Python 3.8+).
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ---- bounded-network defaults (override with env for tests / slow links) ----
CONNECT_TIMEOUT = float(os.environ.get("FLOECAD_CONNECT_TIMEOUT", "20"))  # seconds
READ_TIMEOUT = float(os.environ.get("FLOECAD_READ_TIMEOUT", "60"))        # seconds
DEADLINE = float(os.environ.get("FLOECAD_DEADLINE", "1800"))             # seconds total
MAX_RETRIES = int(os.environ.get("FLOECAD_MAX_RETRIES", "3"))
READ_CHUNK = 1024 * 1024  # 1 MiB

# The LFS batch response only carries oid/size/actions metadata; anything past
# this bound is a misbehaving or hostile endpoint and is refused unread.
MAX_BATCH_RESPONSE_BYTES = 4 * 1024 * 1024
# Remote error strings are capped and redacted before they reach logs.
MAX_ERROR_TEXT = 240

MANIFEST_NAME = "DEPENDENCIES.json"
SUPPORTED_SCHEMA_VERSION = 1
_REQUIRED_SOURCE_KIND = "git-lfs"
# Opt-in flag/env for a deliberate local rebuild/replacement of the slices.
ENV_LOCAL_RELINK = "FLOECAD_LOCAL_RELINK"
_TRUTHY = ("1", "true", "yes", "on")


class BootstrapError(Exception):
    """Base class for actionable bootstrap failures."""


class ManifestError(BootstrapError):
    pass


class PathEscapeError(BootstrapError):
    pass


class IntegrityError(BootstrapError):
    pass


class UnsupportedSourceError(BootstrapError):
    pass


class FetchError(BootstrapError):
    pass


# --------------------------------------------------------------------------- #
# Path safety
# --------------------------------------------------------------------------- #
def package_root() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def safe_install_path(root: str, rel_path: str) -> str:
    """Resolve rel_path under root, refusing absolute paths and '..' escapes."""
    if not rel_path or not rel_path.strip():
        raise PathEscapeError("empty installPath in manifest")
    if os.path.isabs(rel_path) or rel_path.startswith(("/", "\\")):
        raise PathEscapeError("absolute installPath is not allowed: %r" % rel_path)
    # Normalise without requiring existence, then confirm containment.
    root_abs = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root_abs, rel_path))
    try:
        common = os.path.commonpath([root_abs, candidate])
    except ValueError:
        raise PathEscapeError(
            "installPath is on a different drive/root than the package: %r"
            % rel_path
        )
    if common != root_abs:
        raise PathEscapeError(
            "installPath escapes the package directory: %r" % rel_path
        )
    return candidate


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #
def load_manifest(root: str) -> dict:
    path = os.path.join(root, MANIFEST_NAME)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        raise ManifestError("manifest not found: %s" % path)
    except json.JSONDecodeError as exc:
        raise ManifestError("manifest is not valid JSON (%s): %s" % (path, exc))
    validate_manifest(data)
    return data


def validate_manifest(data: dict) -> None:
    if not isinstance(data, dict):
        raise ManifestError("%s must contain a JSON object" % MANIFEST_NAME)
    raw_version = data.get("schemaVersion")
    if isinstance(raw_version, bool) or not isinstance(raw_version, int):
        raise ManifestError(
            "%s has missing or non-integer schemaVersion %r; this bootstrap "
            "supports schemaVersion %d"
            % (MANIFEST_NAME, raw_version, SUPPORTED_SCHEMA_VERSION)
        )
    # Exact match: a newer/unknown schema may change field semantics, so it is
    # refused rather than silently interpreted with this schema's rules.
    if raw_version != SUPPORTED_SCHEMA_VERSION:
        raise ManifestError(
            "unsupported schemaVersion %r in %s; this bootstrap supports "
            "schemaVersion %d"
            % (raw_version, MANIFEST_NAME, SUPPORTED_SCHEMA_VERSION)
        )
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ManifestError("manifest declares no artifacts")
    for art in artifacts:
        for key in ("installPath", "size", "sha256", "source"):
            if key not in art:
                raise ManifestError("artifact missing %r: %r" % (key, art.get("name")))
        if not isinstance(art["size"], int) or art["size"] < 0:
            raise ManifestError("artifact %r has invalid size" % art.get("name"))
        if not _is_hex(art["sha256"], 64):
            raise ManifestError("artifact %r has invalid sha256" % art.get("name"))
        src = art["source"]
        if src.get("kind") != _REQUIRED_SOURCE_KIND:
            raise UnsupportedSourceError(
                "artifact %r uses unsupported source kind %r (only %r is supported)"
                % (art.get("name"), src.get("kind"), _REQUIRED_SOURCE_KIND)
            )
        for key in ("sourceId", "oid", "upstreamPath"):
            if not src.get(key):
                raise ManifestError(
                    "artifact %r source missing %r" % (art.get("name"), key)
                )
        if not _is_hex(src["oid"], 64):
            raise ManifestError("artifact %r has invalid LFS oid" % art.get("name"))
        if src["oid"] != art["sha256"]:
            raise ManifestError(
                "artifact %r: LFS oid does not match sha256" % art.get("name")
            )


def _is_hex(value: object, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(c in "0123456789abcdef" for c in value.lower())
    )


def _is_safe_url(url: str) -> bool:
    """HTTPS from any host is allowed. Plain HTTP is allowed only for loopback,
    so the hermetic test bridge (and an on-prem LFS mirror on localhost) works
    without enabling cleartext downloads from remote hosts."""
    lower = url.lower()
    if lower.startswith("https://"):
        return True
    if lower.startswith("http://"):
        rest = lower[len("http://"):]
        host = rest.split("/", 1)[0].split(":", 1)[0]
        return host in ("127.0.0.1", "localhost", "::1", "[::1]")
    return False


# --------------------------------------------------------------------------- #
# Error-message redaction
# --------------------------------------------------------------------------- #
# LFS download hrefs are short-lived pre-signed URLs: their query strings carry
# bearer credentials. None of them may ever be written to stdout/stderr or into
# an exception that a caller might log. Remote error messages are also
# attacker-influenced text, so they are cleaned and length-capped before use.
_QUERY_URL_RE = re.compile(r"(https?://[^\s?#\"'<>]+)\?[^\s\"'<>]*")
_SECRET_PARAM_RE = re.compile(
    r"(?i)\b(access[_-]?token|auth|token|sig|signature|expires|policy|"
    r"key-pair-id|x-amz-[a-z0-9-]+)=([^\s&\"'<>]+)"
)


def redact(text: object, limit: int = MAX_ERROR_TEXT) -> str:
    """Return `text` safe for logs: URL queries and token-like parameters are
    replaced, and the result is capped at `limit` characters."""
    value = str(text)
    value = _QUERY_URL_RE.sub(r"\1?<redacted>", value)
    value = _SECRET_PARAM_RE.sub(r"\1=<redacted>", value)
    if len(value) > limit:
        value = value[:limit] + "...(truncated)"
    return value


def resolve_sources(manifest: dict) -> dict:
    sources = manifest.get("sources", {})
    if not isinstance(sources, dict):
        raise ManifestError("manifest 'sources' must be an object")
    return sources


# --------------------------------------------------------------------------- #
# Hashing / verification
# --------------------------------------------------------------------------- #
def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_matches(path: str, size: int, sha256: str) -> bool:
    try:
        if os.path.getsize(path) != size:
            return False
    except OSError:
        return False
    return sha256_file(path) == sha256.lower()


def artifact_status(root: str, art: dict, local_relink: bool = False) -> str:
    """Return one of: 'ok', 'missing', 'invalid' — or 'local' for a
    present-but-unpinned artifact when the local-relink opt-in is active."""
    dest = safe_install_path(root, art["installPath"])
    if not os.path.exists(dest):
        return "missing"
    if file_matches(dest, art["size"], art["sha256"]):
        return "ok"
    return "local" if local_relink else "invalid"


# --------------------------------------------------------------------------- #
# Git-LFS fetch: HTTP with a strict redirect policy
# --------------------------------------------------------------------------- #
class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow redirects only when the target satisfies the same URL policy.

    In particular an HTTPS request may never be redirected to plain HTTP (a
    transport downgrade), and no redirect may point at a scheme/host the
    initial policy would have refused.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        if (req.full_url.lower().startswith("https://")
                and not newurl.lower().startswith("https://")):
            raise FetchError(
                "refusing HTTPS-to-non-HTTPS redirect to %s" % redact(newurl)
            )
        if not _is_safe_url(newurl):
            raise FetchError("refusing redirect to unsafe URL %s" % redact(newurl))
        return redirected


_OPENER = urllib.request.build_opener(_SafeRedirectHandler())


def _urlopen(req, timeout):
    # urllib uses a single timeout for connect and each read; callers bound the
    # overall operation with the deadline as well. The opener enforces the
    # redirect policy above.
    return _OPENER.open(req, timeout=timeout)


def _read_bounded(resp, limit: int) -> bytes:
    """Read at most `limit` bytes from `resp`; raise if the body is larger."""
    chunks = []
    total = 0
    while True:
        chunk = resp.read(min(READ_CHUNK, limit + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise FetchError(
                "LFS batch response exceeds the %d-byte limit; refusing to "
                "read further" % limit
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _http_post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Accept": "application/vnd.git-lfs+json",
            "Content-Type": "application/vnd.git-lfs+json",
        },
    )
    with _urlopen(req, CONNECT_TIMEOUT) as resp:
        raw = _read_bounded(resp, MAX_BATCH_RESPONSE_BYTES)
    return json.loads(raw.decode("utf-8"))


def resolve_lfs_urls(source: dict, objects: list, deadline: float) -> dict:
    """Ask the pinned LFS batch endpoint for fresh download URLs.

    Returns {oid: href}. The returned URLs are short-lived pre-signed links and
    are deliberately never persisted; only endpoint + oid are durable pins.
    """
    endpoint = source.get("lfsBatchApi")
    if not endpoint:
        raise ManifestError("LFS source missing 'lfsBatchApi'")
    batch_objects = [{"oid": o["oid"], "size": o["size"]} for o in objects]
    payload = {
        "operation": "download",
        "transfers": [source.get("lfsTransfer", "basic")],
        "objects": batch_objects,
    }
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        _check_deadline(deadline)
        try:
            data = _http_post_json(endpoint, payload)
            break
        except (urllib.error.URLError, OSError, http.client.HTTPException,
                json.JSONDecodeError) as exc:
            last_exc = exc
            if attempt >= MAX_RETRIES or time.monotonic() >= deadline:
                raise FetchError(
                    "could not reach LFS batch endpoint %s after %d attempt(s): %s\n"
                    "Check network access. The libraries can also be obtained by "
                    "running the relink kit (see OCCT_RELINK.md), or a deliberate "
                    "local replacement can be kept by setting %s=1."
                    % (redact(endpoint), attempt, _reason(exc), ENV_LOCAL_RELINK)
                )
            time.sleep(min(2 ** attempt, 10))
    else:  # pragma: no cover - defensive
        raise FetchError("LFS batch resolution failed: %s" % _reason(last_exc))

    by_oid = {o["oid"]: o for o in objects}
    resolved = {}
    for obj in data.get("objects", []):
        oid = obj.get("oid")
        if oid not in by_oid:
            continue
        if "error" in obj:
            error = obj["error"] if isinstance(obj["error"], dict) else {}
            message = error.get("message") or obj["error"]
            raise FetchError(
                "LFS server rejected object %s: %s"
                % (oid[:12], redact(message))
            )
        action = (obj.get("actions") or {}).get("download")
        href = (action or {}).get("href")
        if not href:
            raise FetchError(
                "LFS object %s is not available for download from the pinned source"
                % oid[:12]
            )
        if not _is_safe_url(href):
            raise FetchError("refusing non-HTTPS LFS download URL for %s" % oid[:12])
        resolved[oid] = href
    missing = [o["oid"] for o in objects if o["oid"] not in resolved]
    if missing:
        raise FetchError(
            "pinned LFS source did not return a download URL for: %s"
            % ", ".join(m[:12] for m in missing)
        )
    return resolved


def _check_deadline(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise FetchError("network deadline exceeded (set FLOECAD_DEADLINE to extend)")


def _reason(exc) -> str:
    return redact(getattr(exc, "reason", None) or str(exc))


def download_verified(url: str, dest_tmp: str, size: int, sha256: str,
                      deadline: float) -> None:
    """Stream url -> dest_tmp, enforcing exact size and SHA-256.

    Raises IntegrityError on a wrong hash or wrong length and FetchError on
    network problems. Never touches the final destination.
    """
    req = urllib.request.Request(url, method="GET")
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        _check_deadline(deadline)
        digest = hashlib.sha256()
        written = 0
        try:
            with _urlopen(req, min(READ_TIMEOUT, max(1.0, deadline - time.monotonic()))) as resp:
                if resp.status != 200:
                    raise FetchError("HTTP %s fetching object" % resp.status)
                with open(dest_tmp, "wb") as out:
                    while True:
                        _check_deadline(deadline)
                        chunk = resp.read(READ_CHUNK)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > size:
                            raise IntegrityError(
                                "download is larger than the pinned size "
                                "(expected %d bytes)" % size
                            )
                        digest.update(chunk)
                        out.write(chunk)
            got_hash = digest.hexdigest()
            if written != size:
                raise IntegrityError(
                    "partial download: got %d of %d bytes" % (written, size)
                )
            if got_hash != sha256.lower():
                raise IntegrityError(
                    "download hash mismatch: expected %s, got %s"
                    % (sha256[:12], got_hash[:12])
                )
            return
        except IntegrityError:
            # A wrong hash or truncated body will not be repaired by a blind
            # retry from scratch against the same pinned object; fail loudly.
            _remove_quiet(dest_tmp)
            raise
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            last_exc = exc
            _remove_quiet(dest_tmp)
            if attempt >= MAX_RETRIES or time.monotonic() >= deadline:
                raise FetchError(
                    "download failed after %d attempt(s): %s"
                    % (attempt, _reason(exc))
                )
            time.sleep(min(2 ** attempt, 10))
    # pragma: no cover - defensive
    raise FetchError("download failed: %s" % last_exc)


def _remove_quiet(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
def install_artifact(root: str, art: dict, source: dict, deadline: float,
                     offline: bool, log, local_relink: bool = False) -> str:
    """Ensure one artifact is present and verified. Returns the action taken."""
    dest = safe_install_path(root, art["installPath"])
    name = art.get("name", art["installPath"])

    if os.path.exists(dest):
        if file_matches(dest, art["size"], art["sha256"]):
            log("keep   %s (already matches pinned SHA-256, not rewritten)" % name)
            return "kept"
        if local_relink:
            log("keep   %s (local relink in effect: bytes differ from the pinned "
                "SHA-256 and are deliberately NOT overwritten)" % name)
            return "kept-local"

    preexisting = os.path.exists(dest)
    if preexisting:
        log("replace %s (present but size/hash do not match the pin)" % name)

    if offline:
        raise FetchError(
            "--offline set and %s is missing or invalid at %s; cannot fetch"
            % (name, art["installPath"])
        )

    urls = resolve_lfs_urls(
        source, [{"oid": art["source"]["oid"], "size": art["size"]}], deadline
    )
    href = urls[art["source"]["oid"]]

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".floecad-tmp-", suffix=".a", dir=os.path.dirname(dest)
    )
    os.close(fd)
    try:
        log("fetch  %s (%d bytes) from pinned LFS source" % (name, art["size"]))
        download_verified(href, tmp_path, art["size"], art["sha256"], deadline)
        # Atomic on the same volume (tmp is a sibling of the destination).
        os.replace(tmp_path, dest)
    except BaseException:
        _remove_quiet(tmp_path)
        raise
    log("verify %s OK (size + SHA-256 match)" % name)
    return "replaced" if preexisting else "installed"


def run(root: str, check: bool, offline: bool, log=print,
        local_relink: bool = False) -> int:
    manifest = load_manifest(root)
    sources = resolve_sources(manifest)
    artifacts = manifest["artifacts"]

    if check:
        # Strictly read-only: no network, no writes.
        ok = True
        local_count = 0
        for art in artifacts:
            safe_install_path(root, art["installPath"])  # surface escape errors
            status = artifact_status(root, art, local_relink=local_relink)
            label = {"ok": "OK    ", "missing": "MISS  ", "invalid": "BAD   ",
                     "local": "LOCAL "}[status]
            log("%s %s" % (label, art["installPath"]))
            if status == "local":
                local_count += 1
                continue
            if status != "ok":
                ok = False
        if ok and local_count:
            log("%d of %d artifact(s) are deliberate local replacements accepted "
                "by %s; they are NOT the pinned official bytes. Official/release "
                "verification must run plain --check."
                % (local_count, len(artifacts), ENV_LOCAL_RELINK))
            return 0
        if ok:
            log("All %d pinned artifact(s) present and verified." % len(artifacts))
            return 0
        log("Some artifacts are missing or invalid. Run: python3 bootstrap.py")
        return 2

    deadline = time.monotonic() + DEADLINE
    actions = []
    for art in artifacts:
        source_id = art["source"]["sourceId"]
        source = sources.get(source_id)
        if not source:
            raise ManifestError(
                "artifact %r references unknown source %r"
                % (art.get("name"), source_id)
            )
        if source.get("kind") != _REQUIRED_SOURCE_KIND:
            raise UnsupportedSourceError(
                "source %r has unsupported kind %r"
                % (source_id, source.get("kind"))
            )
        actions.append(install_artifact(root, art, source, deadline, offline, log,
                                        local_relink=local_relink))

    # Post-install verification (defense in depth). Unpinned bytes only pass
    # when the local-relink opt-in explicitly allows them.
    for art in artifacts:
        if artifact_status(root, art, local_relink=local_relink) not in ("ok", "local"):
            raise IntegrityError(
                "post-install verification failed for %s" % art["installPath"]
            )
    if "kept-local" in actions:
        log("NOTE: %d artifact(s) kept as deliberate local replacements; the "
            "pinned official bytes were NOT restored. Official/release builds "
            "must run without %s." % (actions.count("kept-local"), ENV_LOCAL_RELINK))
    log("Done. %d artifact(s) ready: %s."
        % (len(artifacts), ", ".join(sorted(set(actions)))))
    return 0


def _env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in _TRUTHY


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fetch and verify FloeCADKit's pinned native OCCT slices."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="read-only: verify installed artifacts without network or writes",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="never use the network; fail if an artifact is missing/invalid",
    )
    parser.add_argument(
        "--local-relink",
        action="store_true",
        help="deliberate local rebuild/replacement: never overwrite existing "
             "slices that differ from the pins; for --check, report them as "
             "LOCAL and exit 0 (also enabled by %s=1)" % ENV_LOCAL_RELINK,
    )
    parser.add_argument(
        "--root",
        default=None,
        help="package root containing DEPENDENCIES.json (default: this script's dir)",
    )
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    root = os.path.abspath(args.root) if args.root else package_root()
    local_relink = args.local_relink or _env_flag(ENV_LOCAL_RELINK)
    started = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        print("FloeCADKit bootstrap starting at %s (root=%s, check=%s, offline=%s, "
              "local_relink=%s)"
              % (started, root, args.check, args.offline, local_relink))
        return run(root, check=args.check, offline=args.offline,
                   local_relink=local_relink)
    except BootstrapError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("error: filesystem operation failed: %s" % exc, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())

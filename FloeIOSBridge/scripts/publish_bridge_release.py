#!/usr/bin/env python3
"""Independent local publisher for the public Floe iOS Bridge release.

This helper consumes the already-verified Bridge release APIs (``package_bridge``,
``verify_bridge`` and ``verify_public_release``) and publishes exactly three
public assets to the existing ``JiangNanGenius/floe-agent`` repository:

* ``Floe-iOS-Bridge-<version>-unsigned.ipa``
* ``Floe-iOS-Bridge-<version>-unsigned.ipa.sha256``
* ``Floe-iOS-Bridge-<version>-public.json``

Design constraints:

* verification/dry-run is the default; publication requires explicit
  ``--publish`` and an immutable public tag that already exists;
* the helper never creates, moves or pushes a Git tag;
* every network writer is behind ``--publish``; the preflight is read-only;
* the qualification receipt is a private operator handoff: it is validated but
  never uploaded or included in a public report;
* the release is created as a draft, every asset is read back and verified, and
  only then is the draft flipped to a stable release with
  ``make_latest="false"`` (the GitHub REST string enum, not a JSON boolean);
* public availability is proved with an unauthenticated streamed download of all
  three assets and a full verifier run.

The module has no shell execution for GitHub.  ``gh`` is invoked with argument
arrays only; credentials stay in the authenticated CLI/keyring or the
``GH_TOKEN`` environment consumed by ``gh`` itself and are never read here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_bridge as pb  # noqa: E402
import verify_bridge as vb  # noqa: E402
import verify_public_release as vp  # noqa: E402

REPO = "JiangNanGenius/floe-agent"
TAG_PREFIX = vp.TAG_PREFIX
PUBLIC_SUMMARY_PREFIX = f"{pb.CANONICAL_PREFIX}"
REPORT_SCHEMA = "floe-ios-bridge-publication-report/v1"
RECEIPT_SCHEMA = "floe-ios-bridge-qualification-v1"

SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = vp.SEMVER_RE
BUILD_RE = re.compile(r"^[0-9]+$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

MAX_IPA_BYTES = 1024 * 1024 * 1024
MAX_SUMMARY_BYTES = 1024 * 1024
MAX_SIDECAR_BYTES = 4096
MAX_NOTES_BYTES = 64 * 1024
MAX_RECEIPT_BYTES = 64 * 1024
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_CHUNK_BYTES = 64 * 1024

PUBLIC_SUMMARY_FIELDS = {
    "schema", "product", "mode", "marketingVersion", "buildNumber",
    "bundleIdentifier", "applicationExtensionBundleIdentifier",
    "coreBundleIdentifier", "sourceRef", "sourceTreeSHA256",
    "sourceFileCount", "artifact", "topology", "verification", "limitations",
}
PUBLIC_ARTIFACT_FIELDS = {"filename", "sha256", "bytes"}
PUBLIC_TOPOLOGY_FIELDS = {"topLevelApps", "appExtensions", "xctests", "nestedApps"}
PUBLIC_VERIFICATION_FIELDS = {
    "mode", "checks", "failed", "unsigned", "noDDI", "hostNoXCTest",
    "arm64IPhoneOS", "roleVersionsAgree", "symbolsVerified",
}

QUALIFICATION_CHECKS = (
    "iphoneLocalControl",
    "crossApp",
    "ocrScreenshot",
    "videoRemote",
    "backgroundStopResume",
    "nativeDDIRecovery",
    "rebootRecovery",
    "authentication",
    "packageSigning",
)
RECEIPT_FIELDS = {
    "schema",
    "sourceRef",
    "sourceTreeSHA256",
    "ipaSHA256",
    "marketingVersion",
    "buildNumber",
    "checks",
    "ipadQualification",
}
IPAD_QUALIFICATION = "assumed-by-owner"
REBOOT_OWNER_ASSUMPTION = "assumed-by-owner"
REBOOT_ASSUMPTION_NOTE = "Reboot recovery was accepted by the owner and was not retested for this release."
CORE_SMOKE_NOT_REQUIRED = "not-required-by-owner"
CORE_SMOKE_DEFERRED_CHECKS = frozenset({"backgroundStopResume", "nativeDDIRecovery"})
CORE_SMOKE_SCOPE_NOTE = "By owner direction, qualification is limited to iPhone core control and a two-operation iPad smoke check; separate DDI recovery and Stop/Resume tests were not required for this release."

FORBIDDEN_TEXT_PATTERNS = (
    (re.compile(r"/Users/[^/\s\"']+"), "absolute user path"),
    (re.compile(r"/Volumes/[^/\s\"']+"), "absolute volume path"),
    (re.compile(r"/private/[^/\s\"']+"), "private path"),
    (re.compile(r"/var/folders/[^/\s\"']+"), "temporary path"),
    (re.compile(r"/home/[^/\s\"']+"), "home path"),
    (re.compile(r"[A-Za-z]:\\\\"), "windows path"),
    (re.compile(r"file://"), "file URL"),
    (re.compile(r"Local/(?:Private|Scratch)"), "local private path"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "github token"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"), "github token"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"(?i)\bAuthorization\s*:"), "authorization header"),
    (re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._-]{10,}"), "bearer token"),
    (
        re.compile(
            r"(?i)\b(?:udid|pairing record|pairing key|control key|private key|"
            r"serial number)\b"
        ),
        "device or secret reference",
    ),
    (
        re.compile(
            r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
        ),
        "UUID",
    ),
)
FORBIDDEN_ARCHIVE_PARTS = (
    "_CodeSignature",
    "embedded.mobileprovision",
    "embedded.provisionprofile",
    "ExportOptions.plist",
    "manifest.plist",
)
FORBIDDEN_ARCHIVE_SUFFIXES = (
    ".mobileprovision",
    ".provisionprofile",
    ".dSYM",
    ".p12",
    ".pfx",
    ".cer",
    ".key",
    ".pem",
)
PUBLIC_ASSET_NAMES = ("ipa", "sidecar", "summary")


class PublicationAbort(Exception):
    """A fail-closed publication/verification decision."""

    def __init__(
        self,
        phase: str,
        status: str,
        message: str,
        *,
        exit_code: int,
        failed_checks: list | None = None,
    ):
        super().__init__(message)
        self.phase = phase
        self.status = status
        self.message = message
        self.exit_code = exit_code
        self.failed_checks = failed_checks or []


class GitHubError(RuntimeError):
    def __init__(self, message: str, *, status: int | None = None):
        super().__init__(message)
        self.status = status


class NotFound(GitHubError):
    pass


class AmbiguousWrite(GitHubError):
    """A write may have been accepted even though the response failed."""


class DownloadError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def sanitize_secrets(text: str) -> str:
    value = str(text)
    value = re.sub(r"github_pat_[A-Za-z0-9_]+", "github_pat_<redacted>", value)
    value = re.sub(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b", "gh_<redacted>", value)
    value = re.sub(
        r"(?i)(authorization\s*:\s*)(\S+)", r"\1<redacted>", value
    )
    value = re.sub(
        r"(?i)(bearer\s+)[A-Za-z0-9._-]{10,}", r"\1<redacted>", value
    )
    return value


def public_message(text: str, private_roots: list | None = None) -> str:
    value = sanitize_secrets(str(text))
    for root in private_roots or []:
        root_text = str(root)
        if root_text:
            value = value.replace(root_text, "<private-path>")
    value = re.sub(r"/Users/[^/\s\"']+", "<private-path>", value)
    value = re.sub(r"/Volumes/[^/\s\"']+", "<private-path>", value)
    value = re.sub(r"/private/[^/\s\"']+", "<private-path>", value)
    value = re.sub(r"/var/folders/[^/\s\"']+", "<private-path>", value)
    value = re.sub(r"/home/[^/\s\"']+", "<private-path>", value)
    value = re.sub(r"file://[^\s\"']+", "<private-path>", value)
    value = re.sub(r"Local/(?:Private|Scratch)", "<private-path>", value)
    return value[:800]


def forbidden_text_findings(text: str) -> list[str]:
    findings: list[str] = []
    for pattern, label in FORBIDDEN_TEXT_PATTERNS:
        if pattern.search(text):
            findings.append(label)
    return sorted(set(findings))


def atomic_write_json(path: Path, payload: dict) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def read_small_file(path: Path, label: str, maximum: int) -> bytes:
    path = Path(path)
    if path.is_symlink():
        raise PublicationAbort("preflight", "preflight-failed", f"{label} must not be a symlink", exit_code=2)
    try:
        stat = path.stat()
    except OSError as error:
        raise PublicationAbort("preflight", "preflight-failed", f"{label} is not readable: {error}", exit_code=2)
    if not path.is_file():
        raise PublicationAbort("preflight", "preflight-failed", f"{label} is not a regular file", exit_code=2)
    if stat.st_size > maximum:
        raise PublicationAbort(
            "preflight",
            "preflight-failed",
            f"{label} exceeds the {maximum}-byte limit",
            exit_code=2,
        )
    return path.read_bytes()


def resolve_input_file(path: str, label: str) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_symlink():
        raise PublicationAbort("preflight", "preflight-failed", f"{label} must not be a symlink", exit_code=2)
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise PublicationAbort("preflight", "preflight-failed", f"{label} does not exist: {error}", exit_code=2)
    if not resolved.is_file():
        raise PublicationAbort("preflight", "preflight-failed", f"{label} is not a regular file", exit_code=2)
    return resolved


def git_text(repo_root: Path, arguments: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *arguments],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise GitHubError(sanitize_secrets(result.stderr.strip() or "git command failed"))
    return result.stdout


@dataclass
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


class GhTransport:
    """Minimal ``gh api`` transport with argument arrays and no shell."""

    def __init__(
        self,
        *,
        gh: str = "gh",
        timeout: int = 300,
        runner=None,
    ):
        self.gh = gh
        self.timeout = timeout
        self._runner = runner or self._subprocess_runner

    def _subprocess_runner(self, argv: list[str], input_bytes: bytes | None, input_path: Path | None) -> CommandResult:
        if input_path is not None:
            with Path(input_path).open("rb") as handle:
                result = subprocess.run(
                    argv,
                    stdin=handle,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=self.timeout,
                )
        else:
            result = subprocess.run(
                argv,
                input=input_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeout,
            )
        return CommandResult(result.returncode, result.stdout, result.stderr)

    def _run(self, argv: list[str], *, input_bytes: bytes | None = None, input_path: Path | None = None) -> CommandResult:
        try:
            return self._runner(argv, input_bytes, input_path)
        except FileNotFoundError as error:
            raise GitHubError(f"authenticated {self.gh} CLI is not available") from error
        except subprocess.TimeoutExpired as error:
            raise AmbiguousWrite("GitHub request timed out") from error
        except OSError as error:
            raise AmbiguousWrite(f"GitHub request failed: {error}") from error

    @staticmethod
    def _parse_include(stdout: bytes) -> tuple[int | None, bytes]:
        header_end = -1
        separator_length = 0
        for separator in (b"\r\n\r\n", b"\n\n"):
            index = stdout.find(separator)
            if index != -1 and (header_end == -1 or index < header_end):
                header_end = index
                separator_length = len(separator)
        if header_end == -1:
            return None, stdout
        header = stdout[:header_end].decode("iso-8859-1", "replace")
        body = stdout[header_end + separator_length:]
        first_line = header.splitlines()[0] if header.splitlines() else ""
        match = re.match(r"HTTP/\S+\s+(\d{3})", first_line)
        return (int(match.group(1)) if match else None), body

    def api_json(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
    ) -> tuple[int, dict]:
        argv = [
            self.gh,
            "api",
            "--hostname",
            "github.com",
            "--method",
            method,
            "--include",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
        ]
        input_bytes = None
        if payload is not None:
            argv.extend(["-H", "Content-Type: application/json", "--input", "-"])
            input_bytes = json.dumps(payload, sort_keys=True).encode("utf-8")
        argv.append(path)
        result = self._run(argv, input_bytes=input_bytes)
        status, body = self._parse_include(result.stdout)
        if status is None and result.returncode != 0:
            raise self._error_for(method, result, None)
        if status == 204:
            return 204, {}
        if status == 404:
            raise NotFound("GitHub resource not found", status=404)
        if status is not None and status >= 400:
            raise self._error_for(method, result, status, body)
        try:
            parsed = json.loads(body.decode("utf-8")) if body.strip() else {}
        except ValueError as error:
            if result.returncode == 0:
                raise GitHubError("GitHub returned a non-JSON response") from error
            raise self._error_for(method, result, status, body) from error
        if status is None:
            status = 200 if result.returncode == 0 else 1
        return status, parsed if isinstance(parsed, dict) else {"items": parsed}

    def _error_for(
        self,
        method: str,
        result: CommandResult,
        status: int | None,
        body: bytes | None = None,
    ) -> GitHubError:
        detail = sanitize_secrets(result.stderr.decode("utf-8", "replace")).strip()
        if not detail and body:
            detail = sanitize_secrets(body.decode("utf-8", "replace")).strip()
        detail = detail[:500] or "GitHub request failed"
        if method.upper() in {"POST", "PATCH", "PUT"} and (status is None or status >= 500):
            return AmbiguousWrite(detail, status=status)
        return GitHubError(detail, status=status)

    def upload(
        self,
        upload_url: str,
        name: str,
        source_path: Path,
        *,
        content_type: str = "application/octet-stream",
    ) -> tuple[int, dict]:
        base_url = upload_url.split("{", 1)[0]
        separator = "&" if "?" in base_url else "?"
        url = base_url + separator + "name=" + urllib.parse.quote(name, safe="")
        argv = [
            self.gh,
            "api",
            "--method",
            "POST",
            "--include",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            f"Content-Type: {content_type}",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            "--input",
            str(source_path),
            url,
        ]
        result = self._run(argv, input_path=Path(source_path))
        status, body = self._parse_include(result.stdout)
        if status is None and result.returncode != 0:
            raise self._error_for("POST", result, None)
        if status == 404:
            raise NotFound("GitHub upload endpoint not found", status=404)
        if status is not None and status >= 400:
            raise self._error_for("POST", result, status, body)
        try:
            parsed = json.loads(body.decode("utf-8")) if body.strip() else {}
        except ValueError as error:
            raise AmbiguousWrite("GitHub upload returned an unreadable response") from error
        return status or 201, parsed if isinstance(parsed, dict) else {}

    def download(self, url: str, destination: Path, *, max_bytes: int) -> tuple[int, str]:
        argv = [
            self.gh,
            "api",
            "--method",
            "GET",
            "-H",
            "Accept: application/octet-stream",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            url,
        ]
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".part")
        digest = hashlib.sha256()
        total = 0
        error_file = tempfile.TemporaryFile()
        process = None
        try:
            process = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=error_file,
            )
            assert process.stdout is not None
            with temporary.open("wb") as handle:
                while True:
                    chunk = process.stdout.read(DEFAULT_CHUNK_BYTES)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > max_bytes:
                        process.kill()
                        process.wait()
                        raise DownloadError(f"asset exceeds the {max_bytes}-byte limit")
                    handle.write(chunk)
                    digest.update(chunk)
            returncode = process.wait()
            error_file.seek(0)
            stderr = sanitize_secrets(error_file.read().decode("utf-8", "replace").strip())
            if returncode != 0:
                raise GitHubError(stderr[:500] or "authenticated asset download failed")
            os.replace(temporary, destination)
            return total, digest.hexdigest()
        except Exception:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            if temporary.exists():
                temporary.unlink()
            raise
        finally:
            error_file.close()


class GitHubClient:
    """Typed helpers over ``GhTransport`` for the Bridge release endpoints."""

    def __init__(self, repo: str = REPO, transport: GhTransport | None = None):
        if not REPO_RE.fullmatch(repo):
            raise GitHubError("invalid repository name")
        self.repo = repo
        self.transport = transport or GhTransport()

    def get_tag_ref(self, tag: str) -> dict:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/git/ref/tags/{urllib.parse.quote(tag, safe='')}"
        )
        return payload

    def get_tag_object(self, object_sha: str) -> dict:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/git/tags/{urllib.parse.quote(object_sha, safe='')}"
        )
        return payload

    def get_latest_release(self) -> dict:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/releases/latest"
        )
        return payload

    def get_release_by_tag(self, tag: str) -> dict:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/releases/tags/{urllib.parse.quote(tag, safe='')}"
        )
        return payload

    def get_release(self, release_id: int) -> dict:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/releases/{int(release_id)}"
        )
        return payload

    def list_releases(self, page: int = 1) -> list:
        status, payload = self.transport.api_json(
            "GET", f"repos/{self.repo}/releases?per_page=100&page={int(page)}"
        )
        items = payload.get("items") if isinstance(payload, dict) else None
        return items if isinstance(items, list) else []

    def find_release(self, tag: str) -> dict | None:
        try:
            return self.get_release_by_tag(tag)
        except NotFound:
            pass
        for page in range(1, 11):
            releases = self.list_releases(page)
            if not releases:
                break
            for release in releases:
                if isinstance(release, dict) and release.get("tag_name") == tag:
                    return release
        return None

    def create_release(self, payload: dict) -> dict:
        status, body = self.transport.api_json(
            "POST", f"repos/{self.repo}/releases", payload
        )
        return body

    def update_release(self, release_id: int, payload: dict) -> dict:
        status, body = self.transport.api_json(
            "PATCH", f"repos/{self.repo}/releases/{int(release_id)}", payload
        )
        return body

    def upload_asset(self, release: dict, name: str, source_path: Path) -> dict:
        upload_url = str(release.get("upload_url") or "")
        if not upload_url:
            release_id = release.get("id")
            if not isinstance(release_id, int):
                raise GitHubError("release has no upload URL or id")
            upload_url = f"https://uploads.github.com/repos/{self.repo}/releases/{release_id}/assets"
        status, body = self.transport.upload(upload_url, name, Path(source_path))
        return body

    def download_asset(self, asset: dict, destination: Path, *, max_bytes: int) -> tuple[int, str]:
        url = str(asset.get("url") or "")
        if not url:
            asset_id = asset.get("id")
            if not isinstance(asset_id, int):
                raise GitHubError("release asset has no API URL or id")
            url = f"https://api.github.com/repos/{self.repo}/releases/assets/{asset_id}"
        return self.transport.download(url, destination, max_bytes=max_bytes)


class PublicDownloader:
    """Unauthenticated, streamed, bounded public asset download."""

    def __init__(
        self,
        *,
        timeout: int = 120,
        chunk_size: int = DEFAULT_CHUNK_BYTES,
        allow_http: bool = False,
        allowed_hosts: set | None = None,
        opener=None,
    ):
        self.timeout = timeout
        self.chunk_size = chunk_size
        self.allow_http = allow_http
        self.allowed_hosts = set(allowed_hosts or {
            "github.com",
            "api.github.com",
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
        })
        self._opener = opener or urllib.request.urlopen

    def _validate_url(self, url: str) -> None:
        parsed = urllib.parse.urlsplit(url)
        schemes = {"https"} | ({"http"} if self.allow_http else set())
        if parsed.scheme not in schemes:
            raise DownloadError("public asset URL must use HTTPS")
        if parsed.username or parsed.password:
            raise DownloadError("public asset URL must not contain credentials")
        host = (parsed.hostname or "").lower()
        if not host:
            raise DownloadError("public asset URL has no host")
        if host not in self.allowed_hosts and not host.endswith(".githubusercontent.com"):
            raise DownloadError(f"public asset host {host!r} is not allowed")
        if parsed.scheme == "https" and parsed.port not in (None, 443):
            raise DownloadError("public asset URL uses a non-standard HTTPS port")
        if parsed.scheme == "http" and parsed.port is None:
            raise DownloadError("public test HTTP URL must include a port")

    def fetch(
        self,
        url: str,
        destination: Path,
        *,
        expected_size: int,
        expected_sha256: str,
        max_bytes: int,
    ) -> tuple[int, str]:
        if expected_size <= 0 or expected_size > max_bytes:
            raise DownloadError("invalid expected public asset size")
        if not SHA256_RE.fullmatch(expected_sha256):
            raise DownloadError("invalid expected public asset hash")
        self._validate_url(url)
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".part")
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/octet-stream",
                "Accept-Encoding": "identity",
                "User-Agent": "floe-ios-bridge-publisher/1",
            },
            method="GET",
        )
        digest = hashlib.sha256()
        total = 0
        try:
            with self._opener(request, timeout=self.timeout) as response:
                final_url = response.geturl()
                self._validate_url(final_url)
                status = getattr(response, "status", None) or response.getcode()
                if status != 200:
                    raise DownloadError(f"public asset returned HTTP {status}")
                content_length = response.headers.get("Content-Length")
                if content_length is not None:
                    try:
                        declared = int(content_length)
                    except ValueError as error:
                        raise DownloadError("public asset has an invalid Content-Length") from error
                    if declared != expected_size:
                        raise DownloadError(
                            f"public asset Content-Length {declared} does not match expected {expected_size}"
                        )
                with temporary.open("wb") as handle:
                    while True:
                        chunk = response.read(self.chunk_size)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > expected_size or total > max_bytes:
                            raise DownloadError("public asset exceeds the expected size")
                        handle.write(chunk)
                        digest.update(chunk)
            if total != expected_size:
                raise DownloadError(
                    f"public asset size {total} does not match expected {expected_size}"
                )
            actual = digest.hexdigest()
            if actual != expected_sha256:
                raise DownloadError("public asset SHA256 does not match the local artifact")
            os.replace(temporary, destination)
            return total, actual
        except urllib.error.HTTPError as error:
            raise DownloadError(f"public asset download failed with HTTP {error.code}") from error
        except urllib.error.URLError as error:
            raise DownloadError(f"public asset download failed: {error.reason}") from error
        finally:
            if temporary.exists():
                temporary.unlink()


def run_public_verifier(
    *,
    ipa: str,
    sidecar: str,
    summary: str,
    version: str,
    build: str,
    source_ref: str,
    tag: str,
    repo_root: str,
    project: str,
    latest_json: str,
    expect_latest_tag: str,
    strict: bool,
) -> dict:
    """Invoke the existing read-only public verifier as an independent process."""
    command = [
        sys.executable,
        "-B",
        str(Path(__file__).resolve().parent / "verify_public_release.py"),
        "--ipa",
        str(ipa),
        "--sha256",
        str(sidecar),
        "--public-summary",
        str(summary),
        "--version",
        str(version),
        "--build",
        str(build),
        "--source-ref",
        str(source_ref),
        "--tag",
        str(tag),
        "--repo-root",
        str(repo_root),
        "--project",
        str(project),
        "--latest-json",
        str(latest_json),
        "--expect-latest-tag",
        str(expect_latest_tag),
        "--strict",
        "--json",
    ]
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "ok": False,
            "checks": [{"name": "verifier-run", "ok": False, "detail": str(error)}],
            "command": command,
        }
    payload = {}
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        payload = {
            "ok": False,
            "checks": [
                {
                    "name": "verifier-json",
                    "ok": False,
                    "detail": sanitize_secrets(result.stderr[-500:]),
                }
            ],
        }
    if not isinstance(payload, dict):
        payload = {"ok": False, "checks": [{"name": "verifier-json", "ok": False}]}
    payload["command"] = command
    payload["returncode"] = result.returncode
    if result.returncode != 0:
        payload["ok"] = False
    return payload


def validate_notes(path: Path) -> tuple[str, str, int]:
    raw = read_small_file(path, "release notes", MAX_NOTES_BYTES)
    if not raw.strip():
        raise PublicationAbort("preflight", "preflight-failed", "release notes are empty", exit_code=2)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicationAbort("preflight", "preflight-failed", "release notes are not UTF-8", exit_code=2)
    if "\x00" in text:
        raise PublicationAbort("preflight", "preflight-failed", "release notes contain a NUL byte", exit_code=2)
    findings = forbidden_text_findings(text)
    if findings:
        raise PublicationAbort(
            "preflight",
            "preflight-failed",
            "release notes contain private or secret material: " + ", ".join(findings),
            exit_code=2,
        )
    return text, sha256_bytes(raw), len(raw)


def validate_receipt(
    path: Path,
    *,
    source_ref: str,
    source_tree_sha256: str,
    ipa_sha256: str,
    version: str,
    build: str,
) -> tuple[dict, str, int]:
    raw = read_small_file(path, "qualification receipt", MAX_RECEIPT_BYTES)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt is not valid JSON", exit_code=2)
    if not isinstance(payload, dict):
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt must be a JSON object", exit_code=2)
    unknown = sorted(set(payload) - RECEIPT_FIELDS)
    missing = sorted(RECEIPT_FIELDS - set(payload))
    if unknown or missing:
        raise PublicationAbort(
            "preflight",
            "preflight-failed",
            "qualification receipt fields are not the exact public schema"
            + (f"; unknown={unknown}" if unknown else "")
            + (f"; missing={missing}" if missing else ""),
            exit_code=2,
        )
    if payload.get("schema") != RECEIPT_SCHEMA:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt schema is not recognized", exit_code=2)
    if not isinstance(payload.get("sourceRef"), str) or not SHA1_RE.fullmatch(payload["sourceRef"]):
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt sourceRef is not a 40-hex commit", exit_code=2)
    if payload["sourceRef"] != source_ref:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt sourceRef does not match the release source", exit_code=2)
    for field, expected, label in (
        ("sourceTreeSHA256", source_tree_sha256, "source tree"),
        ("ipaSHA256", ipa_sha256, "IPA"),
    ):
        value = payload.get(field)
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            raise PublicationAbort("preflight", "preflight-failed", f"qualification receipt {field} is not a SHA256", exit_code=2)
        if value != expected:
            raise PublicationAbort("preflight", "preflight-failed", f"qualification receipt {label} hash does not match the artifact", exit_code=2)
    if payload.get("marketingVersion") != version:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt marketingVersion does not match", exit_code=2)
    if payload.get("buildNumber") != build:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt buildNumber does not match", exit_code=2)
    checks = payload.get("checks")
    if not isinstance(checks, dict) or set(checks) != set(QUALIFICATION_CHECKS):
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt checks are not the exact required set", exit_code=2)
    deferred = {name for name, value in checks.items() if value == CORE_SMOKE_NOT_REQUIRED}
    if deferred and deferred != CORE_SMOKE_DEFERRED_CHECKS:
        raise PublicationAbort("preflight", "preflight-failed", "owner-directed core smoke scope must identify exactly its two omitted checks", exit_code=2)
    for name in QUALIFICATION_CHECKS:
        if name in deferred:
            continue
        if name == "rebootRecovery" and checks.get(name) == REBOOT_OWNER_ASSUMPTION:
            continue
        if checks.get(name) is not True:
            raise PublicationAbort("preflight", "preflight-failed", f"qualification receipt check {name} is not true", exit_code=2)
    if payload.get("ipadQualification") != IPAD_QUALIFICATION:
        raise PublicationAbort("preflight", "preflight-failed", "qualification receipt ipadQualification must be assumed-by-owner", exit_code=2)
    for value in payload.values():
        if isinstance(value, str):
            findings = forbidden_text_findings(value)
            if findings and value not in {source_ref, source_tree_sha256, ipa_sha256}:
                raise PublicationAbort(
                    "preflight",
                    "preflight-failed",
                    "qualification receipt contains private or secret material: " + ", ".join(findings),
                    exit_code=2,
                )
    return payload, sha256_bytes(raw), len(raw)


def validate_ipa_archive(path: Path) -> None:
    try:
        if not zipfile.is_zipfile(path):
            raise PublicationAbort("preflight", "preflight-failed", "IPA is not a readable ZIP archive", exit_code=2)
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if not infos:
                raise PublicationAbort("preflight", "preflight-failed", "IPA archive is empty", exit_code=2)
            total_uncompressed = 0
            apps: set[str] = set()
            appexes: set[str] = set()
            xctests: set[str] = set()
            for info in infos:
                name = info.filename
                normalized = name.replace("\\", "/")
                parts = [part for part in normalized.split("/") if part]
                if not parts or name.startswith("/") or "\\" in name or any(part == ".." for part in parts):
                    raise PublicationAbort("preflight", "preflight-failed", "IPA contains an unsafe path", exit_code=2)
                for part in parts:
                    if part in FORBIDDEN_ARCHIVE_PARTS:
                        raise PublicationAbort("preflight", "preflight-failed", "IPA contains signing, profile or symbol material", exit_code=2)
                lowered = name.lower()
                if any(lowered.endswith(suffix) for suffix in FORBIDDEN_ARCHIVE_SUFFIXES):
                    raise PublicationAbort("preflight", "preflight-failed", "IPA contains signing, profile or symbol material", exit_code=2)
                mode = (info.external_attr >> 16) & 0o170000
                if mode == 0o120000:
                    raise PublicationAbort("preflight", "preflight-failed", "IPA contains a symbolic link", exit_code=2)
                total_uncompressed += int(info.file_size)
                if total_uncompressed > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                    raise PublicationAbort("preflight", "preflight-failed", "IPA uncompressed size exceeds the safety bound", exit_code=2)
                for index, part in enumerate(parts):
                    prefix = "/".join(parts[: index + 1])
                    if part.endswith(".app"):
                        apps.add(prefix)
                    elif part.endswith(".appex"):
                        appexes.add(prefix)
                    elif part.endswith(".xctest"):
                        xctests.add(prefix)
            top_apps = {
                item for item in apps
                if item.startswith("Payload/") and item.count("/") == 1
            }
            if len(top_apps) != 1 or len(apps) != 1 or len(appexes) != 1 or len(xctests) != 1:
                raise PublicationAbort(
                    "preflight",
                    "preflight-failed",
                    "IPA topology is not one app, one app extension and one XCTest bundle",
                    exit_code=2,
                )
    except zipfile.BadZipFile as error:
        raise PublicationAbort("preflight", "preflight-failed", "IPA ZIP structure is corrupt", exit_code=2)


@dataclass
class CheckRecord:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class PublicationInputs:
    ipa: Path
    sidecar: Path
    summary: Path
    notes: Path
    receipt: Path
    version: str
    build: str
    source_ref: str
    tag: str
    repo_root: Path
    project: Path
    publish: bool
    report_path: Path | None
    scratch_dir: Path | None
    evidence_dir: Path | None
    expect_latest_tag: str | None


class Publisher:
    def __init__(
        self,
        inputs: PublicationInputs,
        *,
        client,
        verifier,
        downloader,
        sleep_fn=time.sleep,
        clock=utc_stamp,
    ):
        self.inputs = inputs
        self.client = client
        self.verifier = verifier
        self.downloader = downloader
        self.sleep_fn = sleep_fn
        self.clock = clock
        self.checks: list[CheckRecord] = []
        self.verifier_reports: list[dict] = []
        self.report = self._base_report()
        self.identity = None
        self.provenance = None
        self.summary_payload = None
        self.receipt_payload = None
        self.notes_text = None
        self.notes_sha256 = None
        self.receipt_sha256 = None
        self.local_assets: dict[str, dict] = {}
        self.latest_before = None
        self.latest_before_tag = None
        self.existing_release = None
        self.existing_kind = None
        self.remote_tag_style = None
        self.local_tag_style = None
        self._temporary_paths: list[Path] = []
        self._temporary_dirs: list[Path] = []
        self._owns_scratch = False
        self.scratch_dir = inputs.scratch_dir
        self.evidence_dir = inputs.evidence_dir

    def _base_report(self) -> dict:
        return {
            "schema": REPORT_SCHEMA,
            "phase": "preflight",
            "status": "starting",
            "ok": False,
            "complete": False,
            "mode": "publish" if self.inputs.publish else "verify",
            "version": self.inputs.version,
            "buildNumber": self.inputs.build,
            "sourceRef": self.inputs.source_ref,
            "sourceTreeSHA256": None,
            "tag": self.inputs.tag or (TAG_PREFIX + self.inputs.version),
            "assets": [],
            "release": None,
            "latest": {
                "beforeTag": None,
                "afterTag": None,
                "bridgeIsLatest": False,
                "concurrencyReviewPending": False,
            },
            "notes": {"sha256": None, "bytes": None},
            "limitations": [],
        }

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.checks.append(CheckRecord(name, bool(ok), sanitize_secrets(detail)))
        return bool(ok)

    def _abort(self, phase: str, status: str, message: str, *, exit_code: int, failed: list | None = None):
        raise PublicationAbort(
            phase,
            status,
            message,
            exit_code=exit_code,
            failed_checks=failed or [item.name for item in self.checks if not item.ok],
        )

    def run(self) -> tuple[int, dict]:
        try:
            self.preflight()
            if not self.inputs.publish:
                return self._verify_only()
            return self._publish_flow()
        except PublicationAbort as error:
            report = self._abort_report(error)
            return error.exit_code, report

    def _workspace(self) -> Path:
        if self.scratch_dir is None:
            directory = Path(tempfile.mkdtemp(prefix="floe-bridge-publication-"))
            self._temporary_dirs.append(directory)
            self.scratch_dir = directory
            self._owns_scratch = True
        else:
            self.scratch_dir = Path(self.scratch_dir)
            self.scratch_dir.mkdir(parents=True, exist_ok=True)
        return self.scratch_dir

    def _temp_dir(self, prefix: str) -> Path:
        root = self._workspace()
        directory = Path(tempfile.mkdtemp(prefix=prefix, dir=str(root)))
        self._temporary_dirs.append(directory)
        return directory

    def _latest_json(self, payload: dict, label: str) -> Path:
        root = self._workspace()
        path = root / f"{label}-latest-{os.getpid()}.json"
        atomic_write_json(path, payload)
        self._temporary_paths.append(path)
        return path

    def _cleanup_temporaries(self) -> None:
        for path in self._temporary_paths:
            try:
                if path.exists():
                    path.unlink()
            except OSError:
                pass
        self._temporary_paths.clear()
        for directory in self._temporary_dirs:
            try:
                shutil.rmtree(directory, ignore_errors=True)
            except OSError:
                pass
        self._temporary_dirs.clear()

    def _private_roots(self) -> list:
        values = [self.inputs.repo_root]
        if self.scratch_dir is not None:
            values.append(self.scratch_dir)
        if self.evidence_dir is not None:
            values.append(self.evidence_dir)
        return values

    def _public_report(self) -> dict:
        report = json.loads(json.dumps(self.report))
        report["limitations"] = self._limitations()
        if self.inputs.publish:
            report["limitations"].append("The helper never changes repository latest/feed/store state.")
        if report.get("latest", {}).get("concurrencyReviewPending"):
            report["limitations"].append(
                "Another release changed the repository latest pointer during publication; "
                "verify causality before announcing this release."
            )
        return report

    def _limitations(self) -> list[str]:
        limitations = [
            "Static package verification only; runtime behavior and physical-device acceptance are not proven by this helper.",
            "The private qualification receipt is an operator handoff; the helper validates its contract but does not independently prove phone behavior.",
            "Physical iPad qualification is explicitly waived and recorded as assumed-by-owner.",
            "The helper never creates, moves or pushes Git tags and never changes the Mac Bridge or App releases.",
        ]
        if not self.inputs.publish:
            limitations.append("Dry run: no release, tag or asset was created or changed.")
        if (self.receipt_payload or {}).get("checks", {}).get("rebootRecovery") == REBOOT_OWNER_ASSUMPTION:
            limitations.append(REBOOT_ASSUMPTION_NOTE)
        if any(value == CORE_SMOKE_NOT_REQUIRED for value in (self.receipt_payload or {}).get("checks", {}).values()):
            limitations.append(CORE_SMOKE_SCOPE_NOTE)
        return limitations

    def _abort_report(self, error: PublicationAbort) -> dict:
        self.report["phase"] = error.phase
        self.report["status"] = error.status
        self.report["ok"] = False
        self.report["complete"] = False
        self.report["error"] = public_message(error.message, self._private_roots())
        self.report["failedChecks"] = sorted(set(error.failed_checks))
        self._write_outputs()
        self._cleanup_temporaries()
        return self._public_report()

    def _write_outputs(self) -> None:
        if self.inputs.report_path is not None:
            atomic_write_json(Path(self.inputs.report_path), self._public_report())
        if not self.inputs.publish:
            return
        evidence_dir = self.evidence_dir
        if evidence_dir is None:
            return
        evidence_dir = Path(evidence_dir)
        evidence_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "schema": REPORT_SCHEMA + "/evidence",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "report": self._public_report(),
            "checks": [
                {"name": item.name, "ok": item.ok, "detail": item.detail}
                for item in self.checks
            ],
            "verifierReports": self.verifier_reports,
            "inputs": {
                "ipaName": self.inputs.ipa.name,
                "sidecarName": self.inputs.sidecar.name,
                "summaryName": self.inputs.summary.name,
                "notesName": self.inputs.notes.name,
                "receiptName": self.inputs.receipt.name,
                "receiptSha256": self.receipt_sha256,
                "notesSha256": self.notes_sha256,
            },
        }
        atomic_write_json(evidence_dir / f"publication-{self.clock()}.json", payload)

    def preflight(self) -> None:
        self.report["phase"] = "preflight"
        self._validate_paths()
        self._validate_source_and_identity()
        self._validate_local_tag()
        self._validate_summary_and_sidecar()
        self._validate_receipt()
        self._validate_notes()
        validate_ipa_archive(self.inputs.ipa)
        self.check("ipa-archive-public-surface", True, "no signature, profile or symbol entries")
        self._validate_remote_tag()
        self._capture_latest()
        self._find_existing_release()
        self._classify_existing_release()
        self._run_verifier_local()

    def _validate_paths(self) -> None:
        inputs = self.inputs
        repo_root = Path(inputs.repo_root).expanduser()
        try:
            repo_root = repo_root.resolve(strict=True)
        except OSError as error:
            self._abort("preflight", "preflight-failed", f"repository root is not readable: {error}", exit_code=2)
        if not repo_root.is_dir():
            self._abort("preflight", "preflight-failed", "repository root is not a directory", exit_code=2)
        try:
            top = git_text(repo_root, ["rev-parse", "--show-toplevel"]).strip()
        except GitHubError as error:
            self._abort("preflight", "preflight-failed", f"repository root is not a Git checkout: {error}", exit_code=2)
        if Path(top).resolve() != repo_root:
            self._abort("preflight", "preflight-failed", "repository root is not the Git top level", exit_code=2)
        inputs.repo_root = repo_root
        inputs.ipa = resolve_input_file(str(inputs.ipa), "IPA")
        if inputs.sidecar is None:
            inputs.sidecar = inputs.ipa.with_name(inputs.ipa.name + ".sha256")
        else:
            inputs.sidecar = resolve_input_file(str(inputs.sidecar), "SHA256 sidecar")
        inputs.summary = resolve_input_file(str(inputs.summary), "public summary")
        inputs.notes = resolve_input_file(str(inputs.notes), "release notes")
        inputs.receipt = resolve_input_file(str(inputs.receipt), "qualification receipt")
        inputs.project = resolve_input_file(str(inputs.project), "project.yml")
        if inputs.ipa.stat().st_size <= 0 or inputs.ipa.stat().st_size > MAX_IPA_BYTES:
            self._abort("preflight", "preflight-failed", "IPA size is outside the allowed bound", exit_code=2)
        if inputs.ipa.name != pb.canonical_ipa_name(inputs.version):
            self._abort("preflight", "preflight-failed", "IPA filename is not the canonical release name", exit_code=2)
        if inputs.sidecar.name != inputs.ipa.name + ".sha256":
            self._abort("preflight", "preflight-failed", "sidecar filename is not the exact IPA name plus .sha256", exit_code=2)
        expected_summary = f"{PUBLIC_SUMMARY_PREFIX}-{inputs.version}-public.json"
        if inputs.summary.name != expected_summary:
            self._abort("preflight", "preflight-failed", "public summary filename is not canonical", exit_code=2)
        if inputs.summary.stat().st_size > MAX_SUMMARY_BYTES:
            self._abort("preflight", "preflight-failed", "public summary exceeds the size bound", exit_code=2)
        if inputs.sidecar.stat().st_size > MAX_SIDECAR_BYTES:
            self._abort("preflight", "preflight-failed", "sidecar exceeds the size bound", exit_code=2)
        if inputs.report_path is not None:
            report_path = Path(inputs.report_path).expanduser()
            if report_path.is_symlink():
                self._abort("preflight", "preflight-failed", "report path must not be a symlink", exit_code=2)
            if report_path.exists() and not report_path.is_file():
                self._abort("preflight", "preflight-failed", "report path must be a regular file", exit_code=2)
            inputs.report_path = report_path.resolve()
        if inputs.scratch_dir is not None:
            scratch_dir = Path(inputs.scratch_dir).expanduser()
            if scratch_dir.is_symlink():
                self._abort("preflight", "preflight-failed", "scratch directory must not be a symlink", exit_code=2)
            inputs.scratch_dir = scratch_dir.resolve()
        if inputs.evidence_dir is not None:
            evidence_dir = Path(inputs.evidence_dir).expanduser()
            if evidence_dir.is_symlink():
                self._abort("preflight", "preflight-failed", "evidence directory must not be a symlink", exit_code=2)
            inputs.evidence_dir = evidence_dir.resolve()
        if inputs.publish:
            self._workspace()
            if self.evidence_dir is None:
                self.evidence_dir = Path(tempfile.mkdtemp(prefix="floe-bridge-evidence-"))
                self._temporary_dirs.append(self.evidence_dir)
            else:
                self.evidence_dir = Path(self.evidence_dir)
                self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self.check("paths-canonical", True, "canonical public filenames")

    def _validate_source_and_identity(self) -> None:
        source_ref = self.inputs.source_ref
        if not SHA1_RE.fullmatch(source_ref):
            self._abort("preflight", "preflight-failed", "source ref must be an explicit 40-hex commit", exit_code=2)
        version = self.inputs.version
        build = self.inputs.build
        if not SEMVER_RE.fullmatch(version):
            self._abort("preflight", "preflight-failed", "marketing version must be x.y.z", exit_code=2)
        if int(version.split(".", 1)[0]) < vb.RELEASE_MINIMUM_MAJOR:
            self._abort("preflight", "preflight-failed", "marketing version is below the release minimum", exit_code=2)
        if not BUILD_RE.fullmatch(build) or int(build) < vb.RELEASE_MINIMUM_BUILD:
            self._abort("preflight", "preflight-failed", "build number is below the release minimum", exit_code=2)
        tag = self.inputs.tag or (TAG_PREFIX + version)
        if tag != TAG_PREFIX + version:
            self._abort("preflight", "preflight-failed", "tag is not the canonical Bridge tag", exit_code=2)
        self.inputs.tag = tag
        self.report["tag"] = tag
        try:
            resolved = vb.resolve_ref(self.inputs.repo_root, source_ref)
            identity, commit = vb.load_identity_for_source(
                self.inputs.project, self.inputs.repo_root, source_ref
            )
            identity = vb.apply_identity_overrides(identity, version, build)
            identity = vb.validate_identity(identity, vb.RELEASE)
        except vb.IdentityError as error:
            self._abort("preflight", "preflight-failed", f"trusted project identity is invalid: {error}", exit_code=2)
        if resolved != source_ref or commit != source_ref:
            self._abort("preflight", "preflight-failed", "source ref did not resolve to the explicit commit", exit_code=2)
        try:
            provenance = pb.compute_provenance(
                self.inputs.repo_root, self.inputs.project.parent, vb.RELEASE, source_ref
            )
        except (RuntimeError, ValueError, vb.IdentityError) as error:
            self._abort("preflight", "preflight-failed", f"source provenance failed: {error}", exit_code=2)
        if not provenance.get("ok"):
            self._abort(
                "preflight",
                "preflight-failed",
                "source worktree does not match the frozen commit",
                exit_code=2,
            )
        if provenance.get("sourceRef") != source_ref:
            self._abort("preflight", "preflight-failed", "source provenance did not bind the explicit commit", exit_code=2)
        self.identity = identity
        self.provenance = provenance
        self.report["sourceTreeSHA256"] = provenance.get("sourceTreeSHA256")
        self.check("trusted-identity", True, json.dumps(identity.as_json(), sort_keys=True))
        self.check("source-provenance", True, str(provenance.get("sourceTreeSHA256")))

    def _validate_local_tag(self) -> None:
        checks = vp.check_tag(
            self.inputs.repo_root,
            self.inputs.tag,
            self.inputs.source_ref,
            self.inputs.version,
        )
        failed = [item["name"] for item in checks if not item["ok"]]
        if failed:
            self._abort(
                "preflight",
                "preflight-failed",
                "local immutable tag does not bind the explicit source commit",
                exit_code=2,
                failed=failed,
            )
        try:
            object_sha = git_text(
                self.inputs.repo_root,
                ["rev-parse", "--verify", f"refs/tags/{self.inputs.tag}"],
            ).strip()
            kind = git_text(self.inputs.repo_root, ["cat-file", "-t", object_sha]).strip()
            if kind == "tag":
                tag_text = git_text(self.inputs.repo_root, ["cat-file", "tag", object_sha])
                name_line = next(
                    (line.split(" ", 1)[1] for line in tag_text.splitlines() if line.startswith("tag ")),
                    "",
                )
                if name_line != self.inputs.tag:
                    self._abort("preflight", "preflight-failed", "local annotated tag object names a different tag", exit_code=2)
            self.local_tag_style = kind
        except GitHubError as error:
            self._abort("preflight", "preflight-failed", f"local tag could not be inspected: {error}", exit_code=2)
        self.check("local-tag-binding", True, f"{self.inputs.tag} -> {self.inputs.source_ref}")

    def _validate_summary_and_sidecar(self) -> None:
        try:
            sidecar_checks = vp.check_sidecar(self.inputs.ipa, self.inputs.sidecar)
            summary_checks = vp.check_public_summary(
                self.inputs.summary,
                self.identity,
                self.provenance,
                self.inputs.ipa,
            )
        except (OSError, ValueError) as error:
            self._abort("preflight", "preflight-failed", f"public asset validation failed: {error}", exit_code=2)
        failed = [
            item["name"]
            for item in list(sidecar_checks) + list(summary_checks)
            if not item["ok"]
        ]
        if failed:
            self._abort(
                "preflight",
                "preflight-failed",
                "public sidecar or summary does not match the artifact",
                exit_code=2,
                failed=failed,
            )
        try:
            payload = json.loads(self.inputs.summary.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            self._abort("preflight", "preflight-failed", f"public summary is unreadable: {error}", exit_code=2)
        if not isinstance(payload, dict):
            self._abort("preflight", "preflight-failed", "public summary is not a JSON object", exit_code=2)
        extra_summary = set(payload) - PUBLIC_SUMMARY_FIELDS
        if extra_summary:
            self._abort("preflight", "preflight-failed", "public summary contains unexpected fields", exit_code=2)
        for field, allowed in (
            ("artifact", PUBLIC_ARTIFACT_FIELDS),
            ("topology", PUBLIC_TOPOLOGY_FIELDS),
            ("verification", PUBLIC_VERIFICATION_FIELDS),
        ):
            nested = payload.get(field)
            if not isinstance(nested, dict) or set(nested) - allowed:
                self._abort("preflight", "preflight-failed", f"public summary {field} is not the minimal schema", exit_code=2)
        if not isinstance(payload.get("limitations"), list):
            self._abort("preflight", "preflight-failed", "public summary limitations are not a list", exit_code=2)
        if payload.get("sourceRef") != self.inputs.source_ref:
            self._abort("preflight", "preflight-failed", "public summary sourceRef does not match", exit_code=2)
        if payload.get("sourceTreeSHA256") != self.provenance.get("sourceTreeSHA256"):
            self._abort("preflight", "preflight-failed", "public summary source tree hash does not match", exit_code=2)
        artifact = payload.get("artifact") if isinstance(payload.get("artifact"), dict) else {}
        if artifact.get("filename") != self.inputs.ipa.name:
            self._abort("preflight", "preflight-failed", "public summary artifact filename does not match", exit_code=2)
        ipa_sha = sha256_file(self.inputs.ipa)
        if artifact.get("sha256") != ipa_sha:
            self._abort("preflight", "preflight-failed", "public summary IPA hash does not match", exit_code=2)
        if artifact.get("bytes") != self.inputs.ipa.stat().st_size:
            self._abort("preflight", "preflight-failed", "public summary IPA size does not match", exit_code=2)
        self.summary_payload = payload
        self.local_assets = {
            self.inputs.ipa.name: {
                "kind": "ipa",
                "path": self.inputs.ipa,
                "sha256": ipa_sha,
                "bytes": self.inputs.ipa.stat().st_size,
            },
            self.inputs.sidecar.name: {
                "kind": "sidecar",
                "path": self.inputs.sidecar,
                "sha256": sha256_file(self.inputs.sidecar),
                "bytes": self.inputs.sidecar.stat().st_size,
            },
            self.inputs.summary.name: {
                "kind": "summary",
                "path": self.inputs.summary,
                "sha256": sha256_file(self.inputs.summary),
                "bytes": self.inputs.summary.stat().st_size,
            },
        }
        self.report["assets"] = [
            {
                "name": name,
                "sha256": self.local_assets[name]["sha256"],
                "bytes": self.local_assets[name]["bytes"],
                "action": "candidate",
            }
            for name in (
                self.inputs.ipa.name,
                self.inputs.sidecar.name,
                self.inputs.summary.name,
            )
        ]
        self.check("public-sidecar", True, str(self.inputs.sidecar.name))
        self.check("public-summary", True, str(self.inputs.summary.name))

    def _validate_receipt(self) -> None:
        ipa_sha = self.local_assets[self.inputs.ipa.name]["sha256"]
        payload, digest, size = validate_receipt(
            self.inputs.receipt,
            source_ref=self.inputs.source_ref,
            source_tree_sha256=str(self.provenance.get("sourceTreeSHA256")),
            ipa_sha256=ipa_sha,
            version=self.inputs.version,
            build=self.inputs.build,
        )
        self.receipt_payload = payload
        self.receipt_sha256 = digest
        self.check("qualification-receipt", True, f"{size} bytes")

    def _validate_notes(self) -> None:
        text, digest, size = validate_notes(self.inputs.notes)
        if (self.receipt_payload or {}).get("checks", {}).get("rebootRecovery") == REBOOT_OWNER_ASSUMPTION:
            if REBOOT_ASSUMPTION_NOTE not in text:
                self._abort("preflight", "preflight-failed", "release notes must disclose the owner-assumed reboot recovery", exit_code=2)
        if any(value == CORE_SMOKE_NOT_REQUIRED for value in (self.receipt_payload or {}).get("checks", {}).values()):
            if CORE_SMOKE_SCOPE_NOTE not in text:
                self._abort("preflight", "preflight-failed", "release notes must disclose the owner-directed core smoke scope", exit_code=2)
        self.notes_text = text
        self.notes_sha256 = digest
        self.report["notes"] = {"sha256": digest, "bytes": size}
        self.check("release-notes-public", True, f"{size} bytes")

    def _validate_remote_tag(self, *, phase: str = "preflight") -> None:
        status = "preflight-failed" if phase == "preflight" else "publication-failed"
        exit_code = 2 if phase == "preflight" else 3
        try:
            ref = self.client.get_tag_ref(self.inputs.tag)
        except NotFound as error:
            self._abort(phase, status, "remote immutable tag does not exist", exit_code=exit_code)
        except GitHubError as error:
            self._abort(phase, status, f"remote tag lookup failed: {error}", exit_code=exit_code)
        if not isinstance(ref, dict) or ref.get("ref") != f"refs/tags/{self.inputs.tag}":
            self._abort(phase, status, "remote tag ref name is not canonical", exit_code=exit_code)
        object_ref = ref.get("object") if isinstance(ref.get("object"), dict) else {}
        object_type = object_ref.get("type")
        object_sha = object_ref.get("sha")
        if object_type not in {"commit", "tag"} or not isinstance(object_sha, str) or not SHA1_RE.fullmatch(object_sha):
            self._abort(phase, status, "remote tag ref has no usable object", exit_code=exit_code)
        if object_type == "commit":
            if object_sha != self.inputs.source_ref:
                self._abort(phase, status, "remote lightweight tag points to a different commit", exit_code=exit_code)
            self.remote_tag_style = "lightweight"
        else:
            try:
                tag_object = self.client.get_tag_object(object_sha)
            except NotFound as error:
                self._abort(phase, status, "remote annotated tag object is missing", exit_code=exit_code)
            except GitHubError as error:
                self._abort(phase, status, f"remote tag object lookup failed: {error}", exit_code=exit_code)
            if not isinstance(tag_object, dict):
                self._abort(phase, status, "remote annotated tag object is unreadable", exit_code=exit_code)
            if tag_object.get("sha") not in (None, object_sha):
                self._abort(phase, status, "remote tag object SHA does not match the ref", exit_code=exit_code)
            if tag_object.get("tag") != self.inputs.tag:
                self._abort(phase, status, "remote tag object names a different tag", exit_code=exit_code)
            inner = tag_object.get("object") if isinstance(tag_object.get("object"), dict) else {}
            if inner.get("type") != "commit" or inner.get("sha") != self.inputs.source_ref:
                self._abort(phase, status, "remote annotated tag does not peel to the explicit source commit", exit_code=exit_code)
            self.remote_tag_style = "annotated"
        self.check("remote-tag-binding", True, f"{self.remote_tag_style} -> {self.inputs.source_ref}")

    def _capture_latest(self) -> None:
        try:
            latest = self.client.get_latest_release()
        except NotFound as error:
            self._abort("preflight", "preflight-failed", "repository has no releases/latest to preserve", exit_code=2)
        except GitHubError as error:
            self._abort("preflight", "preflight-failed", f"releases/latest lookup failed: {error}", exit_code=2)
        if not isinstance(latest, dict):
            self._abort("preflight", "preflight-failed", "releases/latest payload is unreadable", exit_code=2)
        tag = latest.get("tag_name")
        if not isinstance(tag, str) or not tag:
            self._abort("preflight", "preflight-failed", "releases/latest has no tag_name", exit_code=2)
        if latest.get("draft") is True or latest.get("prerelease") is True:
            self._abort("preflight", "preflight-failed", "releases/latest is not stable", exit_code=2)
        if tag == self.inputs.tag:
            self._abort("preflight", "preflight-failed", "Bridge tag is already the repository latest release", exit_code=2)
        if self.inputs.expect_latest_tag is not None and tag != self.inputs.expect_latest_tag:
            self._abort("preflight", "preflight-failed", "releases/latest changed since the caller captured it", exit_code=2)
        self.latest_before = latest
        self.latest_before_tag = tag
        self.report["latest"]["beforeTag"] = tag
        self.check("latest-captured", True, tag)

    def _find_existing_release(self) -> None:
        try:
            release = self.client.find_release(self.inputs.tag)
        except GitHubError as error:
            self._abort("preflight", "preflight-failed", f"release lookup failed: {error}", exit_code=2)
        self.existing_release = release

    def _classify_existing_release(self) -> None:
        release = self.existing_release
        if release is None:
            self.existing_kind = None
            return
        if not isinstance(release, dict):
            self._abort("preflight", "preflight-failed", "existing release payload is unreadable", exit_code=2)
        if release.get("tag_name") != self.inputs.tag:
            self._abort("preflight", "preflight-failed", "existing release has a different tag", exit_code=2)
        draft = release.get("draft")
        prerelease = release.get("prerelease")
        if draft not in (True, False):
            self._abort("preflight", "preflight-failed", "existing release draft flag is unreadable", exit_code=2)
        if draft is True:
            self.existing_kind = "draft"
            if prerelease is not False:
                self._abort("preflight", "preflight-failed", "existing draft is marked prerelease", exit_code=2)
        elif draft is False:
            self.existing_kind = "published"
            if prerelease is not False:
                self._abort("preflight", "preflight-failed", "existing release is a prerelease", exit_code=2)
        target = release.get("target_commitish")
        if not isinstance(target, str) or not target:
            self._abort("preflight", "preflight-failed", "existing release has no source target", exit_code=2)
        # The immutable tag ref is the source authority. GitHub may echo the
        # default branch instead of the explicit commit in target_commitish
        # when the tag already exists, so only a conflicting explicit 40-hex
        # value is rejected here.
        if SHA1_RE.fullmatch(target) and target != self.inputs.source_ref:
            self._abort("preflight", "preflight-failed", "existing release targets a different source commit", exit_code=2)
        if release.get("name") != self._release_title():
            self._abort("preflight", "preflight-failed", "existing release name does not match the reviewed title", exit_code=2)
        if release.get("body") != self.notes_text:
            self._abort("preflight", "preflight-failed", "existing release notes differ from the reviewed notes file", exit_code=2)
        assets = release.get("assets")
        if not isinstance(assets, list):
            self._abort("preflight", "preflight-failed", "existing release assets are unreadable", exit_code=2)
        seen: dict[str, dict] = {}
        for asset in assets:
            if not isinstance(asset, dict):
                self._abort("preflight", "preflight-failed", "existing release has an unreadable asset", exit_code=2)
            name = asset.get("name")
            if not isinstance(name, str) or not name:
                self._abort("preflight", "preflight-failed", "existing release has an unnamed asset", exit_code=2)
            if name in seen:
                self._abort("preflight", "preflight-failed", "existing release has duplicate asset names", exit_code=2)
            if name not in self.local_assets:
                self._abort("preflight", "preflight-failed", "existing release has an unexpected extra asset", exit_code=2)
            if asset.get("state") != "uploaded":
                self._abort("preflight", "preflight-failed", "existing release has an incomplete asset upload", exit_code=2)
            if asset.get("size") != self.local_assets[name]["bytes"]:
                self._abort("preflight", "preflight-failed", "existing release asset size does not match", exit_code=2)
            digest = asset.get("digest")
            if digest is not None and digest != "sha256:" + self.local_assets[name]["sha256"]:
                self._abort("preflight", "preflight-failed", "existing release asset digest does not match", exit_code=2)
            if draft is False and not isinstance(asset.get("browser_download_url"), str):
                self._abort("preflight", "preflight-failed", "published asset has no browser download URL", exit_code=2)
            if draft is True and not isinstance(asset.get("url"), str):
                self._abort("preflight", "preflight-failed", "draft asset has no API URL", exit_code=2)
            seen[name] = asset
        if draft is False and set(seen) != set(self.local_assets):
            self._abort("preflight", "preflight-failed", "published release does not have exactly the three public assets", exit_code=2)
        if draft is True and not set(seen).issubset(set(self.local_assets)):
            self._abort("preflight", "preflight-failed", "draft release has a foreign asset", exit_code=2)
        self.check("existing-release", True, self.existing_kind)

    def _release_title(self) -> str:
        return f"Floe iOS Bridge {self.inputs.version}"

    def _release_url(self, release: dict) -> str:
        value = release.get("html_url")
        if isinstance(value, str) and value:
            return value
        return f"https://github.com/{REPO}/releases/tag/{urllib.parse.quote(self.inputs.tag, safe='')}"

    def _run_verifier_local(self) -> None:
        latest_path = self._latest_json(self.latest_before, "before")
        payload = self._run_verifier(
            ipa=self.inputs.ipa,
            sidecar=self.inputs.sidecar,
            summary=self.inputs.summary,
            latest_json=latest_path,
            expect_latest_tag=self.latest_before_tag,
            phase="preflight",
        )
        if not payload.get("ok"):
            self._abort(
                "preflight",
                "preflight-failed",
                "full public verifier rejected the local asset set",
                exit_code=2,
                failed=self._verifier_failed_names(payload),
            )
        self.check("full-public-verifier", True, "local asset set")

    def _run_verifier(
        self,
        *,
        ipa: Path,
        sidecar: Path,
        summary: Path,
        latest_json: Path,
        expect_latest_tag: str,
        phase: str,
    ) -> dict:
        try:
            payload = self.verifier(
                ipa=str(ipa),
                sidecar=str(sidecar),
                summary=str(summary),
                version=self.inputs.version,
                build=self.inputs.build,
                source_ref=self.inputs.source_ref,
                tag=self.inputs.tag,
                repo_root=str(self.inputs.repo_root),
                project=str(self.inputs.project),
                latest_json=str(latest_json),
                expect_latest_tag=str(expect_latest_tag),
                strict=True,
            )
        except Exception as error:
            self._abort(
                phase,
                "preflight-failed" if phase == "preflight" else "publication-failed",
                f"public verifier could not run: {error}",
                exit_code=2 if phase == "preflight" else 3,
            )
        if not isinstance(payload, dict):
            self._abort(
                phase,
                "preflight-failed" if phase == "preflight" else "publication-failed",
                "public verifier returned an unreadable report",
                exit_code=2 if phase == "preflight" else 3,
            )
        if payload.get("returncode") not in (None, 0):
            payload["ok"] = False
        for key, expected in (
            ("sourceRef", self.inputs.source_ref),
            ("tag", self.inputs.tag),
            ("version", self.inputs.version),
            ("buildNumber", self.inputs.build),
        ):
            if key in payload and payload.get(key) != expected:
                payload["ok"] = False
        tree = payload.get("sourceTreeSHA256")
        if tree is not None and tree != self.provenance.get("sourceTreeSHA256"):
            payload["ok"] = False
        self.verifier_reports.append(payload)
        return payload

    @staticmethod
    def _verifier_failed_names(payload: dict) -> list[str]:
        names = []
        checks = payload.get("checks")
        if isinstance(checks, list):
            for item in checks:
                if isinstance(item, dict) and not item.get("ok"):
                    names.append(str(item.get("name") or "verifier-check"))
        if not names:
            names.append("full-public-verifier")
        return sorted(set(names))

    def _verify_only(self) -> tuple[int, dict]:
        self.report["phase"] = "verified"
        if self.existing_kind == "published":
            self._readback_release_assets(self.existing_release, phase="published-readback")
            return self._finish_public_readback("already-published")
        self.report["ok"] = True
        self.report["complete"] = True
        self.report["status"] = "dry-run"
        if self.existing_kind == "draft":
            self.report["wouldResumeDraft"] = True
        else:
            self.report["wouldCreateDraft"] = True
        self._write_outputs()
        self._cleanup_temporaries()
        return 0, self._public_report()

    def _publish_flow(self) -> tuple[int, dict]:
        if self.existing_kind == "published":
            self._readback_release_assets(self.existing_release, phase="published-readback")
            return self._finish_public_readback("already-published")
        if self.existing_kind == "draft":
            release = self.existing_release
            action = "resumed-draft"
        else:
            release = self._create_draft()
            action = "created-draft"
            if release.get("draft") is False:
                # A reconcile after an uncertain create may discover that a
                # complete published release already exists.
                self.existing_release = release
                self.existing_kind = "published"
                self._classify_existing_release()
                self._readback_release_assets(release, phase="published-readback")
                return self._finish_public_readback("already-published")
        self._ensure_draft_assets(release)
        self._readback_release_assets(release, phase="draft-readback")
        # Re-bind the immutable remote tag immediately before the stable flip.
        self._validate_remote_tag(phase="publish")
        self._flip_draft(release)
        return self._finish_public_readback(action)

    def _create_draft(self) -> dict:
        self.report["phase"] = "create-draft"
        payload = {
            "tag_name": self.inputs.tag,
            "target_commitish": self.inputs.source_ref,
            "name": self._release_title(),
            "body": self.notes_text,
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
            "generate_release_notes": False,
        }
        try:
            release = self.client.create_release(payload)
        except AmbiguousWrite as error:
            release = self._reconcile_after_write("create", str(error))
        except GitHubError as error:
            if error.status in (409, 422) or (error.status is not None and error.status >= 500):
                release = self._reconcile_after_write("create", str(error))
            else:
                self._abort("create-draft", "publication-failed", f"release creation was rejected: {error}", exit_code=3)
        if not isinstance(release, dict) or not isinstance(release.get("id"), int):
            release = self._reconcile_after_write("create", "release response had no id")
        self._classify_existing_release_for(release, expected_draft=False)
        self.check("draft-created", release.get("draft") is True, str(release.get("id")))
        return release

    def _reconcile_after_write(self, operation: str, detail: str) -> dict:
        for attempt in range(1, 4):
            try:
                release = self.client.find_release(self.inputs.tag)
            except GitHubError as error:
                self._abort("reconcile", "uncertain", f"reconcile lookup failed: {error}", exit_code=3)
            if release is not None:
                if not isinstance(release, dict) or release.get("tag_name") != self.inputs.tag:
                    self._abort("reconcile", "publication-failed", "a conflicting release appeared during reconciliation", exit_code=3)
                self.check(f"{operation}-reconciled", True, f"attempt {attempt}")
                return release
            if attempt < 3:
                self.sleep_fn(attempt)
        self._abort(
            "reconcile",
            "uncertain",
            f"{operation} outcome is unknown and no matching release was observed; reconcile manually before retrying",
            exit_code=3,
        )

    def _classify_existing_release_for(self, release: dict, *, expected_draft: bool) -> None:
        saved = self.existing_release
        saved_kind = self.existing_kind
        self.existing_release = release
        try:
            self._classify_existing_release()
        finally:
            self.existing_release = saved
            self.existing_kind = saved_kind
        if expected_draft and release.get("draft") is not True:
            self._abort("create-draft", "publication-failed", "created release is not a draft", exit_code=3)

    def _refetch_release(self, release: dict) -> dict:
        release_id = release.get("id")
        if not isinstance(release_id, int):
            self._abort("release", "publication-failed", "release id is missing", exit_code=3)
        try:
            return self.client.get_release(release_id)
        except GitHubError as error:
            self._abort("release", "publication-failed", f"release readback failed: {error}", exit_code=3)

    def _ensure_draft_assets(self, release: dict) -> None:
        release = self._refetch_release(release)
        if release.get("draft") is not True:
            self._abort("upload", "publication-failed", "release is not a draft before upload", exit_code=3)
        for name in (self.inputs.ipa.name, self.inputs.sidecar.name, self.inputs.summary.name):
            release = self._refetch_release(release)
            assets = {item.get("name"): item for item in release.get("assets", []) if isinstance(item, dict)}
            if name in assets:
                self.local_assets[name]["action"] = "reused"
            else:
                self._upload_asset(release, name)
                release = self._wait_for_asset(release, name)
                if release is None:
                    self._abort("upload", "uncertain", f"uploaded asset {name} did not appear; reconcile before retrying", exit_code=3)
                self.local_assets[name]["action"] = "uploaded"
        release = self._refetch_release(release)
        self._classify_existing_release_for(release, expected_draft=True)

    def _wait_for_asset(self, release: dict, name: str) -> dict | None:
        for attempt in range(1, 4):
            release = self._refetch_release(release)
            assets = {item.get("name"): item for item in release.get("assets", []) if isinstance(item, dict)}
            if name in assets:
                return release
            if attempt < 3:
                self.sleep_fn(attempt)
        return None

    def _upload_asset(self, release: dict, name: str) -> None:
        self.report["phase"] = "upload"
        allowed = {self.inputs.ipa.name, self.inputs.sidecar.name, self.inputs.summary.name}
        if name not in allowed:
            self._abort("upload", "publication-failed", "refusing to upload a non-allowlisted asset", exit_code=3)
        source = self.local_assets[name]["path"]
        try:
            asset = self.client.upload_asset(release, name, source)
        except AmbiguousWrite:
            # The write may have been accepted; the caller reconciles with a
            # authenticated GET before retrying or failing.
            return
        except GitHubError as error:
            if error.status in (409, 422) or (error.status is not None and error.status >= 500):
                return
            self._abort("upload", "publication-failed", f"asset upload was rejected: {error}", exit_code=3)
        if not isinstance(asset, dict) or asset.get("name") != name:
            self._abort("upload", "uncertain", "asset upload returned an unreadable response", exit_code=3)

    def _readback_release_assets(self, release: dict, *, phase: str) -> None:
        self.report["phase"] = phase
        release = self._refetch_release(release)
        expected_draft = release.get("draft") is True
        self._classify_existing_release_for(release, expected_draft=expected_draft)
        assets = {item.get("name"): item for item in release.get("assets", []) if isinstance(item, dict)}
        directory = self._temp_dir("asset-readback-")
        for name in (self.inputs.ipa.name, self.inputs.sidecar.name, self.inputs.summary.name):
            asset = assets.get(name)
            if asset is None:
                self._abort(phase, "publication-failed", f"required asset {name} is missing", exit_code=3)
            destination = directory / name
            max_bytes = MAX_IPA_BYTES if name == self.inputs.ipa.name else (
                MAX_SUMMARY_BYTES if name == self.inputs.summary.name else MAX_SIDECAR_BYTES
            )
            try:
                size, digest = self.client.download_asset(asset, destination, max_bytes=max_bytes)
            except Exception as error:
                self._abort(phase, "publication-failed", f"authenticated readback of {name} failed: {error}", exit_code=3)
            local = self.local_assets[name]
            if size != local["bytes"] or digest != local["sha256"]:
                self._abort(phase, "publication-failed", f"authenticated readback of {name} does not match the local artifact", exit_code=3)
            if name != self.inputs.ipa.name:
                try:
                    if destination.read_bytes() != local["path"].read_bytes():
                        self._abort(phase, "publication-failed", f"{name} bytes differ from the local original", exit_code=3)
                except OSError as error:
                    self._abort(phase, "publication-failed", f"{name} readback is unreadable: {error}", exit_code=3)
            self.check(f"readback-{local['kind']}", True, digest)
        latest_path = self._latest_json(self.latest_before, "before")
        payload = self._run_verifier(
            ipa=directory / self.inputs.ipa.name,
            sidecar=directory / self.inputs.sidecar.name,
            summary=directory / self.inputs.summary.name,
            latest_json=latest_path,
            expect_latest_tag=self.latest_before_tag,
            phase=phase,
        )
        if not payload.get("ok"):
            self._abort(phase, "publication-failed", "full public verifier rejected the remote asset bytes", exit_code=3, failed=self._verifier_failed_names(payload))

    def _flip_draft(self, release: dict) -> None:
        self.report["phase"] = "publish"
        release = self._refetch_release(release)
        if release.get("draft") is False:
            # A concurrent run may have published the same matching draft
            # after our readback.  Treat that as an idempotent completion.
            self._classify_existing_release_for(release, expected_draft=False)
            self.check("published-before-flip", True, str(release.get("id")))
            self.report["release"] = {
                "id": release.get("id"),
                "url": self._release_url(release),
                "draft": False,
                "prerelease": False,
            }
            return
        if release.get("draft") is not True:
            self._abort("publish", "publication-failed", "release is not a draft before publication", exit_code=3)
        release_id = release.get("id")
        payload = {"draft": False, "prerelease": False, "make_latest": "false"}
        try:
            updated = self.client.update_release(int(release_id), payload)
        except AmbiguousWrite as error:
            updated = self._reconcile_flip(int(release_id), str(error))
        except GitHubError as error:
            if error.status is not None and error.status >= 500:
                updated = self._reconcile_flip(int(release_id), str(error))
            else:
                self._abort("publish", "publication-failed", f"draft publication was rejected: {error}", exit_code=3)
        if not isinstance(updated, dict) or updated.get("draft") is not False or updated.get("prerelease") is not False:
            updated = self._refetch_release_by_id(int(release_id))
        if updated.get("draft") is not False or updated.get("prerelease") is not False:
            self._abort("publish", "uncertain", "draft publication outcome is unknown; reconcile before retrying", exit_code=3)
        self.report["release"] = {
            "id": updated.get("id"),
            "url": self._release_url(updated),
            "draft": False,
            "prerelease": False,
        }
        self.check("stable-publication", True, str(updated.get("id")))

    def _reconcile_flip(self, release_id: int, detail: str) -> dict:
        for attempt in range(1, 4):
            release = self._refetch_release_by_id(release_id)
            if release.get("draft") is False and release.get("prerelease") is False:
                self.check("publish-reconciled", True, f"attempt {attempt}")
                return release
            if attempt < 3:
                self.sleep_fn(attempt)
        self._abort("publish", "uncertain", "draft publication was not observed after an ambiguous response", exit_code=3)

    def _refetch_release_by_id(self, release_id: int) -> dict:
        try:
            return self.client.get_release(release_id)
        except GitHubError as error:
            self._abort("publish", "uncertain", f"published release could not be read back: {error}", exit_code=3)

    def _get_published_release(self) -> dict:
        last_error = None
        for attempt in range(1, 4):
            try:
                release = self.client.get_release_by_tag(self.inputs.tag)
            except NotFound as error:
                last_error = error
                if attempt < 3:
                    self.sleep_fn(attempt)
                continue
            except GitHubError as error:
                self._abort("public-readback", "public-readback-failed", f"published release lookup failed: {error}", exit_code=4)
            if isinstance(release, dict) and release.get("draft") is False:
                return release
            last_error = GitHubError("release is not published")
            if attempt < 3:
                self.sleep_fn(attempt)
        self._abort("public-readback", "public-readback-failed", f"published release lookup failed: {last_error}", exit_code=4)

    def _finish_public_readback(self, action: str) -> tuple[int, dict]:
        self.report["phase"] = "public-readback"
        release = self._get_published_release()
        self._classify_existing_release_for(release, expected_draft=False)
        if release.get("draft") is not False or release.get("prerelease") is not False:
            self._abort("public-readback", "public-readback-failed", "release is not public and stable", exit_code=4)
        self.report["release"] = {
            "id": release.get("id"),
            "url": self._release_url(release),
            "draft": False,
            "prerelease": False,
        }
        self.report["assets"] = []
        assets = {item.get("name"): item for item in release.get("assets", []) if isinstance(item, dict)}
        directory = self._temp_dir("public-readback-")
        for name in (self.inputs.ipa.name, self.inputs.sidecar.name, self.inputs.summary.name):
            asset = assets.get(name)
            if asset is None:
                self._abort("public-readback", "public-readback-failed", f"public asset {name} is missing", exit_code=4)
            url = asset.get("browser_download_url")
            if not isinstance(url, str) or not url:
                self._abort("public-readback", "public-readback-failed", f"public asset {name} has no browser URL", exit_code=4)
            destination = directory / name
            max_bytes = MAX_IPA_BYTES if name == self.inputs.ipa.name else (
                MAX_SUMMARY_BYTES if name == self.inputs.summary.name else MAX_SIDECAR_BYTES
            )
            try:
                size, digest = self.downloader.fetch(
                    url,
                    destination,
                    expected_size=self.local_assets[name]["bytes"],
                    expected_sha256=self.local_assets[name]["sha256"],
                    max_bytes=max_bytes,
                )
            except Exception as error:
                self._abort("public-readback", "public-readback-failed", f"unauthenticated public readback of {name} failed: {error}", exit_code=4)
            if size != self.local_assets[name]["bytes"] or digest != self.local_assets[name]["sha256"]:
                self._abort("public-readback", "public-readback-failed", f"public asset {name} does not match the local artifact", exit_code=4)
            self.check(f"public-readback-{self.local_assets[name]['kind']}", True, digest)
            self.report["assets"].append({
                "name": name,
                "sha256": digest,
                "bytes": size,
                "action": self.local_assets[name].get("action", "verified"),
            })
        try:
            latest_after = self.client.get_latest_release()
        except GitHubError as error:
            self._abort("public-readback", "public-readback-failed", f"releases/latest readback failed: {error}", exit_code=4)
        if not isinstance(latest_after, dict):
            self._abort("public-readback", "public-readback-failed", "releases/latest readback is unreadable", exit_code=4)
        latest_after_tag = latest_after.get("tag_name")
        if latest_after_tag == self.inputs.tag:
            self._abort("public-readback", "public-readback-failed", "Bridge release became repository latest despite make_latest=false", exit_code=4)
        if not isinstance(latest_after_tag, str) or not latest_after_tag:
            self._abort("public-readback", "public-readback-failed", "releases/latest readback has no tag", exit_code=4)
        if latest_after.get("draft") is True or latest_after.get("prerelease") is True:
            self._abort("public-readback", "public-readback-failed", "releases/latest readback is not stable", exit_code=4)
        self.report["latest"]["afterTag"] = latest_after_tag
        self.report["latest"]["bridgeIsLatest"] = False
        concurrency = latest_after_tag != self.latest_before_tag
        self.report["latest"]["concurrencyReviewPending"] = concurrency
        latest_path = self._latest_json(latest_after, "after")
        payload = self._run_verifier(
            ipa=directory / self.inputs.ipa.name,
            sidecar=directory / self.inputs.sidecar.name,
            summary=directory / self.inputs.summary.name,
            latest_json=latest_path,
            expect_latest_tag=self.latest_before_tag,
            phase="public-readback",
        )
        if not payload.get("ok"):
            failed = self._verifier_failed_names(payload)
            if concurrency and set(failed).issubset({"latest-pointer-unchanged", "full-public-verifier"}):
                retry = self._run_verifier(
                    ipa=directory / self.inputs.ipa.name,
                    sidecar=directory / self.inputs.sidecar.name,
                    summary=directory / self.inputs.summary.name,
                    latest_json=latest_path,
                    expect_latest_tag=str(latest_after_tag),
                    phase="public-readback",
                )
                if retry.get("ok"):
                    payload = retry
                    self.check("latest-concurrency-review", True, "latest changed by another release")
                else:
                    self._abort("public-readback", "public-readback-failed", "public verifier rejected the published assets", exit_code=4, failed=self._verifier_failed_names(retry))
            else:
                self._abort("public-readback", "public-readback-failed", "public verifier rejected the published assets", exit_code=4, failed=failed)
        self.report["release"] = {
            "id": release.get("id"),
            "url": self._release_url(release),
            "draft": False,
            "prerelease": False,
        }
        self.report["phase"] = "complete"
        self.report["ok"] = True
        self.report["complete"] = True
        self.report["status"] = (
            "published-with-latest-concurrency-review"
            if self.report["latest"]["concurrencyReviewPending"]
            else ("already-published" if action == "already-published" else "published")
        )
        self._write_outputs()
        self._cleanup_temporaries()
        return 0, self._public_report()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify or publish the three canonical public Floe iOS Bridge release assets."
    )
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--sha256", dest="sidecar")
    parser.add_argument("--public-summary", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--qualification-receipt", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--source-ref", required=True, help="explicit immutable 40-hex source commit")
    parser.add_argument("--tag", help="must equal floe-ios-bridge-v<version>")
    parser.add_argument("--repo-root")
    parser.add_argument("--project")
    parser.add_argument("--expect-latest-tag")
    parser.add_argument("--report")
    parser.add_argument("--scratch-dir")
    parser.add_argument("--evidence-dir")
    parser.add_argument("--publish", action="store_true", help="perform the GitHub release transaction")
    parser.add_argument("--check", action="store_true", help="explicit read-only verification (default)")
    parser.add_argument("--json", action="store_true", help="print the report as JSON (default)")
    return parser


def main(argv: list | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.publish and args.check:
        parser.error("--publish and --check are mutually exclusive")
    repo_root = Path(args.repo_root).expanduser().resolve() if args.repo_root else Path(__file__).resolve().parents[2]
    project = Path(args.project).expanduser().resolve() if args.project else repo_root / "FloeIOSBridge" / "project.yml"
    version = args.version
    tag = args.tag or (TAG_PREFIX + version)
    scratch = Path(args.scratch_dir).expanduser().resolve() if args.scratch_dir else (
        repo_root / "Local" / "Scratch" / "ios-bridge-1.0-20261101" / "publication"
        if args.publish else None
    )
    evidence = Path(args.evidence_dir).expanduser().resolve() if args.evidence_dir else (
        repo_root / "Local" / "Private" / "ios-bridge-1.0-20261101" / "publication"
        if args.publish else None
    )
    inputs = PublicationInputs(
        ipa=Path(args.ipa).expanduser(),
        sidecar=Path(args.sha256).expanduser() if args.sha256 else None,
        summary=Path(args.public_summary).expanduser(),
        notes=Path(args.notes).expanduser(),
        receipt=Path(args.qualification_receipt).expanduser(),
        version=version,
        build=args.build,
        source_ref=args.source_ref,
        tag=tag,
        repo_root=repo_root,
        project=project,
        publish=bool(args.publish),
        report_path=Path(args.report).expanduser() if args.report else None,
        scratch_dir=scratch,
        evidence_dir=evidence,
        expect_latest_tag=args.expect_latest_tag,
    )
    publisher = Publisher(
        inputs,
        client=GitHubClient(),
        verifier=run_public_verifier,
        downloader=PublicDownloader(),
    )
    try:
        code, report = publisher.run()
    except Exception as error:  # fail closed, retain a private report for publish attempts
        publisher.report["phase"] = publisher.report.get("phase", "preflight")
        publisher.report["status"] = "internal-failed"
        publisher.report["ok"] = False
        publisher.report["complete"] = False
        publisher.report["error"] = public_message(f"{type(error).__name__}: {error}", publisher._private_roots())
        publisher._write_outputs()
        publisher._cleanup_temporaries()
        phase = publisher.report.get("phase")
        code = 4 if phase == "public-readback" else (
            3 if phase in {"create-draft", "upload", "draft-readback", "reconcile", "publish"} else 2
        )
        report = publisher._public_report()
    print(json.dumps(report, indent=2, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())

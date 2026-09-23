#!/usr/bin/env python3
"""Idempotent, resumable GitHub -> Gitee release mirror (metadata + assets).

GitHub Releases stays the trust-bearing primary. This tool publishes a
*verified copy* of one already-published GitHub release to the public Gitee
mirror used for China downloads:

  * release metadata (name, body + mirror notice, prerelease flag, target
    commit),
  * every release asset, byte-for-byte,
  * for assets that exceed Gitee's single-attachment limit, a deterministic
    shard set plus a manifest that pins every piece by size and digest.

Design constraints (matching the repository's mirror policy):

  * GitHub is the only source of bytes. Nothing is ever read back from Gitee
    as a source; the Gitee copy is only verified.
  * No full asset is ever held in RAM: downloads stream into temp files (or
    straight into shard files) with 1 MiB chunks while hashing.
  * A run is resumable: files already present on Gitee are verified by size
    and digest and are not uploaded again; only missing or mismatching files
    are transferred. Repeated runs converge and stay idempotent.
  * Failures are truthful. A partial mirror reports the exact per-file state
    and exits non-zero; it never claims success for bytes that were not
    verified.
  * The Gitee token is read from a file (``--gitee-token-file`` or the
    ``GITEE_TOKEN_FILE`` environment variable) and is sent only in an
    ``Authorization`` header. It is never printed, never placed in a URL, a
    filename or a summary.

Shard layout (app release assets, schema ``floe-release-shard-manifest/v1``)::

    <asset-name>.part-00.bin ... <asset-name>.part-NN.bin
    <asset-name>.parts.json

Guest-image component releases keep the App's pinned fallback contract:
schema ``floe-image-shard-manifest/v1`` in ``shard-manifest.json`` with
``part-00.bin`` ... pieces beside it (see FloeExecution
``LinuxGuestImageShardFetch``).

Exit codes: 0 = every planned file verified, 2 = configuration/preflight
failure, 3 = at least one asset failed or could not be verified, 130 =
interrupted.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import secrets
import shutil
import ssl
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from urllib.parse import quote, urljoin, urlsplit

DEFAULT_GITHUB_API = "https://api.github.com"
DEFAULT_GITEE_API = "https://gitee.com/api/v5"
DEFAULT_GITEE_WEB = "https://gitee.com"
DEFAULT_SHARD_BYTES = 64 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
JSON_BODY_LIMIT = 64 * 1024 * 1024
HTTP_RETRY_STATUS = (408, 425, 429, 500, 502, 503, 504)
REDIRECT_STATUS = (301, 302, 303, 307, 308)
MAX_REDIRECTS = 6

RELEASE_SHARD_SCHEMA = "floe-release-shard-manifest/v1"
IMAGE_SHARD_SCHEMA = "floe-image-shard-manifest/v1"
IMAGE_SHARD_ASSET = "shard-manifest.json"
MIRROR_MANIFEST_ASSET = "GITEE-MIRROR-MANIFEST.json"
MIRROR_SUMMARY_SCHEMA = "floe-gitee-release-mirror/v1"
TOOL_VERSION = "1"

# Files this tool owns on a mirrored release and may therefore replace or
# prune when their content no longer matches the GitHub source.
OWNED_PATTERN = re.compile(
    r"^(GITEE-MIRROR-MANIFEST\.json|shard-manifest\.json|.+\.parts\.json|.+\.part-\d{2}\.bin|part-\d{2}\.bin)$"
)
MIRROR_ASSET_PATTERN = re.compile(r"^(GITEE-MIRROR-MANIFEST\.json|.+\.parts\.json|shard-manifest\.json)$")

TAG_PATTERN = re.compile(r"^(v[0-9A-Za-z._-]{1,120}|floe-linux-guest-[0-9A-Za-z._-]{1,120})$")


class MirrorError(Exception):
    """Fatal, operator-facing failure (exit code 2)."""


class HttpError(MirrorError):
    def __init__(self, method, url, status, body):
        self.method = method
        self.url = url
        self.status = status
        self.body = body
        super().__init__("%s %s -> HTTP %s: %s" % (method, url, status, body[:500]))


class AssetFailure(Exception):
    """Per-asset failure that does not abort the remaining assets (exit 3)."""


class BudgetExceeded(Exception):
    """The run's time budget ended; remaining work is reported as deferred."""


def redact(text, secret):
    if not text:
        return text
    text = str(text)
    if secret:
        text = text.replace(secret, "***")
    return text


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def human_bytes(value):
    value = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            return "%.0f %s" % (value, unit) if unit == "B" else "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%.1f TiB" % value


class Log:
    def __init__(self, secret):
        self.secret = secret
        self.lines = []

    def emit(self, message):
        line = redact(message, self.secret)
        self.lines.append(line)
        print(line, flush=True)


class HttpResult:
    __slots__ = ("status", "headers", "body")

    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def header(self, name, default=None):
        return self.headers.get(name.lower(), default)


class ConcatReader:
    """File-like view over [bytes, file, bytes] used for streaming multipart."""

    def __init__(self, parts, on_bytes=None):
        self._parts = []
        self._consumed = 0
        self._on_bytes = on_bytes
        for kind, payload, length in parts:
            self._parts.append([kind, payload, length])
        self._index = 0

    def tell(self):
        return self._consumed

    def read(self, size=-1):
        if size is None or size < 0:
            size = CHUNK_BYTES
        if self._index >= len(self._parts):
            return b""
        kind, payload, remaining = self._parts[self._index]
        if kind == "bytes":
            chunk = payload[:remaining]
            self._parts[self._index][1] = payload[remaining:]
            self._parts[self._index][2] = 0
        else:
            chunk = payload.read(min(size, remaining))
            if not chunk and remaining > 0:
                raise MirrorError("upload source shrank while streaming multipart")
        consumed = len(chunk)
        self._consumed += consumed
        self._parts[self._index][2] -= consumed
        if self._parts[self._index][2] <= 0:
            if kind == "file":
                payload.close()
            self._index += 1
        if self._on_bytes is not None:
            self._on_bytes(self._consumed)
        return chunk


class FileSink:
    """Streaming writer that hashes while it writes a single file."""

    def __init__(self, path, algorithms=("sha256",)):
        self.path = path
        self.hashers = {name: hashlib.new(name) for name in algorithms}
        self.size = 0
        self._file = open(path, "wb")

    def write(self, chunk):
        self._file.write(chunk)
        self.size += len(chunk)
        for hasher in self.hashers.values():
            hasher.update(chunk)

    def close(self):
        self._file.close()
        return {
            "path": self.path,
            "bytes": self.size,
            "digests": {name: hasher.hexdigest() for name, hasher in self.hashers.items()},
        }


class ShardSink:
    """Streaming writer that splits one download into fixed-size shard files.

    The whole-source digest and each shard digest are computed in the same
    pass, so a large asset is never stored twice on disk.
    """

    def __init__(self, part_paths, shard_bytes, algorithms=("sha256",)):
        if not part_paths:
            raise ValueError("no shard paths")
        self.part_paths = list(part_paths)
        self.shard_bytes = int(shard_bytes)
        self.algorithms = tuple(algorithms)
        self.hashers = {name: hashlib.new(name) for name in algorithms}
        self.size = 0
        self.parts = []
        self._index = 0
        self._part_bytes = 0
        self._file = None
        self._part_hashers = None
        self._open_current()

    def _open_current(self):
        self._file = open(self.part_paths[self._index], "wb")
        self._part_hashers = {name: hashlib.new(name) for name in self.algorithms}
        self._part_bytes = 0

    def _close_current(self):
        if self._file is None:
            return
        self._file.close()
        self.parts.append(
            {
                "index": self._index,
                "path": self.part_paths[self._index],
                "bytes": self._part_bytes,
                "digests": {name: hasher.hexdigest() for name, hasher in self._part_hashers.items()},
            }
        )
        self._file = None

    def write(self, chunk):
        view = memoryview(chunk)
        while view:
            room = self.shard_bytes - self._part_bytes
            if room <= 0:
                if self._index + 1 >= len(self.part_paths):
                    raise MirrorError("shard plan is too small for the downloaded asset")
                self._close_current()
                self._index += 1
                self._open_current()
                continue
            piece = view[:room]
            self._file.write(piece)
            self._part_bytes += len(piece)
            self.size += len(piece)
            for hasher in self.hashers.values():
                hasher.update(piece)
            for hasher in self._part_hashers.values():
                hasher.update(piece)
            view = view[len(piece):]

    def close(self):
        self._close_current()
        return {
            "bytes": self.size,
            "digests": {name: hasher.hexdigest() for name, hasher in self.hashers.items()},
            "parts": self.parts,
        }


class HttpClient:
    def __init__(self, timeout=600, retries=3, user_agent="floe-gitee-release-mirror/1"):
        self.timeout = timeout
        self.retries = retries
        self.user_agent = user_agent
        self._ssl_context = ssl.create_default_context()

    # -- low level ---------------------------------------------------------

    def _connect(self, url, timeout):
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise MirrorError("unsupported URL scheme: %s" % url)
        if parts.scheme == "https":
            return http.client.HTTPSConnection(
                parts.hostname, parts.port, timeout=timeout, context=self._ssl_context
            )
        return http.client.HTTPConnection(parts.hostname, parts.port, timeout=timeout)

    @staticmethod
    def _target(url):
        parts = urlsplit(url)
        target = parts.path or "/"
        if parts.query:
            target += "?" + parts.query
        return target

    def _sleep(self, attempt, headers=None):
        delay = min(2.0 ** attempt, 30.0)
        if headers:
            retry_after = headers.get("retry-after")
            if retry_after:
                try:
                    delay = max(delay, min(float(retry_after), 120.0))
                except ValueError:
                    pass
        time.sleep(delay)

    def request(self, method, url, headers=None, body=None, content_length=None,
                timeout=None, retries=None, expect=(200, 201, 204), allow_404=False,
                max_body=JSON_BODY_LIMIT):
        timeout = timeout or self.timeout
        retries = self.retries if retries is None else retries
        headers = dict(headers or {})
        headers.setdefault("User-Agent", self.user_agent)
        if body is not None and content_length is None and not hasattr(body, "read"):
            content_length = len(body)
        if content_length is not None:
            headers.setdefault("Content-Length", str(content_length))
        attempt = 0
        while True:
            connection = None
            try:
                connection = self._connect(url, timeout)
                connection.request(method, self._target(url), body=body, headers=headers)
                response = connection.getresponse()
                payload = response.read(max_body + 1)
                result = HttpResult(response.status, {k.lower(): v for k, v in response.getheaders()}, payload)
                if len(payload) > max_body:
                    raise MirrorError("response body exceeds %d bytes for %s" % (max_body, url))
                if result.status in expect:
                    return result
                if allow_404 and result.status == 404:
                    return result
                if result.status in HTTP_RETRY_STATUS and attempt < retries:
                    self._sleep(attempt, result.headers)
                    attempt += 1
                    body = self._rewind(body)
                    continue
                raise HttpError(method, url, result.status, payload.decode("utf-8", "replace"))
            except (OSError, http.client.HTTPException, ssl.SSLError) as error:
                if attempt < retries:
                    self._sleep(attempt)
                    attempt += 1
                    body = self._rewind(body)
                    continue
                raise MirrorError("%s %s failed after %d attempts: %s" % (method, url, attempt + 1, error))
            finally:
                if connection is not None:
                    connection.close()

    @staticmethod
    def _rewind(body):
        """Retry of a body-carrying request needs a fresh reader."""
        if hasattr(body, "rewind"):
            body.rewind()
        elif hasattr(body, "read"):
            # A partially consumed stream cannot be replayed. Callers that own
            # stream retries (uploads) pass retries=0 and rebuild the reader.
            if getattr(body, "tell", lambda: 0)() > 0:
                raise MirrorError("request body stream cannot be replayed for retry")
        return body

    # -- streaming download ------------------------------------------------

    def download(self, url, headers, sink_factory, expected_size=None, retries=None, timeout=None,
                 progress=None, progress_interval=0):
        """Streams ``url`` into a fresh sink, returning the sink's result dict.

        Redirects are followed manually; the Authorization header is dropped
        when the redirect changes host (GitHub asset downloads redirect to a
        pre-signed object host). ``progress(received_bytes)`` is called at
        most every ``progress_interval`` bytes and once at the end.
        """
        timeout = timeout or self.timeout
        retries = self.retries if retries is None else retries
        attempt = 0
        while True:
            connection = None
            try:
                current = url
                request_headers = dict(headers or {})
                request_headers.setdefault("User-Agent", self.user_agent)
                response = None
                for _ in range(MAX_REDIRECTS):
                    previous_host = urlsplit(current).hostname
                    connection = self._connect(current, timeout)
                    connection.request("GET", self._target(current), headers=request_headers)
                    response = connection.getresponse()
                    if response.status in REDIRECT_STATUS:
                        location = response.getheader("Location")
                        response.read()
                        connection.close()
                        if not location:
                            raise MirrorError("redirect without Location from %s" % current)
                        current = urljoin(current, location)
                        if urlsplit(current).hostname != previous_host:
                            request_headers.pop("Authorization", None)
                        continue
                    break
                if response is None:
                    raise MirrorError("too many redirects while fetching %s" % url)
                if response.status != 200:
                    payload = response.read()[:1000]
                    connection.close()
                    if response.status in HTTP_RETRY_STATUS and attempt < retries:
                        self._sleep(attempt)
                        attempt += 1
                        continue
                    raise HttpError("GET", current, response.status, payload.decode("utf-8", "replace"))
                sink = sink_factory()
                received = 0
                next_report = progress_interval if progress_interval else 0
                try:
                    while True:
                        chunk = response.read(CHUNK_BYTES)
                        if not chunk:
                            break
                        sink.write(chunk)
                        received += len(chunk)
                        if progress is not None and next_report and received >= next_report:
                            progress(received)
                            next_report = received + progress_interval
                finally:
                    connection.close()
                    try:
                        sink.close()
                    except Exception:
                        pass
                if progress is not None:
                    progress(received)
                result = sink.close()
                if expected_size is not None and received != expected_size:
                    raise MirrorError(
                        "size mismatch for %s: expected %d bytes, received %d" % (url, expected_size, received)
                    )
                return result
            except (OSError, http.client.HTTPException, ssl.SSLError) as error:
                if connection is not None:
                    connection.close()
                if attempt < retries:
                    self._sleep(attempt)
                    attempt += 1
                    continue
                raise MirrorError("GET %s failed after %d attempts: %s" % (url, attempt + 1, error))


class GitHubClient:
    def __init__(self, client, api_base, repo, token):
        self.client = client
        self.api_base = api_base.rstrip("/")
        self.repo = repo
        self.token = token
        self.log = None

    def _headers(self, accept="application/vnd.github+json"):
        headers = {"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            headers["Authorization"] = "Bearer %s" % self.token
        return headers

    def _get(self, path, params=None, allow_404=False):
        url = "%s/repos/%s%s" % (self.api_base, self.repo, path)
        if params:
            url += "?" + "&".join("%s=%s" % (k, quote(str(v), safe="")) for k, v in params.items())
        result = self.client.request("GET", url, headers=self._headers(), allow_404=allow_404)
        if result.status == 404:
            return None
        return json.loads(result.body.decode("utf-8"))

    def release_by_tag(self, tag):
        return self._get("/releases/tags/%s" % quote(tag, safe=""))

    def latest_release(self):
        return self._get("/releases/latest")

    def release(self, release_id):
        return self._get("/releases/%s" % release_id)

    def assets(self, release_id):
        assets = []
        page = 1
        while True:
            batch = self._get("/releases/%s/assets" % release_id, {"per_page": 100, "page": page})
            if not batch:
                break
            assets.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        return assets

    def download_asset(self, asset_id, sink_factory, expected_size=None, progress=None, progress_interval=0):
        url = "%s/repos/%s/releases/assets/%s" % (self.api_base, self.repo, asset_id)
        headers = self._headers("application/octet-stream")
        return self.client.download(
            url, headers, sink_factory, expected_size=expected_size,
            progress=progress, progress_interval=progress_interval,
        )


class GiteeClient:
    def __init__(self, client, api_base, web_base, repo, token, log):
        self.client = client
        self.api_base = api_base.rstrip("/")
        self.web_base = web_base.rstrip("/")
        self.repo = repo
        self.token = token
        self.log = log

    def _headers(self):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "token %s" % self.token
        return headers

    def _url(self, path, params=None):
        url = "%s/repos/%s%s" % (self.api_base, self.repo, path)
        if params:
            url += "?" + "&".join("%s=%s" % (k, quote(str(v), safe="")) for k, v in params.items())
        return url

    def _json(self, method, path, payload=None, params=None, allow_404=False, expect=(200, 201)):
        body = None
        headers = self._headers()
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        result = self.client.request(
            method, self._url(path, params), headers=headers, body=body, expect=expect, allow_404=allow_404
        )
        if allow_404 and result.status == 404:
            return None
        if not result.body:
            return {}
        return json.loads(result.body.decode("utf-8"))

    def get(self, path, params=None, allow_404=False):
        return self._json("GET", path, params=params, allow_404=allow_404)

    def post(self, path, payload):
        return self._json("POST", path, payload=payload)

    def patch(self, path, payload):
        return self._json("PATCH", path, payload=payload)

    def delete(self, path):
        return self._json("DELETE", path, expect=(200, 204))

    def release_by_tag(self, tag):
        return self.get("/releases/tags/%s" % quote(tag, safe=""), allow_404=True)

    def release(self, release_id):
        return self.get("/releases/%s" % release_id)

    def create_release(self, tag, name, body, target_commitish, prerelease):
        payload = {
            "tag_name": tag,
            "name": name,
            "body": body,
            "target_commitish": target_commitish,
            "prerelease": bool(prerelease),
        }
        return self.post("/releases", payload)

    def update_release(self, release_id, payload):
        return self.patch("/releases/%s" % release_id, payload)

    def list_attach_files(self, release_id):
        files = []
        page = 1
        while True:
            batch = self.get("/releases/%s/attach_files" % release_id, {"per_page": 100, "page": page})
            if not batch:
                break
            files.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        return files

    def upload_attach_file(self, release_id, path, name, timeout=None, progress=None):
        url = self._url("/releases/%s/attach_files" % release_id)
        size = os.path.getsize(path)
        boundary = "----floe" + secrets.token_hex(16)
        safe_name = name.replace("\\", "_").replace('"', "_").replace("\r", "_").replace("\n", "_")
        prologue = (
            "--%s\r\n"
            'Content-Disposition: form-data; name="file"; filename="%s"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n" % (boundary, safe_name)
        ).encode("utf-8")
        epilogue = ("\r\n--%s--\r\n" % boundary).encode("utf-8")
        content_length = len(prologue) + size + len(epilogue)
        headers = self._headers()
        headers["Content-Type"] = "multipart/form-data; boundary=%s" % boundary
        headers["Content-Length"] = str(content_length)
        headers["User-Agent"] = self.client.user_agent
        attempt = 0
        while True:
            reader = ConcatReader(
                [("bytes", prologue, len(prologue)), ("file", open(path, "rb"), size), ("bytes", epilogue, len(epilogue))],
                on_bytes=progress,
            )
            try:
                result = self.client.request(
                    "POST", url, headers=headers, body=reader, content_length=content_length,
                    expect=(200, 201), timeout=timeout, retries=0,
                )
                payload = json.loads(result.body.decode("utf-8")) if result.body else {}
                if not payload.get("id"):
                    raise MirrorError("Gitee upload response had no attachment id")
                return payload
            except HttpError as error:
                if error.status in HTTP_RETRY_STATUS and attempt < self.client.retries:
                    self.client._sleep(attempt)
                    attempt += 1
                    continue
                raise
            except (MirrorError, OSError, http.client.HTTPException, ssl.SSLError) as error:
                if attempt < self.client.retries:
                    self.client._sleep(attempt)
                    attempt += 1
                    continue
                raise MirrorError("upload of %s failed after %d attempts: %s" % (name, attempt + 1, error))

    def delete_attach_file(self, release_id, attach_id):
        try:
            self.delete("/releases/%s/attach_files/%s" % (release_id, attach_id))
        except HttpError as error:
            if error.status != 404:
                raise

    def download_attach_file(self, release_id, attach_id, name, sink_factory, expected_size=None):
        url = "%s/%s/attach_files/%s/download/%s" % (self.web_base, self.repo, attach_id, quote(name, safe=""))
        return self.client.download(url, {"User-Agent": self.client.user_agent}, sink_factory, expected_size=expected_size)

    def download_release_asset(self, tag, name, sink_factory, expected_size=None):
        url = "%s/%s/releases/download/%s/%s" % (self.web_base, self.repo, quote(tag, safe=""), quote(name, safe=""))
        return self.client.download(url, {"User-Agent": self.client.user_agent}, sink_factory, expected_size=expected_size)


def parse_sha256(digest):
    if not digest:
        return None
    value = str(digest).strip()
    if value.startswith("sha256:"):
        value = value[len("sha256:"):]
    if re.fullmatch(r"[0-9a-fA-F]{64}", value):
        return value.lower()
    return None


def canonical_json(payload, volatile=()):
    clone = json.loads(json.dumps(payload))
    for key in volatile:
        clone.pop(key, None)
    return json.dumps(clone, sort_keys=True, separators=(",", ":"))


def content_fingerprint(payload):
    return hashlib.sha256(canonical_json(payload, volatile=("generatedAt", "run")).encode("utf-8")).hexdigest()


def shard_name(asset_name, index):
    return "%s.part-%02d.bin" % (asset_name, index)


def plan_parts(asset_size, shard_bytes):
    count = max(1, (asset_size + shard_bytes - 1) // shard_bytes)
    return count


def build_asset_plan(assets, shard_bytes, profile, include, exclude, log):
    include = set(include.split(",")) if include else None
    exclude = set(exclude.split(",")) if exclude else set()
    chosen = []
    for asset in assets:
        name = asset["name"]
        if include is not None and name not in include:
            continue
        if name in exclude:
            continue
        chosen.append(asset)
    entries = []
    guest_archive_used = False
    for asset in chosen:
        name = asset["name"]
        size = int(asset["size"])
        sharded = size > shard_bytes
        if profile == "guest-image" and not guest_archive_used and name.endswith(".zip") and name.startswith("floe-linux-guest-"):
            sharded = True
            guest_archive_used = True
        entry = {
            "asset": asset,
            "size": size,
            "sharded": sharded,
            "digest": parse_sha256(asset.get("digest")),
        }
        if sharded:
            if profile == "guest-image" and name.startswith("floe-linux-guest-"):
                entry["image_archive"] = True
                entry["part_names"] = ["part-%02d.bin" % i for i in range(plan_parts(size, shard_bytes))]
                entry["shard_manifest"] = IMAGE_SHARD_ASSET
            else:
                entry["part_names"] = [shard_name(name, i) for i in range(plan_parts(size, shard_bytes))]
                entry["shard_manifest"] = "%s.parts.json" % name
        entries.append(entry)
    if profile == "guest-image" and not guest_archive_used:
        log.emit("[plan] warning: no floe-linux-guest-*.zip archive found; guest-image shard contract not produced")
    return entries


def expected_layout(entries):
    """Every Gitee attachment name the plan expects to exist."""
    wanted = set()
    for entry in entries:
        if entry["sharded"]:
            wanted.add(entry["shard_manifest"])
            wanted.update(entry["part_names"])
        else:
            wanted.add(entry["asset"]["name"])
    wanted.add(MIRROR_MANIFEST_ASSET)
    return wanted


class MirrorRunner:
    def __init__(self, args):
        self.args = args
        self.token = self._read_token()
        self.log = Log(self.token)
        self.github = GitHubClient(HttpClient(), args.github_api, args.github_repo, os.environ.get("GITHUB_TOKEN", ""))
        self.gitee = GiteeClient(
            HttpClient(timeout=args.timeout, retries=args.retries), args.gitee_api, args.gitee_web, args.gitee_repo,
            self.token, self.log,
        )
        self.work_dir = None
        self.summary = None

    def _read_token(self):
        path = self.args.gitee_token_file or os.environ.get("GITEE_TOKEN_FILE")
        if not path:
            raise MirrorError("no Gitee token: pass --gitee-token-file or set GITEE_TOKEN_FILE")
        if not os.path.isfile(path):
            raise MirrorError("Gitee token file not found: %s" % path)
        with open(path, "r", encoding="utf-8") as handle:
            token = handle.read().strip()
        if not token:
            raise MirrorError("Gitee token file is empty")
        return token

    # -- helpers -----------------------------------------------------------

    def _progress(self, label, total):
        """Throttled progress reporter: at most one line per --progress-mib."""
        interval = max(int(self.args.progress_mib * 1024 * 1024), 1)
        start = time.monotonic()
        reported = {"value": -1}

        def report(received):
            if received < total and received - reported["value"] < interval:
                return
            if received == reported["value"]:
                return
            self._check_budget()
            reported["value"] = received
            elapsed = max(time.monotonic() - start, 0.001)
            self.log.emit(
                "[progress] %s %s/%s (%.2f MiB/s, %.0fs)"
                % (label, human_bytes(received), human_bytes(total), received / 1048576.0 / elapsed, elapsed)
            )

        return report

    def _check_budget(self):
        if self.deadline is not None and time.monotonic() > self.deadline:
            raise BudgetExceeded("time budget of %.0f minutes reached" % self.args.time_budget_minutes)

    def _attach_index(self, release_id):
        """name -> [attach file dicts] preserving Gitee's page order."""
        index = {}
        for item in self.gitee.list_attach_files(release_id):
            index.setdefault(item["name"], []).append(item)
        return index

    def _attach_item_by_id(self, release_id, attach_id):
        for item in self.gitee.list_attach_files(release_id):
            if str(item.get("id")) == str(attach_id):
                return item
        return None

    def _verify_gitee_file(self, release_id, item, expected_bytes, expected_digest, algos):
        """Downloads one Gitee attachment and checks size + digest. Returns dict."""
        name = item["name"]
        if int(item.get("size") or -1) != expected_bytes:
            return {"ok": False, "reason": "size %s != expected %d" % (item.get("size"), expected_bytes)}
        expected_digest = expected_digest or {}
        wanted = {key: value for key, value in expected_digest.items() if key in algos}
        mode = self.args.verify
        if mode == "none":
            return {"ok": True, "level": "unverified", "digests": {}}
        if mode == "size":
            return {"ok": True, "level": "size-only", "digests": {}}
        with tempfile.TemporaryDirectory(dir=self.work_dir, prefix="verify-") as tmp:
            target = os.path.join(tmp, "copy.bin")
            try:
                result = self.gitee.download_attach_file(
                    release_id, item["id"], name,
                    lambda: FileSink(target, algorithms=algos), expected_size=expected_bytes,
                )
            except MirrorError as error:
                return {"ok": False, "reason": "download failed: %s" % error}
            digests = result["digests"]
            for key, value in wanted.items():
                if digests.get(key) != value:
                    return {
                        "ok": False,
                        "level": "digest-mismatch",
                        "reason": "%s %s != GitHub %s" % (key, digests.get(key), value),
                        "digests": digests,
                    }
            level = "hash" if wanted else "size-only"
            return {"ok": True, "level": level, "digests": digests}

    def _ensure_asset_files(self, entry, release_id, index):
        """Ensures one GitHub asset is mirrored. Returns (status, detail)."""
        asset = entry["asset"]
        name = asset["name"]
        size = entry["size"]
        github_digest = entry["digest"]
        algos = ("sha256", "sha512") if (self.args.profile == "guest-image" and entry.get("image_archive")) else ("sha256",)

        if not entry["sharded"]:
            expected_digest = {"sha256": github_digest} if github_digest else {}
            existing = index.get(name, [])
            verified_item = None
            for item in existing:
                verdict = self._verify_gitee_file(release_id, item, size, expected_digest, algos)
                if verdict["ok"]:
                    verified_item = item
                    break
            if verified_item is not None:
                keep_id = verified_item["id"]
                for item in existing:
                    if item["id"] != keep_id:
                        self.log.emit("[dedupe] %s: removing extra Gitee copy id=%s" % (name, item["id"]))
                        self.gitee.delete_attach_file(release_id, item["id"])
                return "skipped" if len(existing) <= 1 else "deduped", {"verifiedFrom": "existing"}

            # Upload fresh bytes from GitHub.
            local = os.path.join(self.work_dir, "asset")
            os.makedirs(local, exist_ok=True)
            target = os.path.join(local, os.path.basename(name))
            sink = FileSink(target, algorithms=algos)
            self.log.emit("[download] %s (%s) from GitHub" % (name, human_bytes(size)))
            download_started = time.monotonic()
            result = self.github.download_asset(
                asset["id"], lambda: sink, expected_size=size,
                progress=self._progress("download " + name, size),
                progress_interval=max(int(self.args.progress_mib * 1024 * 1024), 1),
            )
            self.log.emit(
                "[download] %s done in %.0fs (%.2f MiB/s)"
                % (name, time.monotonic() - download_started, size / 1048576.0 / max(time.monotonic() - download_started, 0.001))
            )
            computed = result["digests"]
            if github_digest and computed.get("sha256") != github_digest:
                raise AssetFailure(
                    "GitHub download digest mismatch for %s: %s != declared %s"
                    % (name, computed.get("sha256"), github_digest)
                )
            for item in index.get(name, []):
                self.log.emit("[replace] %s: removing unverified Gitee copy id=%s" % (name, item["id"]))
                self.gitee.delete_attach_file(release_id, item["id"])
            self._check_budget()
            uploaded = self.gitee.upload_attach_file(
                release_id, target, name, progress=self._progress("upload " + name, size)
            )
            authoritative = self._attach_item_by_id(release_id, uploaded.get("id")) or uploaded
            expected = {"sha256": github_digest} if github_digest else {"sha256": computed.get("sha256")}
            verdict = self._verify_gitee_file(release_id, authoritative, size, expected, algos)
            if not verdict["ok"]:
                raise AssetFailure("%s uploaded but failed verification: %s" % (name, verdict.get("reason")))
            os.unlink(target)
            return "uploaded", {
                "attachId": uploaded.get("id"),
                "sha256": computed.get("sha256"),
                "sourceDigestVerified": bool(github_digest),
                "verification": verdict.get("level"),
            }

        # Sharded asset: create parts + manifest locally, then reconcile each.
        part_names = entry["part_names"]
        parts = []
        whole = None
        expected_parts, existing_manifest = self._parts_from_existing_manifest(release_id, index, entry)
        need_download = False
        for idx, part_name in enumerate(part_names):
            item = self._best_existing(index, part_name)
            expected = expected_parts.get(part_name) or {}
            if item is not None and int(item.get("size") or -1) == self._part_size(size, idx, len(part_names)):
                if expected.get("digests") and expected.get("bytes") == item.get("size"):
                    verdict = self._verify_gitee_file(release_id, item, expected["bytes"], expected["digests"], algos)
                    if verdict["ok"]:
                        parts.append({"index": idx, "name": part_name, "bytes": expected["bytes"],
                                      "digests": expected["digests"], "status": "skipped",
                                      "verification": verdict.get("level")})
                        continue
                need_download = True
                parts.append({"index": idx, "name": part_name, "bytes": int(item.get("size")), "digests": {}, "status": "pending"})
                continue
            need_download = True
            parts.append({"index": idx, "name": part_name, "bytes": None, "digests": {}, "status": "pending"})

        if need_download:
            self.log.emit("[download] %s (%s) from GitHub" % (name, human_bytes(size)))
            os.makedirs(self.work_dir, exist_ok=True)
            local_parts = [os.path.join(self.work_dir, "parts", part) for part in part_names]
            os.makedirs(os.path.dirname(local_parts[0]), exist_ok=True)
            sink = ShardSink(local_parts, self.args.shard_bytes, algorithms=algos)
            download_started = time.monotonic()
            result = self.github.download_asset(
                asset["id"], lambda: sink, expected_size=size,
                progress=self._progress("download " + name, size),
                progress_interval=max(int(self.args.progress_mib * 1024 * 1024), 1),
            )
            self.log.emit(
                "[download] %s done in %.0fs (%.2f MiB/s)"
                % (name, time.monotonic() - download_started, size / 1048576.0 / max(time.monotonic() - download_started, 0.001))
            )
            whole = result["digests"]
            if github_digest and whole.get("sha256") != github_digest:
                raise AssetFailure(
                    "GitHub download digest mismatch for %s: %s != declared %s"
                    % (name, whole.get("sha256"), github_digest)
                )
            for part in result["parts"]:
                idx = part["index"]
                expected = expected_parts.get(part_names[idx]) or {}
                expected_digest = (expected.get("digests") or {}).get("sha256")
                if expected_digest and expected_digest != part["digests"].get("sha256"):
                    raise AssetFailure(
                        "shard %s of %s changed under the same release tag; refusing to reuse"
                        % (part_names[idx], name)
                    )
                parts[idx]["bytes"] = part["bytes"]
                parts[idx]["digests"] = part["digests"]
        else:
            whole = dict(existing_manifest.get("digests") or {}) if existing_manifest else {}
            if github_digest:
                whole.setdefault("sha256", github_digest)
            whole.setdefault("sha256", "")
            if github_digest and whole.get("sha256") and whole["sha256"] != github_digest:
                raise AssetFailure(
                    "existing shard manifest for %s pins %s but GitHub now reports %s"
                    % (name, whole["sha256"], github_digest)
                )

        # Resolve existing copies (sequential), then upload the rest. Uploads
        # are independent streams; --upload-workers raises aggregate
        # throughput on high-latency cross-border paths where one connection
        # is window-limited.
        upload_queue = []
        for part in parts:
            if part["status"] == "skipped":
                continue
            part_name = part["name"]
            item = self._best_existing(index, part_name)
            if item is not None:
                if int(item.get("size") or -1) == part["bytes"]:
                    expected = {key: value for key, value in part["digests"].items() if key in algos}
                    verdict = self._verify_gitee_file(release_id, item, part["bytes"], expected, algos)
                    if verdict["ok"]:
                        part["status"] = "skipped"
                        part["verification"] = verdict.get("level")
                        continue
                    self.log.emit("[replace] %s: removing unverified copy id=%s" % (part_name, item["id"]))
                else:
                    self.log.emit("[replace] %s: removing size-mismatched copy id=%s" % (part_name, item["id"]))
                self.gitee.delete_attach_file(release_id, item["id"])
            upload_queue.append(part)

        def upload_part(part):
            self._check_budget()
            part_name = part["name"]
            local_path = os.path.join(self.work_dir, "parts", part_name)
            started = time.monotonic()
            uploaded = self.gitee.upload_attach_file(
                release_id, local_path, part_name,
                progress=self._progress("upload " + part_name, part["bytes"]),
            )
            elapsed = max(time.monotonic() - started, 0.001)
            self.log.emit(
                "[part] %s %s -> attach %s in %.0fs (%.2f MiB/s)"
                % (part_name, human_bytes(part["bytes"]), uploaded.get("id"), elapsed,
                   part["bytes"] / 1048576.0 / elapsed)
            )
            return part, uploaded

        part_errors = []
        outcomes = []
        if upload_queue:
            workers = max(1, min(int(self.args.upload_workers), len(upload_queue)))
            if workers > 1:
                self.log.emit("[upload] %d parts over %d parallel connections" % (len(upload_queue), workers))
            if workers == 1:
                for part in upload_queue:
                    try:
                        outcomes.append(upload_part(part))
                    except BudgetExceeded:
                        raise
                    except (MirrorError, OSError) as error:
                        part_errors.append("%s: %s" % (part["name"], error))
                        self.log.emit("[fail] part %s: %s" % (part["name"], error))
            else:
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    future_parts = {pool.submit(upload_part, part): part for part in upload_queue}
                    for future, part in future_parts.items():
                        try:
                            outcomes.append(future.result())
                        except BudgetExceeded:
                            raise
                        except (MirrorError, OSError) as error:
                            part_errors.append("%s: %s" % (part["name"], error))
                            self.log.emit("[fail] part %s: %s" % (part["name"], error))

        for part, uploaded in outcomes:
            self._check_budget()
            item = self._attach_item_by_id(release_id, uploaded.get("id")) or uploaded
            expected = {key: value for key, value in part["digests"].items() if key in algos}
            verdict = self._verify_gitee_file(release_id, item, part["bytes"], expected, algos)
            if not verdict["ok"]:
                part_errors.append("%s: %s" % (part["name"], verdict.get("reason")))
                self.log.emit("[fail] part %s verification: %s" % (part["name"], verdict.get("reason")))
                continue
            part["status"] = "uploaded"
            part["attachId"] = uploaded.get("id")
            part["verification"] = verdict.get("level")

        incomplete = [
            p["name"] for p in parts
            if p["status"] not in ("skipped", "uploaded") or not p.get("verification") or not p["digests"]
        ]
        if part_errors or incomplete:
            raise AssetFailure(
                "sharded asset %s is incomplete; %s"
                % (name, "; ".join((part_errors + ["missing verified parts: " + ", ".join(incomplete)]) if incomplete else part_errors))
            )

        # Manifest last: it is the contract the App uses.
        manifest = self._shard_manifest(entry, parts, whole)
        manifest_path = os.path.join(self.work_dir, "parts", entry["shard_manifest"])
        os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
        with open(manifest_path, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2, sort_keys=False)
            handle.write("\n")
        status, detail = self._sync_small_file(release_id, entry["shard_manifest"], manifest_path, index)
        return ("uploaded" if any(p["status"] == "uploaded" for p in parts) or status == "uploaded" else "skipped"), {
            "parts": parts,
            "whole": whole,
            "manifest": detail,
        }

    def _part_size(self, asset_size, index, count):
        remaining = asset_size - index * self.args.shard_bytes
        return min(self.args.shard_bytes, remaining)

    def _best_existing(self, index, name):
        items = index.get(name) or []
        return items[0] if items else None

    def _parts_from_existing_manifest(self, release_id, index, entry):
        """Reads the already published shard manifest, when it is usable.

        Returns ``(parts_by_name, manifest_info)``. An unusable or missing
        manifest returns ``({}, None)`` and the caller recomputes everything
        from the GitHub source.
        """
        items = index.get(entry["shard_manifest"]) or []
        if not items:
            return {}, None
        item = items[0]
        try:
            parsed_size = int(item.get("size") or -1)
            if parsed_size <= 0 or parsed_size > 4 * 1024 * 1024:
                return {}, None
            result = self.gitee.download_attach_file(
                release_id, item["id"], entry["shard_manifest"],
                lambda: _MemorySink(parsed_size), expected_size=parsed_size,
            )
            payload = json.loads(result["data"].decode("utf-8"))
        except (MirrorError, ValueError, KeyError) as error:
            self.log.emit("[manifest] %s unreadable (%s); will recompute" % (entry["shard_manifest"], error))
            return {}, None
        if payload.get("schema") != (IMAGE_SHARD_SCHEMA if entry.get("image_archive") else RELEASE_SHARD_SCHEMA):
            return {}, None
        expected_source = entry["asset"]["name"]
        if payload.get("sourceAsset") not in (None, expected_source) and payload.get("archive") != expected_source:
            return {}, None
        parts = {}
        if entry.get("image_archive"):
            for shard in payload.get("shards", []):
                parts[shard.get("name")] = {
                    "bytes": shard.get("bytes"),
                    "digests": {"sha512": shard.get("sha512")} if shard.get("sha512") else {},
                }
            info = {
                "digests": {"sha512": payload.get("archiveSHA512", "")},
                "bytes": payload.get("archiveBytes"),
                "schema": payload.get("schema"),
            }
        else:
            for part in payload.get("parts", []):
                parts[part.get("name")] = {
                    "bytes": part.get("bytes"),
                    "digests": {"sha256": part.get("sha256")} if part.get("sha256") else {},
                }
            info = {
                "digests": {"sha256": payload.get("sha256", "")},
                "bytes": payload.get("size"),
                "schema": payload.get("schema"),
            }
        return parts, info

    def _shard_manifest(self, entry, parts, whole):
        asset = entry["asset"]
        if entry.get("image_archive"):
            archive_name = asset["name"]
            image_id = archive_name
            if image_id.startswith("floe-linux-guest-"):
                image_id = image_id[len("floe-linux-guest-"):]
            if image_id.endswith(".zip"):
                image_id = image_id[: -len(".zip")]
            return {
                "schema": IMAGE_SHARD_SCHEMA,
                "imageID": image_id,
                "archive": archive_name,
                "archiveBytes": entry["size"],
                "archiveSHA512": whole.get("sha512", ""),
                "shards": [
                    {
                        "index": part["index"],
                        "name": part["name"],
                        "bytes": part["bytes"],
                        "sha512": part["digests"].get("sha512", ""),
                    }
                    for part in parts
                ],
            }
        return {
            "schema": RELEASE_SHARD_SCHEMA,
            "sourceRepo": self.args.github_repo,
            "sourceReleaseTag": self.args.tag,
            "sourceAsset": asset["name"],
            "sourceAssetURL": asset.get("browser_download_url"),
            "size": entry["size"],
            "sha256": whole.get("sha256", "") or entry["digest"] or "",
            "shardBytes": self.args.shard_bytes,
            "parts": [
                {
                    "index": part["index"],
                    "name": part["name"],
                    "bytes": part["bytes"],
                    "sha256": part["digests"].get("sha256", ""),
                }
                for part in parts
            ],
        }

    def _sync_small_file(self, release_id, name, path, index):
        """Idempotently uploads a generated manifest, replacing stale copies."""
        payload = open(path, "rb").read()
        digest = hashlib.sha256(payload).hexdigest()
        size = len(payload)
        existing = index.get(name) or []
        for item in existing:
            if int(item.get("size") or -1) == size:
                verdict = self._verify_gitee_file(release_id, item, size, {"sha256": digest}, ("sha256",))
                if verdict["ok"]:
                    keep_id = item["id"]
                    for other in existing:
                        if other["id"] != keep_id:
                            self.log.emit("[dedupe] %s: removing extra copy id=%s" % (name, other["id"]))
                            self.gitee.delete_attach_file(release_id, other["id"])
                    return "skipped", {"attachId": keep_id, "sha256": digest}
        for item in existing:
            self.log.emit("[replace] %s: removing stale copy id=%s" % (name, item["id"]))
            self.gitee.delete_attach_file(release_id, item["id"])
        uploaded = self.gitee.upload_attach_file(release_id, path, name)
        authoritative = self._attach_item_by_id(release_id, uploaded.get("id")) or uploaded
        verdict = self._verify_gitee_file(release_id, authoritative, size, {"sha256": digest}, ("sha256",))
        if not verdict["ok"]:
            raise AssetFailure("%s failed verification: %s" % (name, verdict.get("reason")))
        return "uploaded", {"attachId": uploaded.get("id"), "sha256": digest}

    # -- release metadata --------------------------------------------------

    def _mirror_body(self, release, release_url):
        body = (release.get("body") or "").rstrip()
        notice = (
            "\n\n---\n\n**Gitee 中国大陆镜像（GitHub 为信任主源）。** 本镜像的发行说明与资产"
            "由 GitHub Release 同步生成，资产与 GitHub 逐字节相同（大小与 SHA-256 见 "
            "`%s`；超过 Gitee 单附件上限的资产按固定分片发布，分片清单见对应 "
            "`*.parts.json`）。GitHub 主源：%s\n\n"
            "**Gitee China mirror (GitHub is the trust-bearing primary).** Metadata and "
            "assets are synced from the GitHub release named above; assets are byte-identical "
            "to GitHub (sizes and SHA-256 in `%s`). Assets above Gitee's single-attachment "
            "limit are published as fixed-size shards described by the matching "
            "`*.parts.json`. Source release: %s"
            % (MIRROR_MANIFEST_ASSET, release_url, MIRROR_MANIFEST_ASSET, release_url)
        )
        return body + notice

    def _ensure_release(self, release, release_url):
        tag = release["tag_name"]
        name = release.get("name") or tag
        body = self._mirror_body(release, release_url)
        target = self.args.ref_sha or release.get("target_commitish") or ""
        existing = self.gitee.release_by_tag(tag)
        if existing is None:
            self.log.emit("[release] creating Gitee release for %s" % tag)
            if self.args.dry_run:
                return {"status": "planned", "releaseId": None, "created": True}, None
            created = self.gitee.create_release(
                tag, name, body, target, bool(release.get("prerelease", True))
            )
            existing = self.gitee.release_by_tag(tag)
            if existing is None:
                existing = created
            return {"status": "created", "releaseId": existing.get("id")}, existing
        updates = {}
        if (existing.get("name") or "") != name:
            updates["name"] = name
        if (existing.get("body") or "").strip() != body.strip():
            updates["body"] = body
        if bool(existing.get("prerelease")) != bool(release.get("prerelease", True)):
            updates["prerelease"] = bool(release.get("prerelease", True))
        # Gitee's release PATCH endpoint does not document target_commitish, so
        # the target commit is only set when the release is created.
        if not updates:
            return {"status": "unchanged", "releaseId": existing.get("id")}, existing
        self.log.emit("[release] updating Gitee release %s: %s" % (tag, ", ".join(sorted(updates))))
        if self.args.dry_run:
            return {"status": "planned-update", "releaseId": existing.get("id"), "updates": sorted(updates)}, existing
        self.gitee.update_release(existing["id"], updates)
        return {"status": "updated", "releaseId": existing.get("id"), "updates": sorted(updates)}, existing

    # -- main flow ---------------------------------------------------------

    def run(self):
        args = self.args
        if not TAG_PATTERN.match(args.tag):
            raise MirrorError("refusing suspicious tag %r" % args.tag)
        if args.shard_mib is not None:
            args.shard_bytes = int(float(args.shard_mib) * 1024 * 1024)
        if args.shard_bytes < 1024:
            raise MirrorError("shard size must be at least 1 KiB")
        profile = args.profile
        if profile == "auto":
            profile = "guest-image" if args.tag.startswith("floe-linux-guest-") else "app"
        args.profile = profile

        free = shutil.disk_usage(os.path.abspath(args.work_root or tempfile.gettempdir()))
        free_mib = free.free // (1024 * 1024)
        if free_mib < args.min_free_mib:
            raise MirrorError(
                "only %d MiB free under %s; --min-free-mib is %d" % (free_mib, args.work_root or tempfile.gettempdir(), args.min_free_mib)
            )

        release = self.github.release_by_tag(args.tag)
        if release is None:
            raise MirrorError("GitHub release tag %s was not found in %s" % (args.tag, args.github_repo))
        if release.get("draft"):
            raise MirrorError("refusing to mirror draft release %s" % args.tag)
        assets = self.github.assets(release["id"])
        release_url = release.get("html_url") or "https://github.com/%s/releases/tag/%s" % (args.github_repo, args.tag)

        entries = build_asset_plan(assets, args.shard_bytes, profile, args.include_assets, args.exclude_assets, self.log)
        wanted = expected_layout(entries)
        self.log.emit(
            "[plan] %s: %d assets, %d Gitee attachments planned, shard size %s"
            % (args.tag, len(entries), len(wanted), human_bytes(args.shard_bytes))
        )
        for entry in entries:
            kind = "sharded" if entry["sharded"] else "verbatim"
            self.log.emit(
                "[plan]   %-60s %10s %s%s"
                % (
                    entry["asset"]["name"],
                    human_bytes(entry["size"]),
                    kind,
                    "" if entry["digest"] else " (no GitHub digest)",
                )
            )

        self.summary = {
            "schema": MIRROR_SUMMARY_SCHEMA,
            "toolVersion": TOOL_VERSION,
            "generatedAt": utc_now(),
            "dryRun": bool(args.dry_run),
            "source": {
                "repo": args.github_repo,
                "tag": args.tag,
                "releaseId": release["id"],
                "releaseURL": release_url,
                "prerelease": bool(release.get("prerelease")),
                "publishedAt": release.get("published_at"),
                "assetCount": len(assets),
            },
            "gitee": {"repo": args.gitee_repo, "releaseId": None, "releaseURL": None},
            "gates": {
                "refs": {
                    "tag": args.tag,
                    "expectedSha": args.ref_sha or None,
                    "refVerifiedBeforeRun": bool(args.ref_verified),
                },
                "releaseMetadata": {"status": "pending"},
                "assets": {
                    "total": len(entries),
                    "filesPlanned": len(wanted),
                    "verified": 0,
                    "uploaded": 0,
                    "skipped": 0,
                    "failed": 0,
                    "deferred": 0,
                },
            },
            "limits": {
                "shardBytes": args.shard_bytes,
                "shardMiB": round(args.shard_bytes / (1024 * 1024), 3),
                "githubDigestsAvailable": sum(1 for asset in assets if parse_sha256(asset.get("digest"))),
            },
            "assets": [],
        }

        self.deadline = None
        if args.time_budget_minutes and args.time_budget_minutes > 0:
            self.deadline = time.monotonic() + args.time_budget_minutes * 60.0
            self.log.emit("[budget] deferring new transfers after %.0f minutes" % args.time_budget_minutes)

        self.work_dir = tempfile.mkdtemp(prefix="gitee-mirror-", dir=args.work_root)
        try:
            metadata, gitee_release = self._ensure_release(release, release_url)
            self.summary["gates"]["releaseMetadata"] = metadata
            if gitee_release is None:
                # dry-run create path: no attachments can be reconciled yet.
                for entry in entries:
                    self.summary["assets"].append(self._asset_summary(entry, "planned", "release would be created"))
                self.summary["gates"]["assets"]["skipped"] = len(entries)
                self.summary["ok"] = True
                return self._finish(ok=True)
            release_id = gitee_release["id"]
            self.summary["gitee"]["releaseId"] = release_id
            self.summary["gitee"]["releaseURL"] = "https://gitee.com/%s/releases/tag/%s" % (args.gitee_repo, args.tag)

            index = self._attach_index(release_id)
            failures = 0
            deferred = 0
            for entry in entries:
                name = entry["asset"]["name"]
                try:
                    if self.deadline is not None and time.monotonic() > self.deadline:
                        raise BudgetExceeded("time budget reached before starting %s" % name)
                    if args.dry_run:
                        state = "present" if self._entry_present(entry, index) else "missing"
                        self.summary["assets"].append(self._asset_summary(entry, "planned-" + state, None))
                        self.summary["gates"]["assets"]["skipped" if state == "present" else "uploaded"] += 1
                        continue
                    status, detail = self._ensure_asset_files(entry, release_id, index)
                    self.summary["assets"].append(self._asset_summary(entry, status, detail))
                    if status == "uploaded":
                        self.summary["gates"]["assets"]["uploaded"] += 1
                    else:
                        self.summary["gates"]["assets"]["skipped"] += 1
                    self.summary["gates"]["assets"]["verified"] += 1
                    index = self._attach_index(release_id)
                except BudgetExceeded as error:
                    deferred += 1
                    self.summary["gates"]["assets"]["deferred"] += 1
                    self.summary["assets"].append(self._asset_summary(entry, "deferred", str(error)))
                    self.log.emit("[deferred] %s: %s (re-run resumes)" % (name, error))
                except (AssetFailure, MirrorError) as error:
                    failures += 1
                    self.summary["gates"]["assets"]["failed"] += 1
                    detail = str(error)
                    if isinstance(error, HttpError) and error.status in (400, 413, 422):
                        detail += " (if Gitee rejected an oversized attachment, lower --shard-mib)"
                    self.summary["assets"].append(self._asset_summary(entry, "failed", detail))
                    self.log.emit("[fail] %s: %s" % (name, detail))

            if not args.dry_run and args.write_manifest:
                self._write_mirror_manifest(release_id, entries)

            if args.prune_unknown:
                self._prune_unknown(release_id, index, wanted)

            return self._finish(ok=failures == 0 and deferred == 0)
        finally:
            if not args.keep_work and self.work_dir:
                shutil.rmtree(self.work_dir, ignore_errors=True)

    def _entry_present(self, entry, index):
        if entry["sharded"]:
            names = list(entry["part_names"]) + [entry["shard_manifest"]]
            return all(index.get(name) for name in names)
        return bool(index.get(entry["asset"]["name"]))

    def _asset_summary(self, entry, status, detail):
        digest = entry["digest"]
        if isinstance(detail, dict):
            if detail.get("sha256"):
                digest = detail["sha256"]
            elif isinstance(detail.get("whole"), dict) and detail["whole"].get("sha256"):
                digest = detail["whole"]["sha256"]
        return {
            "name": entry["asset"]["name"],
            "size": entry["size"],
            "sha256": digest,
            "sharded": entry["sharded"],
            "giteeNames": ([entry["shard_manifest"]] + list(entry["part_names"])) if entry["sharded"] else [entry["asset"]["name"]],
            "status": status,
            "detail": detail,
        }

    def _write_mirror_manifest(self, release_id, entries):
        payload = {
            "schema": MIRROR_SUMMARY_SCHEMA,
            "sourceRepo": self.args.github_repo,
            "sourceTag": self.args.tag,
            "sourceReleaseURL": "https://github.com/%s/releases/tag/%s" % (self.args.github_repo, self.args.tag),
            "sourcePublishedAt": self.summary["source"].get("publishedAt"),
            "giteeRepo": self.args.gitee_repo,
            "policy": "GitHub is the trust-bearing primary; assets are byte-identical copies",
            # Stable mapping only: no per-run status, so an unchanged mapping
            # keeps the same bytes (and the same fingerprint) across runs.
            "assets": [
                {
                    "name": item["name"],
                    "size": item["size"],
                    "sha256": item["sha256"],
                    "giteeNames": item["giteeNames"],
                    "sharded": item["sharded"],
                }
                for item in self.summary["assets"]
            ],
        }
        payload["contentFingerprint"] = content_fingerprint(payload)
        path = os.path.join(self.work_dir, MIRROR_MANIFEST_ASSET)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        index = self._attach_index(release_id) if release_id else {}
        status, detail = self._sync_small_file(release_id, MIRROR_MANIFEST_ASSET, path, index)
        self.summary["gates"]["releaseMetadata"]["mirrorManifest"] = {
            "status": status,
            "fingerprint": payload["contentFingerprint"],
        }
        self.log.emit("[manifest] %s %s (%s)" % (MIRROR_MANIFEST_ASSET, status, payload["contentFingerprint"][:16]))
        if release_id:
            attach_id = (detail or {}).get("attachId")
            item = self._attach_item_by_id(release_id, attach_id) if attach_id else None
            if item is None:
                matches = self._attach_index(release_id).get(MIRROR_MANIFEST_ASSET) or []
                item = matches[0] if matches else None
            if item is None:
                raise AssetFailure("mirror manifest is not visible on Gitee after sync")
            result = self.gitee.download_attach_file(
                release_id, item["id"], MIRROR_MANIFEST_ASSET,
                lambda: _MemorySink(int(item.get("size") or 0)),
                expected_size=int(item.get("size") or 0),
            )
            readback = json.loads(result["data"].decode("utf-8"))
            if readback.get("contentFingerprint") != payload["contentFingerprint"]:
                raise AssetFailure("mirror manifest read-back mismatch")

    def _prune_unknown(self, release_id, index, wanted):
        for name, items in index.items():
            if name in wanted:
                continue
            if not OWNED_PATTERN.match(name):
                continue
            for item in items:
                self.log.emit("[prune] removing owned-but-unplanned %s id=%s" % (name, item["id"]))
                self.gitee.delete_attach_file(release_id, item["id"])

    def _finish(self, ok):
        gates = self.summary["gates"]["assets"]
        final_ok = bool(ok) and gates["failed"] == 0 and gates.get("deferred", 0) == 0
        self.summary["ok"] = final_ok
        self.log.emit(
            "[done] %s verified=%d uploaded=%d skipped=%d failed=%d deferred=%d exit=%d"
            % (
                self.args.tag,
                gates["verified"],
                gates["uploaded"],
                gates["skipped"],
                gates["failed"],
                gates.get("deferred", 0),
                0 if final_ok else 3,
            )
        )
        if self.args.summary_json:
            with open(self.args.summary_json, "w", encoding="utf-8") as handle:
                json.dump(self.summary, handle, indent=2, sort_keys=True)
                handle.write("\n")
        return 0 if final_ok else 3


class _MemorySink:
    """Small response sink for manifest read-back (bounded by the caller)."""

    def __init__(self, expected):
        self.expected = expected
        self.data = b""

    def write(self, chunk):
        self.data += chunk
        if len(self.data) > max(self.expected + 4096, 4096):
            raise MirrorError("manifest read-back exceeded expected size")

    def close(self):
        return {"bytes": len(self.data), "digests": {}, "data": self.data}


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Mirror one GitHub release (metadata + assets) to Gitee")
    parser.add_argument("--tag", required=True, help="published GitHub release tag to mirror")
    parser.add_argument("--github-repo", default="JiangNanGenius/floe-agent")
    parser.add_argument("--gitee-repo", default="JiangNanGenius/floe-agent")
    parser.add_argument("--github-api", default=DEFAULT_GITHUB_API)
    parser.add_argument("--gitee-api", default=DEFAULT_GITEE_API)
    parser.add_argument("--gitee-web", default=DEFAULT_GITEE_WEB)
    parser.add_argument("--gitee-token-file", default=None)
    parser.add_argument("--profile", choices=("auto", "app", "guest-image"), default="auto")
    parser.add_argument("--shard-mib", default=None, help="maximum Gitee attachment size in MiB (default 64)")
    parser.add_argument("--shard-bytes", type=int, default=None, help="exact shard size in bytes (overrides --shard-mib)")
    parser.add_argument("--include-assets", default="", help="comma-separated asset names to mirror (default all)")
    parser.add_argument("--exclude-assets", default="", help="comma-separated asset names to skip")
    parser.add_argument("--verify", choices=("hash", "size", "none"), default="hash",
                        help="verification of files already on Gitee (hash downloads and compares digests)")
    parser.add_argument("--dry-run", action="store_true", help="plan only; performs no Gitee mutation")
    parser.add_argument("--write-manifest", action="store_true", default=True,
                        help="publish MIRROR-MANIFEST.json (default on)")
    parser.add_argument("--no-write-manifest", dest="write_manifest", action="store_false")
    parser.add_argument("--prune-unknown", action="store_true",
                        help="delete owned-but-unplanned attachments from this release only")
    parser.add_argument("--keep-work", action="store_true", help="keep the temp work directory")
    parser.add_argument("--work-root", default=None, help="directory for temp files (default system temp)")
    parser.add_argument("--min-free-mib", type=int, default=2048)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--progress-mib", type=float, default=64.0,
                        help="emit one progress line per N MiB transferred (default 64)")
    parser.add_argument("--upload-workers", type=int, default=1,
                        help="parallel upload connections for sharded assets (default 1)")
    parser.add_argument("--time-budget-minutes", type=float, default=0.0,
                        help="stop starting new transfers after N minutes and report deferred work "
                             "(0 = no budget; a re-run resumes)")
    parser.add_argument("--ref-sha", default=None, help="commit SHA the mirrored tag must point at (ref gate)")
    parser.add_argument("--ref-verified", default="", help="set by the workflow after git ls-remote confirmed the ref")
    parser.add_argument("--summary-json", default=None)
    args = parser.parse_args(argv)
    if args.shard_bytes is None:
        if args.shard_mib is None:
            args.shard_bytes = DEFAULT_SHARD_BYTES
        else:
            args.shard_bytes = int(float(args.shard_mib) * 1024 * 1024)
    args.shard_bytes = int(args.shard_bytes)
    return args


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    runner = None
    exit_code = 2
    try:
        runner = MirrorRunner(args)
        exit_code = runner.run()
        return exit_code
    except MirrorError as error:
        if runner is not None:
            runner.log.emit("[fatal] %s" % error)
        else:
            print("[fatal] %s" % error, file=sys.stderr, flush=True)
        if runner is not None and runner.args.summary_json:
            payload = runner.summary or {"schema": MIRROR_SUMMARY_SCHEMA, "ok": False}
            payload["ok"] = False
            payload["fatal"] = str(redact(str(error), runner.token))
            try:
                with open(runner.args.summary_json, "w", encoding="utf-8") as handle:
                    json.dump(payload, handle, indent=2, sort_keys=True)
                    handle.write("\n")
            except OSError:
                pass
        return 2
    except AssetFailure as error:
        if runner is not None:
            runner.log.emit("[fatal] %s" % error)
        else:
            print("[fatal] %s" % error, file=sys.stderr, flush=True)
        return 3
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Prepare the signature-verified Lua WASI fixture for Qualification hosts.

The pinned Lua 5.4.8 ``lua.wasm`` ships as a repository-tracked immutable
artifact under ``capability-hub/packages/``.  This script is deliberately
strict and offline:

* the committed signed catalog is authenticated against the pinned public
  key with the existing ``capability-hub/build.py`` tooling (never a
  temporary key, never a skipped check), scoped to the ``floe/lua`` entry so
  verifying the signature never reads every tracked artifact;
* the catalog's floe/lua digest must match the fixed manifest, and its URL
  must be an immutable full-SHA artifact URL;
* the repository-tracked artifact must exist and match that pinned digest
  and size exactly, including the WASM magic; a missing or corrupt artifact
  is an integrity error and fails.  There is intentionally no download
  fallback: the Qualification hosts must run the exact bytes committed in
  this repository, not bytes fetched from a URL;
* the verified bytes are installed atomically into the cache directory so
  an earlier verified fixture is never disturbed by a failure.

Nothing rebuilds Lua, no network is used and no large dependency is
fetched.  Print exactly one absolute path on stdout so a workflow can
capture it, e.g.::

    FLOE_LUA_WASI="$(python3 scripts/prepare_lua_qualification.py)" ...
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[2]
CAPABILITY_TOOL = REPO_ROOT / 'capability-hub' / 'build.py'
LUA_ID = 'floe/lua'
WASM_MAGIC = b'\0asm\x01\0\0\0'


def default_cache_dir():
    override = os.environ.get('FLOE_LUA_CACHE_DIR')
    if override:
        return Path(override)
    runner_temp = os.environ.get('RUNNER_TEMP')
    if runner_temp:
        return Path(runner_temp) / 'floe-lua-qualification'
    return REPO_ROOT / 'Local' / 'Scratch' / 'lua-qualification'


def load_capability_tool(path=CAPABILITY_TOOL):
    """Load the repository's existing catalog verifier/build tool."""
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f'capability catalog tooling missing at {path}')
    spec = importlib.util.spec_from_file_location('floe_capability_build', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def lua_manifest_entry(tool):
    entry = next((e for e in tool.MANIFEST if e.get('id') == LUA_ID), None)
    if entry is None:
        raise RuntimeError('fixed manifest has no floe/lua entry')
    return entry


def repo_artifact_path(tool, base=None):
    """Tracked immutable artifact path for floe/lua inside the catalog checkout."""
    base = Path(base) if base is not None else Path(tool.ROOT)
    return base / lua_manifest_entry(tool)['path']


def verify_signed_catalog(tool, base=None):
    """Authenticate the committed catalog; return (payload, floe/lua package).

    Read-only and scoped: only ``catalog.json``, ``catalog.sig`` and the
    pinned public key are read, so authenticating the signature never pulls
    every tracked artifact through the digest checks of ``tool.check()``.
    """
    base = Path(base) if base is not None else Path(tool.ROOT)
    catalog = (base / 'catalog.json').read_bytes()
    signature = (base / 'catalog.sig').read_text().strip()
    trusted = base64.b64decode(
        json.loads(Path(tool.PUBLIC_KEY).read_text())['publicKey'])
    tool.verify_catalog(catalog, signature, trusted)
    payload = json.loads(catalog)
    if payload.get('schemaVersion') != 1:
        raise RuntimeError('Unsupported catalog schema version')
    package = next((p for p in payload.get('packages', [])
                    if p.get('id') == LUA_ID), None)
    if package is None:
        raise RuntimeError(f'signed catalog has no {LUA_ID} package')
    return payload, package


def pinned_lua_entry(tool, base=None):
    """Verify the signed catalog and return (url, sha256, sizeBytes) for floe/lua.

    The catalog signature, the floe/lua entry's immutable full-SHA URL and
    its agreement with the fixed manifest are all required here.  The
    repository's tracked artifact bytes are verified separately by this
    script against the same pinned digest and size.
    """
    _, package = verify_signed_catalog(tool, base=base)
    entry = lua_manifest_entry(tool)
    match = re.fullmatch(
        rf"{re.escape(tool.URL_PREFIX)}/([0-9a-f]{{40}})/capability-hub/{re.escape(entry['path'])}",
        package.get('url', ''))
    if not match:
        raise RuntimeError(
            f'{LUA_ID} catalog URL is not an immutable artifact URL')
    for field in ('version', 'command', 'minimumAppVersion'):
        if package.get(field) != entry[field]:
            raise RuntimeError(
                f'{LUA_ID} catalog {field} does not match the fixed manifest')
    sha256 = entry.get('sha256')
    size = entry.get('sizeBytes')
    if not sha256 or size is None:
        raise RuntimeError(
            'fixed manifest is missing the pinned floe/lua digest or size')
    if package.get('sha256') != sha256:
        raise RuntimeError(
            'signed catalog floe/lua digest does not match the fixed manifest')
    return package['url'], sha256, size


def verify_wasm(data, sha256, size, label='lua.wasm'):
    """Require the pinned size, digest and WASM magic; reject archives/JSON."""
    if size is None or len(data) != size:
        raise RuntimeError(f'{label} size mismatch (expected {size}, got {len(data)})')
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        raise RuntimeError(f'{label} SHA-256 mismatch (expected {sha256}, got {digest})')
    if not data.startswith(WASM_MAGIC):
        raise RuntimeError(f'{label} is not a WASM module')
    return data


def read_verified(path, sha256, size):
    """Return the bytes when ``path`` already holds the exact verified fixture."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return None
    try:
        return verify_wasm(data, sha256, size, Path(path).name)
    except RuntimeError:
        return None


def install_atomically(cache_dir, data, target_name='lua.wasm'):
    """Stage beside the target, then atomically replace it; the old file stays
    intact for every earlier failure path (missing or corrupt artifact)."""
    target = Path(cache_dir) / target_name
    descriptor, temporary = tempfile.mkstemp(prefix='.floe-lua-', dir=str(cache_dir))
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        temporary.write_bytes(data)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def prepare(sha256, size, cache_dir, repo_artifact):
    """Return ``(path, source)`` with source in {'cache', 'repository'}.

    Preference: an already-verified cache file, then the committed
    repository artifact (never a network request).  A missing repository
    artifact is a hard integrity error, not a reason to download different
    bytes: the Qualification hosts must run the exact fixture tracked in
    this repository.
    """
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / 'lua.wasm'
    cached = read_verified(target, sha256, size)
    if cached is not None:
        return target, 'cache'
    artifact = Path(repo_artifact)
    if not artifact.is_file():
        raise RuntimeError(
            f'repository-tracked artifact {artifact} is missing; refusing to '
            'substitute downloaded bytes for the committed floe/lua fixture')
    data = read_verified(artifact, sha256, size)
    if data is None:
        raise RuntimeError(
            f'tracked repository artifact {artifact} does not match the '
            'signed catalog digest; refusing to replace committed bytes')
    return install_atomically(cache_dir, data), 'repository'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-dir', type=Path, default=default_cache_dir(),
                        help='directory that holds the verified lua.wasm fixture')
    parser.add_argument('--base', type=Path, default=None,
                        help='capability catalog checkout root (testing only)')
    args = parser.parse_args(argv)
    tool = load_capability_tool()
    url, sha256, size = pinned_lua_entry(tool, args.base)
    target, source = prepare(sha256, size, args.cache_dir,
                             repo_artifact=repo_artifact_path(tool, args.base))
    print(f'{source} {target} ({size} bytes, pinned at {url})', file=sys.stderr)
    print(target.resolve())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

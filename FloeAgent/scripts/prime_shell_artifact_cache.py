#!/usr/bin/env python3
"""Prime SwiftPM's binary archive cache from the reviewed shell manifest.

Archives are downloaded through GitHub's release API and checked against the
manifest SHA-256 before atomic publication. SwiftPM independently checks them
again on extraction. No framework, source revision or checksum is replaced.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit


def github_asset(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or parsed.netloc != 'github.com' or parsed.fragment:
        raise ValueError('Expected a GitHub HTTPS release asset')
    match = re.fullmatch(r'/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)', parsed.path)
    if not match:
        raise ValueError('Expected a direct, immutable release asset URL')
    repo, tag, name = (unquote(value) for value in match.groups())
    if any(character in name for character in '/?*[]'):
        raise ValueError('Expected an exact asset filename')
    return repo, tag, name


def cache_key(url):
    # SwiftPM BinaryArtifactsManager uses spm_mangledToC99ExtendedIdentifier.
    # These reviewed URLs are ASCII and start with an alphabetic scheme.
    if not url.isascii():
        raise ValueError('Non-ASCII artifact URL needs an explicit cache-key review')
    return re.sub(r'[^a-zA-Z0-9_]', '_', url)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def prime(url, checksum, cache_dir, download=None):
    repo, tag, name = github_asset(url)
    if not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Missing pinned SHA-256')
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / cache_key(url)
    if target.exists() and digest(target) == checksum:
        return target
    fd, temporary = tempfile.mkstemp(prefix='.floe-artifact-', dir=cache_dir)
    os.close(fd)
    temporary = Path(temporary)
    try:
        if download:
            download(temporary)
        else:
            subprocess.run(['gh', 'release', 'download', tag, '--repo', repo,
                            '--pattern', name, '--output', str(temporary), '--clobber'],
                           check=True, timeout=300)
        if digest(temporary) != checksum:
            raise ValueError(f'Checksum mismatch for {name}; cache was not changed')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'ThirdParty/FloeShellEngine')
    parser.add_argument('--cache-dir', type=Path, required=True)
    args = parser.parse_args()
    # Read the actual SwiftPM model, rather than evaluating guessed URL patterns.
    manifest = json.loads(subprocess.check_output(['swift', 'package', '--package-path',
        str(args.manifest_dir), 'dump-package'], timeout=120))
    targets = [target for target in manifest['targets'] if target['type'] == 'binary']
    if not targets:
        raise ValueError('The reviewed shell manifest contains no binary targets')
    for target in targets:
        prime(target['url'], target['checksum'], args.cache_dir)
        print(f'Verified SwiftPM archive: {target["name"]}', flush=True)


if __name__ == '__main__':
    main()

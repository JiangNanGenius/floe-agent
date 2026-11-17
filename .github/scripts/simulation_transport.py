#!/usr/bin/env python3
"""Install and recheck three frozen SimulationKit frameworks from a bounded ZIP.

Caller must independently bind the ZIP digest to the restricted release asset.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import urllib.error
import urllib.request
import zipfile

COMPONENTS = ('FloeMeshingNative', 'FloeFieldsNative', 'FloeRapierNative')
MAX_ZIP = 512 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
MAX_FILE = 256 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def expected_files(vendor):
    expected = {}
    manifests = {}
    for name in COMPONENTS:
        manifest = vendor / (name + '.manifest.json')
        require(manifest.is_file() and not manifest.is_symlink(), 'Missing tracked manifest')
        data = json.loads(manifest.read_text())
        files = data['files']
        require(isinstance(files, dict) and len(files) == 13, 'Unexpected manifest file count')
        for relative, value in files.items():
            path = PurePosixPath(relative)
            require(isinstance(relative, str) and not path.is_absolute() and relative == path.as_posix()
                    and '..' not in path.parts and '\\' not in relative
                    and re.fullmatch(r'[0-9a-f]{64}', value), 'Unsafe manifest entry')
            full = name + '.xcframework/' + relative
            require(full not in expected, 'Duplicate manifest entry')
            expected[full] = value
        manifests[name] = digest(manifest)
    require(len(expected) == 39, 'All 39 framework files are required')
    return expected, manifests


def observed_files(vendor, expected):
    seen = set()
    for name in COMPONENTS:
        root = vendor / (name + '.xcframework')
        require(root.is_dir() and not root.is_symlink(), 'Missing framework')
        for base, dirs, files in os.walk(root, followlinks=False):
            for item in dirs + files:
                path = Path(base) / item
                st = path.lstat()
                require(not stat.S_ISLNK(st.st_mode), 'Framework contains symlink')
                if stat.S_ISDIR(st.st_mode):
                    continue
                require(stat.S_ISREG(st.st_mode), 'Non-regular framework file')
                rel = path.relative_to(vendor).as_posix()
                require(rel in expected and digest(path) == expected[rel], 'Framework file mismatch')
                seen.add(rel)
    require(seen == set(expected), 'Framework file set incomplete')


def install(vendor, archive, sha256, evidence):
    expected, manifests = expected_files(vendor)
    require(re.fullmatch(r'[0-9a-f]{64}', sha256), 'Invalid transport hash')
    require(archive.is_file() and 0 < archive.stat().st_size <= MAX_ZIP and digest(archive) == sha256,
            'Transport hash or size mismatch')
    for name in COMPONENTS:
        target = vendor / (name + '.xcframework')
        require(not target.exists() and not target.is_symlink(), 'Refusing to replace framework')
    with zipfile.ZipFile(archive) as source:
        items = source.infolist()
        names = [i.filename for i in items]
        require(len(items) == 39 and len(set(names)) == 39 and set(names) == set(expected),
                'Transport must contain exactly the 39 manifest files')
        require(sum(i.file_size for i in items) <= MAX_TOTAL, 'Transport expands beyond limit')
        for item in items:
            path = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in item.filename
                    and not item.is_dir() and not (item.flag_bits & 1)
                    and stat.S_IFMT(mode) in (0, stat.S_IFREG)
                    and 0 < item.file_size <= MAX_FILE, 'Unsafe transport entry')
        require(source.testzip() is None, 'Transport CRC mismatch')
        # Keep staging on the destination volume so the final renames cannot
        # cross filesystems; failures leave the private stage for inspection.
        stage = vendor / '.simulation-extracted'
        require(not stage.exists(), 'Extraction staging already exists')
        stage.mkdir(mode=0o700)
        for item in items:
            target = stage / item.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            h = hashlib.sha256()
            with source.open(item) as inp, target.open('xb') as out:
                for block in iter(lambda: inp.read(8 * 1024 * 1024), b''):
                    h.update(block)
                    out.write(block)
            require(h.hexdigest() == expected[item.filename], 'Transport member digest mismatch')
    observed_files(stage, expected)
    # Targets are absent, and the fresh staging tree has no symlinks or extra files.
    for name in COMPONENTS:
        src = stage / (name + '.xcframework')
        dst = vendor / (name + '.xcframework')
        require(not dst.exists() and not dst.is_symlink(), 'Framework appeared during install')
        os.rename(src, dst)
    observed_files(vendor, expected)
    stage.rmdir()
    with evidence.open('x') as out:
        json.dump({'transportSHA256': sha256, 'manifestSHA256': manifests,
                   'fileSHA256': expected}, out, indent=2, sort_keys=True)
        out.write('\n')


def verify(vendor, evidence):
    expected, manifests = expected_files(vendor)
    saved = json.loads(evidence.read_text())
    require(saved['fileSHA256'] == expected and saved['manifestSHA256'] == manifests,
            'Manifest or recorded input changed')
    observed_files(vendor, expected)


def verify_release_target(release, source_sha, lookup):
    """Resolve a live tag to the product commit, or validate a tagless draft."""
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha), 'Invalid product source SHA')
    tag = 'v1.8.42-simulation-transport-fa252b61852d'
    require(release.get('draft') is True and release.get('tag_name') == tag, 'Unexpected release')
    ref = lookup('git/ref/tags/' + tag, missing_ok=True)
    if ref is None:
        require(release.get('target_commitish') == source_sha, 'Tagless draft target mismatch')
        return {'mode': 'tag_absent', 'targetCommitish': source_sha}
    obj = ref['object']
    visited = set()
    for _ in range(8):
        kind, value = obj.get('type'), obj.get('sha')
        require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{40}', value), 'Invalid tag object')
        require(value not in visited, 'Tag object cycle')
        visited.add(value)
        if kind == 'commit':
            require(value == source_sha, 'Draft tag resolves to another commit')
            return {'mode': 'tag_resolved', 'resolvedCommit': value}
        require(kind == 'tag', 'Unsupported tag object type')
        tag_object = lookup('git/tags/' + value, missing_ok=False)
        require(tag_object is not None, 'Tag object missing')
        obj = tag_object['object']
    raise ValueError('Tag object chain too long')


def github_lookup(path, missing_ok=False):
    repo = os.environ['GITHUB_REPOSITORY']
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo), 'Invalid repository')
    token = os.environ['GH_TOKEN']
    request = urllib.request.Request('https://api.github.com/repos/' + repo + '/' + path,
                                     headers={'Authorization': 'Bearer ' + token,
                                              'Accept': 'application/vnd.github+json'})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise ValueError('Unexpected API redirect')
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            data = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404 and missing_ok:
            return None
        raise ValueError('GitHub ref lookup failed with HTTP ' + str(error.code)) from None
    require(len(data) <= 1024 * 1024, 'GitHub API response too large')
    return json.loads(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('install', 'verify', 'verify-release-target'))
    parser.add_argument('--vendor', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--release-metadata', type=Path)
    parser.add_argument('--source-sha')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--sha256')
    args = parser.parse_args()
    if args.operation == 'verify-release-target':
        require(args.release_metadata is not None, 'Release metadata required')
        result = verify_release_target(json.loads(args.release_metadata.read_text()), args.source_sha or '', github_lookup)
        with args.evidence.open('x') as out:
            json.dump(result, out, sort_keys=True)
            out.write('\n')
        return
    require(args.vendor is not None, 'Vendor directory required')
    vendor = args.vendor.resolve()
    require(vendor.is_dir(), 'Vendor directory missing')
    if args.operation == 'install':
        require(args.archive is not None, 'Archive required')
        install(vendor, args.archive, args.sha256 or '', args.evidence)
    else:
        verify(vendor, args.evidence)


if __name__ == '__main__':
    main()

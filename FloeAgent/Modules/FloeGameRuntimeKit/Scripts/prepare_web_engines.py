#!/usr/bin/env python3
"""Prepare pinned, licensed Web SDK files. --check never downloads or rewrites.

Only exact whitelisted tar members are read. No archive paths are extracted.
The App uses the same fixed per-file pins through GameEnginePackStore.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--engine', choices=['kaplay', 'babylon', 'playcanvas'])
    parser.add_argument('--archives', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error('Use an absolute output path')
    root = Path(__file__).resolve().parents[1]
    index = json.loads((root / 'Sources/FloeGameRuntime/Resources/RuntimePins.json').read_text())
    assert index['version'] == 1
    results = []
    for spec in index['packs']:
        if args.engine and spec['engine'] != args.engine:
            continue
        if spec['license'] not in {'MIT', 'Apache-2.0'}:
            raise ValueError('Resource pin requires a separate distribution-license review')
        target = args.output / (spec['engine'] + '-' + spec['version'])
        if not args.check and not target.exists():
            args.output.mkdir(parents=True, exist_ok=True)
            archive = args.archives / (spec['package'] + '-' + spec['version'] + '.tgz') if args.archives else None
            if archive and archive.is_file():
                raw = archive.read_bytes()
            else:
                with urllib.request.urlopen(spec['tarballURL'], timeout=90) as response:
                    raw = response.read(40 * 1024 * 1024 + 1)
            if len(raw) > 40 * 1024 * 1024:
                raise ValueError('Archive exceeds limit')
            assert 'sha512-' + base64.b64encode(hashlib.sha512(raw).digest()).decode() == spec['tarballIntegrity']
            stage = Path(tempfile.mkdtemp(prefix='.game-pack-', dir=args.output))
            try:
                with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as tar:
                    for file in spec['files']:
                        member = tar.getmember('package/' + file['packagePath'])
                        assert member.isfile() and member.size == file['bytes'] and member.size <= 16 * 1024 * 1024
                        data = tar.extractfile(member).read(file['bytes'] + 1)
                        assert len(data) == file['bytes'] and hashlib.sha256(data).hexdigest() == file['sha256']
                        output = stage / file['path']
                        output.parent.mkdir(parents=True, exist_ok=True)
                        output.write_bytes(data)
                (stage / 'resource-manifest.json').write_text(json.dumps(spec, indent=2) + '\n')
                if target.exists():
                    raise FileExistsError(target)
                stage.rename(target)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
        for file in spec['files']:
            path = target / file['path']
            assert path.is_file() and not path.is_symlink()
            assert path.stat().st_size == file['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == file['sha256']
        results.append({'engine': spec['engine'], 'version': spec['version'], 'license': spec['license'], 'directory': str(target), 'verifiedFiles': len(spec['files'])})
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()

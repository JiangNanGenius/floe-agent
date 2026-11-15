#!/usr/bin/env python3
"""Create or verify a prepared-resource manifest (no network, no execution)."""
import argparse, hashlib, json, os, sys
from pathlib import Path

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def records(root):
    out = []
    for path in sorted(Path(root).rglob('*')):
        if path.is_symlink():
            raise SystemExit(f"symlink rejected: {path}")
        if path.is_dir():
            continue
        rel = path.relative_to(root).as_posix()
        if rel == '.DS_Store' or rel.endswith('/.DS_Store'):
            continue
        out.append({'path': rel, 'sha256': digest(path), 'bytes': path.stat().st_size,
                    'executable': bool(path.stat().st_mode & 0o111)})
    return out

def value_for(root, resource_id, pin_id, engine, version, runtime_id, notes):
    files = records(root)
    return {'schemaVersion': 1, 'id': resource_id, 'pinID': pin_id,
            'engine': engine, 'version': version, 'runtimeID': runtime_id,
            'files': files, 'notes': notes}

def write(root, manifest, resource_id, pin_id, engine, version, runtime_id, notes):
    root = Path(root).resolve(); manifest = Path(manifest).resolve()
    value = value_for(root, resource_id, pin_id, engine, version, runtime_id, notes)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n')
    print(f"WROTE {len(value['files'])} files, {sum(f['bytes'] for f in value['files'])} bytes -> {manifest}")

def check(root, manifest):
    root = Path(root).resolve(); manifest = Path(manifest).resolve()
    if not manifest.is_file():
        raise SystemExit('manifest missing: ' + str(manifest))
    current = json.loads(manifest.read_text())
    if current.get('schemaVersion') != 1 or not isinstance(current.get('files'), list):
        raise SystemExit('invalid manifest: ' + str(manifest))
    files = current['files']
    expected = {f['path']: f for f in files}
    actual = {p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
    if set(expected) != set(actual):
        extra = sorted(set(actual) - set(expected))[:3]
        missing = sorted(set(expected) - set(actual))[:3]
        raise SystemExit(f'prepared tree mismatch extra={extra} missing={missing}')
    for rel, file in expected.items():
        data = actual[rel].read_bytes()
        if len(data) != file['bytes'] or hashlib.sha256(data).hexdigest() != file['sha256']:
            raise SystemExit('file mismatch: ' + rel)
    print(f"OK {len(files)} files, {sum(f['bytes'] for f in files)} bytes -> {manifest}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--id', required=False)
    ap.add_argument('--pin-id', required=False)
    ap.add_argument('--engine', required=False)
    ap.add_argument('--version', required=False)
    ap.add_argument('--runtime-id', required=False)
    ap.add_argument('--note', action='append', default=[])
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args()
    if args.check:
        check(args.root, args.manifest)
        return
    if not all([args.id, args.pin_id, args.engine, args.version, args.runtime_id]):
        raise SystemExit('id, pin-id, engine, version and runtime-id are required when writing')
    write(args.root, args.manifest, args.id, args.pin_id, args.engine,
          args.version, args.runtime_id, args.note)

if __name__ == '__main__':
    main()

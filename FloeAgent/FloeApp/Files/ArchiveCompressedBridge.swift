#if canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeTools
import FloeWorkspace

/// Bridges workspace.archive's compressed formats (tar.gz/tar.bz2/tar.xz and
/// single-file gz/bz2/xz) onto the bundled CPython, so the archive tool is
/// the single entry point. The fixed script below enforces the same limits
/// as the native paths: entry/byte caps, name sanitization, no overwrite.
enum ArchiveCompressedBridge {
    static func makeHandler(service: LocalPythonService) -> ArchiveCompressedHandler {
        { request in
            if request.format == "rar" { return try await RARArchiveService.run(request) }
            let args: [String: Any] = [
                "action": request.action,
                "format": request.format,
                "source": request.source,
                "destination": request.destination as Any,
                "root": request.workspaceRoot.path
            ]
            let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let script = Self.script.replacingOccurrences(of: "__ARGS_JSON__", with: argsJSON)
            let outcome = await service.run(
                ScriptExecutionRequest(script: script, timeout: 30, maxOutputBytes: 64 * 1024),
                cancellation: request.cancellation
            )
            switch outcome {
            case .ok(_, let stdout, let stderr, _, _, _):
                let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("status=ok") { return text }
                throw FloeError.internalError(text.isEmpty ? stderr : text)
            case .jsException(let message, _):
                throw FloeError.internalError("archive bridge failed: \(message)")
            case .timedOut:
                throw FloeError.internalError("archive bridge timed out")
            case .cancelled:
                throw FloeError.cancelled
            }
        }
    }

    // Safety contract (mirrors the native paths): entry cap 5000, total
    // uncompressed cap 256 MiB, skip absolute/parent-escaping names, never
    // overwrite, destinations must be new paths.
    private static let script = #"""
import json, os, tarfile, gzip, bz2, lzma, shutil

args = json.loads(r'''__ARGS_JSON__''')
action, fmt, source = args['action'], args['format'], args['source']
destination, root = args['destination'], args['root']
MAX_ENTRIES, MAX_BYTES = 5000, 256 * 1024 * 1024
TAR_MODES = {'tgz': ('r:gz', 'w:gz', '.tar.gz'), 'tbz2': ('r:bz2', 'w:bz2', '.tar.bz2'), 'txz': ('r:xz', 'w:xz', '.tar.xz')}
SINGLE = {'gz': gzip, 'bz2': bz2, 'xz': lzma}

def full(path):
    if not path or path.startswith(('/', '~')) or '..' in path.split('/'):
        raise ValueError('unsafe path: %r' % path)
    return os.path.join(root, path)

def safe_name(name):
    parts = [p for p in name.split('/') if p]
    return bool(parts) and '..' not in parts and not name.startswith(('/', '~'))

if action == 'create':
    if not destination:
        raise ValueError('destination is required for create')
    src, dst = full(source), full(destination)
    if os.path.exists(dst):
        raise FileExistsError('destination already exists: ' + destination)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if fmt in TAR_MODES:
        entries, total = 0, 0
        with tarfile.open(dst, TAR_MODES[fmt][1]) as tf:
            if os.path.isdir(src):
                for base, dirs, files in os.walk(src):
                    dirs.sort()
                    for name in sorted(dirs):
                        tf.add(os.path.join(base, name), arcname=os.path.relpath(os.path.join(base, name), os.path.dirname(src)), recursive=False)
                    for name in sorted(files):
                        path = os.path.join(base, name)
                        total += os.path.getsize(path)
                        if entries + 1 > MAX_ENTRIES or total > MAX_BYTES:
                            raise ValueError('archive exceeds entry/byte caps')
                        tf.add(path, arcname=os.path.relpath(path, os.path.dirname(src)))
                        entries += 1
            else:
                total = os.path.getsize(src)
                if total > MAX_BYTES:
                    raise ValueError('archive exceeds byte cap')
                tf.add(src, arcname=os.path.basename(src))
                entries = 1
        print('status=ok action=create format=%s source=%s destination=%s entries=%d uncompressedBytes=%d' % (fmt, source, destination, entries, total))
    else:
        total = os.path.getsize(src)
        if os.path.isdir(src) or total > MAX_BYTES:
            raise ValueError('gz/bz2/xz compress a single file within the byte cap')
        opener = {'gz': gzip.open, 'bz2': bz2.open, 'xz': lzma.open}[fmt]
        with open(src, 'rb') as fin, opener(dst, 'wb') as fout:
            shutil.copyfileobj(fin, fout)
        print('status=ok action=create format=%s source=%s destination=%s entries=1 uncompressedBytes=%d' % (fmt, source, destination, total))
elif action == 'extract':
    if not destination:
        raise ValueError('destination is required for extract')
    src, dst = full(source), full(destination)
    if os.path.exists(dst):
        raise FileExistsError('destination already exists: ' + destination)
    if fmt in TAR_MODES:
        extracted, skipped, total = 0, 0, 0
        os.makedirs(dst)
        with tarfile.open(src, TAR_MODES[fmt][0]) as tf:
            for member in tf:
                if not member.isreg():
                    continue
                if os.path.basename(member.name).startswith('._'):
                    continue
                if extracted + 1 > MAX_ENTRIES:
                    raise ValueError('archive exceeds entry cap')
                if not safe_name(member.name):
                    skipped += 1
                    continue
                total += member.size
                if total > MAX_BYTES:
                    raise ValueError('archive exceeds byte cap')
                target = os.path.join(dst, member.name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with tf.extractfile(member) as fin, open(target, 'xb') as fout:
                    shutil.copyfileobj(fin, fout)
                extracted += 1
        print('status=ok action=extract format=%s source=%s destination=%s entries=%d skipped=%d uncompressedBytes=%d' % (fmt, source, destination, extracted, skipped, total))
    else:
        opener = {'gz': gzip.open, 'bz2': bz2.open, 'xz': lzma.open}[fmt]
        written = 0
        with opener(src, 'rb') as fin, open(dst, 'xb') as fout:
            while True:
                chunk = fin.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAX_BYTES:
                    fout.close()
                    os.remove(dst)
                    raise ValueError('decompressed output exceeds byte cap')
                fout.write(chunk)
        print('status=ok action=extract format=%s source=%s destination=%s entries=1 uncompressedBytes=%d' % (fmt, source, destination, written))
elif action == 'list':
    if fmt not in TAR_MODES:
        raise ValueError('list applies to tar.gz/tar.bz2/tar.xz archives')
    src = full(source)
    lines, count, truncated = [], 0, False
    with tarfile.open(src, TAR_MODES[fmt][0]) as tf:
        for member in tf:
            if count >= 500:
                truncated = True
                break
            lines.append('%s\t%d\t%s' % ('dir' if member.isdir() else 'file', member.size, member.name))
            count += 1
    print('status=ok action=list format=%s source=%s entries=%d truncated=%s' % (fmt, source, count, str(truncated).lower()))
    for line in lines:
        print(line)
else:
    raise ValueError('action must be create, extract or list')
"""#
}
#endif

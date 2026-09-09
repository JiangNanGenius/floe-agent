#!/usr/bin/env python3
"""Compile pinned Calc filters and replace only explicitly locked archive members.

Uses a sparse checkout of the exact engine commit plus verified embedding inputs.
The original bundle remains unchanged. A receipt is not runtime qualification.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_office_native_sources import DEFAULT_LOCK

FILTER_LOCK = DEFAULT_LOCK.parent / 'filter-overlay.lock.json'
SPARSE_PATHS = [
    '/engine/sc/inc/', '/engine/sc/source/filter/inc/',
    '/engine/sc/source/filter/xcl97/xcl97rec.cxx', '/engine/oox/inc/',
    '/engine/sc/source/filter/excel/xlroot.cxx', '/engine/sc/source/ui/inc/',
    '/engine/officecfg/registry/cppheader.xsl',
    '/engine/officecfg/registry/component-schema.dtd',
    '/engine/officecfg/registry/schema/org/openoffice/Office/Common.xcs',
    '/engine/solenv/bin/generate-tokens.py', '/engine/oox/source/token/',
]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def archive_members(path):
    """Read BSD/GNU ar members, excluding only the regenerated symbol indexes."""
    data = Path(path).read_bytes()
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('Expected a regular static archive')
    offset, result, long_names = 8, {}, b''
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b'`\n':
            raise ValueError('Malformed archive header')
        size = int(header[48:58])
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size:
            raise ValueError('Truncated archive member')
        name = header[:16].decode('ascii').strip()
        if name.startswith('#1/'):
            length = int(name[3:])
            if length > len(body):
                raise ValueError('Invalid extended archive filename')
            name, body = body[:length].rstrip(b'\0').decode(), body[length:]
        elif name == '//':
            long_names = body
        elif name.startswith('/') and name[1:].isdigit():
            start = int(name[1:])
            end = long_names.find(b'/\n', start)
            if start >= len(long_names) or end == -1:
                raise ValueError('Invalid archive filename table reference')
            name = long_names[start:end].decode()
        else:
            name = name.rstrip('/')
        if name and name not in ('/', '//') and not name.startswith('__.SYMDEF'):
            if name in result:
                raise ValueError('Duplicate archive member: ' + name)
            result[name] = hashlib.sha256(body).hexdigest()
        offset += 60 + size + size % 2
    if offset != len(data):
        raise ValueError('Truncated archive padding')
    return result


def verify_replacement(before, after, name, object_hash):
    verify_replacements(before, after, {name: object_hash})


def verify_replacements(before, after, objects):
    if not objects or set(before) != set(after) or not set(objects) <= set(before):
        raise ValueError('Archive membership changed')
    changed = {key for key in before if before[key] != after[key]}
    if changed != set(objects) or any(after[name] != checksum for name, checksum in objects.items()):
        raise ValueError('Replacement changed an unexpected archive member')


def select_linker_archive(bundle, overlay, destination):
    """Revalidate the receipt and select one owned library in a new linker list."""
    bundle, overlay, destination = (Path(p).resolve() for p in (bundle, overlay, destination))
    lock = json.loads(FILTER_LOCK.read_text())
    report = json.loads((overlay / 'filter-overlay.json').read_text())
    original, replacement = bundle / lock['archive'], overlay / 'libscfiltlo.a'
    if (report.get('sourceCommit') != lock['commit']
            or report.get('patchSHA256') != lock['patchSHA256']
            or digest(FILTER_LOCK.parent / lock['patch']) != lock['patchSHA256']
            or report.get('sourceFiles') != lock['files']
            or not report.get('compilePassed') or not report.get('archiveReplacementPassed')
            or digest(original) != lock['originalArchiveSHA256']
            or digest(replacement) != report.get('archiveSHA256')):
        raise ValueError('Filter overlay is not the current verified build')
    expected = set(lock.get('members', {lock['member']: ''}))
    objects = report.get('objectSHA256ByMember', {lock['member']: report['objectSHA256']})
    if set(objects) != expected:
        raise ValueError('Filter overlay does not contain every locked replacement')
    verify_replacements(archive_members(original), archive_members(replacement), objects)
    lines = (bundle / 'prepared/ios-all-static-libs.list').read_text().splitlines()
    matches = [i for i, line in enumerate(lines) if Path(line).resolve() == original.resolve()]
    if len(matches) != 1:
        raise ValueError('Expected exactly one original Calc filter linker input')
    # Own the selected archive so later work in the build directory cannot change it.
    owned = destination / 'libscfiltlo.a'
    shutil.copyfile(replacement, owned)
    lines[matches[0]] = str(owned)
    linker = destination / 'ios-filter-static-libs.list'
    linker.write_text('\n'.join(lines) + '\n')
    return linker, {**report, 'selectedArchive': str(owned),
                    'selectedArchiveSHA256': digest(owned), 'linkerListSHA256': digest(linker)}


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def generate_headers(source, generated):
    engine = source / 'engine'
    (generated / 'officecfg/Office').mkdir(parents=True)
    (generated / 'oox/token').mkdir(parents=True)
    (generated / 'misc').mkdir()
    run(['xsltproc', '--nonet', '--stringparam', 'ns1', 'Office',
         '--stringparam', 'ns2', 'Common', '-o', generated / 'officecfg/Office/Common.hxx',
         engine / 'officecfg/registry/cppheader.xsl',
         engine / 'officecfg/registry/schema/org/openoffice/Office/Common.xcs'])
    tokens = engine / 'oox/source/token'
    generators = [
        ('tokens', 'token', engine / 'solenv/bin/generate-tokens.py',
         [generated / 'misc/tokenhash.gperf']),
        ('namespaces', 'namespace', tokens / 'namespaces.py',
         [generated / 'misc/namespaces.txt', tokens / 'namespaces-strict.txt',
          generated / 'namespaces-strictnames.inc']),
        ('properties', 'property', tokens / 'properties.py', []),
    ]
    for plural, singular, script, extra in generators:
        ids = generated / 'misc' / (singular + 'ids.inc')
        run([sys.executable, '-B', script, tokens / (plural + '.txt'), ids,
             generated / (singular + 'names.inc'), *extra])
        (generated / 'oox/token' / (plural + '.hxx')).write_bytes(
            (tokens / (plural + '.hxx.head')).read_bytes() + ids.read_bytes()
            + (tokens / (plural + '.hxx.tail')).read_bytes())


def build(bundle, source, output):
    bundle, source, output = (Path(p).resolve() for p in (bundle, source, output))
    lock = json.loads(FILTER_LOCK.read_text())
    engine_lock = json.loads(DEFAULT_LOCK.read_text())
    if lock['commit'] != engine_lock['commit']:
        raise ValueError('Filter and embedded engine commits differ')
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != lock['commit']:
        raise ValueError('Unexpected filter source commit')
    run(['git', '-C', source, 'diff', '--quiet', 'HEAD', '--', 'engine'])
    patch = FILTER_LOCK.parent / lock['patch']
    if digest(patch) != lock['patchSHA256']:
        raise ValueError('Filter patch digest differs from lock')
    archive = bundle / lock['archive']
    if digest(archive) != lock['originalArchiveSHA256']:
        raise ValueError('Unexpected original filter archive')
    # Never apply onto unrelated source edits or silently double-apply a patch.
    for name, hashes in lock['files'].items():
        if digest(source / name) != hashes['originalSHA256']:
            raise ValueError('Unexpected original filter source: ' + name)
    output.mkdir(parents=True)
    receipt = output / 'filter-overlay.json'
    report = {'sourceCommit': actual, 'patchSHA256': lock['patchSHA256'],
              'originalArchiveSHA256': digest(archive), 'compilePassed': False,
              'archiveReplacementPassed': False, 'runtimeRoundtripPassed': False}

    def save():
        receipt.write_text(json.dumps(report, indent=2) + '\n')

    save()
    run(['git', '-C', source, 'apply', '--check', patch])
    run(['git', '-C', source, 'apply', patch])
    for name, hashes in lock['files'].items():
        if digest(source / name) != hashes['patchedSHA256']:
            raise ValueError('Patched filter source differs from lock: ' + name)
    report['sourceFiles'] = lock['files']
    generated = output / 'generated'
    generate_headers(source, generated)
    engine = bundle / 'source/engine'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-std=c++20', '-c',
               '-target', 'arm64-apple-ios' + engine_lock['minimumIOS'], '-isysroot', sdk,
               '-DLIBO_INTERNAL_ONLY', '-DCPPU_ENV=gcc3', '-DIOS', '-DDISABLE_DYNLOADING=1',
               '-O2', '-fPIC', '-fvisibility=hidden', '-fvisibility-inlines-hidden', '-DNDEBUG']
    includes = [engine / 'config_host', engine / 'include', generated,
                source / 'engine/sc/inc', source / 'engine/sc/source/filter/inc',
                source / 'engine/sc/source/ui/inc',
                source / 'engine/oox/inc',
                engine / 'workdir/UnoApiHeadersTarget/udkapi/comprehensive',
                engine / 'workdir/UnoApiHeadersTarget/offapi/comprehensive',
                engine / 'workdir/UnpackedTarball/boost']
    for include in includes:
        command += ['-I', str(include)]
    members = lock.get('members', {lock['member']: 'engine/sc/source/filter/xcl97/xcl97rec.cxx'})
    report['compileCommands'] = {}
    replacements = []
    for name, source_file in members.items():
        if Path(name).name != name or source_file not in lock['files']:
            raise ValueError('Unpinned filter replacement source')
        replacement = output / name
        compile_command = command + [str(source / source_file), '-o', str(replacement)]
        report['compileCommands'][name] = compile_command
        if name == lock['member']:
            report['compileCommand'] = compile_command
        save()
        with (output / (name + '.compile.log')).open('w') as log:
            run(compile_command, stdout=log, stderr=subprocess.STDOUT)
        replacements.append(replacement)
    objects = {p.name: digest(p) for p in replacements}
    report.update(compilePassed=True, objectSHA256=objects[lock['member']],
                  objectSHA256ByMember=objects)
    save()
    before = archive_members(archive)
    patched_archive = output / archive.name
    shutil.copyfile(archive, patched_archive)
    run(['xcrun', 'ar', '-r', patched_archive, *replacements])
    run(['xcrun', 'ranlib', patched_archive])
    after = archive_members(patched_archive)
    verify_replacements(before, after, objects)
    if digest(archive) != lock['originalArchiveSHA256']:
        raise ValueError('Original archive was modified')
    report.update(archiveReplacementPassed=True, archiveSHA256=digest(patched_archive),
                  archive=str(patched_archive), replacedMember=lock['member'],
                  replacedMembers=list(members), preservedMemberCount=len(before) - len(members))
    save()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.bundle, args.source, args.output), indent=2))

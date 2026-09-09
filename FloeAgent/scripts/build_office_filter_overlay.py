#!/usr/bin/env python3
"""Compile pinned Calc filters and replace only explicitly locked archive members.

Uses a sparse checkout of the exact engine commit plus verified embedding inputs.
The original bundle remains unchanged. A receipt is not runtime qualification.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile

from prepare_office_native_sources import DEFAULT_LOCK

FILTER_LOCK = DEFAULT_LOCK.parent / 'filter-overlay.lock.json'
SPARSE_PATHS = [
    '/engine/sc/inc/', '/engine/sc/source/filter/inc/',
    '/engine/sc/source/filter/xcl97/xcl97rec.cxx', '/engine/oox/inc/',
    '/engine/sc/source/filter/excel/xlroot.cxx', '/engine/sc/source/ui/inc/',
    '/engine/sc/source/filter/oox/unitconverter.cxx',
    '/engine/sc/source/filter/oox/drawingfragment.cxx',
    '/engine/sc/source/filter/oox/worksheetfragment.cxx',
    '/engine/sc/source/filter/oox/worksheethelper.cxx',
    '/engine/oox/source/vml/vmlshape.cxx',
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
    """Revalidate every locked archive before selecting owned linker inputs."""
    bundle, overlay, destination = (Path(p).resolve() for p in (bundle, overlay, destination))
    lock = json.loads(FILTER_LOCK.read_text())
    report = json.loads((overlay / 'filter-overlay.json').read_text())
    original, replacement = bundle / lock['archive'], overlay / 'libscfiltlo.a'
    if (report.get('sourceCommit') != lock['commit']
            or report.get('patchSHA256') != lock['patchSHA256']
            or digest(FILTER_LOCK.parent / lock['patch']) != lock['patchSHA256']
            or report.get('sourceFiles') != lock['files']
            or report.get('headerDependencies', {}) != lock.get('headerDependencies', {})
            or not report.get('compilePassed') or not report.get('archiveReplacementPassed')
            or digest(original) != lock['originalArchiveSHA256']
            or digest(replacement) != report.get('archiveSHA256')):
        raise ValueError('Filter overlay is not the current verified build')
    expected = set(lock.get('members', {lock['member']: ''}))
    for spec in lock.get('headerDependencies', {}).values():
        if digest(FILTER_LOCK.parent / spec['patch']) != spec['patchSHA256']:
            raise ValueError('Filter header dependency patch differs from lock')
    objects = report.get('objectSHA256ByMember', {lock['member']: report['objectSHA256']})
    if set(objects) != expected:
        raise ValueError('Filter overlay does not contain every locked replacement')
    verify_replacements(archive_members(original), archive_members(replacement), objects)
    additional = report.get('additionalArchives', {})
    if set(additional) != set(lock.get('additionalArchives', {})):
        raise ValueError('Filter overlay additional archive set differs from lock')
    selections = [(original, replacement, 'libscfiltlo.a')]
    for name, spec in lock.get('additionalArchives', {}).items():
        if Path(name).name != name or name == 'libscfiltlo.a':
            raise ValueError('Invalid additional archive name')
        current = additional[name]
        source_archive, patched_archive = bundle / spec['archive'], overlay / name
        if (digest(source_archive) != spec['originalArchiveSHA256']
                or digest(patched_archive) != current.get('archiveSHA256')
                or set(current.get('objectSHA256ByMember', {})) != set(spec['members'])):
            raise ValueError('Additional archive is not the locked verified build')
        verify_replacements(archive_members(source_archive), archive_members(patched_archive),
                            current['objectSHA256ByMember'])
        selections.append((source_archive, patched_archive, name))
    lines = (bundle / 'prepared/ios-all-static-libs.list').read_text().splitlines()
    replacements = []
    for source_archive, patched_archive, name in selections:
        matches = [i for i, line in enumerate(lines) if Path(line).resolve() == source_archive.resolve()]
        if len(matches) != 1:
            raise ValueError('Expected exactly one original filter linker input: ' + name)
        replacements.append((matches[0], patched_archive, destination / name))
    # Own the selected archive so later work in the build directory cannot change it.
    selected_hashes = {}
    for index, patched_archive, owned in replacements:
        shutil.copyfile(patched_archive, owned)
        lines[index] = str(owned)
        selected_hashes[owned.name] = digest(owned)
    owned = destination / 'libscfiltlo.a'
    linker = destination / 'ios-filter-static-libs.list'
    linker.write_text('\n'.join(lines) + '\n')
    return linker, {**report, 'selectedArchive': str(owned),
                    'selectedArchiveSHA256': digest(owned),
                    'selectedArchiveSHA256ByName': selected_hashes,
                    'linkerListSHA256': digest(linker)}


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def extract_header_archive(archive, output, spec):
    """Extract a hash-pinned, bounded header tree without archive links or traversal."""
    if digest(archive) != spec['sha256']:
        raise ValueError('Header dependency archive differs from lock')
    root = PurePosixPath(spec['root'])
    if root.is_absolute() or len(root.parts) != 1 or root.name in ('', '.', '..'):
        raise ValueError('Invalid header archive root')
    with tarfile.open(archive, 'r:*') as stream:
        members = stream.getmembers()
        if len(members) > 10000 or sum(item.size for item in members) > 32 * 1024 * 1024:
            raise ValueError('Header archive exceeds extraction limit')
        names = set()
        for item in members:
            path = PurePosixPath(item.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts
                    or path.parts[0] != root.name or path in names
                    or not (item.isfile() or item.isdir())):
                raise ValueError('Unsafe header archive member')
            names.add(path)
        output.mkdir(parents=True, exist_ok=False)
        # All members checked before writing, including hard links and symlinks.
        for item in members:
            target = output / item.name
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(item) as source, target.open('xb') as destination:
                    shutil.copyfileobj(source, destination)
    return output / root.name


def prepare_header_dependencies(lock, output):
    includes = []
    for name, spec in lock.get('headerDependencies', {}).items():
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('Invalid header dependency name')
        if not spec['url'].startswith('https://'):
            raise ValueError('Header dependency requires HTTPS')
        patch = FILTER_LOCK.parent / spec['patch']
        if digest(patch) != spec['patchSHA256']:
            raise ValueError('Header dependency patch differs from lock')
        archive = output / (name + '.tar.xz')
        run(['curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
             '--retry', '2', '--max-time', '90', '--max-filesize', str(4 * 1024 * 1024),
             '--output', archive, spec['url']])
        root = extract_header_archive(archive, output / ('headers-' + name), spec)
        run(['patch', '--batch', '--forward', '-p1', '-i', patch.resolve()], cwd=root)
        include = root / spec['include']
        if not include.is_dir() or not include.resolve().is_relative_to(root.resolve()):
            raise ValueError('Header dependency include directory is invalid')
        includes.append(include)
    return includes


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
    for name, spec in lock.get('additionalArchives', {}).items():
        if (Path(name).name != name or name == archive.name
                or digest(bundle / spec['archive']) != spec['originalArchiveSHA256']):
            raise ValueError('Unexpected additional filter archive')
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
    header_includes = prepare_header_dependencies(lock, output)
    report['headerDependencies'] = lock.get('headerDependencies', {})
    save()
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
    for include in includes + header_includes:
        command += ['-I', str(include)]
    members = lock.get('members', {lock['member']: 'engine/sc/source/filter/xcl97/xcl97rec.cxx'})
    all_members = dict(members)
    for spec in lock.get('additionalArchives', {}).values():
        if set(all_members) & set(spec['members']):
            raise ValueError('Ambiguous object names across archives')
        all_members.update(spec['members'])
    report['compileCommands'] = {}
    replacements = []
    for name, source_file in all_members.items():
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
    all_objects = {p.name: digest(p) for p in replacements}
    objects = {name: all_objects[name] for name in members}
    report.update(compilePassed=True, objectSHA256=objects[lock['member']],
                  objectSHA256ByMember=objects)
    save()
    before = archive_members(archive)
    patched_archive = output / archive.name
    shutil.copyfile(archive, patched_archive)
    run(['xcrun', 'ar', '-r', patched_archive, *(output / name for name in members)])
    run(['xcrun', 'ranlib', patched_archive])
    after = archive_members(patched_archive)
    verify_replacements(before, after, objects)
    if digest(archive) != lock['originalArchiveSHA256']:
        raise ValueError('Original archive was modified')
    report.update(archiveSHA256=digest(patched_archive),
                  archive=str(patched_archive), replacedMember=lock['member'],
                  replacedMembers=list(members), preservedMemberCount=len(before) - len(members))
    report['additionalArchives'] = {}
    for name, spec in lock.get('additionalArchives', {}).items():
        original = bundle / spec['archive']
        patched = output / name
        extra_objects = {member: all_objects[member] for member in spec['members']}
        before_extra = archive_members(original)
        shutil.copyfile(original, patched)
        run(['xcrun', 'ar', '-r', patched, *(output / member for member in spec['members'])])
        run(['xcrun', 'ranlib', patched])
        verify_replacements(before_extra, archive_members(patched), extra_objects)
        if digest(original) != spec['originalArchiveSHA256']:
            raise ValueError('Original additional archive was modified')
        report['additionalArchives'][name] = {
            'originalArchiveSHA256': spec['originalArchiveSHA256'],
            'archiveSHA256': digest(patched), 'objectSHA256ByMember': extra_objects,
            'replacedMembers': list(extra_objects),
            'preservedMemberCount': len(before_extra) - len(extra_objects)}
    report['archiveReplacementPassed'] = True
    save()
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.bundle, args.source, args.output), indent=2))

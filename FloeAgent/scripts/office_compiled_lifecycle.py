"""One portable contract for the compiled embedded iOS lifecycle member.

Parent prepared-source overlays and compiled VCL repairs have different patch
identities. New builds/storage/pins require this block; an old device pin may
remain usable for development only until a new exact-source component is pinned.
"""
import copy
import hashlib
from pathlib import Path, PurePosixPath
import re
import struct
import os
import subprocess

HEX64 = re.compile(r'[0-9a-f]{64}\Z')
HEX40 = re.compile(r'[0-9a-f]{40}\Z')
HASH_FIELDS = ('originalArchiveSHA256', 'archiveSHA256', 'linkerListSHA256')


def require(condition, message):
    if not condition:
        raise ValueError('Compiled embedded lifecycle: ' + message)


def relative(value):
    require(isinstance(value, str), 'path must be text')
    path = PurePosixPath(value)
    require(bool(value) and not path.is_absolute() and '..' not in path.parts
            and '\\' not in value and '\x00' not in value and str(path) == value,
            'noncanonical contract path')
    return path


def contract(lock, platform, *, spec=None):
    require(platform in ('IOS', 'IOSSIMULATOR'), 'unknown platform')
    overlay = lock.get('embeddedLifecycleOverlay') or {}
    selected = spec if spec is not None else (overlay.get('compiledMembers') or {}).get(platform)
    if selected is None:
        return None
    require(isinstance(selected, dict), 'invalid tracked member contract')
    require(set(selected) <= {'sourceFile', 'originalSHA256', 'patchedSHA256', 'patchSHA256',
                             'archive', 'members', 'patch', 'additionalArchives', 'compileOverrides', 'additionalMembers'},
            'unknown tracked member field')
    require(isinstance(lock.get('commit'), str) and HEX40.fullmatch(lock['commit']), 'invalid source commit')
    for key in ('originalSHA256', 'patchedSHA256', 'patchSHA256'):
        require(isinstance(selected.get(key), str) and HEX64.fullmatch(selected[key]), 'invalid tracked ' + key)
    require(isinstance(overlay.get('sha256'), str) and HEX64.fullmatch(overlay['sha256']), 'invalid parent patch hash')
    for key in ('sourceFile', 'archive', 'patch'):
        relative(selected.get(key))
    members = selected.get('members')
    require(isinstance(members, dict) and bool(members), 'missing tracked members')
    for member, source in members.items():
        require(str(relative(member)) == Path(member).name and source == selected['sourceFile'], 'member/source mapping differs')
    additions = selected.get('additionalMembers', {})
    require(isinstance(additions, dict), 'invalid additional member contracts')
    sources = {selected['sourceFile']}
    for member, child in additions.items():
        require(str(relative(member)) == Path(member).name and member not in members,
                'duplicate/conflicting member name')
        require(isinstance(child, dict) and set(child) <= {
            'sourceFile', 'originalSHA256', 'patchedSHA256', 'patch', 'patchSHA256',
            'originalMemberSHA256', 'compileOverrides'}, 'invalid additional member fields')
        require(isinstance(child.get('originalMemberSHA256'), str)
                and HEX64.fullmatch(child['originalMemberSHA256']), 'invalid original member hash')
        nested = {k: v for k, v in child.items() if k != 'originalMemberSHA256'}
        nested.update(archive=selected['archive'], members={member: child.get('sourceFile')})
        contract(lock, platform, spec=nested)
        require(child['sourceFile'] not in sources, 'duplicate/conflicting member source')
        sources.add(child['sourceFile'])
    extras = selected.get('additionalArchives', {})
    require(isinstance(extras, dict), 'invalid additional archive contracts')
    for name, child in extras.items():
        require(Path(name).name == name and name != Path(selected['archive']).name,
                'invalid/duplicate additional archive name')
        require(isinstance(child, dict) and not child.get('additionalArchives'), 'nested archive contracts forbidden')
        contract(lock, platform, spec=child)
        require(Path(child['archive']).name == name, 'additional archive path/name differ')
    overrides = selected.get('compileOverrides', {})
    require(isinstance(overrides, dict) and set(overrides) <= {'flags', 'sourceIncludes', 'bundleIncludes', 'auxiliaryIncludes', 'officecfgHeaders'},
            'invalid compile overrides')
    for key, values in overrides.items():
        if key == 'officecfgHeaders':
            require(isinstance(values, dict) and bool(values), 'invalid officecfg header contracts')
            for component, header in values.items():
                require(isinstance(component, str) and 1 <= len(component.split('/')) <= 3
                        and all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', part) for part in component.split('/')),
                        'invalid officecfg component namespace')
                require(isinstance(header, dict) and set(header) == {
                    'schemaSHA256', 'stylesheetSHA256', 'dtdSHA256', 'generatedSHA256'}
                    and all(isinstance(value, str) and HEX64.fullmatch(value) for value in header.values()),
                    'invalid officecfg input/output hashes')
            continue
        require(isinstance(values, list) and all(isinstance(v, str) and v and '\x00' not in v for v in values),
                'invalid compile override values')
        if key == 'flags':
            require(all(re.fullmatch(r'-D[A-Za-z_][A-Za-z_0-9]*(?:=[A-Za-z_0-9]+)?', v) for v in values), 'only literal define additions are allowed')
        else:
            for value in values:
                relative(value)
                if key == 'sourceIncludes': require(value.startswith('engine/'), 'source include must belong to pinned engine')
                if key == 'auxiliaryIncludes': require(value.startswith('source/engine/workdir/'), 'auxiliary root must belong to verified engine headers')
    return selected


def member_specs(selected):
    """Explicit source/patch recipe for each archive member; no source inference."""
    base = {k: selected[k] for k in ('sourceFile', 'originalSHA256', 'patchedSHA256',
                                    'patch', 'patchSHA256')}
    if selected.get('compileOverrides'):
        base['compileOverrides'] = selected['compileOverrides']
    return {**{name: copy.deepcopy(base) for name in selected['members']},
            **copy.deepcopy(selected.get('additionalMembers', {}))}


def schema_version(selected):
    if selected.get('additionalMembers') or any(schema_version(c) == 3 for c in selected.get('additionalArchives', {}).values()):
        return 3
    return 2 if selected.get('additionalArchives') else 1


def source_bytes(checkout, spec, commit):
    """Read a checked working file, or a sparse-missing local pinned Git blob.

    Never repair a changed file, materialize the shared checkout, or fetch.
    The caller verifies checkout HEAD; the fallback names the immutable commit.
    """
    root = Path(checkout).resolve()
    path = root / relative(spec['sourceFile'])
    require(path.resolve().is_relative_to(root) and not path.is_symlink(), 'unsafe member source')
    require(isinstance(commit, str) and HEX40.fullmatch(commit), 'invalid source commit')
    limit = 16 * 1024 * 1024
    if path.exists():
        require(path.is_file() and path.stat().st_size <= limit, 'invalid member source file')
        data = path.read_bytes()
    else:
        target = commit + ':' + spec['sourceFile']
        env = dict(os.environ, GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
        command = ['git', '-C', str(root), 'cat-file']
        try:
            size = int(subprocess.check_output(command + ['-s', target], env=env, stderr=subprocess.PIPE, timeout=30))
            require(0 <= size <= limit, 'pinned member source blob is too large')
            data = subprocess.check_output(command + ['blob', target], env=env, stderr=subprocess.PIPE, timeout=30)
            require(isinstance(data, bytes) and len(data) == size, 'pinned source blob size differs')
        except (subprocess.SubprocessError, OSError, TypeError, ValueError) as error:
            raise ValueError('Compiled embedded lifecycle: member source unavailable in local pinned Git objects: '
                             + spec['sourceFile']) from error
    require(hashlib.sha256(data).hexdigest() == spec['originalSHA256'], 'member source hash differs')
    return data


def object_abi(path, platform):
    """Read the actual Mach-O object's CPU and build platform, without compiling."""
    data = path if isinstance(path, bytes) else Path(path).read_bytes()
    require(platform in ('IOS', 'IOSSIMULATOR'), 'unknown object ABI platform')
    require(len(data) >= 32 and data[:4] == b'\xcf\xfa\xed\xfe', 'member is not little-endian Mach-O 64')
    _, cpu, subtype, kind, count, commands, _, _ = struct.unpack_from('<8I', data)
    require(cpu == 0x100000c and subtype == 0 and kind == 1 and 32 + commands <= len(data), 'wrong member architecture/type')
    offset = 32; platforms = []
    for _ in range(count):
        require(offset + 8 <= 32 + commands, 'truncated member load command')
        command, size = struct.unpack_from('<2I', data, offset)
        require(size >= 8 and offset + size <= 32 + commands, 'invalid member load command')
        if command == 0x32:
            require(size >= 24, 'invalid member build version')
            platforms.append(struct.unpack_from('<I', data, offset + 8)[0])
        offset += size
    require(offset == 32 + commands and platforms == [{'IOS': 2, 'IOSSIMULATOR': 7}[platform]],
            'wrong/missing member ABI platform')
    return {'arch': 'arm64', 'platform': platform}


def single_lock(lock, platform, selected):
    result = copy.deepcopy(lock)
    result['embeddedLifecycleOverlay']['compiledMembers'][platform] = {
        k: copy.deepcopy(v) for k, v in selected.items() if k != 'additionalArchives'}
    return result


def identity(lock, platform, *, lock_path=None):
    selected = contract(lock, platform)
    if selected is None:
        return None
    if lock_path is not None:
        base = Path(lock_path).parent.resolve()
        for spec in member_specs(selected).values():
            patch = base / relative(spec['patch'])
            require(patch.is_file() and not patch.is_symlink()
                    and patch.resolve().is_relative_to(base), 'compiled patch is not a contained regular file')
            require(hashlib.sha256(patch.read_bytes()).hexdigest() == spec['patchSHA256'], 'compiled patch bytes differ from lock')
    result = {
        'schemaVersion': schema_version(selected),
        'platform': platform,
        'archive': selected['archive'],
        'members': {name: spec['sourceFile'] for name, spec in member_specs(selected).items()},
        'sourceCommit': lock['commit'],
        # Keep the old parent spelling unambiguous and backward compatible.
        'patchSHA256': lock['embeddedLifecycleOverlay']['sha256'],
        'compiledPatchSHA256': selected['patchSHA256'],
        'sourceFile': selected['sourceFile'],
        'originalSourceSHA256': selected['originalSHA256'],
        'patchedSourceSHA256': selected['patchedSHA256'],
        'compilePassed': True,
        'archiveReplacementPassed': True,
    }
    if selected.get('compileOverrides'):
        result['compileOverrides'] = copy.deepcopy(selected['compileOverrides'])
    if schema_version(selected) == 3:
        result['memberSources'] = member_specs(selected)
    return result


def validate(block, lock, platform, *, lock_path=None, expected=None, original_archives=None):
    """Validate new receipt/pin exactly; never silently downgrade a new schema."""
    fixed = identity(lock, platform, lock_path=lock_path)
    if fixed is None:
        require(block is None, 'untracked compiled member claim')
        return None
    require(isinstance(block, dict), 'required compiled member receipt is missing')
    extras = contract(lock, platform).get('additionalArchives', {})
    version3 = fixed['schemaVersion'] == 3
    extra_fields = ({'additionalArchives'} if extras else set()) | ({'linkOwnership'} if extras or version3 else set())
    if version3:
        extra_fields |= {'originalObjectSHA256ByMember', 'objectABIByMember'}
    require(set(block) == set(fixed) | set(HASH_FIELDS) | {'objectSHA256ByMember'} | extra_fields, 'receipt fields differ')
    for key, value in fixed.items():
        require(block.get(key) == value and type(block.get(key)) is type(value), 'receipt identity differs: ' + key)
    for key in HASH_FIELDS:
        require(isinstance(block.get(key), str) and HEX64.fullmatch(block[key]), 'invalid ' + key)
    require(block['originalArchiveSHA256'] != block['archiveSHA256'], 'archive was not replaced')
    objects = block.get('objectSHA256ByMember')
    require(isinstance(objects, dict) and set(objects) == set(fixed['members']), 'object member inventory differs')
    require(all(isinstance(value, str) and HEX64.fullmatch(value) for value in objects.values()), 'invalid object hash')
    if version3:
        originals = block['originalObjectSHA256ByMember']
        require(isinstance(originals, dict) and set(originals) == set(objects)
                and all(isinstance(v, str) and HEX64.fullmatch(v) for v in originals.values()), 'invalid original member inventory')
        for name, spec in fixed['memberSources'].items():
            if 'originalMemberSHA256' in spec:
                require(originals[name] == spec['originalMemberSHA256'], 'original member hash differs')
            require(originals[name] != objects[name], 'member was not replaced')
        require(block['objectABIByMember'] == {n: {'arch': 'arm64', 'platform': platform} for n in objects}, 'member ABI proof differs')
    if original_archives is not None:
        archive_name = Path(fixed['archive']).name
        require(original_archives.get(archive_name) == block['originalArchiveSHA256'], 'original archive differs from platform proof')
    if extras:
        children = block.get('additionalArchives')
        require(isinstance(children, dict) and set(children) == set(extras), 'additional archive inventory differs')
        for name, selected in extras.items():
            validate(children[name], single_lock(lock, platform, selected), platform,
                     lock_path=lock_path, original_archives=original_archives)
    if extras or version3:
        validate_link_ownership(block['linkOwnership'], block, lock, platform)
    if expected is not None:
        require(block == expected, 'restored receipt differs from pinned compiled member')
    return copy.deepcopy(block)


def validate_manifest(manifest, lock, platform, *, lock_path=None, expected=None):
    """Validate portable evidence, including the producer's platform originals."""
    originals = None
    if contract(lock, platform) is not None:
        sdk = {'IOS': 'iphoneos', 'IOSSIMULATOR': 'iphonesimulator'}[platform]
        proof = manifest.get('platformOriginalArchives')
        require(isinstance(proof, dict) and proof.get('sdk') == sdk
                and isinstance(proof.get('archives'), dict), 'missing/wrong platform original archive proof')
        originals = proof['archives']
    return validate(manifest.get('embeddedLifecycleMember'), lock, platform,
                    lock_path=lock_path, expected=expected, original_archives=originals)


def validate_legacy_simulator(block, lock, original_archives):
    """Historical pre-schema simulator only; not canonical compiled evidence.

    Kept for the independently audited f033 component during current App
    acceptance. New producers always emit schemaVersion and cannot enter here.
    """
    selected = contract(lock, 'IOSSIMULATOR')
    require(selected is not None and isinstance(block, dict), 'historical simulator member missing')
    require(schema_version(selected) != 3, 'multi-source contracts cannot use historical compatibility')
    require('schemaVersion' not in block, 'versioned receipts cannot use historical compatibility')
    keys = {'platform', 'archive', 'originalArchiveSHA256', 'archiveSHA256',
            'objectSHA256ByMember', 'members', 'linkerListSHA256', 'patchSHA256', 'sourceCommit'}
    require(set(block) == keys, 'historical simulator fields differ')
    require(block['platform'] == 'IOSSIMULATOR' and block['sourceCommit'] == lock['commit']
            and block['archive'] == selected['archive'] and block['members'] == selected['members']
            and block['patchSHA256'] == lock['embeddedLifecycleOverlay']['sha256'], 'historical simulator identity differs')
    for key in HASH_FIELDS:
        require(isinstance(block[key], str) and HEX64.fullmatch(block[key]), 'invalid historical ' + key)
    objects = block['objectSHA256ByMember']
    require(isinstance(objects, dict) and set(objects) == set(selected['members'])
            and all(isinstance(v, str) and HEX64.fullmatch(v) for v in objects.values()), 'historical object inventory differs')
    require(block['originalArchiveSHA256'] == original_archives.get(Path(selected['archive']).name), 'historical original archive differs')
    return copy.deepcopy(block)


def validate_link_ownership(proof, block, lock, platform):
    """Producer-measured linkmap identity, not an independent compilation proof."""
    require(isinstance(proof, dict) and set(proof) == {'linkMapSHA256', 'linkerListSHA256', 'archives', 'preparedObjects'},
            'missing/invalid link ownership proof')
    require(isinstance(proof['linkMapSHA256'], str) and HEX64.fullmatch(proof['linkMapSHA256']), 'invalid link map hash')
    require(isinstance(proof['linkerListSHA256'], str) and HEX64.fullmatch(proof['linkerListSHA256']), 'invalid final linker list hash')
    all_blocks = {Path(block['archive']).name: block, **block.get('additionalArchives', {})}
    expected = {name: {'archiveSHA256': item['archiveSHA256'],
                       'objectSHA256ByMember': item['objectSHA256ByMember']}
                for name, item in all_blocks.items()}
    require(proof['archives'] == expected, 'linked archive/member identities differ')
    prepared = proof['preparedObjects']
    files = lock['embeddedLifecycleOverlay']['files']
    require(isinstance(prepared, dict) and set(prepared) == set(files), 'prepared object source inventory differs')
    for name, item in prepared.items():
        require(isinstance(item, dict) and set(item) == {'preparedSourceSHA256', 'objectSHA256', 'objectName'}, 'invalid prepared object evidence')
        require(item['preparedSourceSHA256'] == files[name]['preparedSHA256']
                and item['objectName'] == Path(name).stem + '.o'
                and isinstance(item['objectSHA256'], str) and HEX64.fullmatch(item['objectSHA256']), 'prepared source/object differs')

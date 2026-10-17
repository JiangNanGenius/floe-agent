"""One portable contract for the compiled embedded iOS lifecycle member.

Parent prepared-source overlays and compiled VCL repairs have different patch
identities. New builds/storage/pins require this block; an old device pin may
remain usable for development only until a new exact-source component is pinned.
"""
import copy
import hashlib
from pathlib import Path, PurePosixPath
import re

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
                             'archive', 'members', 'patch', 'additionalArchives', 'compileOverrides'},
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
    extras = selected.get('additionalArchives', {})
    require(isinstance(extras, dict), 'invalid additional archive contracts')
    for name, child in extras.items():
        require(Path(name).name == name and name != Path(selected['archive']).name,
                'invalid/duplicate additional archive name')
        require(isinstance(child, dict) and not child.get('additionalArchives'), 'nested archive contracts forbidden')
        contract(lock, platform, spec=child)
        require(Path(child['archive']).name == name, 'additional archive path/name differ')
    overrides = selected.get('compileOverrides', {})
    require(isinstance(overrides, dict) and set(overrides) <= {'flags', 'sourceIncludes', 'bundleIncludes'},
            'invalid compile overrides')
    for key, values in overrides.items():
        require(isinstance(values, list) and all(isinstance(v, str) and v and '\x00' not in v for v in values),
                'invalid compile override values')
        if key == 'flags':
            require(all(re.fullmatch(r'-D[A-Za-z_][A-Za-z_0-9]*(?:=[A-Za-z_0-9]+)?', v) for v in values), 'only literal define additions are allowed')
        else:
            for value in values:
                relative(value)
                if key == 'sourceIncludes': require(value.startswith('engine/'), 'source include must belong to pinned engine')
    return selected


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
        patch = base / relative(selected['patch'])
        require(patch.is_file() and not patch.is_symlink()
                and patch.resolve().is_relative_to(base), 'compiled patch is not a contained regular file')
        require(hashlib.sha256(patch.read_bytes()).hexdigest() == selected['patchSHA256'], 'compiled patch bytes differ from lock')
    result = {
        'schemaVersion': 2 if selected.get('additionalArchives') else 1,
        'platform': platform,
        'archive': selected['archive'],
        'members': dict(selected['members']),
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
    return result


def validate(block, lock, platform, *, lock_path=None, expected=None, original_archives=None):
    """Validate new receipt/pin exactly; never silently downgrade a new schema."""
    fixed = identity(lock, platform, lock_path=lock_path)
    if fixed is None:
        require(block is None, 'untracked compiled member claim')
        return None
    require(isinstance(block, dict), 'required compiled member receipt is missing')
    extras = contract(lock, platform).get('additionalArchives', {})
    extra_fields = {'additionalArchives', 'linkOwnership'} if extras else set()
    require(set(block) == set(fixed) | set(HASH_FIELDS) | {'objectSHA256ByMember'} | extra_fields, 'receipt fields differ')
    for key, value in fixed.items():
        require(block.get(key) == value and type(block.get(key)) is type(value), 'receipt identity differs: ' + key)
    for key in HASH_FIELDS:
        require(isinstance(block.get(key), str) and HEX64.fullmatch(block[key]), 'invalid ' + key)
    require(block['originalArchiveSHA256'] != block['archiveSHA256'], 'archive was not replaced')
    objects = block.get('objectSHA256ByMember')
    require(isinstance(objects, dict) and set(objects) == set(fixed['members']), 'object member inventory differs')
    require(all(isinstance(value, str) and HEX64.fullmatch(value) for value in objects.values()), 'invalid object hash')
    if original_archives is not None:
        archive_name = Path(fixed['archive']).name
        require(original_archives.get(archive_name) == block['originalArchiveSHA256'], 'original archive differs from platform proof')
    if extras:
        children = block.get('additionalArchives')
        require(isinstance(children, dict) and set(children) == set(extras), 'additional archive inventory differs')
        for name, selected in extras.items():
            validate(children[name], single_lock(lock, platform, selected), platform,
                     lock_path=lock_path, original_archives=original_archives)
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
    all_blocks = {Path(block['archive']).name: block, **block['additionalArchives']}
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

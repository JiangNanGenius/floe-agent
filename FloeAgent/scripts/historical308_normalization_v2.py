#!/usr/bin/env python3
"""Historical308-only Apple normalization and paired AppleDouble evidence.

This module parses/hashes Mach-O bytes but never writes them. Apple's codesign
is the sole binary mutator. The final source/transport comparison is complete
byte equality, including the resulting active segment metadata.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import zipfile

NORMALIZATION = 'apple-fixed-adhoc-remove-and-paired-appledouble-v2'
IDENTIFIER = 'org.floeagent.historical308.normalization.v2'
MAX_METADATA = 1024 * 1024
MACHO = {bytes.fromhex(x) for x in ('cffaedfe', 'cefaedfe', 'feedfacf', 'feedface',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


class NormalizationError(ValueError):
    pass


def insist(condition, message):
    if not condition:
        raise NormalizationError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def image(data):
    """Read the actual build308 layout: one arm64 image, thin or one-slice FAT.

    Other architectures/layouts need a separate review, never guessed offsets.
    All offsets below are absolute file offsets. No field is rewritten here.
    """
    insist(len(data) >= 32, 'Truncated Mach-O')
    magic = data[:4]
    base, size, fat_size_field = 0, len(data), None
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = magic == b'\xca\xfe\xba\xbf'
        insist(struct.unpack_from('>I', data, 4)[0] == 1, 'Only the reviewed single arm64 FAT slice is supported')
        width = 32 if wide else 20
        insist(len(data) >= 8 + width, 'Truncated FAT descriptor')
        fields = struct.unpack_from('>iiQQII' if wide else '>iiIII', data, 8)
        cpu, subtype, base, size, alignment = fields[:5]
        insist(cpu == 0x100000c and subtype == 0 and 0 <= alignment <= 24
               and base >= 8 + width and base % (1 << alignment) == 0
               and size > 0 and base + size == len(data), 'Unexpected FAT architecture or extent')
        fat_size_field = {'offset': 24 if wide else 20, 'bytes': 8 if wide else 4}
    insist(data[base:base + 4] == b'\xcf\xfa\xed\xfe' and size >= 32,
           'Only the reviewed little-endian arm64 Mach-O image is supported')
    header = struct.unpack_from('<IiiIIIII', data, base)
    insist(header[1:3] == (0x100000c, 0), 'Unexpected Mach-O architecture')
    ncmds, sizeofcmds = header[4:6]
    insist(0 < ncmds <= 8192 and sizeofcmds <= min(size - 32, 1024 * 1024), 'Invalid load command budget')
    offset, end = base + 32, base + 32 + sizeofcmds
    segments, signature = [], None
    for i in range(ncmds):
        insist(offset + 8 <= end, 'Truncated load command')
        cmd, length = struct.unpack_from('<II', data, offset)
        insist(length >= 8 and length % 8 == 0 and offset + length <= end, 'Invalid load command extent')
        if cmd == 0x19:
            insist(length >= 72, 'Truncated segment command')
            s = struct.unpack_from('<II16sQQQQiiII', data, offset)
            insist(72 + s[9] * 80 == length, 'Invalid segment section table')
            segments.append({'name': s[2].split(b'\0', 1)[0].decode('ascii'),
                             'offset': offset, 'vmsize': s[4], 'fileoff': s[5], 'filesize': s[6],
                             'vmsizeField': {'offset': offset + 32, 'bytes': 8},
                             'filesizeField': {'offset': offset + 48, 'bytes': 8}})
        if cmd == 0x1d:
            insist(signature is None and length == 16 and i == ncmds - 1,
                   'Only a single trailing LC_CODE_SIGNATURE is reviewed')
            _, _, start, length_data = struct.unpack_from('<IIII', data, offset)
            signature = {'commandOffset': offset, 'dataOffset': base + start, 'bytes': length_data}
            insist(base + start >= end and length_data > 0 and start + length_data == size,
                   'Signature extent is not the complete slice tail')
        offset += length
    insist(offset == end, 'Load command count/extent mismatch')
    linkedit = [s for s in segments if s['name'] == '__LINKEDIT']
    insist(len(linkedit) == 1, 'A unique reviewed __LINKEDIT segment is required')
    linkedit = linkedit[0]
    insist(base + linkedit['fileoff'] + linkedit['filesize'] == len(data), 'Unexpected __LINKEDIT file extent')
    return {'base': base, 'bytes': size, 'fatSizeField': fat_size_field, 'header': list(header),
            'loadCommandsEnd': end, 'linkedit': linkedit, 'signature': signature}


def changed_ranges(before, after):
    """Every byte in the common prefix is compared; no equivalence masking."""
    result, active = [], None
    for offset in range(0, len(after), 1024 * 1024):
        a, b = before[offset:offset + 1024 * 1024], after[offset:offset + 1024 * 1024]
        a = a[:len(b)]
        if a == b:
            if active is not None:
                result.append(active); active = None
            continue
        for i, (x, y) in enumerate(zip(a, b)):
            current = offset + i
            if x != y:
                if active is None:
                    active = {'offset': current, 'endExclusive': current + 1}
                else:
                    active['endExclusive'] = current + 1
            elif active is not None:
                result.append(active); active = None
    if active is not None:
        result.append(active)
    for r in result:
        r['bytes'] = r['endExclusive'] - r['offset']
        insist(r['bytes'] <= 32, 'Unexpected broad binary rewrite')
        r['beforeHex'] = before[r['offset']:r['endExclusive']].hex()
        r['afterHex'] = after[r['offset']:r['endExclusive']].hex()
    return result


def prove_roundtrip(before, after):
    old, new = image(before), image(after)
    insist(new['signature'] is None and old['base'] == new['base']
           and bool(old['fatSizeField']) == bool(new['fatSizeField']), 'Roundtrip changed the image layout or retained a signature')
    insist(len(after) <= len(before), 'Roundtrip grew the unsigned image')
    allowed = [old['linkedit']['vmsizeField'] | {'name': '__LINKEDIT.vmsize'}]
    signature = old['signature']
    if signature:
        insist(old['header'][4] == new['header'][4] + 1 and old['header'][5] == new['header'][5] + 16,
               'Signature removal did not remove exactly its load command')
        insist(0 <= signature['dataOffset'] - len(after) <= 15
               and not any(before[len(after):signature['dataOffset']]), 'Unexpected removed bytes outside signature/alignment')
        insist(new['loadCommandsEnd'] == signature['commandOffset']
               and not any(after[signature['commandOffset']:signature['commandOffset'] + 16]),
               'Removed signature command was not cleared')
        allowed.extend([{'offset': old['base'] + 16, 'bytes': 8, 'name': 'header.ncmds+sizeofcmds'},
                        old['linkedit']['filesizeField'] | {'name': '__LINKEDIT.filesize'},
                        {'offset': signature['commandOffset'], 'bytes': 16, 'name': 'removed LC_CODE_SIGNATURE'}])
        if old['fatSizeField']:
            allowed.append(old['fatSizeField'] | {'name': 'FAT slice size'})
    else:
        insist(len(before) == len(after), 'Unsigned roundtrip changed the file length')
    ranges = changed_ranges(before, after)
    for r in ranges:
        matches = [f for f in allowed if f['offset'] <= r['offset'] and r['endExclusive'] <= f['offset'] + f['bytes']]
        insist(len(matches) == 1, 'Apple tool changed bytes outside the explicitly checked signature metadata')
        r['field'] = matches[0]['name']
    # Hash every compared non-signature span. These hashes are evidence about
    # this tool transformation, not exceptions to final source/transport SHA.
    spans, cursor = [], 0
    for field in sorted(allowed, key=lambda f: f['offset']):
        if field['offset'] > cursor:
            block = after[cursor:field['offset']]
            insist(block == before[cursor:field['offset']], 'Non-signature data changed')
            spans.append({'offset': cursor, 'bytes': len(block), 'sha256': sha(block)})
        cursor = max(cursor, field['offset'] + field['bytes'])
    if cursor < len(after):
        insist(after[cursor:] == before[cursor:len(after)], 'Non-signature data changed')
        spans.append({'offset': cursor, 'bytes': len(after) - cursor, 'sha256': sha(after[cursor:])})
    return {'inputSHA256': sha(before), 'inputBytes': len(before), 'outputSHA256': sha(after), 'outputBytes': len(after),
            'inputLayout': old, 'outputLayout': new, 'changedRanges': ranges,
            'removedSignature': None if signature is None else signature | {'sha256': sha(before[signature['dataOffset']:])},
            'removedAlignmentBytes': 0 if signature is None else signature['dataOffset'] - len(after),
            'nonSignatureSpans': spans, 'nonSignatureDataUnchanged': True, 'finalUnsigned': True}


def normalize_machos(app, *, signed=False, require_unsigned=False, invoke=subprocess.run, evidence_directory=None):
    env = dict(os.environ, LANG='C', LC_ALL='C')
    log, proofs = [], []

    def run(argv, *, check=True):
        result = invoke(argv, capture_output=True, text=True, env=env, timeout=90)
        # Logs are private, separate from the deterministic source binding.
        log.append({'argv': argv, 'exitCode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        if evidence_directory is not None:
            with (Path(evidence_directory) / 'MACHO-COMMANDS.private.jsonl').open('a') as stream:
                stream.write(json.dumps(log[-1], sort_keys=True) + '\n')
        insist(not check or result.returncode == 0, 'Apple codesign rejected normalization: ' + str(argv[-1]))
        return result

    app = Path(app)
    if signed:
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    for path in sorted(app.rglob('*')):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in MACHO:
            continue
        relative = path.relative_to(app).as_posix()
        before = path.read_bytes(); before_mode = stat.S_IMODE(path.stat().st_mode)
        parsed = image(before)
        if require_unsigned:
            insist(parsed['signature'] is None, 'Output IPA contains signed Mach-O')
        # A fixed ID and no timestamp make this an Apple-defined deterministic
        # projection. It grants no signing identity or publication authority.
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', IDENTIFIER, '--timestamp=none', str(path)])
        intermediate = path.read_bytes()
        insist(image(intermediate)['signature'] is not None, 'Apple did not create the temporary adhoc signature')
        run(['/usr/bin/codesign', '--verify', '--strict', str(path)])
        run(['/usr/bin/codesign', '--remove-signature', str(path)])
        after = path.read_bytes()
        insist(stat.S_IMODE(path.stat().st_mode) == before_mode, 'Apple normalization changed file permissions')
        proof = prove_roundtrip(before, after)
        proof.update({'path': relative, 'mode': before_mode, 'intermediateSHA256': sha(intermediate),
                      'intermediateBytes': len(intermediate), 'identifier': IDENTIFIER, 'timestamp': 'none'})
        proofs.append(proof)
        if evidence_directory is not None:
            with (Path(evidence_directory) / 'MACHO-TRANSFORMS.private.jsonl').open('a') as stream:
                stream.write(json.dumps(proof, sort_keys=True) + '\n')
    insist(proofs, 'No reviewed Mach-O image found')
    return {'files': proofs, 'privateCommandLog': log}


def appledouble(data):
    """Strict reviewed v2 layout; opaque attribute values are hashed, not echoed."""
    insist(26 <= len(data) <= MAX_METADATA, 'AppleDouble size is outside the bounded contract')
    magic, version, filler, count = struct.unpack_from('>II16sH', data)
    insist(magic == 0x51607 and version == 0x20000 and filler == b'Mac OS X        '
           and 1 <= count <= 2, 'Unknown AppleDouble header/layout')
    end = 26 + 12 * count
    insist(end <= len(data), 'Truncated AppleDouble entry table')
    entries, seen, extents = [], set(), []
    for i in range(count):
        kind, offset, length = struct.unpack_from('>III', data, 26 + 12 * i)
        insist(kind in (2, 9) and kind not in seen and end <= offset <= len(data)
               and length <= len(data) - offset, 'Unknown, duplicate or out-of-bounds AppleDouble entry')
        seen.add(kind)
        if length:
            extents.append((offset, offset + length))
        entries.append({'id': kind, 'offset': offset, 'bytes': length, 'sha256': sha(data[offset:offset + length])})
    insist(9 in seen, 'AppleDouble FinderInfo entry is required')
    extents.sort()
    insist(all(a[1] <= b[0] for a, b in zip(extents, extents[1:])), 'Overlapping AppleDouble entries')
    cursor = end
    for begin, finish in extents:
        insist(not any(data[cursor:begin]), 'Unreviewed bytes between AppleDouble entries')
        cursor = finish
    insist(not any(data[cursor:]), 'Unreviewed trailing AppleDouble bytes')
    finder = next(e for e in entries if e['id'] == 9)
    insist(finder['bytes'] >= 32, 'Truncated AppleDouble FinderInfo')
    attrs = []
    finder_end = finder['offset'] + finder['bytes']
    if finder['bytes'] > 32:
        start = (finder['offset'] + 32 + 3) & ~3
        insist(start + 36 <= finder_end and not any(data[finder['offset'] + 32:start]), 'Invalid attribute alignment/header')
        values = struct.unpack_from('>8I2H', data, start)
        amagic, tag, total, data_start, data_length, r1, r2, r3, flags, nattrs = values
        insist(amagic == 0x41545452 and tag == 0 and total == len(data)
               and r1 == r2 == r3 == flags == 0 and 1 <= nattrs <= 256
               and start + 36 <= data_start <= finder_end and data_length == finder_end - data_start,
               'Unknown or inconsistent AppleDouble attribute header')
        pos, names, attr_extents = start + 36, set(), []
        for _ in range(nattrs):
            insist(pos + 11 <= data_start, 'Truncated AppleDouble attribute entry')
            offset, length, aflags, name_length = struct.unpack_from('>IIHB', data, pos)
            insist(aflags == 0 and 2 <= name_length <= 255 and pos + 11 + name_length <= data_start
                   and data_start <= offset <= finder_end and length <= finder_end - offset,
                   'Invalid AppleDouble attribute extent')
            name = data[pos + 11:pos + 11 + name_length]
            insist(name[-1:] == b'\0' and b'\0' not in name[:-1] and name not in names, 'Invalid or duplicate attribute name')
            try:
                name[:-1].decode('utf-8', 'strict')
            except UnicodeDecodeError as error:
                raise NormalizationError('Invalid attribute name encoding') from error
            names.add(name)
            attrs.append({'nameSHA256': sha(name), 'nameBytes': name_length, 'offset': offset,
                          'bytes': length, 'sha256': sha(data[offset:offset + length])})
            attr_extents.append((offset, offset + length))
            next_pos = (pos + 11 + name_length + 3) & ~3
            insist(next_pos <= data_start and not any(data[pos + 11 + name_length:next_pos]), 'Nonzero attribute table padding')
            pos = next_pos
        insist(not any(data[pos:data_start]), 'Unreviewed attribute table bytes')
        cursor = data_start
        for begin, finish in sorted(attr_extents):
            insist(begin >= cursor and not any(data[cursor:begin]), 'Overlapping or unreviewed attribute data')
            cursor = finish
        insist(not any(data[cursor:finder_end]), 'Unreviewed attribute tail')
    return {'magic': '0x00051607', 'version': '0x00020000', 'bytes': len(data), 'sha256': sha(data),
            'entries': entries, 'attributes': attrs}


def paired_metadata(signed_ipa, transport_archive, signed_app, transport_app, destination):
    """Move only exact validated pairs to private metadata; no ._ wildcard removal."""
    signed_app, transport_app, destination = Path(signed_app), Path(transport_app), Path(destination)
    insist(not destination.exists(), 'Metadata destination must be new')
    app_prefix = 'Payload/' + signed_app.name + '/'
    insist(signed_app.name == transport_app.name, 'App roots differ')
    records = []
    with zipfile.ZipFile(signed_ipa) as original, zipfile.ZipFile(transport_archive) as transport:
        a, b = {i.filename.rstrip('/'): i for i in original.infolist()}, {i.filename.rstrip('/'): i for i in transport.infolist()}
        insist(len(a) == len(original.infolist()) and len(b) == len(transport.infolist()), 'Duplicate archive member in metadata mapping')
        meta = [i for n, i in a.items() if n.startswith('__MACOSX/') and not i.is_dir()]
        candidates = {n for n, i in b.items() if n.startswith(app_prefix) and not i.is_dir() and Path(n).name.startswith('._')}
        insist(not any(n.startswith(app_prefix) and not i.is_dir() and Path(n).name.startswith('._') for n, i in a.items()),
               'Ambiguous AppleDouble member already inside signed Payload')
        expected = {i.filename[len('__MACOSX/'):] for i in meta}
        insist(candidates == expected, 'Missing, unknown or conflicting paired AppleDouble member')
        allowed_dirs = {str(parent) for name in ('__MACOSX/' + n for n in expected) for parent in Path(name).parents if str(parent) != '.'}
        insist(all(n in allowed_dirs for n, i in a.items() if n.startswith('__MACOSX') and i.is_dir()),
               'Unknown metadata directory')
        for info in sorted(meta, key=lambda i: i.filename):
            logical = info.filename[len('__MACOSX/'):]
            insist(logical.startswith(app_prefix) and Path(logical).name.startswith('._')
                   and logical in b and not b[logical].is_dir(), 'Unmapped AppleDouble path')
            target = str(Path(logical).with_name(Path(logical).name[2:]))
            insist(Path(target).name and target in a and target in b and not a[target].is_dir()
                   and not b[target].is_dir(), 'AppleDouble target is missing or not a regular archive member')
            insist(info.file_size <= MAX_METADATA and b[logical].file_size <= MAX_METADATA, 'AppleDouble member exceeds budget')
            raw, other = original.read(info), transport.read(b[logical])
            structure = appledouble(raw)
            insist(raw == other, 'Paired AppleDouble bytes conflict')
            local_relative = logical[len(app_prefix):]
            local = transport_app / local_relative
            insist(local.is_file() and not local.is_symlink() and local.read_bytes() == raw,
                   'Extracted AppleDouble differs from the exact archive pair')
            insist(not (signed_app / local_relative).exists(), 'Signed Payload already contains the mapped metadata path')
            records.append({'logicalPath': local_relative, 'targetPath': target[len(app_prefix):],
                            'signedMember': info.filename, 'transportMember': logical,
                            'signedArchiveMode': info.external_attr >> 16, 'transportArchiveMode': b[logical].external_attr >> 16,
                            'structure': structure})
        # Validate ALL records first; no partial mapping on unknown/conflict.
        destination.mkdir(parents=True)
        for record in records:
            local = transport_app / record['logicalPath']
            target = destination / record['logicalPath']
            target.parent.mkdir(parents=True, exist_ok=True)
            local.replace(target)
    summary = {'sha256': sha(canonical(records)), 'mappings': len(records),
               'bytes': sum(r['structure']['bytes'] for r in records)}
    return {'summary': summary, 'entries': records}

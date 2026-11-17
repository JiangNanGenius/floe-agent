#!/usr/bin/env python3
"""Seal the signing-only route's artifacts without placing its private key on CI."""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import zipfile

PRODUCT_SHA = 'fa252b61852dd37d489635c0dd83fe8c6b4b2d00'
CIPHERTEXTS = ['FloeTestFlightExport.cms', 'FloeTestFlightEvidence.cms', 'FloeTestFlightUpload.cms', 'FloeTestFlightApple.cms']


def run(*args, data=None):
    return subprocess.run(args, input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, check=True).stdout


def config():
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate configuration key')
            result[key] = value
        return result
    value = json.loads(os.environ['SECURE_TESTFLIGHT'], object_pairs_hook=unique)
    if not isinstance(value, dict) or set(value) != {'source_sha', 'infra_sha', 'recipient_sha256', 'recipient_certificate_base64'}:
        raise ValueError('invalid secure TestFlight configuration')
    if value['source_sha'] != PRODUCT_SHA or run('git', 'rev-parse', 'HEAD').decode().strip() != PRODUCT_SHA:
        raise ValueError('product commit mismatch')
    if not re.fullmatch(r'[0-9a-f]{64}', os.environ['ARTIFACT_SHA256']):
        raise ValueError('invalid transport digest')
    if not os.environ['GITHUB_RUN_ID'].isdigit() or not os.environ['GITHUB_RUN_ATTEMPT'].isdigit():
        raise ValueError('invalid signing run identity')
    if os.environ['GITHUB_RUN_ATTEMPT'] != '1':
        raise ValueError('secure TestFlight signing does not permit reruns; inspect Apple and the original run before a new dispatch')
    if not isinstance(value['infra_sha'], str) or not re.fullmatch(r'[0-9a-f]{40}', value['infra_sha']) or value['infra_sha'] != os.environ['GITHUB_SHA']:
        raise ValueError('infrastructure commit mismatch')
    digest = value['recipient_sha256']
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('invalid certificate digest')
    der = base64.b64decode(value['recipient_certificate_base64'], validate=True)
    if not 100 <= len(der) <= 65536 or hashlib.sha256(der).hexdigest() != digest:
        raise ValueError('certificate digest mismatch')
    return value, der


def validate():
    value, der = config()
    folder = Path(os.environ['RUNNER_TEMP']) / 'FloeTestFlightRecipient'
    folder.mkdir(mode=0o700, exist_ok=True)
    source, pem = folder / 'recipient.der', folder / 'recipient.pem'
    source.write_bytes(der)
    if run('openssl', 'x509', '-inform', 'DER', '-in', str(source), '-outform', 'DER') != der:
        raise ValueError('expected one canonical DER certificate')
    run('openssl', 'x509', '-inform', 'DER', '-in', str(source), '-out', str(pem))
    run('openssl', 'x509', '-in', str(pem), '-checkend', '0', '-noout')
    key = run('openssl', 'x509', '-in', str(pem), '-pubkey', '-noout')
    details = run('openssl', 'pkey', '-pubin', '-text', '-noout', data=key).decode('ascii')
    size = re.search(r'Public-Key:\s*\((\d+) bit\)', details)
    if not size or int(size.group(1)) < 3072 or 'Modulus:' not in details:
        raise ValueError('recipient must use RSA with at least 3072 bits')
    return value, pem


def paths(root, selections):
    found = []
    for selection in selections:
        path = root / selection
        if path.is_symlink():
            raise ValueError('artifact root must not be a symlink')
        if path.is_file():
            found.append(path)
        elif path.is_dir():
            for current, dirs, files in os.walk(path, followlinks=False):
                dirs.sort()
                files.sort()
                directory = Path(current)
                for name in list(dirs):
                    item = directory / name
                    if item.is_symlink():
                        found.append(item)
                        dirs.remove(name)
                found.extend(directory / name for name in files)
    return sorted(found, key=lambda p: p.relative_to(root).as_posix())


def verify_archive(archive):
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)) or names.count('MANIFEST.json') != 1:
            raise ValueError('invalid archive names')
        manifest = json.loads(source.read('MANIFEST.json'))
        entries = manifest['files']
        if set(names) != {'MANIFEST.json'} | {entry['path'] for entry in entries} or len(entries) != len(names) - 1:
            raise ValueError('archive file list mismatch')
        for entry in entries:
            item = source.getinfo(entry['path'])
            attributes = item.external_attr >> 16
            kind = 'symlink' if stat.S_ISLNK(attributes) else 'file' if stat.S_ISREG(attributes) else None
            if kind != entry['type'] or stat.S_IMODE(attributes) != entry['mode'] or item.file_size != entry['size']:
                raise ValueError('archive file metadata mismatch')
            digest = hashlib.sha256()
            with source.open(item) as data:
                while chunk := data.read(1024 * 1024):
                    digest.update(chunk)
            if digest.hexdigest() != entry['sha256']:
                raise ValueError('archive file digest mismatch')


def write_archive(root, value, name, selections, archive):
    entries = []
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=3, allowZip64=True) as out:
        for path in paths(root, selections):
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                data = os.readlink(path).encode('utf-8')
                item = zipfile.ZipInfo(relative)
                item.create_system = 3
                item.external_attr = (stat.S_IFLNK | mode) << 16
                out.writestr(item, data)
                digest, size, kind = hashlib.sha256(data).hexdigest(), len(data), 'symlink'
            elif stat.S_ISREG(info.st_mode):
                digestor = hashlib.sha256()
                size = 0
                item = zipfile.ZipInfo(relative)
                item.create_system = 3
                item.compress_type = zipfile.ZIP_DEFLATED
                item.external_attr = (stat.S_IFREG | mode) << 16
                with path.open('rb') as source, out.open(item, 'w', force_zip64=True) as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
                        digestor.update(chunk)
                        size += len(chunk)
                digest, kind = digestor.hexdigest(), 'file'
            else:
                raise ValueError('unsupported artifact file type')
            entries.append({'path': relative, 'type': kind, 'mode': mode, 'size': size, 'sha256': digest})
        manifest = {'schema': 1, 'product_sha': value['source_sha'], 'signing_infra_sha': value['infra_sha'],
                    'recipient_sha256': value['recipient_sha256'], 'tag': os.environ['RELEASE_TAG'],
                    'transport_sha256': os.environ['ARTIFACT_SHA256'], 'run_id': os.environ['GITHUB_RUN_ID'],
                    'run_attempt': os.environ['GITHUB_RUN_ATTEMPT'], 'version': os.environ.get('APP_VERSION'),
                    'build': os.environ.get('APP_BUILD'),
                    'signing_job_status': os.environ.get('SIGNING_JOB_STATUS', 'unknown'),
                    'ciphertexts': CIPHERTEXTS, 'archive_ciphertext': name, 'files': entries}
        out.writestr('MANIFEST.json', json.dumps(manifest, indent=2, sort_keys=True) + '\n')


def seal(root, value, pem, name, selections):
    archive = root / (name + '.zip')
    ciphertext = root / name
    tmp = ciphertext.with_suffix('.cms.partial')
    try:
        write_archive(root, value, name, selections, archive)
        verify_archive(archive)
        run('openssl', 'cms', '-encrypt', '-binary', '-aes256', '-outform', 'DER', '-in', str(archive), '-out', str(tmp), str(pem))
        run('openssl', 'cms', '-cmsout', '-inform', 'DER', '-in', str(tmp), '-noout')
        tmp.replace(ciphertext)
    finally:
        archive.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)


def main():
    value, pem = validate()
    if sys.argv[1:] == ['validate']:
        return
    if sys.argv[1:] not in (['encrypt-early'], ['encrypt-upload'], ['encrypt-apple']):
        raise ValueError('expected validate, encrypt-early, encrypt-upload or encrypt-apple')
    root = Path(os.environ['RUNNER_TEMP'])
    if sys.argv[1:] == ['encrypt-upload']:
        required = ['TestFlightExport/UPLOAD-RECEIPT.txt', 'TestFlightExport/TESTFLIGHT-SUMMARY.txt']
        if os.environ.get('SIGNING_JOB_STATUS') == 'success':
            for path in required:
                file = root / path
                if file.is_symlink() or not file.is_file() or file.stat().st_size == 0:
                    raise ValueError('successful upload is missing nonempty evidence: ' + path)
        seal(root, value, pem, CIPHERTEXTS[2], required)
        return
    if sys.argv[1:] == ['encrypt-apple']:
        apple = root / 'APPLE-INTERNAL.json'
        if os.environ.get('SIGNING_JOB_STATUS') == 'success' and (apple.is_symlink() or not apple.is_file() or apple.stat().st_size == 0):
            raise ValueError('successful Apple verification is missing nonempty evidence')
        seal(root, value, pem, CIPHERTEXTS[3], ['APPLE-INTERNAL.json'])
        return
    if os.environ.get('SIGNING_JOB_STATUS') == 'success':
        for required in ('TestFlightExport/FloeAgent.ipa',
                         'TestFlightExport/bundle-normalization.json', 'TestFlightExport/apns-signing-profile.json',
                         'FloeSignedPayload/provenance.json'):
            file = root / required
            if file.is_symlink() or not file.is_file() or file.stat().st_size == 0:
                raise ValueError('successful signing is missing nonempty evidence: ' + required)
        if not (root / 'FloeSignedPayload/symbols').is_dir() or not paths(root, ['FloeSignedPayload/symbols']):
            raise ValueError('successful signing is missing symbols')
    seal(root, value, pem, CIPHERTEXTS[0], ['TestFlightExport/FloeAgent.ipa', 'TestFlightExport/bundle-normalization.json',
                                          'TestFlightExport/apns-signing-profile.json'])
    seal(root, value, pem, CIPHERTEXTS[1], ['FloeSignedPayload/provenance.json', 'FloeSignedPayload/symbols',
                                          'apns-signing-profile.json'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print('Secure TestFlight artifact error:', error, file=sys.stderr)
        sys.exit(1)

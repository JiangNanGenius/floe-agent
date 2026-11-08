#!/usr/bin/env python3
"""Preparation-only historical308 source binding; no publication or trust writes.

Policy/controller inputs are external reviewed trust, never values learned from
the binding being verified. No valid policy/controller entry ships with this
module. Signatures are checked before parsing an untrusted binding, followed by
independent GitHub/source/archive/device-manifest checks. Ordinary release and
Feather trust contracts are unchanged.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

REPOSITORY = 'JiangNanGenius/floe-agent'
TAG, VERSION, BUILD, BUNDLE = 'v1.7.67', '1.7.67', '308', 'org.floeagent.ios'
IPA_NAME = 'Floe-Agent-1.7.67-build308-unsigned.ipa'
BINDING_NAME = 'FLOE-HISTORICAL-SOURCE-BINDING.json'
WORKFLOW = '.github/workflows/prepare-historical308.yml'
SOURCE_WORKFLOW = '.github/workflows/release-unsigned-ipa.yml'
NORMALIZATION = 'apple-fixed-adhoc-remove-and-paired-appledouble-v2'
SHA = re.compile(r'[0-9a-f]{64}')
COMMIT = re.compile(r'[0-9a-f]{40}')
MACHO = {bytes.fromhex(x) for x in ('cffaedfe', 'cefaedfe', 'feedfacf', 'feedface',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


class BindingError(ValueError):
    def __init__(self, code, path, reason):
        self.code, self.path, self.reason = code, path, reason
        super().__init__(f'{code} at {path}: {reason}')


def require(condition, code, path, reason):
    if not condition:
        raise BindingError(code, path, reason)


def exact(value, names, path):
    require(isinstance(value, dict) and set(value) == set(names.split()),
            'schema', path, 'Missing or unknown fields')


def positive(value):
    return type(value) is int and value > 0


def hexadecimal(value, pattern=SHA):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def timestamp(value, path):
    require(isinstance(value, str), 'missingProof', path, 'UTC attempt/artifact timestamp required')
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(result.tzinfo is not None, 'missingProof', path, 'Timestamp must include a timezone')
    return result


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def read_json(path, maximum=65536):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= maximum,
            'missingProof', path.name, 'A bounded regular JSON file is required')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'schema', key, 'Duplicate JSON key')
            result[key] = value
        return result
    def constant(_):
        raise BindingError('schema', path.name, 'Non-finite JSON value')
    return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=constant)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


publication = module('historical_publication_audit', 'verify_github_release_publication.py')
recovery = module('historical_safe_archive', 'verify_accepted_sdk_recovery.py')
projection = module('historical_normalization_v2', 'historical308_normalization_v2.py')


def validate_policy(policy, review_only=False):
    exact(policy, 'schemaVersion purpose normalization app original transport expectedManifest packagerSHA256', 'policy')
    require(type(policy['schemaVersion']) is int and policy['schemaVersion'] == 2
            and policy['purpose'] == 'historical308-preparation-only-v2'
            and policy['normalization'] == NORMALIZATION,
            'policy', 'policy.purpose', 'This contract prepares build308 only; it grants no publication authority')
    app = policy['app']; exact(app, 'tag tagObjectSHA sourceCommit version build bundleIdentifier', 'policy.app')
    require((app['tag'], app['version'], app['build'], app['bundleIdentifier']) == (TAG, VERSION, BUILD, BUNDLE)
            and hexadecimal(app['tagObjectSHA'], COMMIT) and hexadecimal(app['sourceCommit'], COMMIT),
            'policy', 'policy.app', 'The exact immutable build308 identity is required')
    original = policy['original']; exact(original, 'runID runAttempt artifactID archiveSHA256 archiveBytes', 'policy.original')
    transport = policy['transport']; exact(transport, 'archiveSHA256 archiveBytes releaseID assetID', 'policy.transport')
    require(all(positive(original[k]) for k in ('runID', 'runAttempt', 'artifactID', 'archiveBytes'))
            and hexadecimal(original['archiveSHA256']) and positive(transport['archiveBytes'])
            and positive(transport['releaseID']) and positive(transport['assetID'])
            and hexadecimal(transport['archiveSHA256']) and hexadecimal(policy['packagerSHA256']),
            'policy', 'policy.original', 'Pinned original run/artifact and both archive identities are required')
    manifest = policy['expectedManifest']; exact(manifest, 'sha256 files bytes', 'policy.expectedManifest')
    if not review_only:
        require(hexadecimal(manifest['sha256']) and positive(manifest['files']) and positive(manifest['bytes']),
                'missingReviewedManifest', 'policy.expectedManifest', 'Review the complete original device manifest before preparing a binding')


def validate_controller(controller):
    exact(controller, 'commit ref runID runAttempt workflow', 'controller')
    require(hexadecimal(controller['commit'], COMMIT) and positive(controller['runID'])
            and positive(controller['runAttempt']) and controller['workflow'] == WORKFLOW
            and isinstance(controller['ref'], str)
            and re.fullmatch(r'refs/tags/[A-Za-z0-9][A-Za-z0-9._/-]*', controller['ref'])
            and '..' not in controller['ref'] and '//' not in controller['ref']
            and not controller['ref'].endswith(('/', '.lock'))
            and controller['ref'] != 'refs/tags/' + TAG,
            'controller', 'controller', 'An exact reviewed packaging tag/commit/run is required; it is not the App source')


def github_api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))


def check_sources(policy, controller, api_get, *, completed_controller):
    app, original = policy['app'], policy['original']
    ref = api_get('git/ref/tags/' + TAG)
    require(isinstance(ref.get('object'), dict) and ref['object'].get('type') == 'tag'
            and ref['object'].get('sha') == app['tagObjectSHA'],
            'sourceTag', 'app.tagObjectSHA', 'Original annotated tag object changed')
    obj = api_get('git/tags/' + app['tagObjectSHA'])
    commit, _ = publication.peel_tag_commit(ref, obj, TAG)
    require(commit == app['sourceCommit'], 'sourceTag', 'app.sourceCommit', 'Original App source changed')
    run = api_get(f"actions/runs/{original['runID']}/attempts/{original['runAttempt']}")
    require(run.get('id') == original['runID'] and run.get('run_attempt') == original['runAttempt']
            and run.get('head_repository', {}).get('full_name') == REPOSITORY
            and run.get('head_sha') == app['sourceCommit'] and run.get('head_branch') == TAG
            and run.get('path') == SOURCE_WORKFLOW and run.get('event') == 'workflow_dispatch'
            and run.get('status') == 'completed' and run.get('conclusion') == 'success',
            'originalRun', 'original.runID', 'The original exact-source successful run is required')
    artifact = api_get(f"actions/artifacts/{original['artifactID']}")
    require(artifact.get('expired') is False, 'originalArtifactExpired', 'original.artifactID',
            'Original artifact authority is missing/expired; retained bytes alone are insufficient')
    require(artifact.get('id') == original['artifactID'] and artifact.get('name') == 'testflight-1.7.67-build308'
            and artifact.get('digest') == 'sha256:' + original['archiveSHA256']
            and artifact.get('size_in_bytes') == original['archiveBytes']
            and artifact.get('workflow_run', {}).get('id') == original['runID']
            and artifact.get('workflow_run', {}).get('head_sha') == app['sourceCommit'],
            'originalArtifact', 'original.artifactID', 'Original artifact/run/digest/size mismatch')
    require(timestamp(run.get('run_started_at'), 'original.runStartedAt') <=
            timestamp(artifact.get('created_at'), 'original.artifactCreatedAt') <=
            timestamp(run.get('updated_at'), 'original.runCompletedAt'),
            'originalAttempt', 'original.artifactID', 'Artifact was not created within the exact successful attempt')
    jobs = api_get(f"actions/runs/{original['runID']}/attempts/{original['runAttempt']}/jobs?per_page=100")
    require(isinstance(jobs.get('jobs'), list) and jobs.get('total_count') == len(jobs['jobs']),
            'missingProof', 'original.jobs', 'The complete original job page is required')
    confirmations = [step for job in jobs['jobs'] if job.get('conclusion') == 'success'
                     for step in job.get('steps', [])
                     if step.get('name') == 'Confirm Apple processing and existing internal Floe QA availability'
                     and step.get('conclusion') == 'success']
    require(len(confirmations) == 1, 'originalDelivery', 'original.jobs', 'Original internal delivery success step is missing or ambiguous')
    transport = policy['transport']
    private_release = api_get(f"releases/{transport['releaseID']}")
    private_asset = api_get(f"releases/assets/{transport['assetID']}")
    require(private_release.get('id') == transport['releaseID'] and private_release.get('draft') is True
            and any(a.get('id') == transport['assetID'] for a in private_release.get('assets', []))
            and private_asset.get('id') == transport['assetID'] and private_asset.get('name') == 'local-device.zip'
            and private_asset.get('state') == 'uploaded' and private_asset.get('size') == transport['archiveBytes']
            and private_asset.get('digest') == 'sha256:' + transport['archiveSHA256'],
            'transportAuthority', 'transport', 'The original private transport identity is missing or changed')
    if controller is None:
        return
    require(controller['commit'] != app['sourceCommit'], 'controller', 'controller.commit',
            'Packaging controller must be identified separately from the original App source')
    controller_tag = controller['ref'][len('refs/tags/'):]
    controller_ref = api_get('git/ref/tags/' + controller_tag)
    controller_object = api_get('git/tags/' + controller_ref['object']['sha']) if controller_ref.get('object', {}).get('type') == 'tag' else {}
    controller_commit, _ = publication.peel_tag_commit(controller_ref, controller_object, controller_tag)
    require(controller_commit == controller['commit'], 'controllerTag', 'controller.commit', 'Reviewed controller tag moved')
    current = api_get(f"actions/runs/{controller['runID']}/attempts/{controller['runAttempt']}")
    state = current.get('status') == 'completed' and current.get('conclusion') == 'success'
    if not completed_controller:
        state = state or (current.get('status') == 'in_progress' and current.get('conclusion') is None)
    require(current.get('id') == controller['runID'] and current.get('run_attempt') == controller['runAttempt']
            and current.get('head_repository', {}).get('full_name') == REPOSITORY
            and current.get('head_sha') == controller['commit']
            and current.get('head_branch') == controller['ref'][len('refs/tags/'):]
            and current.get('path') == WORKFLOW and current.get('event') == 'workflow_dispatch' and state,
            'controllerRun', 'controller.runID', 'Exact packaging controller/run/state mismatch')


def file_manifest(app):
    entries = []
    for path in [Path(app), *sorted(Path(app).rglob('*'))]:
        require(not path.is_symlink(), 'unsafeArchive', 'deviceManifest', 'Device symlinks are not accepted')
        if path.is_file():
            entries.append({'path': path.relative_to(app).as_posix(), 'kind': 'file', 'sha256': digest(path),
                            'bytes': path.stat().st_size, 'mode': stat.S_IMODE(path.stat().st_mode),
                            'executable': bool(path.stat().st_mode & 0o111)})
        else:
            require(path.is_dir(), 'unsafeArchive', 'deviceManifest', 'Unsupported device file type')
            entries.append({'path': path.relative_to(app).as_posix(), 'kind': 'directory',
                            'mode': stat.S_IMODE(path.stat().st_mode),
                            'executable': bool(path.stat().st_mode & 0o111)})
    require(entries, 'deviceManifest', 'deviceManifest', 'Empty device payload')
    return {'sha256': hashlib.sha256(canonical(entries)).hexdigest(),
            'files': sum(x['kind'] == 'file' for x in entries),
            'bytes': sum(x.get('bytes', 0) for x in entries)}, entries


def report_manifest_mismatch(policy, review, work):
    """Private failure evidence only; never a substitute for the manifest gate.

    The exact reviewed policy and all normalization/source assertions remain
    authoritative. Do not write this diagnostic into release subjects or use
    its actual manifest to update the expected policy automatically.
    """
    if review['manifest'] == policy['expectedManifest']:
        return
    summary = {'diagnosticOnly': True, 'failureCode': 'reviewedManifest',
               'expectedManifest': policy['expectedManifest'], 'actualManifest': review['manifest'],
               'sourceRaw': review['sourceRaw'], 'transportRaw': review['transportRaw'],
               'normalizationProof': review['normalizationProofSummary'],
               'entryCounts': {'total': len(review['entries']),
                               'files': sum(e['kind'] == 'file' for e in review['entries']),
                               'directories': sum(e['kind'] == 'directory' for e in review['entries'])}}
    # Even a full/unwritable diagnostic directory must leave expected/actual
    # in the log and must not turn the following original refusal into success.
    print('HISTORICAL308_MANIFEST_MISMATCH=' + canonical(summary).decode(), flush=True)
    try:
        codesign = Path('/usr/bin/codesign')
        summary['host'] = {'platform': platform.platform(), 'macOS': platform.mac_ver()[0],
                           'python': sys.version, 'codesignPath': str(codesign),
                           'codesignSHA256': digest(codesign) if codesign.is_file() else None,
                           'bindingScriptSHA256': digest(Path(__file__)),
                           'normalizationScriptSHA256': digest(Path(projection.__file__))}
        by_path = {}
        for side in ('signed', 'transport'):
            for item in review['normalizationProof'][side]['files']:
                row = by_path.setdefault(item['path'], {'path': item['path']})
                row[side] = {key: item[key] for key in
                             ('mode', 'inputSHA256', 'inputBytes', 'outputSHA256', 'outputBytes',
                              'intermediateSHA256', 'intermediateBytes', 'outputLayout', 'changedRanges')
                             if key in item}
        outputs = [by_path[path] for path in sorted(by_path)]
        summary['machOFileCount'] = len(outputs)
        for row in outputs:
            print('HISTORICAL308_MACHO_OUTPUT=' + canonical(row).decode(), flush=True)
        destination = Path(work) / 'manifest-mismatch'
        destination.mkdir(mode=0o700, exist_ok=False)
        for name, value in [('DIAGNOSTICS.private.json', summary),
                            ('MACHO-OUTPUTS.private.json', outputs),
                            ('DEVICE-MANIFEST.private.json', review['entries']),
                            ('NORMALIZATION-PROOF.private.json', review['normalizationProof'])]:
            # Exclusive creation in a fresh owner-only child. No App or ZIP
            # bytes, controller policy, expected manifest or subject changes.
            with (destination / name).open('xb') as stream:
                os.chmod(stream.fileno(), 0o600)
                stream.write(canonical(value) + b'\n')
    except Exception as error:
        print('HISTORICAL308_DIAGNOSTIC_ERROR=' + type(error).__name__, file=sys.stderr, flush=True)


def apple_normalize(app, *, signed=False, require_unsigned=False):
    """Apple fixed-identifier adhoc/remove projection, with full byte proof."""
    if require_unsigned:
        require(not any(p.name in ('_CodeSignature', 'embedded.mobileprovision') for p in Path(app).rglob('*')),
                'signedIPA', 'ipa', 'Unsigned output contains signing resources')
    # Apple may itself remove CodeResources when removing a bundle's signature.
    # Freeze the exact existing signing entries BEFORE any Apple operation.
    # This is the same bounded namespace used by the original projection, not
    # permission to remove another resource or silently ignore an unknown path.
    removed = set()
    for path in Path(app).rglob('*'):
        bundle = path.parent
        signing_bundle = bundle.suffix in ('.app', '.appex', '.framework', '.xpc') and (bundle / 'Info.plist').is_file()
        if path.name == '_CodeSignature' and path.is_dir() and signing_bundle:
            removed.update(p.relative_to(app).as_posix() for p in [path, *path.rglob('*')])
        elif path.name == 'embedded.mobileprovision' and path.is_file() and signing_bundle:
            removed.add(path.relative_to(app).as_posix())
    result = projection.normalize_machos(app, signed=signed, require_unsigned=require_unsigned,
                                         evidence_directory=Path(app).parent.parent)
    # Unsigned input signing entries were rejected before any Apple operation.
    # Clean only this roundtrip's new signing resources; verify_output still
    # requires the complete raw and post-roundtrip manifests to be identical.
    for path in sorted(Path(app).rglob('*'), key=lambda p: len(p.parts), reverse=True):
        bundle = path.parent
        signing_bundle = bundle.suffix in ('.app', '.appex', '.framework', '.xpc') and (bundle / 'Info.plist').is_file()
        if path.name == '_CodeSignature' and path.is_dir() and signing_bundle:
            shutil.rmtree(path)
        elif path.name == 'embedded.mobileprovision' and path.is_file() and signing_bundle:
            path.unlink()
    return {'files': result['files'], 'removedSigningEntries': sorted(removed),
            'privateCommandLog': result['privateCommandLog']}


def resource_preservation(before, after, proof, mapped_metadata=()):
    """Check every original resource/directory/mode, separately from Mach-O proof."""
    old, new = {e['path']: e for e in before}, {e['path']: e for e in after}
    removed = set(proof['removedSigningEntries']) | set(mapped_metadata)
    machos = {e['path']: e for e in proof['files']}
    require(len(machos) == len(proof['files']) and set(new) == set(old) - removed,
            'normalizationData', 'deviceManifest', 'Normalization added or removed an unreviewed payload entry')
    for path, entry in new.items():
        if path in machos:
            p = machos[path]
            require(old[path]['kind'] == entry['kind'] == 'file'
                    and old[path]['mode'] == entry['mode'] == p['mode']
                    and old[path]['sha256'] == p['inputSHA256'] and old[path]['bytes'] == p['inputBytes']
                    and entry['sha256'] == p['outputSHA256'] and entry['bytes'] == p['outputBytes']
                    and p['nonSignatureDataUnchanged'] is True and p['finalUnsigned'] is True,
                    'normalizationData', path, 'Mach-O proof does not bind the exact input/output bytes and mode')
        else:
            require(entry == old[path], 'normalizationData', path, 'A non-signature resource, directory or mode changed')
    require(set(machos) <= set(new) and removed <= set(old),
            'normalizationData', 'deviceManifest', 'Normalization proof references unknown entries')
    return {'unchangedResourceEntries': len(new) - len(machos), 'verifiedMachOFiles': len(machos),
            'removedSigningEntries': sorted(proof['removedSigningEntries']), 'mappedMetadataEntries': sorted(mapped_metadata)}


def app_in(root):
    apps = list((Path(root) / 'Payload').glob('*.app'))
    require(len(apps) == 1 and apps[0].is_dir(), 'deviceManifest', 'Payload', 'Expected exactly one top-level app')
    info = plistlib.loads((apps[0] / 'Info.plist').read_bytes())
    require((info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'))
            == (BUNDLE, VERSION, BUILD) and str(info.get('DTSDKName', '')).startswith('iphoneos'),
            'deviceIdentity', 'Info.plist', 'Original build308 device identity mismatch')
    return apps[0]


def archive_identity(path, expected, label):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size == expected['archiveBytes']
            and digest(path) == expected['archiveSHA256'], 'archiveDigest', label, 'Original archive bytes differ from reviewed identity')


def selected_members(archive, destination, selection):
    """Validate every ZIP header; select the complete App, never its subset.

    Symbols and unrelated source receipts need not be expanded. The original
    complete archive digest still binds their bytes. The existing traversal,
    duplicate, symlink/type and member-count policy remains authoritative.
    """
    members = archive.infolist()
    require(0 < len(members) <= recovery.MAX_ZIP_MEMBERS,
            'archiveBudget', 'archive', 'Archive member count exceeds the existing budget')
    names, seen = {}, set()
    for info in members:
        names[info] = recovery._validate_zip_member(info, Path(destination).resolve(), seen)
    if selection == 'original':
        selected = [info for info in members if names[info] in ('FloeAgent.ipa', 'TESTFLIGHT-SUMMARY.txt')]
        require({names[info] for info in selected} == {'FloeAgent.ipa', 'TESTFLIGHT-SUMMARY.txt'},
                'missingProof', 'original', 'Signed IPA and original summary are required')
    else:
        roots = {name.split('/')[1] for name in names.values()
                 if name.startswith('Payload/') and len(name.split('/')) >= 2
                 and name.split('/')[1].endswith('.app')}
        require(len(roots) == 1, 'deviceIdentity', 'Payload', 'Exactly one complete App root is required')
        app_root = 'Payload/' + next(iter(roots))
        require(all(not name.startswith('Payload/') or name == app_root or name.startswith(app_root + '/')
                    for name in names.values()), 'deviceIdentity', 'Payload', 'Unexpected payload outside the App')
        selected = [info for info in members if names[info] == 'Payload' or names[info] == app_root
                    or names[info].startswith(app_root + '/')
                    or (selection == 'transport' and names[info] == 'provenance.json')]
        if selection == 'transport':
            require(any(names[info] == 'provenance.json' for info in selected),
                    'missingProof', 'transport.provenance', 'Original transport provenance required')
    total = sum(info.file_size for info in selected)
    require(total <= recovery.MAX_ZIP_UNCOMPRESSED_BYTES,
            'archiveBudget', 'archive', 'Selected complete payload exceeds the existing expansion budget')
    report = {'selectedMembers': len(selected), 'selectedBytes': total,
              'largestSelectedFileBytes': max((i.file_size for i in selected), default=0),
              'manifestBytesUpperBound': sum(len(canonical(names[i])) + 512 for i in selected),
              'skippedMembers': len(members) - len(selected),
              'skippedBytes': sum(i.file_size for i in members) - total}
    return selected, report


def extract_selected(path, destination, selection):
    destination = Path(destination)
    require(not destination.exists(), 'workspace', 'work', 'Selective extraction needs a new owned directory')
    with zipfile.ZipFile(path) as archive:
        members, report = selected_members(archive, destination, selection)
        destination.mkdir(parents=True)
        archive.extractall(destination, members=members)
        for info in sorted(members, key=lambda item: item.filename.count('/'), reverse=True):
            mode = info.external_attr >> 16
            if info.create_system == 3 and stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR):
                destination.joinpath(*info.filename.rstrip('/').split('/')).chmod(mode & 0o7777)
    return report


def plan_archives(policy, original_archive, transport_archive, work):
    # Capacity has no provenance authority. Do not repeat a just-verified full
    # archive hash solely to plan disk use; review/verify never use this shortcut.
    for path, expected in ((Path(original_archive), policy['original']), (Path(transport_archive), policy['transport'])):
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == expected['archiveBytes'],
                'archiveSize', path.name, 'Plan needs the exact regular archive size')
    work = Path(work); require(not work.exists(), 'workspace', 'plan.work', 'Use a new owned plan directory')
    work.mkdir(parents=True)
    with tempfile.TemporaryDirectory(dir=work) as temporary:
        original = extract_selected(original_archive, Path(temporary) / 'original', 'original')
        with zipfile.ZipFile(Path(temporary) / 'original/FloeAgent.ipa') as archive:
            _, signed = selected_members(archive, Path(temporary) / 'signed', 'payload')
        with zipfile.ZipFile(transport_archive) as archive:
            _, transport = selected_members(archive, Path(temporary) / 'transport', 'transport')
    # Codesign may replace its largest input atomically. Budget that extra copy
    # plus conservative manifest/filesystem overhead instead of claiming APFS
    # sharing is exclusive or promising an unmeasured physical peak.
    manifest_bound = 1024 * 1024 + signed['manifestBytesUpperBound'] + transport['manifestBytesUpperBound']
    replacement = max(signed['largestSelectedFileBytes'], transport['largestSelectedFileBytes'])
    review_bound = original['selectedBytes'] + signed['selectedBytes'] + transport['selectedBytes'] + replacement + manifest_bound
    ipa_bound = int(transport['selectedBytes'] * 1.02) + transport['selectedMembers'] * 1024
    preparation_bound = review_bound + transport['selectedBytes'] + ipa_bound
    archives = policy['original']['archiveBytes'] + policy['transport']['archiveBytes']
    return {'kind': 'capacity-plan-only', 'publicationAuthorized': False, 'provenanceVerified': False,
            'archiveDigestsVerified': False,
            'original': original, 'signedApp': signed, 'unsignedTransportApp': transport,
            'inputArchivesBytes': archives, 'reviewScratchUpperBoundBytes': review_bound,
            'prepareScratchUpperBoundBytes': preparation_bound,
            'singleVolumeReviewUpperBoundBytes': archives + review_bound,
            'recommendedAdditionalMarginBytes': 512 * 1024 * 1024,
            'measurement': 'Actual central-directory selected logical bytes plus stated conservative bounds; physical APFS peak is unmeasured. Plan temporarily extracts only the original nested IPA/summary, then removes its owned temporary child.'}


def review_archives(policy, original_archive, transport_archive, work, normalize=apple_normalize):
    archive_identity(original_archive, policy['original'], 'original.archive')
    archive_identity(transport_archive, policy['transport'], 'transport.archive')
    work = Path(work); require(not work.exists(), 'workspace', 'work', 'Use a new owned staging directory')
    work.mkdir(parents=True)
    extract_selected(Path(original_archive), work / 'original', 'original')
    signed_ipa = work / 'original/FloeAgent.ipa'
    summary_path = work / 'original/TESTFLIGHT-SUMMARY.txt'
    require(signed_ipa.is_file() and summary_path.is_file() and summary_path.stat().st_size < 65536,
            'missingProof', 'original.summary', 'Original signed IPA and upload summary are required')
    summary = {}
    for line in summary_path.read_text().splitlines():
        key, separator, value = line.partition('=')
        require(separator and key not in summary, 'originalSummary', 'original.summary', 'Malformed/duplicate summary key')
        summary[key] = value
    require(all(summary.get(k) == v for k, v in {'tag': TAG, 'version': VERSION, 'build': BUILD,
                'commit': policy['app']['sourceCommit'], 'app_rebuilt': 'False',
                'testflight_upload': 'accepted_by_transport'}.items()),
            'originalSummary', 'original.summary', 'Original summary/source/upload identity mismatch')
    extract_selected(signed_ipa, work / 'signed', 'payload')
    extract_selected(Path(transport_archive), work / 'transport', 'transport')
    source_app, unsigned_app = app_in(work / 'signed'), app_in(work / 'transport')
    provenance = read_json(work / 'transport/provenance.json')
    require((provenance.get('source_sha'), provenance.get('version'), provenance.get('build'))
            == (policy['app']['sourceCommit'], VERSION, BUILD), 'transportSource', 'transport.provenance', 'Transport source differs')
    raw_source, raw_source_entries = file_manifest(source_app)
    raw_transport, raw_transport_entries = file_manifest(unsigned_app)
    for name, raw_entries in [('RAW-SIGNED-DEVICE-MANIFEST.private.json', raw_source_entries),
                              ('RAW-TRANSPORT-DEVICE-MANIFEST.private.json', raw_transport_entries)]:
        (work / name).write_bytes(canonical(raw_entries) + b'\n')
        (work / name).chmod(0o600)
    metadata = projection.paired_metadata(signed_ipa, Path(transport_archive), source_app, unsigned_app, work / 'metadata')
    source_proof = normalize(source_app, signed=True)
    transport_proof = normalize(unsigned_app)
    source, entries = file_manifest(source_app); unsigned, actual = file_manifest(unsigned_app)
    resource_proof = {
        'signed': resource_preservation(raw_source_entries, entries, source_proof),
        'transport': resource_preservation(raw_transport_entries, actual, transport_proof,
                                           [e['logicalPath'] for e in metadata['entries']])}
    private_logs = {'signed': source_proof.pop('privateCommandLog'), 'transport': transport_proof.pop('privateCommandLog')}
    normalization_proof = {'signed': source_proof, 'transport': transport_proof, 'resources': resource_proof}
    for name, value in [('NORMALIZATION-PROOF.json', normalization_proof), ('APPLEDOUBLE-METADATA.json', metadata),
                        ('NORMALIZATION-COMMANDS.private.json', private_logs)]:
        (work / name).write_bytes(canonical(value) + b'\n')
        (work / name).chmod(0o600)
    require(source == unsigned and entries == actual, 'normalizationMismatch', 'deviceManifest',
            'Complete source/transport manifests differ after the V2 projection; no hash or field exemption applies')
    return {'app': unsigned_app, 'manifest': source, 'entries': entries,
            'sourceRaw': raw_source, 'transportRaw': raw_transport,
            'metadata': metadata, 'normalizationProof': normalization_proof,
            'normalizationProofSummary': {'sha256': hashlib.sha256(canonical(normalization_proof)).hexdigest(),
                                          'files': len(source_proof['files']) + len(transport_proof['files'])},
            'signedIPA': {'sha256': digest(signed_ipa), 'bytes': signed_ipa.stat().st_size}}


def binding_for(policy, policy_sha, controller, review, ipa):
    return {'schemaVersion': 2, 'kind': 'floe.historical308.source-binding', 'policySHA256': policy_sha,
            'app': policy['app'], 'original': {**policy['original'], 'signedIPA': review['signedIPA']},
            'transport': {k: policy['transport'][k] for k in ('archiveSHA256', 'archiveBytes')},
            'deviceManifest': {'normalization': NORMALIZATION,
                'canonical': review['manifest'], 'sourceRaw': review['sourceRaw'], 'transportRaw': review['transportRaw'],
                'metadata': review['metadata']['summary'], 'normalizationProof': review['normalizationProofSummary']},
            'ipa': {'name': IPA_NAME, 'sha256': digest(ipa), 'bytes': Path(ipa).stat().st_size},
            'controller': controller, 'appRebuilt': False, 'unsigned': True}


def verify_output(ipa, review, work, normalize=apple_normalize):
    ipa = Path(ipa)
    require(ipa.name == IPA_NAME and ipa.is_file() and not ipa.is_symlink(), 'ipa', 'ipa.name', 'Canonical unsigned build308 IPA required')
    publication.audit_staged_ipa(ipa.parent, {'ipa_name': IPA_NAME, 'bundle_id': BUNDLE, 'version': VERSION, 'build': BUILD})
    extract_selected(ipa, Path(work), 'payload')
    app = app_in(work)
    raw_manifest, raw_entries = file_manifest(app)
    normalize(app, require_unsigned=True)
    manifest, entries = file_manifest(app)
    require(raw_manifest == manifest and raw_entries == entries,
            'outputNotCanonical', 'ipa', 'The raw unsigned IPA must already be canonical; verification cannot repair its bytes')
    require(manifest == review['manifest'] and entries == review['entries'],
            'outputManifest', 'ipa', 'IPA is not the complete original normalized device payload')


def verify_subject(subject, controller, invoke=subprocess.run):
    command = ['gh', 'attestation', 'verify', str(subject), '--repo', REPOSITORY,
               '--source-ref', controller['ref'], '--source-digest', controller['commit'],
               '--signer-digest', controller['commit'], '--signer-workflow', REPOSITORY + '/' + WORKFLOW,
               '--deny-self-hosted-runners', '--format', 'json']
    result = invoke(command, check=True, capture_output=True, text=True)
    verified = json.loads(result.stdout)
    invocation = f"https://github.com/{REPOSITORY}/actions/runs/{controller['runID']}/attempts/{controller['runAttempt']}"
    builder = f"https://github.com/{REPOSITORY}/{WORKFLOW}@{controller['ref']}"
    expected = {'name': Path(subject).name, 'digest': {'sha256': digest(subject)}}
    matches = []
    for item in verified if isinstance(verified, list) else []:
        statement = item.get('verificationResult', {}).get('statement', {})
        details = statement.get('predicate', {}).get('runDetails', {})
        matches.append(statement.get('predicateType') == 'https://slsa.dev/provenance/v1'
                       and expected in statement.get('subject', [])
                       and details.get('metadata', {}).get('invocationId') == invocation
                       and details.get('builder', {}).get('id') == builder)
    require(any(matches), 'attestationIdentity', Path(subject).name,
            'No verified subject from the exact reviewed controller/run/attempt')


def verify(policy_path, controller_path, ipa, binding, original_archive, transport_archive,
           work, *, api_get=github_api, invoke=subprocess.run, normalize=apple_normalize):
    policy = read_json(policy_path); validate_policy(policy)
    controller = read_json(controller_path); validate_controller(controller)
    ipa = Path(ipa)
    require(ipa.name == IPA_NAME and ipa.is_file() and not ipa.is_symlink() and ipa.stat().st_size > 0,
            'missingProof', 'ipa', 'A regular canonical unsigned IPA subject is required before signature lookup')
    binding = Path(binding)
    require(binding.name == BINDING_NAME and binding.is_file() and not binding.is_symlink()
            and 0 < binding.stat().st_size <= 65536, 'missingProof', 'binding', 'Bounded regular binding subject required')
    # Deliberately no read_json(binding) or source API before BOTH signatures.
    verify_subject(Path(ipa), controller, invoke)
    verify_subject(binding, controller, invoke)
    record = read_json(binding)
    exact(record, 'schemaVersion kind policySHA256 app original transport deviceManifest ipa controller appRebuilt unsigned', 'binding')
    check_sources(policy, controller, api_get, completed_controller=True)
    review = review_archives(policy, original_archive, transport_archive, Path(work) / 'source', normalize)
    report_manifest_mismatch(policy, review, work)
    require(review['manifest'] == policy['expectedManifest'], 'reviewedManifest', 'deviceManifest', 'Reviewed full device manifest changed')
    verify_output(ipa, review, Path(work) / 'output', normalize)
    expected = binding_for(policy, digest(policy_path), controller, review, ipa)
    require(canonical(record) == canonical(expected), 'bindingMismatch', 'binding', 'Signed binding does not match the independently reconstructed source chain')
    return {'verified': True, 'preparationOnly': True, 'publicationAuthorized': False,
            'appSource': policy['app']['sourceCommit'], 'packagingController': controller,
            'deviceManifest': review['manifest'], 'ipaSHA256': digest(ipa)}


def context_controller():
    controller = {'commit': os.environ.get('GITHUB_SHA'), 'ref': os.environ.get('GITHUB_REF'),
                  'runID': int(os.environ.get('GITHUB_RUN_ID', '0')),
                  'runAttempt': int(os.environ.get('GITHUB_RUN_ATTEMPT', '0')), 'workflow': WORKFLOW}
    validate_controller(controller)
    require(os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and
            os.environ.get('GITHUB_WORKFLOW_REF') == REPOSITORY + '/' + WORKFLOW + '@' + controller['ref'],
            'controller', 'GITHUB_WORKFLOW_REF', 'Trusted Actions preparation context required')
    return controller


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('plan', 'prepare', 'review', 'verify'))
    parser.add_argument('--policy', required=True, type=Path)
    parser.add_argument('--original-archive', required=True, type=Path)
    parser.add_argument('--transport-archive', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--packager', type=Path)
    parser.add_argument('--controller', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--binding', type=Path)
    args = parser.parse_args()
    policy = read_json(args.policy)
    if args.command == 'plan':
        result = plan_archives(policy, args.original_archive, args.transport_archive, args.work)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open('x') as stream: stream.write(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        return
    validate_policy(policy, review_only=args.command == 'review')
    if args.command == 'verify':
        require(all(x is not None for x in (args.controller, args.ipa, args.binding)), 'usage', 'verify', 'Controller/IPA/binding required')
        result = verify(args.policy, args.controller, args.ipa, args.binding, args.original_archive,
                        args.transport_archive, args.work)
    else:
        controller = context_controller() if args.command == 'prepare' else None
        check_sources(policy, controller, github_api, completed_controller=False)
        review = review_archives(policy, args.original_archive, args.transport_archive, args.work / 'source')
        if args.command == 'review':
            args.output.mkdir(parents=True, exist_ok=False)
            (args.output / 'DEVICE-MANIFEST.json').write_bytes(canonical(review['entries']) + b'\n')
            (args.output / 'APPLEDOUBLE-METADATA.json').write_bytes(canonical(review['metadata']) + b'\n')
            (args.output / 'NORMALIZATION-PROOF.json').write_bytes(canonical(review['normalizationProof']) + b'\n')
            result = {'reviewRequired': True, 'readyToBind': False, 'publicationAuthorized': False,
                      'normalization': NORMALIZATION, 'metadata': review['metadata']['summary'],
                      'normalizationProof': review['normalizationProofSummary'],
                      'deviceManifest': review['manifest'], 'sourceRaw': review['sourceRaw'],
                      'transportRaw': review['transportRaw'], 'signedIPA': review['signedIPA']}
            (args.output / 'REVIEW.json').write_bytes(canonical(result) + b'\n')
            print(json.dumps(result, indent=2))
            return
        report_manifest_mismatch(policy, review, args.work)
        require(review['manifest'] == policy['expectedManifest'], 'reviewedManifest', 'deviceManifest', 'Review the exact manifest before preparation')
        require(args.packager is not None and args.packager.is_file() and not args.packager.is_symlink()
                and digest(args.packager) == policy['packagerSHA256'], 'packager', 'packager', 'Reviewed normal producer required')
        args.output.mkdir(parents=True, exist_ok=False)
        subprocess.run(['/bin/bash', str(args.packager), str(review['app']), str(args.output), IPA_NAME], check=True)
        ipa = args.output / IPA_NAME
        verify_output(ipa, review, args.work / 'output')
        linkage = args.output / 'pdfium-linkage.json'
        if linkage.exists(): shutil.move(str(linkage), str(args.work / linkage.name))
        record = binding_for(policy, digest(args.policy), controller, review, ipa)
        (args.output / BINDING_NAME).write_bytes(canonical(record) + b'\n')
        require({p.name for p in args.output.iterdir()} == {IPA_NAME, IPA_NAME + '.sha256', BINDING_NAME},
                'outputAllowlist', 'output', 'Only IPA/checksum/minimal binding may leave private staging')
        (args.work / 'DEVICE-MANIFEST.json').write_bytes(canonical(review['entries']) + b'\n')
        (args.work / 'APPLEDOUBLE-METADATA.json').write_bytes(canonical(review['metadata']) + b'\n')
        (args.work / 'NORMALIZATION-PROOF.json').write_bytes(canonical(review['normalizationProof']) + b'\n')
        result = {'prepared': True, 'publicationAuthorized': False, 'controller': controller,
                  'ipaPath': str(ipa), 'bindingPath': str(args.output / BINDING_NAME)}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

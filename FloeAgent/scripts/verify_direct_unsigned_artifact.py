#!/usr/bin/env python3
"""Verify a retained direct unsigned IPA against the run that produced it.

The lean single-build release route compiles the App once with the accepted
upload SDK. A retry must never compile again: it restores the retained
``expedited-unsigned-ipa-<version>-build<build>`` artifact of the earlier run,
binds every byte to the immutable tag and the exact source commit, and derives
whether that run's TestFlight upload was already accepted. The same helper
re-verifies the artifact in the publish job immediately before attestation and
publication.

Nothing here trusts the artifact's own claims. The run JSON, the artifacts JSON
(GitHub's zip digest), the IPA sidecar, the app's ``Info.plist`` and the
artifact's ``DIRECT-PROVENANCE.json`` must all agree with the requested
immutable tag, source commit, version, build and bundle identifier.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import zipfile

RUN_WORKFLOW_PATH = '.github/workflows/release-unsigned-ipa.yml'
BUNDLE_IDENTIFIER = 'org.floeagent.ios'
SCHEMA_VERSION = 1
SIMULATOR_POLICY = 'skipped_by_user_request'
ROUTE = 'direct-testflight'
SYMBOLS_STATE_REQUIRED = 'capture_required_before_signing'

SHA256_RE = re.compile(r'^[0-9a-f]{40}$')
DIGEST_RE = re.compile(r'^sha256:[0-9a-f]{64}$')
TAG_RE = re.compile(r'^v[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[1-9][0-9]*)?$')


class VerificationError(ValueError):
    """The retained artifact cannot be bound to the requested release source."""


def require(condition: object, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def load_json(path: Path) -> dict:
    require(isinstance(path, Path) and path.is_file() and not path.is_symlink(),
            f'Missing or unsafe JSON input: {path}')
    try:
        payload = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise VerificationError(f'Unreadable JSON input {path}: {error}') from error
    require(isinstance(payload, dict), f'Expected a JSON object in {path}')
    return payload


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def safe_extract_zip(archive: Path, destination: Path) -> None:
    """Extract a regular-file-only zip without trusting member names."""
    require(archive.is_file() and not archive.is_symlink(), f'Missing artifact zip: {archive}')
    require(not destination.exists(), f'Refusing to extract over an existing path: {destination}')
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            name = member.filename
            require('\\' not in name, f'Backslash in artifact entry: {name}')
            require(not name.startswith('/') and not re.match(r'^[A-Za-z]:', name),
                    f'Absolute path in artifact entry: {name}')
            parts = [part for part in name.split('/') if part not in ('', '.')]
            require(all(part != '..' for part in parts), f'Traversal in artifact entry: {name}')
            require(not parts or parts[0] != '__MACOSX', f'AppleDouble entry in artifact: {name}')
            mode = member.external_attr >> 16
            if mode and (mode & 0o170000) == 0o120000:
                raise VerificationError(f'Symlink in artifact: {name}')
            if member.is_dir():
                continue
            target = destination.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, target.open('wb') as sink:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    sink.write(block)


def verify_run(run: dict, *, repository: str, source_sha: str, allow_running: bool = False) -> None:
    # A rebuild-free retry only trusts a finished producer; the first lean run
    # verifies the artifact it just published inside the still-running workflow.
    if allow_running:
        require(run.get('status') in ('completed', 'in_progress', 'queued'),
                'The producing run has an unexpected state')
    else:
        require(run.get('status') == 'completed',
                'The producing run has not completed; reuse only a completed run')
    require(isinstance(run.get('id'), int) and run['id'] > 0, 'Producing run has no id')
    head_repository = run.get('head_repository') or {}
    require(head_repository.get('full_name') == repository, 'Producing run is from another repository')
    require(run.get('head_sha') == source_sha,
            'Producing run source commit does not match the immutable tag')
    require(run.get('path') == RUN_WORKFLOW_PATH, 'Producing run used an unexpected workflow')
    require(run.get('event') == 'workflow_dispatch', 'Producing run was not a manual dispatch')
    require(isinstance(run.get('html_url'), str) and run['html_url'].startswith('https://'),
            'Producing run has no verifiable URL')


def select_artifact(artifacts: dict, name: str) -> dict:
    entries = artifacts.get('artifacts')
    require(isinstance(entries, list), 'Artifacts payload has no artifact list')
    matches = [entry for entry in entries
               if isinstance(entry, dict) and entry.get('name') == name and not entry.get('expired')]
    require(len(matches) == 1, f'Expected exactly one live artifact named {name!r}')
    artifact = matches[0]
    require(isinstance(artifact.get('id'), int) and artifact['id'] > 0,
            'Retained artifact has no id')
    require(isinstance(artifact.get('digest'), str) and DIGEST_RE.fullmatch(artifact['digest']),
            'Retained artifact has no verifiable sha256 digest')
    return artifact


def find_single(pattern: str, root: Path) -> Path:
    matches = sorted(path for path in root.rglob(pattern) if path.is_file())
    require(len(matches) == 1, f'Expected exactly one {pattern!r} under {root}, found {len(matches)}')
    return matches[0]


def live_artifacts(payload: dict) -> list:
    entries = payload.get('artifacts')
    require(isinstance(entries, list), 'Artifacts payload has no artifact list')
    return [entry for entry in entries if isinstance(entry, dict) and not entry.get('expired')]


def testflight_evidence(payloads: list, evidence_name: str) -> list:
    """Return (payload_index, artifact) pairs for accepted-upload evidence.

    The producing run proves its own upload; a rebuild-free retry also publishes
    its TestFlight evidence from the caller run. More than one live evidence
    artifact across runs means the same build was uploaded twice, which must
    never be published as a clean release.
    """
    found = []
    for index, payload in enumerate(payloads):
        matches = [entry for entry in live_artifacts(payload)
                   if entry.get('name') == evidence_name]
        require(len(matches) <= 1, f'Ambiguous TestFlight evidence artifact {evidence_name!r}')
        found.extend((index, entry) for entry in matches)
    return found


def verify_summary(path: Path, expected: dict) -> dict:
    require(path.is_file() and not path.is_symlink(), f'Missing TEST-SUMMARY.txt at {path}')
    fields = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip() or '=' not in line:
            continue
        key, _, value = line.partition('=')
        fields[key.strip()] = value.strip()
    for key, value in expected.items():
        require(fields.get(key) == value,
                f'TEST-SUMMARY.txt {key!r} is {fields.get(key)!r}, expected {value!r}')
    require(fields.get('signed_ipas_published') == 'false',
            'TEST-SUMMARY.txt does not disclaim published signed IPAs')
    return fields


def verify_ipa(ipa: Path, sidecar: Path, expected: dict) -> tuple[dict, dict]:
    """Return the app plist and the sidecar fields for the retained IPA."""
    require(ipa.name.endswith('-unsigned.ipa'), f'Unexpected IPA name: {ipa.name}')
    require(sidecar.name == ipa.name + '.sha256', f'Unexpected checksum name: {sidecar.name}')
    fields = sidecar.read_text(encoding='utf-8').strip().split(maxsplit=1)
    require(len(fields) == 2, 'Checksum file is malformed')
    require(fields[1].lstrip('*') == ipa.name, 'Checksum filename mismatch')
    require(fields[0] == digest_file(ipa), 'Retained IPA checksum mismatch')

    with zipfile.ZipFile(ipa) as bundle:
        names = bundle.namelist()
        require(not any(re.search(r'(^|/)(embedded\.mobileprovision|_CodeSignature)(/|$)', name)
                        for name in names), 'Retained IPA contains signing material')
        app_roots = sorted({name.split('/')[1] for name in names
                            if name.startswith('Payload/') and name.count('/') >= 2
                            and name.split('/')[1].endswith('.app')})
        require(len(app_roots) == 1, 'Retained IPA must contain exactly one app bundle')
        app_root = f'Payload/{app_roots[0]}'
        require(f'{app_root}/Info.plist' in names, 'Retained IPA app bundle has no Info.plist')
        plist = plistlib.loads(bundle.read(f'{app_root}/Info.plist'))
    require(plist.get('CFBundleIdentifier') == expected['bundle_id'], 'IPA bundle identifier mismatch')
    require(plist.get('CFBundleShortVersionString') == expected['version'], 'IPA version mismatch')
    require(plist.get('CFBundleVersion') == expected['build'], 'IPA build mismatch')
    return plist, {'sha256': fields[0], 'bytes': ipa.stat().st_size, 'appRoot': app_root}


def verify_record(record: dict, *, expected: dict, run_id: int) -> None:
    require(record.get('schemaVersion') == SCHEMA_VERSION, 'Unsupported direct provenance record')
    require(record.get('route') == ROUTE, 'Direct provenance route mismatch')
    for key, value in (('tag', expected['tag']), ('version', expected['version']),
                       ('build', expected['build']), ('sourceCommit', expected['source_sha']),
                       ('bundleIdentifier', expected['bundle_id']),
                       ('assetName', expected['ipa_name']),
                       ('artifactName', expected['artifact_name']),
                       ('toolchain', expected['toolchain'])):
        require(record.get(key) == value,
                f'Direct provenance {key!r} is {record.get(key)!r}, expected {value!r}')
    require(record.get('workflow') == RUN_WORKFLOW_PATH.split('/')[-1],
            'Direct provenance workflow mismatch')
    require(record.get('runId') == run_id, 'Direct provenance run mismatch')
    require(isinstance(record.get('runAttempt'), int) and record['runAttempt'] > 0,
            'Direct provenance run attempt is missing')
    require(record.get('simulatorQualification') == SIMULATOR_POLICY,
            'Direct provenance does not record the requested simulator waiver')
    require(record.get('signedPayloadPublished') is False,
            'Direct provenance must not claim a published signed payload')
    require(record.get('signedIpaPublished') is False,
            'Direct provenance must not claim a published signed IPA')
    require(re.fullmatch(r'release-symbols-.+', str(record.get('symbolsArtifact') or '')),
            'Direct provenance has no private symbols artifact')
    require(record.get('symbolsState') == SYMBOLS_STATE_REQUIRED,
            'Direct provenance must record the required pre-signing symbol capture state')


def verify(*, run: dict, artifacts: dict, repository: str, artifact_name: str, tag: str,
           source_sha: str, version: str, build: str, toolchain: str, artifact_zip=None,
           extract_dir=None, ipa=None, sidecar=None, summary=None, record_path=None,
           expect_testflight_accepted: bool = False, allow_running: bool = False,
           evidence_artifacts=None, require_symbols_artifact: bool = False) -> dict:
    require(TAG_RE.fullmatch(tag), f'Invalid release tag: {tag}')
    require(SHA256_RE.fullmatch(source_sha), f'Invalid source digest: {source_sha}')
    require(artifact_name == f'expedited-unsigned-ipa-{version}-build{build}',
            'Artifact name does not match the version/build naming contract')
    verify_run(run, repository=repository, source_sha=source_sha,
               allow_running=allow_running)
    artifact = select_artifact(artifacts, artifact_name)

    expected = {'tag': tag, 'source_sha': source_sha, 'version': version, 'build': build,
                'bundle_id': BUNDLE_IDENTIFIER, 'toolchain': toolchain,
                'artifact_name': artifact_name,
                'ipa_name': f'Floe-Agent-{version}-build{build}-unsigned.ipa'}

    if artifact_zip is not None:
        require(extract_dir is not None, '--artifact-zip requires --extract-dir')
        artifact_zip = Path(artifact_zip)
        require(artifact_zip.is_file() and not artifact_zip.is_symlink(),
                f'Missing artifact zip: {artifact_zip}')
        observed = 'sha256:' + digest_file(artifact_zip)
        require(observed == artifact['digest'],
                f'Downloaded artifact digest {observed} != GitHub digest {artifact["digest"]}')
        safe_extract_zip(artifact_zip, Path(extract_dir))
        root = Path(extract_dir)
        ipa = find_single('*-unsigned.ipa', root)
        sidecar = Path(str(ipa) + '.sha256')
        summary = root / 'TEST-SUMMARY.txt'
        record_path = root / 'DIRECT-PROVENANCE.json'
    else:
        require(ipa is not None and sidecar is not None and summary is not None
                and record_path is not None,
                'Provide either --artifact-zip with --extract-dir or explicit extracted paths')
        ipa, sidecar, summary, record_path = (Path(ipa), Path(sidecar), Path(summary),
                                              Path(record_path))

    require(ipa.name == expected['ipa_name'], f'Unexpected retained IPA: {ipa.name}')
    plist, ipa_fields = verify_ipa(ipa, sidecar, expected)
    summary_fields = verify_summary(summary, {
        'tag': tag, 'version': version, 'build': build, 'source': source_sha,
        'asset': expected['ipa_name'], 'artifact': artifact_name,
    })
    record = load_json(record_path)
    verify_record(record, expected=expected, run_id=run['id'])

    evidence_name = f'testflight-{version}-build{build}'
    payloads = [artifacts] + list(evidence_artifacts or [])
    evidence = testflight_evidence(payloads, evidence_name)
    require(len(evidence) <= 1,
            f'Duplicate accepted TestFlight evidence artifact {evidence_name!r} spans multiple '
            'runs; refusing to publish a build Apple may have accepted twice')
    testflight_accepted = bool(evidence)
    if expect_testflight_accepted:
        require(testflight_accepted,
                f'Run {run["id"]} has no accepted TestFlight evidence artifact {evidence_name!r}')

    symbols_name = record['symbolsArtifact']
    symbols_matches = [entry for entry in live_artifacts(artifacts)
                       if entry.get('name') == symbols_name]
    require(len(symbols_matches) <= 1, f'Ambiguous private symbols artifact {symbols_name!r}')
    symbols_record = symbols_matches[0] if symbols_matches else None
    if require_symbols_artifact:
        require(symbols_record is not None,
                f'Run {run["id"]} has no live private symbols artifact {symbols_name!r}; the '
                'retained unsigned IPA is preserved, but a rebuild-free retry must not distribute '
                'a build whose dSYM was never captured')

    return {
        'schemaVersion': SCHEMA_VERSION,
        'mode': 'retained-direct-unsigned-ipa',
        'runId': run['id'],
        'runAttempt': run.get('run_attempt'),
        'runUrl': run.get('html_url'),
        'artifactRunId': run['id'],
        'artifactName': artifact_name,
        'artifactId': artifact['id'],
        'artifactDigest': artifact['digest'],
        'artifactBytes': artifact.get('size_in_bytes'),
        'tag': tag,
        'sourceCommit': source_sha,
        'version': version,
        'build': build,
        'toolchain': toolchain,
        'bundleIdentifier': plist['CFBundleIdentifier'],
        'minimumOSVersion': plist.get('MinimumOSVersion'),
        'ipaName': ipa.name,
        'ipaPath': str(ipa),
        'ipaSHA256': ipa_fields['sha256'],
        'ipaBytes': ipa_fields['bytes'],
        'appRoot': ipa_fields['appRoot'],
        'testflightAccepted': testflight_accepted,
        'testflightEvidenceArtifact': evidence_name if testflight_accepted else None,
        'testflightEvidenceSource': ('artifact_run' if evidence[0][0] == 0 else 'caller_run')
                                    if testflight_accepted else None,
        'symbolsArtifact': symbols_name,
        'symbolsState': record['symbolsState'],
        'symbolsArtifactPresent': symbols_record is not None,
        'symbolsArtifactId': symbols_record.get('id') if symbols_record else None,
        'symbolsArtifactDigest': symbols_record.get('digest') if symbols_record else None,
        'simulatorQualification': record['simulatorQualification'],
        'signedPayloadPublished': record['signedPayloadPublished'],
        'summary': summary_fields,
        'record': record,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=Path, help='gh api run JSON')
    parser.add_argument('--artifacts', required=True, type=Path, help='gh api artifacts JSON')
    parser.add_argument('--repository', required=True)
    parser.add_argument('--artifact-name', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--toolchain', required=True)
    parser.add_argument('--artifact-zip', type=Path)
    parser.add_argument('--extract-dir', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--sidecar', type=Path)
    parser.add_argument('--summary', type=Path)
    parser.add_argument('--record', type=Path)
    parser.add_argument('--expect-testflight-accepted', action='store_true')
    parser.add_argument('--allow-running', action='store_true',
                        help='Verify an artifact published by the still-running workflow')
    parser.add_argument('--evidence-artifacts', action='append', type=Path, default=None,
                        help='Additional gh api artifacts JSON payloads (e.g. the caller run of '
                             'a rebuild-free retry) searched for accepted TestFlight evidence; '
                             'the unsigned artifact itself still comes from --artifacts')
    parser.add_argument('--require-symbols-artifact', action='store_true',
                        help='Fail unless the producing run still holds the private symbols artifact')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    try:
        report = verify(
            run=load_json(args.run), artifacts=load_json(args.artifacts),
            repository=args.repository, artifact_name=args.artifact_name, tag=args.tag,
            source_sha=args.source_sha, version=args.version, build=args.build,
            toolchain=args.toolchain, artifact_zip=args.artifact_zip,
            extract_dir=args.extract_dir, ipa=args.ipa, sidecar=args.sidecar,
            summary=args.summary, record_path=args.record,
            expect_testflight_accepted=args.expect_testflight_accepted,
            allow_running=args.allow_running,
            evidence_artifacts=[load_json(path) for path in (args.evidence_artifacts or [])],
            require_symbols_artifact=args.require_symbols_artifact)
    except VerificationError as error:
        print(f'Retained direct artifact verification failed: {error}', file=sys.stderr)
        return 1
    text = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(text, encoding='utf-8')
    print(text, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())

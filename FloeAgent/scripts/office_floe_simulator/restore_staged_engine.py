#!/usr/bin/env python3
"""Download and restore the staged real simulator engine for an explicit run.

The heavy Collabora engine for ``iphonesimulator`` is built once by the
``office-real-simulator`` workflow; this module consumes its
``office-real-simulator-engine`` artifact from an explicit run ID and applies
every gate that proves it is the pinned source for this platform:

* flat artifact layout (``office_real_simulator.staged_layout``);
* whole-tarball SHA-256/size against the retained ``simulator-provenance.json``;
* source commit / repository / deployment-patch SHA against
  ``engine.lock.json``; platform ``iphonesimulator`` and arch ``arm64``;
* toolchain identity (Xcode + SDK versions) recorded in the provenance must
  match this runner, so a reused artifact can never come from another
  toolchain silently;
* every manifest entry is re-hashed after extraction and the platform/arch
  sample gate is re-run on the restored archives.

A mismatch fails closed; the base engine is never rebuilt here.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

THIS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))
sys.path.insert(0, str(SCRIPTS_DIR / 'office_real_simulator'))

from sim_host_paths import ENGINE_ARTIFACT_NAME, LOCK_PATH, REPO_ROOT  # noqa: E402
from sim_paths import normalize_xcode_version  # noqa: E402
import restore_simulator_bundle  # noqa: E402
import staged_layout  # noqa: E402


class RestoreStagedEngineError(ValueError):
    pass


def current_toolchain():
    xcode = subprocess.check_output(['xcodebuild', '-version'], text=True)
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    return normalize_xcode_version(xcode), sdk


def download_artifact(run_id, destination, repo='JiangNanGenius/floe-agent'):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    subprocess.run(
        ['gh', 'run', 'download', str(run_id), '--repo', repo,
         '--name', ENGINE_ARTIFACT_NAME, '--dir', str(destination)],
        check=True, timeout=900)
    return destination


def unpack_local_artifact(staged_zip, destination):
    """Unpack a retained, already verified staged-engine ZIP without network.

    Local reproduction reuses the retained READY artifact instead of
    re-downloading it; the provenance gate below still binds the inner
    tarball hash, source commit, platform and toolchain, so a damaged or
    substituted local ZIP fails exactly like a bad download.
    """
    import zipfile
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(staged_zip) as archive:
        for name in archive.namelist():
            target = Path(name)
            if target.is_absolute() or '..' in target.parts:
                raise ValueError(f'unsafe staged archive path: {name}')
        archive.extractall(destination)
    return destination


def restore_staged_engine(run_id, staged_dir, restored_dir, staged_zip=None):
    """Fetch (or reuse a retained ZIP) + validate + restore; returns the restore report."""
    staged = (unpack_local_artifact(Path(staged_zip), staged_dir) if staged_zip
              else download_artifact(run_id, staged_dir))
    layout = staged_layout.resolve(staged)
    expect_xcode, expect_sdk = current_toolchain()
    report = restore_simulator_bundle.restore(
        layout['engineTarball'], restored_dir,
        provenance_path=layout['provenance'],
        reuse=True, expect_xcode=expect_xcode, expect_sdk=expect_sdk,
        rewrite_engine_list=False)
    report['baseEngineRunID'] = str(run_id)
    report['engineArtifactName'] = ENGINE_ARTIFACT_NAME
    report['consumedBy'] = 'office_floe_simulator.restore_staged_engine'
    # ``restore_simulator_bundle.restore`` writes the report before the run
    # identity is known.  Rewrite the in-bundle report with the run binding so
    # downstream producers (office_engine_repair.apply) verify the actual
    # artifact identity from evidence that travels with the bundle instead of
    # trusting the tracked run/artifact metadata alone.
    evidence_path = Path(restored_dir) / 'restore-report.json'
    if evidence_path.parent.is_dir():
        evidence_path.write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True,
                        help='Completed office-real-simulator build-stage run ID')
    parser.add_argument('--staged', type=Path, required=True,
                        help='Fresh directory for the artifact download')
    parser.add_argument('--staged-zip', type=Path, default=None,
                        help='Retained local staged-engine.zip (skips the download; '
                             'the provenance gates still bind it to the pin)')
    parser.add_argument('--restored', type=Path, required=True,
                        help='Fresh directory the bundle is restored into')
    parser.add_argument('--output', type=Path, default=None,
                        help='Write the restore report JSON here')
    args = parser.parse_args()
    if not args.run_id.strip():
        raise SystemExit('a base engine run ID is required; the engine is never rebuilt here')
    report = restore_staged_engine(args.run_id, args.staged, args.restored,
                                   staged_zip=args.staged_zip)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()

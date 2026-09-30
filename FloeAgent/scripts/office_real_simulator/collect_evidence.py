#!/usr/bin/env python3
"""Collect app/container, system and crash evidence after the simulator run.

Gathers (copied, never moved - the simulator state is preserved):

* app data container subset: Documents, Library/Application Support,
  Library/Preferences, Library/Caches/Logs;
* the unified iOS system log for the run window (compact full copy plus a
  predicate-filtered copy for the host label);
* host crash reports (*.ips in ~/Library/Logs/DiagnosticReports) newer than the
  start of the run - simulator crashes are written there by the host;
* optional video and xcresult locations copied into the evidence directory.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from sim_paths import HOST_BUNDLE_ID

CONTAINER_SUBTREES = (
    'Documents',
    'Library/Application Support',
    'Library/Preferences',
    'Library/Caches/Logs',
)


def run(command, check=False):
    result = subprocess.run([str(item) for item in command], text=True,
                            capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f'{command} failed: {result.stderr}')
    return result


def copy_tree(src, dst):
    if src.exists():
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=False)
        return True
    return False


def collect(simulator, output_dir, started_epoch=None, video=None,
            minutes=60, runner_bundle_id=None, runner_app_path=None):
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    container = run(['xcrun', 'simctl', 'get_app_container', simulator,
                     HOST_BUNDLE_ID, 'data']).stdout.strip()
    copied_subtrees = []
    if container:
        container = Path(container)
        container_out = output_dir / 'app-container'
        container_out.mkdir(exist_ok=True)
        for subtree in CONTAINER_SUBTREES:
            if copy_tree(container / subtree, container_out / subtree):
                copied_subtrees.append(subtree)

    # The UI-test runner has its own data container; its Documents may contain
    # the diagnostics copy of the phase receipt (the gate reads the xcresult
    # attachment, this is retained evidence only).
    runner_container = ''
    if runner_bundle_id:
        result = run(['xcrun', 'simctl', 'get_app_container', simulator,
                      runner_bundle_id, 'data'])
        if result.returncode == 0 and result.stdout.strip():
            runner_container = result.stdout.strip()
            copy_tree(Path(runner_container) / 'Documents',
                      output_dir / 'runner-container' / 'Documents')

    # Full compact system log for the run window.
    log_path = output_dir / 'simulator-system.log'
    result = run(['xcrun', 'simctl', 'spawn', simulator, 'log', 'show',
                  '--last', f'{minutes}m', '--style', 'compact'])
    log_path.write_text(result.stdout + ('\nSTDERR:\n' + result.stderr
                                         if result.returncode else ''))
    system_log_ok = result.returncode == 0
    system_log_error = result.stderr.strip() if result.returncode else ''

    # Predicate-filtered: our native/kit labels and the host label.
    filtered = output_dir / 'simulator-office.log'
    predicate = ('eventMessage CONTAINS "Floe" OR eventMessage CONTAINS "cool" '
                 'OR processImagePath CONTAINS "office-real-simulator" '
                 'OR eventMessage CONTAINS "lok_"')
    result = run(['xcrun', 'simctl', 'spawn', simulator, 'log', 'show',
                  '--last', f'{minutes}m', '--style', 'compact',
                  '--predicate', predicate])
    filtered.write_text(result.stdout)
    office_log_ok = result.returncode == 0
    office_log_error = result.stderr.strip() if result.returncode else ''
    log_collection_errors = [msg for msg in (system_log_error, office_log_error) if msg]

    # Recent host crash reports (covers the simulator processes).
    crash_dir = output_dir / 'crashlogs'
    crash_dir.mkdir(exist_ok=True)
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    since = started_epoch or (time.time() - minutes * 60 - 600)
    crash_files = []
    if reports.is_dir():
        for path in sorted(reports.iterdir()):
            if path.suffix not in {'.ips', '.crash'}:
                continue
            try:
                if path.stat().st_mtime >= since - 300:
                    shutil.copy2(path, crash_dir / path.name)
                    crash_files.append(path.name)
            except OSError:
                continue

    video_path = ''
    if video and Path(video).is_file():
        target = output_dir / Path(video).name
        shutil.copy2(video, target)
        video_path = str(target)

    report = {
        'simulator': simulator,
        'bundleID': HOST_BUNDLE_ID,
        'container': str(container) if container else '',
        'copiedContainerSubtrees': copied_subtrees,
        'runnerBundleID': runner_bundle_id or '',
        'runnerAppPath': runner_app_path or '',
        'runnerContainer': runner_container,
        'systemLog': str(log_path),
        'systemLogOk': system_log_ok,
        'officeLog': str(filtered),
        'officeLogOk': office_log_ok,
        'logCollectionErrors': log_collection_errors,
        'crashReports': crash_files,
        'video': video_path,
        'collectedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'hostKind': 'upstream-mobile-host-only',
    }
    (output_dir / 'evidence-report.json').write_text(
        json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator')
    parser.add_argument('output_dir')
    parser.add_argument('--started-epoch', type=float, default=None)
    parser.add_argument('--video', default=None)
    parser.add_argument('--minutes', type=int, default=60)
    parser.add_argument('--runner-bundle-id', default=None)
    parser.add_argument('--runner-app-path', default=None)
    args = parser.parse_args()
    print(json.dumps(collect(args.simulator, args.output_dir,
                             args.started_epoch, args.video, args.minutes,
                             args.runner_bundle_id, args.runner_app_path),
                     indent=2))


if __name__ == '__main__':
    main()

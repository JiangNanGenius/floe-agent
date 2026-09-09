#!/usr/bin/env python3
"""Prepare pinned Office binaries at build time, never from the running app."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'ThirdParty/Collabora/engine.lock.json'
FRAMEWORK = 'FloeOfficeNative.framework'


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def relative(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or '..' in path.parts or '\\' in name
            or str(path) != name.rstrip('/')):
        raise ValueError('Invalid Office artifact path')
    return path


def checked_lock(lock_path):
    lock_path = Path(lock_path)
    lock = json.loads(lock_path.read_text())
    pin = lock['qualifiedHostArtifact']
    if pin['overlaySHA256'] != lock['embeddingOverlay']['sha256']:
        raise ValueError('Native host must be rebuilt for the current source overlay')
    for name, checksum in pin['hostSourceSHA256'].items():
        relative(name)
        if digest(lock_path.parent / 'FloeOfficeNative' / name) != checksum:
            raise ValueError('Native host must be rebuilt for its changed public or implementation source')
    return lock, pin


def inventory(folder, lock, pin):
    manifest_path = folder / 'native-host.json'
    if manifest_path.is_symlink() or digest(manifest_path) != pin['manifestSHA256']:
        raise ValueError('Native Office manifest differs from its qualification pin')
    report = json.loads(manifest_path.read_text())
    if (report['sourceCommit'] != lock['commit'] or report['overlaySHA256'] != pin['overlaySHA256']
            or report['hostSourceSHA256'] != pin['hostSourceSHA256']
            or not all(report.get(key) is True for key in ['hostCompilePassed', 'hostLinkPassed', 'swiftModuleImportPassed'])):
        raise ValueError('Native Office qualification does not match this build')
    files = {'native-host.json': pin['manifestSHA256'],
             FRAMEWORK + '/FloeOfficeNative': pin['executableSHA256']}
    files.update({FRAMEWORK + '/' + str(relative(name)): checksum
                  for name, checksum in pin['frameworkAuxiliarySHA256'].items()})
    files.update({'OfficeRuntimeResources/' + str(relative(name)): checksum
                  for name, checksum in report['runtimeResourceSHA256'].items()})
    directories = {'OfficeRuntimeResources/' + str(relative(name))
                   for name in report['runtimeResourceDirectories']}
    for name in list(files) + list(directories):
        directories.update(str(parent) for parent in relative(name).parents if str(parent) != '.')
    return files, directories


def verify_installed(folder, lock, pin):
    folder = Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('Office host destination is not an owned directory')
    # Reject aliases before reading the receipt or following nested directories.
    entries = list(folder.rglob('*'))
    if any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in entries):
        raise ValueError('Office host contains an unexpected alias')
    files, directories = inventory(folder, lock, pin)
    actual_files = {str(path.relative_to(folder)) for path in entries if path.is_file()}
    actual_directories = {str(path.relative_to(folder)) for path in entries if path.is_dir()}
    if actual_files != set(files) or actual_directories != directories:
        raise ValueError('Office host file or directory inventory changed')
    for name, checksum in files.items():
        if digest(folder / name) != checksum:
            raise ValueError('Office host content checksum mismatch: ' + name)
    return {'verifiedFiles': len(files), 'verifiedDirectories': len(directories),
            'runID': pin['runID'], 'archiveSHA256': pin['archiveSHA256']}


def install(archive, destination, lock_path=LOCK):
    lock, pin = checked_lock(lock_path)
    archive, destination = Path(archive), Path(destination)
    if destination.exists() or destination.is_symlink():
        return verify_installed(destination, lock, pin)
    if digest(archive) != pin['archiveSHA256']:
        raise ValueError('Native Office archive checksum mismatch')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.office-host-') as temporary:
        stage = Path(temporary)
        with zipfile.ZipFile(archive) as source:
            seen = set()
            for item in source.infolist():
                name = relative(item.filename)
                if name.parts[0] != 'OfficeNativeHost' or item.filename in seen:
                    raise ValueError('Unexpected Office archive root or duplicate entry')
                seen.add(item.filename)
                mode = item.external_attr >> 16
                if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                    raise ValueError('Office archive contains a link or special file')
            source.extractall(stage)
        prepared = stage / 'OfficeNativeHost'
        result = verify_installed(prepared, lock, pin)
        (prepared / FRAMEWORK / 'FloeOfficeNative').chmod(0o755)
        prepared.rename(destination)
    return result


def write_project_inputs(folder, output, project_root=ROOT, lock_path=LOCK):
    """Declare every verified payload input for Xcode's script sandbox."""
    lock, pin = checked_lock(lock_path)
    verify_installed(folder, lock, pin)
    folder, project_root, output = Path(folder), Path(project_root), Path(output)
    paths = [folder] + sorted(folder.rglob('*'))
    lines = []
    for path in paths:
        name = str(path.relative_to(project_root))
        if any(char in name for char in '\n\r$'):
            raise ValueError('Office source cannot be represented in an Xcode input list')
        lines.append('$(SRCROOT)/' + name)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use an already downloaded, hash-locked archive')
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    lock, pin = checked_lock(LOCK)
    destination = args.destination or ROOT / 'Vendor/Office' / pin['runID'] / 'OfficeNativeHost'

    def finish(result):
        if args.destination is None:
            write_project_inputs(destination, ROOT / 'Vendor/Office/native-host-inputs.xcfilelist')
        print(json.dumps(result, indent=2))

    if destination.exists() or destination.is_symlink() or args.verify_only:
        finish(verify_installed(destination, lock, pin))
        return
    if args.archive:
        finish(install(args.archive, destination))
        return
    # gh uses the developer's existing login or the CI job's read-only token.
    # Credentials never enter the command, artifact, or application resources.
    with tempfile.TemporaryDirectory(prefix='floe-office-download-') as temporary:
        subprocess.run(['gh', 'run', 'download', pin['runID'], '--repo', 'JiangNanGenius/floe-agent',
                        '--name', pin['artifactName'], '--dir', temporary], check=True)
        finish(install(Path(temporary) / 'OfficeNativeHost.zip', destination))


if __name__ == '__main__':
    main()

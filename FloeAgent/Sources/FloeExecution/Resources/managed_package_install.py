"""Managed pure-Python wheels: ownership-aware merge and recoverable generation commit."""
import csv
import hashlib
import importlib.metadata as metadata
import io
import json
import os
from pathlib import Path
import re
import shutil


def normalize(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def checked_path(root, relative):
    relative = str(relative)
    if not relative or '\\' in relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise ValueError('Package RECORD contains an unsafe path')
    candidate = root / relative
    if os.path.commonpath([str(candidate.resolve()), str(root.resolve())]) != str(root.resolve()):
        raise ValueError('Package file escapes its environment')
    return candidate


def records(distribution, root):
    text = distribution.read_text('RECORD')
    if not text or len(text) > 8 * 1024 * 1024:
        raise ValueError('Package ownership record is missing or too large')
    names = []
    for row in csv.reader(io.StringIO(text), strict=True):
        if len(row) != 3:
            raise ValueError('Invalid package ownership record')
        checked_path(root, row[0])
        names.append(row[0])
    return names


def distributions(root):
    result = {}
    for distribution in metadata.distributions(path=[str(root)]):
        name = distribution.metadata['Name']
        if not name or not distribution.version:
            raise ValueError('Package metadata is incomplete')
        key = normalize(name)
        if key in result:
            raise ValueError('Duplicate installed distribution: ' + key)
        result[key] = distribution
    return result


def validate_tree(root):
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError('Managed Python packages cannot contain symlinks')
            if path.suffix.lower() in ('.so', '.dylib', '.a', '.framework', '.bundle', '.dll', '.exe'):
                raise ValueError('Managed Python package contains native artifacts')


def write_journal(transaction, value):
    temporary = transaction / 'journal.tmp'
    with temporary.open('w') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, transaction / 'journal.json')


def recover(target):
    target = Path(target)
    transaction = target.parent / '.floe-python-transaction'
    if not transaction.exists():
        return
    if transaction.is_symlink() or (transaction / "journal.json").is_symlink() or (transaction / "backup").is_symlink():
        raise ValueError("Unsafe Python recovery path; files were retained")
    journal = json.loads((transaction / 'journal.json').read_text())
    if journal.get('phase') not in ('prepared', 'committing', 'committed') or type(journal.get('had_original')) is not bool:
        raise ValueError('Invalid Python recovery record; files were retained')
    backup = transaction / 'backup'
    if journal['phase'] == 'committing':
        if backup.exists():
            if target.exists():
                shutil.rmtree(target)
            os.replace(backup, target)
        elif not journal['had_original'] and target.exists():
            shutil.rmtree(target)
    shutil.rmtree(transaction)


def merge(target, incoming, merged):
    """Preserve unrelated namespace files; remove obsolete upgraded-package files."""
    validate_tree(incoming)
    new = distributions(incoming)
    if not new:
        raise ValueError('Installer produced no wheel distributions')
    old = distributions(target) if target.exists() else {}
    incoming_owners = {}
    for name, distribution in new.items():
        for relative in records(distribution, incoming):
            incoming_owners.setdefault(relative, set()).add(name)
    retained = {}
    for name, distribution in old.items():
        if name not in new:
            for relative in records(distribution, target):
                retained.setdefault(relative, set()).add(name)
    if target.exists():
        validate_tree(target)
        shutil.copytree(target, merged)
    else:
        merged.mkdir()
    for name, distribution in old.items():
        if name in new:
            for relative in records(distribution, target):
                destination = checked_path(merged, relative)
                if relative not in retained and destination.is_file():
                    destination.unlink()
    for directory, _, files in os.walk(incoming):
        for filename in files:
            source = Path(directory) / filename
            relative = source.relative_to(incoming).as_posix()
            destination = checked_path(merged, relative)
            if relative not in incoming_owners:
                # pip creates console scripts outside wheel RECORD. They are
                # not executable entry points in the app's managed package path.
                if relative.startswith('bin/') or '__pycache__/' in relative:
                    continue
                raise ValueError('Unowned installed file: ' + relative)
            if destination.exists():
                same = hashlib.sha256(destination.read_bytes()).digest() == hashlib.sha256(source.read_bytes()).digest()
                if not same:
                    raise ValueError('Package file conflicts with retained data: ' + relative)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
    # Remove obsolete empty dist-info directories so importlib cannot see them.
    for directory, _, _ in os.walk(merged, topdown=False):
        path = Path(directory)
        if path != merged and not any(path.iterdir()):
            path.rmdir()
    return new


def validate_dependencies(merged):
    from pip._vendor.packaging.requirements import Requirement
    versions = {}
    for distribution in metadata.distributions():
        name = distribution.metadata['Name']
        if name:
            versions.setdefault(normalize(name), distribution.version)
    installed = distributions(merged)
    versions.update({name: distribution.version for name, distribution in installed.items()})
    for distribution in installed.values():
        for text in distribution.requires or []:
            requirement = Requirement(text)
            if requirement.marker and not requirement.marker.evaluate({'extra': ''}):
                continue
            version = versions.get(normalize(requirement.name))
            if not version or (requirement.specifier and not requirement.specifier.contains(version, prereleases=True)):
                raise ValueError('Dependency conflict: ' + distribution.metadata['Name'] + ' requires ' + str(requirement))


def install(specs, target, pip_runner=None):
    target = Path(target)
    recover(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    transaction = target.parent / '.floe-python-transaction'
    transaction.mkdir()
    journal = {'phase': 'prepared', 'had_original': target.exists()}
    write_journal(transaction, journal)
    incoming, merged, backup = (transaction / name for name in ('incoming', 'merged', 'backup'))
    try:
        if pip_runner is None:
            from pip._internal.cli.main import main as pip_runner
        cache = target.parent / 'PythonPackageCache'
        code = pip_runner(['install', '--disable-pip-version-check', '--no-input', '--no-compile',
                           '--only-binary=:all:', '--platform=any', '--implementation=py', '--abi=none',
                           '--cache-dir', str(cache), '--target', str(incoming)] + specs)
        if code:
            raise RuntimeError('Managed package install failed with exit code ' + str(code))
        resolved = merge(target, incoming, merged)
        validate_dependencies(merged)
        journal['phase'] = 'committing'
        write_journal(transaction, journal)
        if journal['had_original']:
            os.replace(target, backup)
        os.replace(merged, target)
        journal['phase'] = 'committed'
        write_journal(transaction, journal)
        print('managedPackages=' + ','.join(specs))
        print('resolvedDistributions=' + ','.join(sorted(resolved)))
    except BaseException:
        recover(target)
        raise
    recover(target)

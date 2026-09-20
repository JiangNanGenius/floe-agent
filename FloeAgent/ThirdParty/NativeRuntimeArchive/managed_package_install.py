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
from urllib.parse import urlsplit, urlunsplit, unquote


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


def normalize_staged_script_records(incoming):
    # pip --target relocates wheel scripts into incoming/bin but leaves their
    # RECORD paths relative to its temporary lib directory (../../bin/name).
    # Rewrite only that exact relocation, proving the actual file is contained.
    # All other traversal remains an error. The committed RECORD is portable
    # for subsequent ownership-aware uninstall and rollback.
    for distribution in distributions(incoming).values():
        info = Path(distribution._path)
        record = checked_path(incoming, str(info.relative_to(incoming) / 'RECORD'))
        if record.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Package ownership record is too large')
        rows = list(csv.reader(io.StringIO(record.read_text()), strict=True))
        changed = False
        for row in rows:
            if len(row) != 3:
                raise ValueError('Invalid package ownership record')
            match = re.fullmatch(r'\.\./\.\./bin/([^/\\]+)', row[0])
            if match:
                relative = 'bin/' + match.group(1)
                actual = checked_path(incoming, relative)
                if not actual.is_file() or actual.is_symlink():
                    raise ValueError('Missing relocated package script')
                row[0] = relative
                changed = True
            else:
                checked_path(incoming, row[0])
        if changed:
            with record.open('w', newline='') as output:
                csv.writer(output).writerows(rows)


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


def resolved_wheels(report):
    if report.is_symlink() or report.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('Invalid dependency resolution report')
    result = json.loads(report.read_text())
    entries = result.get('install')
    if result.get('version') != '1' or not isinstance(entries, list) or len(entries) > 512:
        raise ValueError('Invalid dependency resolution report')
    wheels = []
    for entry in entries:
        download = entry.get('download_info', {})
        address = download.get('url', '')
        parsed = urlsplit(address)
        digest = download.get('archive_info', {}).get('hashes', {}).get('sha256', '')
        if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or len(address) > 4096
                or not unquote(parsed.path).endswith('-none-any.whl')
                or not re.fullmatch('[0-9a-f]{64}', digest)):
            raise ValueError('Resolved dependency requires a compatible pure Python wheel with a SHA-256 digest')
        wheels.append(urlunsplit(parsed._replace(fragment='sha256=' + digest)))
    return wheels


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
        common = ['install', '--disable-pip-version-check', '--no-input', '--no-compile',
                  '--index-url', os.environ.get('FLOE_PYTHON_INDEX_URL', 'https://pypi.org/simple/'),
                  '--only-binary=:all:', '--platform=any', '--implementation=py', '--abi=none',
                  '--cache-dir', str(cache)]
        # --target implies --ignore-installed. Resolve without --target first
        # so the current environment and signed bundled native libraries can
        # satisfy dependencies; only the missing pure wheels are staged.
        report = transaction / 'resolution.json'
        code = pip_runner(common + ['--dry-run', '--report', str(report)] + specs)
        if code:
            raise RuntimeError('Managed dependency resolution failed with exit code ' + str(code))
        wheels = resolved_wheels(report)
        if not wheels:
            validate_dependencies(target)
            recover(target)
            print('managedPackagesAlreadySatisfied=' + ','.join(specs))
            return
        code = pip_runner(common + ['--no-deps', '--target', str(incoming)] + wheels)
        if code:
            raise RuntimeError('Managed package install failed with exit code ' + str(code))
        validate_tree(incoming)
        normalize_staged_script_records(incoming)
        resolved = merge(target, incoming, merged)
        validate_dependencies(merged)
        journal['phase'] = 'committing'
        write_journal(transaction, journal)
        if journal['had_original']:
            os.replace(target, backup)
        os.replace(merged, target)
        journal['phase'] = 'committed'
        write_journal(transaction, journal)
        __import__('importlib').invalidate_caches()
        print('managedPackages=' + ','.join(specs))
        print('resolvedDistributions=' + ','.join(sorted(resolved)))
    except BaseException:
        recover(target)
        raise
    recover(target)

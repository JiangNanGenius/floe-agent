#!/usr/bin/env python3
"""Prepare pinned Office binaries at build time, never from the running app."""
import argparse
import hashlib
import office_compiled_lifecycle as compiled_lifecycle
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import time
import zipfile

try:
    import office_browser_resources as browser_resources
except ModuleNotFoundError:
    # Standalone/copied review harnesses may ship only the bootstrap script
    # and its pre-existing dependencies. Every artifact that actually carries
    # browser bytes or a claim requires the helper below.
    browser_resources = None


def browser_resources_module(*, required):
    if browser_resources is None:
        if required:
            raise ValueError(
                'office_browser_resources.py and its producer must ship beside '
                'the Office bootstrap scripts for a browser resource claim')
        return None
    return browser_resources


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
    # When the host pin claims a scheme lifecycle overlay, the produced host
    # manifest must carry matching provenance so an older host cannot satisfy
    # the claim. Absent claim: hosts built before this overlay stay accepted.
    scheme_claim = pin.get('schemeOverlaySHA256')
    if scheme_claim is not None:
        overlay = lock.get('schemeTaskLifecycleOverlay')
        if overlay is None or scheme_claim != overlay['sha256']:
            raise ValueError('Native host scheme overlay claim does not match its lock')
    # Same contract for the forwarding lifecycle overlay.
    forwarding_claim = pin.get('forwardingOverlaySHA256')
    if forwarding_claim is not None:
        overlay = lock.get('forwardingLifecycleOverlay')
        if overlay is None or forwarding_claim != overlay['sha256']:
            raise ValueError('Native host forwarding overlay claim does not match its lock')
    # Same contract for the kit callback lifecycle overlay. An absent claim
    # keeps hosts built before this overlay usable until the pin is replaced.
    kit_claim = pin.get('kitCallbackOverlaySHA256')
    if kit_claim is not None:
        overlay = lock.get('kitCallbackLifecycleOverlay')
        if overlay is None or kit_claim != overlay['sha256']:
            raise ValueError('Native host kit callback overlay claim does not match its lock')
    # Same contract for the tracked single-member engine repair (blank iOS
    # slideshow fix): when the pin claims it, the claim must match the tracked
    # lock exactly.  Unlike the simulator qualification (which proves the
    # repair and requires it), the device pin stays usable while it predates
    # the repair: `pin_office_host_artifact.py --check` reports SOURCE AHEAD
    # and the re-pin happens only after the cloud rebuild, so a consistent
    # but pre-repair device host can still satisfy local simulator builds.
    import office_engine_repair
    repair_lock, repair_section = office_engine_repair.tracked_contract(
        lock_path=Path(lock_path).parent / 'engine.patch.lock.json',
        platform='IOS')
    repair_claim = pin.get('engineRepair')
    if repair_section is not None and repair_claim is not None:
        expected = office_engine_repair.expected_manifest_block(repair_lock, repair_section)
        if json.dumps(repair_claim, sort_keys=True) != json.dumps(expected, sort_keys=True):
            raise ValueError('Native host engine repair claim does not match its lock')
    if pin.get('embeddedLifecycleMember') is not None:
        compiled_lifecycle.validate(pin['embeddedLifecycleMember'], lock, 'IOS', lock_path=lock_path)
    # The separate browser frontend identity. An immutable legacy pin without
    # the block stays a usable baseline; once the pin claims it, the live
    # adjacent browser contract must match the portable block exactly.
    browser_block = pin.get('browserResources')
    if browser_block is not None:
        try:
            module = browser_resources_module(required=True)
            browser_contract = module.live_contract(
                lock_path, engine_commit=lock.get('commit'))
        except ValueError as failure:
            raise ValueError('Native host browser resources contract is invalid: '
                             + str(failure))
        if browser_contract is None:
            raise ValueError('Native host claims browser resources without a tracked browser patch contract')
        failures = module.compact_block_failures(browser_block, browser_contract)
        if failures:
            raise ValueError('Native host browser resources claim does not match its lock: '
                             + '; '.join(failures))
    for name, checksum in pin['hostSourceSHA256'].items():
        relative(name)
        if digest(lock_path.parent / 'FloeOfficeNative' / name) != checksum:
            raise ValueError('Native host must be rebuilt for its changed public or implementation source')
    if 'filterOverlay' in pin:
        filters = json.loads((lock_path.parent / 'filter-overlay.lock.json').read_text())
        selected = pin['filterOverlay']
        patch = lock_path.parent / relative(filters['patch'])
        if (filters['commit'] != lock['commit']
                or selected['patchSHA256'] != filters['patchSHA256']
                or selected['sourceFiles'] != filters['files']
                or selected.get('headerDependencies', {}) != filters.get('headerDependencies', {})
                or digest(patch) != filters['patchSHA256']):
            raise ValueError('Native host must be rebuilt for the current engine filter patch')
        for spec in filters.get('headerDependencies', {}).values():
            if spec.get('patch') and digest(lock_path.parent / spec['patch']) != spec['patchSHA256']:
                raise ValueError('Native host header dependency patch differs from its lock')
        extras = filters.get('additionalArchives', {})
        if extras:
            actual = selected.get('additionalArchives', {})
            hashes = selected.get('selectedArchiveSHA256ByName', {})
            if set(actual) != set(extras) or set(hashes) != {'libscfiltlo.a', *extras}:
                raise ValueError('Native host is missing qualified additional filter archives')
            for name, spec in extras.items():
                if (actual[name].get('originalArchiveSHA256') != spec['originalArchiveSHA256']
                        or set(actual[name].get('objectSHA256ByMember', {})) != set(spec['members'])
                        or hashes[name] != actual[name].get('archiveSHA256')):
                    raise ValueError('Native host additional filter archive differs from its lock')
    return lock, pin


SIMULATOR_RECEIPT = 'native-host-simulator.json'
SIMULATOR_FRAMEWORK = FRAMEWORK
SIMULATOR_RESOURCES = 'OfficeRuntimeResources'


def verify_simulator_host(folder, lock_path=LOCK):
    """Verify a staged iphonesimulator Office host against the tracked pin.

    This is the simulator sibling of ``checked_lock`` + ``inventory``: the
    device pin stays untouched, and the simulator host carries its own
    receipt (``native-host-simulator.json``) produced by
    ``office_floe_simulator.build_simulator_framework``. Every hash is checked
    against the on-disk bundle; the tracked engine lock still owns the source
    commit and the embedding/scheme/forwarding/kit overlay SHAs, so a host
    built from different sources or overlays can never be embedded.
    """
    lock = json.loads(Path(lock_path).read_text())
    folder = Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('Office simulator host destination is not an owned directory')
    entries = list(folder.rglob('*'))
    if any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in entries):
        raise ValueError('Office simulator host contains an unexpected alias')
    receipt_path = folder / SIMULATOR_RECEIPT
    if not receipt_path.is_file():
        raise ValueError('Office simulator host lacks its qualification receipt')
    receipt = json.loads(receipt_path.read_text())

    failures = []
    def check(condition, message):
        if not condition:
            failures.append(message)

    check(receipt.get('platform') == 'iphonesimulator', 'simulator host platform mismatch')
    check(receipt.get('arch') == 'arm64', 'simulator host arch mismatch')
    check(receipt.get('sourceCommit') == lock['commit'],
          'simulator host source commit differs from the tracked pin')
    check(receipt.get('overlaySHA256') == lock['embeddingOverlay']['sha256'],
          'simulator host embedding overlay differs from the tracked pin')
    expected_sources = {name: digest(Path(lock_path).parent / 'FloeOfficeNative' / relative(name))
                        for name in lock['qualifiedHostArtifact']['hostSourceSHA256']}
    check(receipt.get('hostSourceSHA256') == expected_sources,
          'simulator host implementation sources differ from this checkout')
    scheme = lock.get('schemeTaskLifecycleOverlay')
    if scheme is not None:
        provenance = receipt.get('schemeTaskLifecycle') or {}
        check(provenance.get('patchSHA256') == scheme['sha256']
              and provenance.get('sourceCommit') == lock['commit']
              and provenance.get('files') == {name: spec['preparedSHA256']
                                               for name, spec in scheme['files'].items()},
              'simulator host scheme overlay provenance mismatch')
    forwarding = lock.get('forwardingLifecycleOverlay')
    if forwarding is not None:
        provenance = receipt.get('forwardingLifecycle') or {}
        check(provenance.get('patchSHA256') == forwarding['sha256']
              and provenance.get('sourceCommit') == lock['commit']
              and provenance.get('files') == {name: spec['preparedSHA256']
                                               for name, spec in forwarding['files'].items()},
              'simulator host forwarding overlay provenance mismatch')
    kit = lock.get('kitCallbackLifecycleOverlay')
    kit_applied = receipt.get('kitCallbackOverlayApplied')
    check(isinstance(kit_applied, bool), 'simulator host must record kitCallbackOverlayApplied')
    check(receipt.get('variant') in ('kit', 'nokit')
          and kit_applied == (receipt.get('variant') == 'kit'),
          'simulator host variant contradicts its kit overlay claim')
    if kit is not None and kit_applied:
        provenance = receipt.get('kitCallbackLifecycle') or {}
        check(provenance.get('patchSHA256') == kit['sha256']
              and provenance.get('sourceCommit') == lock['commit']
              and provenance.get('files') == {name: spec['preparedSHA256']
                                               for name, spec in kit['files'].items()},
              'simulator host kit callback overlay provenance mismatch')
    embedded = lock.get('embeddedLifecycleOverlay')
    provenance = receipt.get('embeddedLifecycle')
    if embedded is not None:
        check(isinstance(provenance, dict)
              and provenance.get('patchSHA256') == embedded['sha256']
              and provenance.get('sourceCommit') == lock['commit']
              and provenance.get('files') == {name: spec['preparedSHA256']
                                               for name, spec in embedded['files'].items()},
              'simulator host embedded lifecycle overlay provenance mismatch')
    else:
        check(provenance is None,
              'simulator host carries an embedded lifecycle receipt the pin does not track')
    archives = receipt.get('platformOriginalArchives') or {}
    check(archives.get('sdk') == 'iphonesimulator' and bool(archives.get('archives')),
          'simulator host must record its own platform original archive hashes')
    member_block = receipt.get('embeddedLifecycleMember')
    compiled_contract_status = 'untracked'
    try:
        if compiled_lifecycle.contract(lock, 'IOSSIMULATOR') is not None:
            originals = archives.get('archives') or {}
            if isinstance(member_block, dict) and 'schemaVersion' not in member_block:
                # Historical f033 simulator only; never canonical evidence and
                # never reachable for a producer carrying a schema version.
                compiled_lifecycle.validate_legacy_simulator(member_block, lock, originals)
                compiled_contract_status = 'historical-pre-schema-not-canonical'
            else:
                compiled_lifecycle.validate_manifest(receipt, lock, 'IOSSIMULATOR', lock_path=lock_path)
                compiled_contract_status = 'canonical-v' + str(member_block['schemaVersion'])
        elif member_block is not None:
            raise ValueError('untracked simulator compiled lifecycle member')
    except ValueError as error:
        failures.append(str(error))
    staged = receipt.get('stagedEngine') or {}
    check(bool(staged.get('runID')), 'simulator host staged engine run ID missing')
    check(staged.get('sourceCommit') == lock['commit'],
          'simulator host staged engine source differs from the tracked pin')
    check(bool(staged.get('artifactSHA256')), 'simulator host staged engine artifact hash missing')
    for field in ('sdkVersion', 'sdkBuildVersion', 'xcodeVersion'):
        check(bool(receipt.get(field)), f'simulator host {field} missing')
    for field in ('nativeCompilePassed', 'nativeLinkPassed', 'swiftModuleImportPassed'):
        check(receipt.get(field) is True, f'simulator host {field} is not true')
    filter_block = receipt.get('filterOverlay') or {}
    if filter_block.get('applied'):
        # A simulator host may carry the chart/freehand filter overlay only as
        # simulator-compiled objects with its own verified provenance: same
        # patch and member contract as the lock, platform IOSSIMULATOR, and
        # originals identical to the pre-overlay platform archives recorded by
        # the same receipt. Device bytes or device hashes can never satisfy it.
        import json as _json
        filter_lock = _json.loads((Path(lock_path).parent / 'filter-overlay.lock.json').read_text())
        originals = (receipt.get('platformOriginalArchives') or {}).get('archives') or {}
        recorded = filter_block.get('originalArchiveSHA256ByName') or {}
        check(filter_block.get('platform') == 'IOSSIMULATOR',
              'simulator host filter overlay was not compiled for the simulator')
        check(filter_block.get('patchSHA256') == filter_lock['patchSHA256'],
              'simulator host filter overlay patch differs from the tracked lock')
        locked_members = set(filter_lock['simulator']['members']) | {
            m for spec in filter_lock['simulator']['additionalArchives'].values()
            for m in spec['members']}
        built_members = set(filter_block.get('objectSHA256ByMember') or {})
        for extra in (filter_block.get('additionalArchives') or {}).values():
            built_members |= set(extra.get('objectSHA256ByMember') or {})
        check(built_members == locked_members,
              'simulator host filter overlay member set differs from the tracked lock')
        check(bool(originals) and all(originals.get(name) == sha
                                      for name, sha in recorded.items()),
              'simulator host filter overlay originals differ from its platform archives')
    else:
        check(filter_block.get('applied') is False,
              'simulator host filter overlay block is malformed')
    import office_engine_repair
    repair_lock, repair_section = office_engine_repair.tracked_contract(
        lock_path=Path(lock_path).parent / 'engine.patch.lock.json',
        platform='IOSSIMULATOR')
    if repair_section is not None:
        expected = office_engine_repair.expected_manifest_block(repair_lock, repair_section)
        check(json.dumps(receipt.get('engineRepair'), sort_keys=True)
              == json.dumps(expected, sort_keys=True),
              'simulator host engine repair provenance mismatch')
    # The browser frontend identity is independent of the native repair
    # contract. A new host carries the exact portable block and its packaged
    # bundle digest; a pre-patch host without the block remains compatible
    # while it has no bundle resource or still embeds the pinned original,
    # and is never treated as frontend delivery evidence.
    browser_block = receipt.get('browserResources')
    raw_runtime = receipt.get('runtimeResourceSHA256') or {}
    has_runtime_bundle = (isinstance(raw_runtime, dict)
                          and raw_runtime.get('bundle.js') is not None)
    if browser_block is not None or has_runtime_bundle:
        module = None
        browser_contract = None
        runtime_bundle = None
        try:
            module = browser_resources_module(required=True)
            runtime_bundle = module.runtime_bundle_sha256(raw_runtime)
            browser_contract = module.live_contract(
                lock_path, engine_commit=lock.get('commit'))
        except ValueError as failure:
            failures.append(str(failure))
        if module is not None:
            if browser_contract is not None:
                if isinstance(browser_block, dict):
                    failures.extend(module.compact_block_failures(
                        browser_block, browser_contract,
                        actual_bundle_sha256=runtime_bundle))
                elif runtime_bundle != module.EXPECTED_ORIGINAL_BUNDLE_SHA256:
                    failures.append('simulator host carries a non-baseline browser bundle '
                                    'without a browser resource claim')
            elif browser_block is not None:
                failures.append('simulator host claims browser resources without a '
                                'tracked browser patch contract')

    files = {SIMULATOR_RECEIPT: None,
             SIMULATOR_FRAMEWORK + '/FloeOfficeNative': receipt.get('executableSHA256')}
    files.update({SIMULATOR_FRAMEWORK + '/' + str(relative(name)): checksum
                  for name, checksum in (receipt.get('frameworkAuxiliarySHA256') or {}).items()})
    files.update({SIMULATOR_RESOURCES + '/' + str(relative(name)): checksum
                  for name, checksum in (receipt.get('runtimeResourceSHA256') or {}).items()})
    check(bool(files.get(SIMULATOR_FRAMEWORK + '/FloeOfficeNative')),
          'simulator host receipt lacks the framework executable hash')
    directories = {SIMULATOR_RESOURCES + '/' + str(relative(name))
                   for name in (receipt.get('runtimeResourceDirectories') or [])}
    for name in list(files) + list(directories):
        directories.update(str(parent) for parent in relative(name).parents if str(parent) != '.')
    actual_files = {str(path.relative_to(folder)) for path in entries if path.is_file()}
    actual_directories = {str(path.relative_to(folder)) for path in entries if path.is_dir()}
    check(actual_files == set(files), 'simulator host file inventory changed')
    check(actual_directories == directories, 'simulator host directory inventory changed')
    if actual_files == set(files):
        for name, checksum in files.items():
            if checksum is None:
                continue
            if digest(folder / name) != checksum:
                failures.append('simulator host content checksum mismatch: ' + name)
    if failures:
        raise ValueError('Office simulator host verification failed: ' + '; '.join(failures))
    return {'verifiedFiles': len(actual_files), 'verifiedDirectories': len(actual_directories),
            'variant': receipt.get('variant'),
            'kitCallbackOverlayApplied': receipt.get('kitCallbackOverlayApplied'),
            'compiledLifecycleContract': compiled_contract_status,
            'stagedEngineRunID': staged.get('runID'),
            'platform': receipt.get('platform'), 'arch': receipt.get('arch')}


def inventory(folder, lock, pin):
    manifest_path = folder / 'native-host.json'
    if manifest_path.is_symlink() or digest(manifest_path) != pin['manifestSHA256']:
        raise ValueError('Native Office manifest differs from its qualification pin')
    report = json.loads(manifest_path.read_text())
    if (report['sourceCommit'] != lock['commit'] or report['overlaySHA256'] != pin['overlaySHA256']
            or report['hostSourceSHA256'] != pin['hostSourceSHA256']
            or not all(report.get(key) is True for key in ['hostCompilePassed', 'hostLinkPassed', 'swiftModuleImportPassed'])):
        raise ValueError('Native Office qualification does not match this build')
    scheme_claim = pin.get('schemeOverlaySHA256')
    if scheme_claim is not None:
        overlay = lock['schemeTaskLifecycleOverlay']
        provenance = report.get('schemeTaskLifecycle', {})
        expected_files = {name: spec['preparedSHA256']
                          for name, spec in overlay['files'].items()}
        if (provenance.get('patchSHA256') != scheme_claim
                or provenance.get('sourceCommit') != lock['commit']
                or provenance.get('files') != expected_files):
            raise ValueError('Native Office host lacks the pinned scheme overlay provenance')
    forwarding_claim = pin.get('forwardingOverlaySHA256')
    if forwarding_claim is not None:
        overlay = lock['forwardingLifecycleOverlay']
        provenance = report.get('forwardingLifecycle', {})
        expected_files = {name: spec['preparedSHA256']
                          for name, spec in overlay['files'].items()}
        if (provenance.get('patchSHA256') != forwarding_claim
                or provenance.get('sourceCommit') != lock['commit']
                or provenance.get('files') != expected_files):
            raise ValueError('Native Office host lacks the pinned forwarding overlay provenance')
    kit_claim = pin.get('kitCallbackOverlaySHA256')
    if kit_claim is not None:
        overlay = lock['kitCallbackLifecycleOverlay']
        provenance = report.get('kitCallbackLifecycle', {})
        expected_files = {name: spec['preparedSHA256']
                          for name, spec in overlay['files'].items()}
        if (provenance.get('patchSHA256') != kit_claim
                or provenance.get('sourceCommit') != lock['commit']
                or provenance.get('files') != expected_files):
            raise ValueError('Native Office host lacks the pinned kit callback overlay provenance')
    embedded_claim = pin.get('embeddedLifecycleOverlaySHA256')
    if embedded_claim is not None:
        overlay = lock['embeddedLifecycleOverlay']
        provenance = report.get('embeddedLifecycle', {})
        expected_files = {name: spec['preparedSHA256']
                          for name, spec in overlay['files'].items()}
        if (provenance.get('patchSHA256') != embedded_claim
                or provenance.get('sourceCommit') != lock['commit']
                or provenance.get('files') != expected_files):
            raise ValueError('Native Office host lacks the pinned embedded lifecycle overlay provenance')
    if pin.get('embeddedLifecycleMember') is not None:
        compiled_lifecycle.validate_manifest(report, lock, 'IOS', expected=pin['embeddedLifecycleMember'])
    if 'engineRepair' in pin:
        block = report.get('engineRepair', {})
        if json.dumps(block, sort_keys=True) != json.dumps(pin['engineRepair'], sort_keys=True):
            raise ValueError('Native Office host lacks the pinned engine repair provenance')
    if 'filterOverlay' in pin:
        selected = report.get('filterOverlay', {})
        if (not selected.get('compilePassed') or not selected.get('archiveReplacementPassed')
                or any(selected.get(key) != value for key, value in pin['filterOverlay'].items())):
            raise ValueError('Native Office filter qualification does not match its pin')
    # The browser frontend block must match the pin and the bytes this host
    # actually packages. A legacy pin without the claim is accepted only while
    # the host still embeds the pinned original bundle, so it can never be
    # read as frontend delivery evidence.
    browser_block = pin.get('browserResources')
    raw_runtime = report.get('runtimeResourceSHA256') or {}
    has_runtime_bundle = (isinstance(raw_runtime, dict)
                          and raw_runtime.get('bundle.js') is not None)
    if browser_block is not None or has_runtime_bundle:
        try:
            module = browser_resources_module(required=True)
        except ValueError as failure:
            raise ValueError(str(failure))
        runtime_bundle = module.runtime_bundle_sha256(raw_runtime)
        if browser_block is not None:
            if report.get('browserResources') != browser_block:
                raise ValueError('Native Office host lacks the pinned browser resource identity')
            if runtime_bundle != browser_block.get('bundleSHA256'):
                raise ValueError('Native Office host browser bundle digest differs from its pin')
        elif runtime_bundle != module.EXPECTED_ORIGINAL_BUNDLE_SHA256:
            raise ValueError('Native Office host carries a non-baseline browser bundle '
                             'without a browser resource claim')
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
    """Keep build dependency declarations bounded; verification checks every file."""
    lock, pin = checked_lock(lock_path)
    verify_installed(folder, lock, pin)
    folder, project_root, output = Path(folder), Path(project_root), Path(output)
    # Per-file definitions overflow the script process argument/environment
    # limit. The dedicated copy phase validates the entire pinned directory.
    paths = [folder]
    lines = []
    for path in paths:
        name = str(path.relative_to(project_root))
        if any(char in name for char in '\n\r$'):
            raise ValueError('Office source cannot be represented in an Xcode input list')
        lines.append('$(SRCROOT)/' + name)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('\n'.join(lines) + '\n')


def write_project_configuration(folder, output, project_root=ROOT, lock_path=LOCK):
    """Use the same verified host for Swift import, linking and resource copy.

    Simulator lines previously written by ``office_floe_simulator`` (from an
    explicitly installed, verified iphonesimulator host) are preserved so the
    device bootstrap can run in any order without disabling a simulator
    qualification host.
    """
    lock, pin = checked_lock(lock_path)
    verify_installed(folder, lock, pin)
    name = str(Path(folder).relative_to(project_root))
    if any(char in name for char in '\n\r$#="') or '//' in name:
        raise ValueError('Office source cannot be represented in an Xcode configuration')
    preserved = []
    output = Path(output)
    if output.is_file():
        for line in output.read_text().splitlines():
            if line.startswith('FLOE_OFFICE_SIM_HOST_DIR') or line.startswith('FLOE_OFFICE_SIM_LDFLAG'):
                preserved.append(line)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('// Generated from the verified native Office qualification pin.\n'
                      'FLOE_OFFICE_HOST_DIR = $(PROJECT_DIR)/' + name + '\n'
                      + ('\n'.join(preserved) + '\n' if preserved else ''))


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
            write_project_configuration(destination, ROOT / 'Vendor/Office/native-host.xcconfig')
        print(json.dumps(result, indent=2))

    if destination.exists() or destination.is_symlink() or args.verify_only:
        finish(verify_installed(destination, lock, pin))
        return
    if args.archive:
        finish(install(args.archive, destination))
        return
    # gh uses the developer's existing login or the CI job's read-only token.
    # Credentials never enter the command, artifact, or application resources.
    for attempt in range(3):
        # A failed download may leave a partial ZIP. Retry in a fresh directory;
        # signature/digest/install failures are never retried or bypassed.
        with tempfile.TemporaryDirectory(prefix='floe-office-download-') as temporary:
            try:
                subprocess.run(['gh', 'run', 'download', pin['runID'], '--repo', 'JiangNanGenius/floe-agent',
                                '--name', pin['artifactName'], '--dir', temporary], check=True, timeout=600)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                if attempt == 2:
                    raise
                print(f'Office artifact download interrupted; retry {attempt + 2}/3')
                time.sleep(5 * (attempt + 1))
                continue
            finish(install(Path(temporary) / 'OfficeNativeHost.zip', destination))
            return


if __name__ == '__main__':
    main()

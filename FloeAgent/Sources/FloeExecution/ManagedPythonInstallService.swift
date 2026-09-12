// FloeExecution — Shared managed Python package installer.
// Previously inlined in exec.localPython; extracted so the shell tool and the
// apt capability layer install pure-Python packages through exactly the same
// reviewed, staged, atomic path (py3-none-any wheels only, native rejected).

import Foundation
import FloeCore
import FloeTools

public struct ManagedPythonInstallService: Sendable {
    public enum Outcome: Sendable {
        case ok(output: String)
        case failed(message: String)
        case timedOut(partialOutput: String)
        case cancelled
    }

    private let python: LocalPythonService
    private let packagesChanged: @Sendable () async -> Void

    public init(python: LocalPythonService, packagesChanged: @escaping @Sendable () async -> Void = {}) {
        self.python = python
        self.packagesChanged = packagesChanged
    }

    /// Builds the installer program that runs inside the managed CPython
    /// process. The private installer phase flag permits pip only for this
    /// exact program; agent scripts remain blocked by the audit hook.
    private static func installerScript(packageJSON: String) -> String {
        """
        import json, sys, os, shutil, tempfile
        from pip._internal.cli.main import main as _floe_pip
        _target = next((p for p in sys.path if p.endswith('PythonPackages')), None)
        if not _target:
            raise RuntimeError('Managed package directory is unavailable')
        _specs = json.loads(\(String(reflecting: packageJSON)))
        _parent = os.path.dirname(_target)
        os.makedirs(_parent, exist_ok=True)
        os.makedirs(_target, exist_ok=True)
        _stage = tempfile.mkdtemp(prefix='floe-pip-stage-', dir=_parent)
        _backup = tempfile.mkdtemp(prefix='floe-pip-backup-', dir=_parent)
        _cache = os.path.join(_parent, 'PythonPackageCache')
        os.makedirs(_cache, exist_ok=True)
        _args = ['install', '--disable-pip-version-check', '--no-input',
                 '--only-binary=:all:', '--platform=any', '--implementation=py',
                 '--abi=none', '--cache-dir', _cache, '--target', _stage] + _specs
        try:
            _code = _floe_pip(_args)
            if _code != 0:
                raise RuntimeError(f'Managed package install failed with exit code {_code}')
            _native = []
            for _root, _dirs, _files in os.walk(_stage):
                for _file in _files:
                    if _file.lower().endswith(('.so', '.dylib', '.a', '.framework', '.bundle')):
                        _native.append(os.path.join(_root, _file))
            if _native:
                raise RuntimeError('Managed package contains prohibited native artifacts')
            _distributions = sorted(
                _name[:-10] for _name in os.listdir(_stage)
                if _name.lower().endswith('.dist-info')
            )
            _installed = []
            try:
                for _name in os.listdir(_stage):
                    _source = os.path.join(_stage, _name)
                    _destination = os.path.join(_target, _name)
                    if os.path.lexists(_destination):
                        shutil.move(_destination, os.path.join(_backup, _name))
                    shutil.move(_source, _destination)
                    _installed.append(_name)
            except BaseException:
                for _name in _installed:
                    _destination = os.path.join(_target, _name)
                    if os.path.isdir(_destination): shutil.rmtree(_destination, ignore_errors=True)
                    elif os.path.lexists(_destination): os.remove(_destination)
                for _name in os.listdir(_backup):
                    shutil.move(os.path.join(_backup, _name), os.path.join(_target, _name))
                raise
            print('managedPackages=' + ','.join(_specs))
            print('resolvedDistributions=' + ','.join(_distributions))
        finally:
            shutil.rmtree(_stage, ignore_errors=True)
            shutil.rmtree(_backup, ignore_errors=True)
        """
    }

    public func install(
        specs: [String],
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken?
    ) async -> Outcome {
        var seen = Set<String>()
        let uniqueSpecs = specs.filter { seen.insert($0.lowercased()).inserted }
        guard !uniqueSpecs.isEmpty else { return .ok(output: "") }
        for spec in uniqueSpecs {
            do {
                try ManagedPythonPackageSpecParser.validate(spec)
            } catch {
                return .failed(message: "Invalid package spec \(spec): \(error.localizedDescription)")
            }
        }
        let encoded = (try? JSONEncoder().encode(uniqueSpecs)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let request = ScriptExecutionRequest(
            script: Self.installerScript(packageJSON: encoded),
            inputJSON: nil,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            allowsManagedPackageInstaller: true
        )
        let outcome = await python.run(request, cancellation: cancellation)
        switch outcome {
        case .ok(_, let stdout, let stderr, _, _, _):
            await packagesChanged()
            return .ok(output: stderr.isEmpty ? stdout : stdout + "\n" + stderr)
        case .jsException(let message, let stdout):
            return .failed(message: message + (stdout.isEmpty ? "" : "\n" + stdout))
        case .timedOut(_, let partialStdout):
            return .timedOut(partialOutput: partialStdout)
        case .cancelled:
            return .cancelled
        }
    }

    /// Removes an installed distribution by deleting exactly the files its
    /// RECORD lists, then the dist-info directory. Bundled (read-only)
    /// distributions cannot be removed and report a clear failure.
    public func uninstall(distribution: String) async -> Outcome {
        guard let url = Bundle.module.url(forResource: "managed_package_remove", withExtension: "py"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let data = try? JSONEncoder().encode(["distribution": distribution]) else {
            return .failed(message: "Managed package removal resource is unavailable")
        }
        let request = ScriptExecutionRequest(
            script: script,
            inputJSON: String(decoding: data, as: UTF8.self),
            timeout: 30,
            maxOutputBytes: 64 * 1024,
            allowsManagedPackageInstaller: true
        )
        let outcome = await python.run(request, cancellation: nil)
        switch outcome {
        case .ok(_, let stdout, let stderr, _, _, _):
            await packagesChanged()
            return .ok(output: stderr.isEmpty ? stdout : stdout + "\n" + stderr)
        case .jsException(let message, let stdout):
            return .failed(message: message + (stdout.isEmpty ? "" : "\n" + stdout))
        case .timedOut(_, let partialStdout):
            return .timedOut(partialOutput: partialStdout)
        case .cancelled:
            return .cancelled
        }
    }

    /// Distributions visible to the interpreter: bundled site-packages and
    /// the managed mutable root. Bundled entries cannot be uninstalled.
    public func installedDistributions() async -> [String] {
        let script = """
        import sys, importlib.metadata, re
        _roots = [p for p in sys.path if p.endswith('site-packages') or p.endswith('PythonPackages')]
        _names = {re.sub(r'[-_.]+', '-', d.metadata['Name']).lower()
                  for d in importlib.metadata.distributions(path=_roots) if d.metadata['Name']}
        print('\\n'.join(sorted(_names)))
        """
        let request = ScriptExecutionRequest(script: script, timeout: 10, maxOutputBytes: 64 * 1024)
        guard case .ok(_, let stdout, _, _, _, _) = await python.run(request, cancellation: nil) else { return [] }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

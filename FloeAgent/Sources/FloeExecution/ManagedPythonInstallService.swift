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

    public static func executionContext(_ environment: ToolEnvironment?) -> PythonExecutionContext? {
        guard let environment else { return nil }
        var variables = environment.variables
        variables["FLOE_PYTHON_PACKAGE_TARGET"] = environment.writableLayerURL.appendingPathComponent("usr/lib/floe-python/site-packages").path
        variables["FLOE_PYTHON_WRITABLE_LAYER"] = environment.writableLayerURL.path
        return .init(environmentID: environment.id, environment: variables)
    }

    /// Builds the installer program that runs inside the managed CPython
    /// process. The private installer phase flag permits pip only for this
    /// exact program; agent scripts remain blocked by the audit hook.
    private static func installerScript(packageJSON: String?, recoverOnly: Bool = false) -> String? {
        guard let url = Bundle.module.url(forResource: "managed_package_install", withExtension: "py"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source + "\n" + """
        import sys
        _target = os.environ.get('FLOE_PYTHON_PACKAGE_TARGET') or next((p for p in sys.path if p.endswith('PythonPackages')), None)
        if not _target:
            raise RuntimeError('Managed package directory is unavailable')
        _layer = os.environ.get('FLOE_PYTHON_WRITABLE_LAYER')
        if _layer and os.path.commonpath([os.path.realpath(_target), os.path.realpath(_layer)]) != os.path.realpath(_layer):
            raise RuntimeError('Managed package directory escapes its environment')
        """ + "\n" + (recoverOnly ? "recover(Path(_target))" : "install(json.loads(\(String(reflecting: packageJSON ?? "[]"))), Path(_target))")
    }

    /// Called before inventory or removal so a process interruption cannot hide the previous generation.
    public func recover(environment: ToolEnvironment) async throws {
        guard let script = Self.installerScript(packageJSON: nil, recoverOnly: true) else {
            throw FloeError.invalidConfiguration("Python recovery resource is unavailable")
        }
        let result = await python.run(.init(script: script, timeout: 30, maxOutputBytes: 4096,
            allowsManagedPackageInstaller: true, pythonContext: Self.executionContext(environment)), cancellation: nil)
        switch result {
        case .ok: return
        case .jsException(let message, _): throw FloeError.validationFailed(message)
        case .timedOut: throw FloeError.validationFailed("Python recovery has not completed; files were retained")
        case .cancelled: throw CancellationError()
        }
    }

    public func install(
        specs: [String],
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken?,
        environment: ToolEnvironment? = nil
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
        guard let script = Self.installerScript(packageJSON: encoded) else {
            return .failed(message: "Managed Python installer resource is unavailable")
        }
        var pythonContext = Self.executionContext(environment)
        do {
            let sources = try environment.map { try LanguagePackageSources.load(in: $0.writableLayerURL) } ?? LanguagePackageSources()
            if pythonContext == nil { pythonContext = .init() }
            pythonContext?.environment["FLOE_PYTHON_INDEX_URL"] = sources.pythonIndex
            pythonContext?.environment["PIP_CONFIG_FILE"] = "/dev/null"
            pythonContext?.environment["PIP_EXTRA_INDEX_URL"] = ""
            pythonContext?.environment["PIP_TRUSTED_HOST"] = ""
        } catch { return .failed(message: error.localizedDescription) }
        let request = ScriptExecutionRequest(
            script: script,
            inputJSON: nil,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            allowsManagedPackageInstaller: true,
            pythonContext: pythonContext
        )
        let outcome = await python.run(request, cancellation: cancellation)
        switch outcome {
        case .ok(_, let stdout, let stderr, _, _, _):
            let verification = await verifyInstalled(specs: uniqueSpecs, environment: environment, cancellation: cancellation)
            await packagesChanged()
            let base = stderr.isEmpty ? stdout : stdout + "\n" + stderr
            return .ok(output: verification.isEmpty ? base : base + "\n" + verification)
        case .jsException(let message, let stdout):
            return .failed(message: message + (stdout.isEmpty ? "" : "\n" + stdout))
        case .timedOut(_, let partialStdout):
            return .timedOut(partialOutput: partialStdout)
        case .cancelled:
            return .cancelled
        }
    }

    /// States which copy actually resolved after an install. A persistent
    /// interpreter with several site-packages roots can otherwise satisfy an
    /// import from a read-only bundled copy while pip reports success for the
    /// writable layer; the line names the exact `__file__` location.
    private func verifyInstalled(specs: [String], environment: ToolEnvironment?, cancellation: CancellationToken?) async -> String {
        struct Payload: Encodable { let names: [String] }
        let names = specs.map { spec -> String in
            spec.split(separator: "=", maxSplits: 1).first.map(String.init) ?? spec
        }
        guard let data = try? JSONEncoder().encode(Payload(names: names)),
              let json = String(data: data, encoding: .utf8) else { return "installVerify=unavailable" }
        let source = """
        import importlib.metadata as _metadata, json as _json, os as _os, re as _re
        _target = _os.environ.get('FLOE_PYTHON_PACKAGE_TARGET') or ''
        _rows = []
        for _name in input['names']:
            _key = _re.sub(r'[-_.]+', '-', _name).lower()
            _match = None
            for _distribution in _metadata.distributions():
                _candidate = _distribution.metadata.get('Name')
                if _candidate and _re.sub(r'[-_.]+', '-', _candidate).lower() == _key:
                    _match = _distribution
                    break
            if _match is None:
                _rows.append({'name': _name, 'version': None, 'location': None, 'writable': False})
                continue
            _location = str(_match.locate_file(''))
            _writable = bool(_target) and _os.path.commonpath([_os.path.realpath(_location), _os.path.realpath(_target)]) == _os.path.realpath(_target)
            _rows.append({'name': _match.metadata['Name'], 'version': _match.version, 'location': _location, 'writable': _writable})
        print('installVerify=' + _json.dumps(_rows, ensure_ascii=False))
        """
        let result = await python.run(.init(script: source, inputJSON: json, timeout: 15, maxOutputBytes: 16 * 1024,
            pythonContext: Self.executionContext(environment)), cancellation: cancellation)
        switch result {
        case .ok(_, let stdout, let stderr, _, _, _):
            if let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix("installVerify=") }) {
                return String(line)
            }
            return "installVerify=unavailable" + (stderr.isEmpty ? "" : " " + String(stderr.prefix(200)))
        case .timedOut:
            return "installVerify=timedOut"
        case .cancelled:
            return "installVerify=cancelled"
        case .jsException(let message, _):
            return "installVerify=unavailable " + String(message.prefix(200))
        }
    }

    /// Package inspection executes fixed source, never a user-supplied pip
    /// module/script. Effective versions follow the resolved Python path order.
    public func inspect(command: String, arguments: [String], environment: ToolEnvironment,
                        cancellation: CancellationToken?) async -> Outcome {
        let source = """
        import importlib.metadata as _metadata, json as _json, re as _re, sys as _sys
        _command, _arguments = input['command'], input['arguments']
        def _name(value): return _re.sub(r'[-_.]+', '-', value).lower()
        _installed = {}
        for _distribution in _metadata.distributions():
            _distribution_name = _distribution.metadata.get('Name')
            if _distribution_name:
                _installed.setdefault(_name(_distribution_name), _distribution)
        if _command in ('help', '--help', '-h'):
            print('pip install NAME[==VERSION] | uninstall NAME | list [--format=json] | show NAME | freeze | check | --version')
            print('Installations use the current environment. Native extensions require compatible bundled builds.')
        elif _command in ('--version', '-V'):
            print('pip ' + _metadata.version('pip') + ' (Floe managed, Python ' + _sys.version.split()[0] + ')')
        elif _command == 'freeze':
            for _key, _distribution in sorted(_installed.items()):
                print(_distribution.metadata['Name'] + '==' + _distribution.version)
        elif _command == 'list':
            _rows = [{'name': d.metadata['Name'], 'version': d.version} for _, d in sorted(_installed.items())]
            if _arguments == ['--format=json']: print(_json.dumps(_rows))
            else:
                for _row in _rows: print(_row['name'] + ' ' + _row['version'])
        elif _command == 'show':
            for _requested in _arguments:
                _distribution = _installed.get(_name(_requested))
                if not _distribution: raise ValueError('Package is not installed: ' + _requested)
                print('Name: ' + _distribution.metadata['Name'])
                print('Version: ' + _distribution.version)
                print('Location: ' + str(_distribution.locate_file('')))
                print('Requires: ' + ', '.join(_distribution.requires or []))
        elif _command == 'check':
            from packaging.requirements import Requirement as _Requirement
            _errors = []
            for _distribution in _installed.values():
                for _text in _distribution.requires or []:
                    _requirement = _Requirement(_text)
                    if _requirement.marker and not _requirement.marker.evaluate({'extra': ''}): continue
                    _dependency = _installed.get(_name(_requirement.name))
                    if not _dependency or (_requirement.specifier and not _requirement.specifier.contains(_dependency.version, prereleases=True)):
                        _errors.append(_distribution.metadata['Name'] + ' requires ' + str(_requirement))
            if _errors: raise ValueError('Dependency conflicts: ' + '; '.join(_errors))
            print('No broken requirements found.')
        else: raise ValueError('Unsupported package inspection')
        """
        struct Payload: Encodable { let command: String; let arguments: [String] }
        let payload = try? JSONEncoder().encode(Payload(command: command, arguments: arguments))
        guard let payload else { return .failed(message: "Invalid inspection arguments") }
        let result = await python.run(.init(script: source, inputJSON: String(decoding: payload, as: UTF8.self),
            timeout: 30, maxOutputBytes: 65_536, pythonContext: Self.executionContext(environment)), cancellation: cancellation)
        switch result {
        case .ok(_, let stdout, let stderr, _, _, _): return .ok(output: stdout + (stderr.isEmpty ? "" : "\n" + stderr))
        case .jsException(let message, _): return .failed(message: message)
        case .timedOut(_, let partial): return .timedOut(partialOutput: partial)
        case .cancelled: return .cancelled
        }
    }

    /// Removes an installed distribution by deleting exactly the files its
    /// RECORD lists, then the dist-info directory. Bundled (read-only)
    /// distributions cannot be removed and report a clear failure.
    public func uninstall(distribution: String, environment: ToolEnvironment? = nil, cancellation: CancellationToken? = nil) async -> Outcome {
        if let environment {
            do { try await recover(environment: environment) }
            catch { return .failed(message: error.localizedDescription) }
        }
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
            allowsManagedPackageInstaller: true,
            pythonContext: Self.executionContext(environment)
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

    /// Distributions visible to the interpreter: bundled site-packages and
    /// the managed mutable root. Bundled entries cannot be uninstalled.
    public func installedDistributions(environment: ToolEnvironment? = nil) async -> [String] {
        let script = """
        import sys, importlib.metadata, re
        _roots = [p for p in sys.path if p.endswith('site-packages') or p.endswith('PythonPackages')]
        _names = {re.sub(r'[-_.]+', '-', d.metadata['Name']).lower()
                  for d in importlib.metadata.distributions(path=_roots) if d.metadata['Name']}
        print('\\n'.join(sorted(_names)))
        """
        let request = ScriptExecutionRequest(script: script, timeout: 10, maxOutputBytes: 64 * 1024, pythonContext: Self.executionContext(environment))
        guard case .ok(_, let stdout, _, _, _, _) = await python.run(request, cancellation: nil) else { return [] }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

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
        let request = ScriptExecutionRequest(
            script: script,
            inputJSON: nil,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
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

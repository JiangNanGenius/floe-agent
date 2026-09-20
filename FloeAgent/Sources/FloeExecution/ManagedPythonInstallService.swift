// FloeExecution — Shared managed Python package installer (Linux guest).
//
// Phase 2 (TinyEMU migration): the bundled in-process CPython and its
// iOS-wheelhouse installer left the app. Every managed Python operation runs
// the environment's guest pip inside the shared venv through
// `LinuxGuestLanguagePackages`, so shell `pip`, `exec.localPython`,
// `python.packages` and the package UI all read the same site-packages, and
// riscv64 Linux wheels install through the guest's normal pip.
//
// An environment not owned by the Linux backend fails with the honest
// "switch to the Linux backend" error; there is no silent host fallback and
// no in-process interpreter anymore. Legacy native installs are preserved
// on disk untouched (see docs/PHASE2_migration.md §3.2).

import Foundation
import FloeCore
import FloeTools

public struct ManagedPythonInstallService: Sendable {
    /// Honest refusal for every non-Linux environment: there is no host
    /// interpreter left to fall back to.
    public static let linuxRequiredMessage = "Python/Node run inside this environment's Linux guest. Select the Linux backend for this environment (or install and start the Linux component) and try again."
    public enum Outcome: Sendable {
        case ok(output: String)
        case failed(message: String)
        case timedOut(partialOutput: String)
        case cancelled
    }

    /// Linux guest package ownership. All operations run inside the guest.
    private let linux: LinuxGuestLanguagePackages?
    private let packagesChanged: @Sendable () async -> Void

    public init(
        linux: LinuxGuestLanguagePackages? = nil,
        packagesChanged: @escaping @Sendable () async -> Void = {}
    ) {
        self.linux = linux
        self.packagesChanged = packagesChanged
    }

    private func linuxOwns(_ environment: ToolEnvironment?) async -> Bool {
        guard let environment, let linux else { return false }
        return await linux.owns(environmentID: environment.id)
    }

    /// True when the selected environment is owned by the Linux backend (its
    /// guest may still be stopped). `exec.localPython` uses this to keep
    /// honest environment wording before the guest is started.
    public func isLinuxGuestEnvironment(_ environment: ToolEnvironment?) async -> Bool {
        await linuxOwns(environment)
    }

    /// Legacy native-layout context values. The guest router rewrites every
    /// host path through the environment's 9p map before anything reaches the
    /// guest, so these stay useful for callers that still build a context.
    public static func executionContext(_ environment: ToolEnvironment?) -> PythonExecutionContext? {
        guard let environment else { return nil }
        var variables = environment.variables
        variables["FLOE_PYTHON_PACKAGE_TARGET"] = environment.writableLayerURL.appendingPathComponent("usr/lib/floe-python/site-packages").path
        variables["FLOE_PYTHON_WRITABLE_LAYER"] = environment.writableLayerURL.path
        return .init(environmentID: environment.id, environment: variables)
    }

    /// The guest's real pip is not a staged host transaction: nothing
    /// host-side needs recovery. A Linux-owned environment whose guest is
    /// stopped reports the honest not-running error.
    public func recover(environment: ToolEnvironment) async throws {
        guard await linuxOwns(environment) else { return }
        guard let linux, await linux.isRunning(environmentID: environment.id) else {
            throw FloeError.validationFailed(LinuxGuestError.notRunning(environmentID: environment.id).localizedDescription)
        }
    }

    private func requiresLinux(_ environment: ToolEnvironment?) async -> Outcome? {
        guard let environment else {
            return .failed(message: Self.linuxRequiredMessage)
        }
        guard await linuxOwns(environment), let linux else {
            return .failed(message: Self.linuxRequiredMessage)
        }
        guard await linux.isRunning(environmentID: environment.id) else {
            return .failed(message: LinuxGuestError.notRunning(environmentID: environment.id).localizedDescription)
        }
        return nil
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
        if let unavailable = await requiresLinux(environment) { return unavailable }
        guard let environment, let linux else {
            return .failed(message: Self.linuxRequiredMessage)
        }
        do {
            let output = try await linux.pythonInstall(
                specs: uniqueSpecs,
                environment: environment,
                timeout: timeout,
                cancellation: cancellation
            )
            let verification = await linux.pythonVerification(specs: uniqueSpecs, environment: environment)
            await packagesChanged()
            let base = output.isEmpty ? "pip install \(uniqueSpecs.joined(separator: " "))" : output
            return .ok(output: base + "\n" + verification)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Fixed inspection commands forwarded to the guest venv's own pip. The
    /// shell parser already restricts the accepted commands and arguments.
    public func inspect(command: String, arguments: [String], environment: ToolEnvironment,
                        cancellation: CancellationToken?) async -> Outcome {
        if let unavailable = await requiresLinux(environment) { return unavailable }
        guard let linux else {
            return .failed(message: Self.linuxRequiredMessage)
        }
        do {
            let output = try await linux.pythonInspect(
                command: command,
                arguments: arguments,
                environment: environment,
                cancellation: cancellation
            )
            return .ok(output: output)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    public func uninstall(distribution: String, environment: ToolEnvironment? = nil, cancellation: CancellationToken? = nil) async -> Outcome {
        if let unavailable = await requiresLinux(environment) { return unavailable }
        guard let environment, let linux else {
            return .failed(message: Self.linuxRequiredMessage)
        }
        do {
            let output = try await linux.pythonUninstall(
                distribution: distribution,
                environment: environment,
                cancellation: cancellation
            )
            await packagesChanged()
            return .ok(output: output)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Distributions the environment's shared guest venv sees. A stopped or
    /// non-Linux environment has no host-side catalog to scan: it reports an
    /// empty list instead of pretending packages exist.
    public func installedDistributions(environment: ToolEnvironment? = nil) async -> [String] {
        guard let environment, let linux, await linux.owns(environmentID: environment.id) else { return [] }
        return await linux.pythonDistributionNames(environment: environment)
    }
}

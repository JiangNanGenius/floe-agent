// FloeExecution — the shared Node.js runtime inside a Linux environment.
//
// A Floe Linux environment uses the guest's own Node distribution and the
// environment's own package prefix. Nothing in this file touches the iOS
// host's bundled nodejs-mobile runtime: the environment-level prefix is
// `/floe/env/usr` (host side `<layer>/usr`), so `usr/lib/node_modules` in the
// environment layer is the one directory the package UI, the shell and
// `exec.localService` resolve — exactly the directory the native managed
// installer uses for native environments.
//
// Provisioning follows the shared Python provisioner's pattern: probe the
// guest, let the guest's own apt install `nodejs`/`npm` when they are missing,
// and report pnpm as available only when the guest actually exposes it. The
// result is cached per environment and invalidated on guest stop/delete, so a
// stale interpreter path is never reused.

import Foundation
import FloeCore
import FloeTools

public struct LinuxGuestNodeEnvironment: Sendable, Equatable {
    /// Guest path of the environment-level package prefix (the layer's `usr`).
    public static let guestPrefix = LinuxGuestMountPoint.environment + "/usr"
    /// Environment-level `node_modules` (host `<layer>/usr/lib/node_modules`).
    public static let guestNodeModules = guestPrefix + "/lib/node_modules"
    /// Environment-level executables installed by the guest's package managers.
    public static let guestBin = guestPrefix + "/bin"
    /// Guest staging/transaction root for managed Node generations.
    public static let guestTransactionRoot = LinuxGuestMountPoint.environment + "/var/floe-node-transaction"
    /// The standard guest PATH every manager/service invocation starts from.
    public static let defaultGuestPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    public var environmentID: String
    public var nodePath: String
    public var npmPath: String
    public var pnpmPath: String?
    public var version: String?
    /// Directory holding the `node` executable, prepended to PATH so a
    /// manager script's `#!/usr/bin/env node` shebang resolves.
    public var pathDirectory: String

    public init(
        environmentID: String,
        nodePath: String,
        npmPath: String,
        pnpmPath: String? = nil,
        version: String? = nil,
        pathDirectory: String? = nil
    ) {
        self.environmentID = environmentID
        self.nodePath = nodePath
        self.npmPath = npmPath
        self.pnpmPath = pnpmPath
        self.version = version
        self.pathDirectory = pathDirectory ?? (nodePath as NSString).deletingLastPathComponent
    }

    /// Shell preamble that makes the environment-level modules and binaries
    /// discoverable to the guest shell (`node`, `npx`, package bins) without
    /// renaming any command. A standard project-local `npm install` still
    /// writes `./node_modules`; only the managed environment install targets
    /// `LinuxGuestNodeEnvironment.guestNodeModules`.
    public static func activationPreamble() -> String {
        let modules = guestNodeModules
        let bin = guestBin
        return """
        export PATH=\(bin):$PATH
        if [ -d \(modules) ]; then
          case ":$NODE_PATH:" in
            *":\(modules):"*) ;;
            *) NODE_PATH="\(modules)${NODE_PATH:+:$NODE_PATH}"; export NODE_PATH ;;
          esac
        fi

        """
    }
}

/// What the guest currently exposes. `runnable` requires both node and npm;
/// pnpm stays optional because not every guest image ships it.
public struct LinuxGuestNodeManagers: Sendable, Equatable {
    public var nodePath: String?
    public var npmPath: String?
    public var pnpmPath: String?
    public var version: String?

    public init(nodePath: String? = nil, npmPath: String? = nil, pnpmPath: String? = nil, version: String? = nil) {
        self.nodePath = nodePath
        self.npmPath = npmPath
        self.pnpmPath = pnpmPath
        self.version = version
    }

    public var runnable: Bool { nodePath != nil && npmPath != nil }
}

public enum LinuxGuestNodeProvisionError: Error, LocalizedError, Sendable, Equatable {
    case guestNotRunning(String)
    case nodeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .guestNotRunning(let detail):
            return "the Linux guest is not running: \(detail)"
        case .nodeUnavailable(let detail):
            return "Node.js is not available in this Linux environment: \(detail)"
        }
    }
}

/// Creates and locates the guest's Node distribution per environment. The
/// actor coalesces concurrent callers (package UI, shell and services can ask
/// at once) so apt runs exactly once; a failed or cancelled attempt is
/// discarded and repaired on the next request.
public actor LinuxGuestNodeProvisioner {
    public static let shared = LinuxGuestNodeProvisioner()

    private var cached: [String: LinuxGuestNodeEnvironment] = [:]
    private var inFlight: [String: Task<LinuxGuestNodeEnvironment, Error>] = [:]
    /// Bumped on forget/stop. A provisioning task that finishes after a stop
    /// must not write its (now stale) result back into the cache.
    private var generations: [String: Int] = [:]

    public init() {}

    public func environment(for environmentID: String) -> LinuxGuestNodeEnvironment? {
        cached[environmentID]
    }

    public func forget(environmentID: String) {
        cached[environmentID] = nil
        generations[environmentID, default: 0] += 1
        inFlight[environmentID]?.cancel()
        inFlight[environmentID] = nil
    }

    public func ensure(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestNodeEnvironment {
        if let cached = cached[environmentID] { return cached }
        if let running = inFlight[environmentID] { return try await running.value }
        guard await runner.supports(environmentID: environmentID) else {
            throw LinuxGuestNodeProvisionError.guestNotRunning(environmentID)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let generation = generations[environmentID] ?? 0
        let task = Task { [weak self] () throws -> LinuxGuestNodeEnvironment in
            guard let self else { throw CancellationError() }
            let environment = try await self.provision(
                environmentID: environmentID,
                runner: runner,
                cancellation: cancellation
            )
            try Task.checkCancellation()
            await self.store(environment, generation: generation)
            return environment
        }
        inFlight[environmentID] = task
        defer {
            if inFlight[environmentID] == task { inFlight[environmentID] = nil }
        }
        return try await task.value
    }

    private func store(_ environment: LinuxGuestNodeEnvironment, generation: Int) {
        guard generations[environment.environmentID] ?? 0 == generation else { return }
        cached[environment.environmentID] = environment
    }

    /// Current guest state without installing anything. Used by the package UI
    /// so it can say honestly whether an environment-level pnpm exists before
    /// a change is attempted.
    public func probe(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken? = nil
    ) async -> LinuxGuestNodeManagers {
        guard await runner.supports(environmentID: environmentID) else { return LinuxGuestNodeManagers() }
        var managers = await Self.probeOnce(environmentID: environmentID, runner: runner, cancellation: cancellation)
        if managers.nodePath != nil {
            managers.version = await Self.nodeVersion(
                path: managers.nodePath ?? "node",
                environmentID: environmentID,
                runner: runner,
                cancellation: cancellation
            )
        }
        return managers
    }

    private func provision(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestNodeEnvironment {
        var managers = await Self.probeOnce(environmentID: environmentID, runner: runner, cancellation: cancellation)
        if !managers.runnable {
            _ = try await aptInstall(
                ["nodejs", "npm"],
                environmentID: environmentID,
                runner: runner,
                cancellation: cancellation
            )
            managers = await Self.probeOnce(environmentID: environmentID, runner: runner, cancellation: cancellation)
        }
        guard let nodePath = managers.nodePath, let npmPath = managers.npmPath else {
            throw LinuxGuestNodeProvisionError.nodeUnavailable(
                "the guest has no node/npm after provisioning; preinstall nodejs and npm in the guest image or configure its APT sources"
            )
        }
        // pnpm is optional and never installed implicitly: only node/npm are
        // required for an npm environment. A guest that already ships pnpm
        // (image or user-installed) exposes it; otherwise an explicit pnpm
        // selection reports the missing manager instead of pulling a second
        // package matrix through apt.
        let version = await Self.nodeVersion(
            path: managers.nodePath ?? nodePath,
            environmentID: environmentID,
            runner: runner,
            cancellation: cancellation
        )
        FloeLogger(category: .tools).info(
            "Linux guest Node environment ready environment=\(environmentID) node=\(version ?? nodePath) pnpm=\(managers.pnpmPath ?? "unavailable")"
        )
        return LinuxGuestNodeEnvironment(
            environmentID: environmentID,
            nodePath: nodePath,
            npmPath: npmPath,
            pnpmPath: managers.pnpmPath,
            version: version,
            pathDirectory: (nodePath as NSString).deletingLastPathComponent
        )
    }

    private static func probeOnce(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async -> LinuxGuestNodeManagers {
        let script = """
        for c in node npm pnpm; do
          p=$(command -v "$c" 2>/dev/null || true)
          printf 'floe-manager %s=%s\\n' "$c" "$p"
        done
        """
        let result = try? await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard let result, result.exitCode == 0 else { return LinuxGuestNodeManagers() }
        var managers = LinuxGuestNodeManagers()
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "floe-manager", let index = parts[1].firstIndex(of: "=") else { continue }
            let name = String(parts[1][..<index])
            let path = String(parts[1][parts[1].index(after: index)...]).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            switch name {
            case "node": managers.nodePath = path
            case "npm": managers.npmPath = path
            case "pnpm": managers.pnpmPath = path
            default: break
            }
        }
        return managers
    }

    private static func nodeVersion(
        path: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async -> String? {
        let result = try? await runner.run(
            environmentID: environmentID,
            argv: [path, "--version"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard let result, result.exitCode == 0 else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private func aptInstall(
        _ packages: [String],
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let update = try await runner.run(
            environmentID: environmentID,
            argv: ["apt-get", "update"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 600,
            maxOutputBytes: 128 * 1024,
            cancellation: cancellation
        )
        guard update.exitCode == 0 else {
            throw LinuxGuestNodeProvisionError.nodeUnavailable(
                "apt-get update exited \(update.exitCode): " + boundedDetail(update.stderr.isEmpty ? update.stdout : update.stderr)
            )
        }
        let install = try await runner.run(
            environmentID: environmentID,
            argv: ["apt-get", "install", "-y", "--no-install-recommends"] + packages,
            workingDirectory: nil,
            standardInput: nil,
            timeout: 900,
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        guard install.exitCode == 0 else {
            throw LinuxGuestNodeProvisionError.nodeUnavailable(
                "apt-get install \(packages.joined(separator: " ")) exited \(install.exitCode): "
                    + boundedDetail(install.stderr.isEmpty ? install.stdout : install.stderr)
            )
        }
        return install
    }

    private func boundedDetail(_ text: String) -> String {
        String(text.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

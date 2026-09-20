// FloeExecution — the shared Python interpreter inside a Linux environment.
//
// A Floe Linux environment has exactly one Python installation: the guest's
// Debian Python with one writable venv inside the environment layer
// (`/floe/env/python/venv`, host side `<layer>/python/venv`). shell commands,
// exec.localPython, the managed pip installer and the package UI all resolve
// that same venv, so a package is downloaded and installed once.
//
// Why a venv at all: Debian marks its system Python as externally managed
// (PEP 668), so `pip install` into the system interpreter is refused. Creating
// the venv is not a "second install": the venv uses `--system-site-packages`
// and lives in the environment's writable layer, and the standard `python3` /
// `pip` command names keep working because every guest command runs through
// the activation snippet below. A missing `python3-venv` is repaired with the
// guest's own apt (the environment has networking) and never by installing
// packages into the system interpreter.

import Foundation
import FloeCore
import FloeTools

public struct LinuxGuestPythonEnvironment: Sendable, Equatable {
    /// Guest path of the environment's one venv.
    public static let guestVenvPath = LinuxGuestMountPoint.environment + "/python/venv"

    public var environmentID: String
    public var venvPath: String
    public var pythonPath: String
    public var pipPath: String
    public var activationPath: String
    /// venv site-packages (the managed pip installer's target directory).
    public var sitePackages: String
    public var version: String?

    public init(
        environmentID: String,
        venvPath: String = LinuxGuestPythonEnvironment.guestVenvPath,
        pythonPath: String? = nil,
        pipPath: String? = nil,
        activationPath: String? = nil,
        sitePackages: String,
        version: String? = nil
    ) {
        self.environmentID = environmentID
        self.venvPath = venvPath
        self.pythonPath = pythonPath ?? venvPath + "/bin/python3"
        self.pipPath = pipPath ?? venvPath + "/bin/pip"
        self.activationPath = activationPath ?? venvPath + "/bin/activate"
        self.sitePackages = sitePackages
        self.version = version
    }

    /// Shell preamble that puts the venv first on PATH. Guarded so it is a
    /// no-op before the first Python use; the command names (`python3`, `pip`)
    /// are unchanged.
    public static func activationPreamble() -> String {
        let activation = guestVenvPath + "/bin/activate"
        return "if [ -f \(activation) ]; then . \(activation); fi\n"
    }

    /// argv that runs `command` with the venv active and the caller's
    /// arguments untouched (`sh -c '...' command arg...` keeps `$@` exact).
    public static func activatedArgv(command: String, arguments: [String]) -> [String] {
        ["/bin/sh", "-c", activationPreamble() + "exec \"$0\" \"$@\"", command] + arguments
    }
}

public enum LinuxGuestPythonProvisionError: Error, LocalizedError, Sendable, Equatable {
    case guestNotRunning(String)
    case pythonUnavailable(String)
    case venvCreationFailed(String)
    case pipUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .guestNotRunning(let detail):
            return "the Linux guest is not running: \(detail)"
        case .pythonUnavailable(let detail):
            return "python3 is not available in this Linux environment: \(detail)"
        case .venvCreationFailed(let detail):
            return "the shared Python environment could not be created: \(detail)"
        case .pipUnavailable(let detail):
            return "the shared Python environment has no pip: \(detail)"
        }
    }
}

/// Creates and locates the one shared Python venv per environment. The actor
/// coalesces concurrent callers per environment (shell, localPython, pip
/// command, package UI and localService can all ask at once) so apt/venv run
/// exactly once; a failed or cancelled attempt is discarded and repaired on
/// the next request. A guest stop/delete or a backend change invalidates the
/// cache, so a stale interpreter path is never reused.
public actor LinuxGuestPythonProvisioner {
    public static let shared = LinuxGuestPythonProvisioner()

    private var cached: [String: LinuxGuestPythonEnvironment] = [:]
    private var inFlight: [String: Task<LinuxGuestPythonEnvironment, Error>] = [:]
    /// Bumped on forget/stop so a provisioning task that finishes after the
    /// guest stopped can never write its stale result back into the cache.
    private var generations: [String: Int] = [:]

    public init() {}

    public func environment(for environmentID: String) -> LinuxGuestPythonEnvironment? {
        cached[environmentID]
    }

    public func forget(environmentID: String) {
        cached[environmentID] = nil
        generations[environmentID, default: 0] += 1
        inFlight[environmentID]?.cancel()
        inFlight[environmentID] = nil
    }

    /// Returns the shared interpreter, creating the venv on first use. At most
    /// one provisioning task per environment runs at a time.
    public func ensure(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken? = nil
    ) async throws -> LinuxGuestPythonEnvironment {
        if let cached = cached[environmentID] { return cached }
        if let running = inFlight[environmentID] { return try await running.value }
        guard await runner.supports(environmentID: environmentID) else {
            throw LinuxGuestPythonProvisionError.guestNotRunning(environmentID)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let generation = generations[environmentID] ?? 0
        let task = Task { [weak self] () throws -> LinuxGuestPythonEnvironment in
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
            // The creator clears the slot; a failed task must not be reused,
            // so the next caller provisions afresh.
            if inFlight[environmentID] == task { inFlight[environmentID] = nil }
        }
        return try await task.value
    }

    private func store(_ environment: LinuxGuestPythonEnvironment, generation: Int) {
        guard generations[environment.environmentID] ?? 0 == generation else { return }
        cached[environment.environmentID] = environment
    }

    private func provision(
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestPythonEnvironment {
        let venv = LinuxGuestPythonEnvironment.guestVenvPath
        // 1. An existing venv is reused as-is; its site-packages are read from
        //    the interpreter itself instead of guessing the python version.
        //    pip is still checked and repaired: a half-created venv from an
        //    interrupted run must not stay broken forever.
        if let site = await sitePackages(venvPython: venv + "/bin/python3", environmentID: environmentID, runner: runner, cancellation: cancellation) {
            try await ensurePip(venv: venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
            let version = await pythonVersion(path: venv + "/bin/python3", environmentID: environmentID, runner: runner, cancellation: cancellation)
            return LinuxGuestPythonEnvironment(environmentID: environmentID, sitePackages: site, version: version)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }

        // 2. Make sure the distro Python and its venv module exist. apt is the
        //    guest's own package manager and the environment has networking.
        let probe = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", "command -v python3 >/dev/null 2>&1 && echo python-ok || echo python-missing"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        if !probe.stdout.contains("python-ok") {
            _ = try await aptInstall(
                ["python3", "python3-venv", "python3-pip"],
                environmentID: environmentID,
                runner: runner,
                cancellation: cancellation
            )
        }

        // 3. Create the environment's one venv in the writable layer. If the
        //    venv module is missing, repair it with apt once and retry.
        var creation = try await createVenv(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        if creation.exitCode != 0 {
            _ = try? await aptInstall(["python3-venv", "python3-pip"], environmentID: environmentID, runner: runner, cancellation: cancellation)
            creation = try await createVenv(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }
        guard creation.exitCode == 0 else {
            throw LinuxGuestPythonProvisionError.venvCreationFailed(
                "python3 -m venv \(venv) exited \(creation.exitCode): " + boundedDetail(creation.stderr.isEmpty ? creation.stdout : creation.stderr)
            )
        }

        guard let site = await sitePackages(venvPython: venv + "/bin/python3", environmentID: environmentID, runner: runner, cancellation: cancellation) else {
            throw LinuxGuestPythonProvisionError.venvCreationFailed("the new venv has no python3 at \(venv)/bin/python3")
        }

        // 4. pip is required for the managed installer and the pip shell
        //    command; ensurepip runs inside the venv only.
        try await ensurePip(venv: venv, environmentID: environmentID, runner: runner, cancellation: cancellation)

        let version = await pythonVersion(path: venv + "/bin/python3", environmentID: environmentID, runner: runner, cancellation: cancellation)
        FloeLogger(category: .tools).info(
            "Linux guest Python environment ready environment=\(environmentID) venv=\(venv) version=\(version ?? "unknown")"
        )
        return LinuxGuestPythonEnvironment(environmentID: environmentID, sitePackages: site, version: version)
    }

    /// Ensures `<venv>/bin/pip` exists; repaired with the venv's own
    /// ensurepip, never by installing into the system interpreter.
    private func ensurePip(
        venv: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws {
        let probe = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", "test -x " + venv + "/bin/pip && echo pip-ok || echo pip-missing"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        if probe.stdout.contains("pip-ok") { return }
        let repair = try await runner.run(
            environmentID: environmentID,
            argv: [venv + "/bin/python3", "-m", "ensurepip", "--upgrade"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 300,
            maxOutputBytes: 64 * 1024,
            cancellation: cancellation
        )
        guard repair.exitCode == 0 else {
            throw LinuxGuestPythonProvisionError.pipUnavailable(
                "ensurepip exited \(repair.exitCode): " + boundedDetail(repair.stderr.isEmpty ? repair.stdout : repair.stderr)
            )
        }
    }

    private func createVenv(
        _ venv: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        try await runner.run(
            environmentID: environmentID,
            argv: ["python3", "-m", "venv", "--system-site-packages", venv],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 300,
            maxOutputBytes: 64 * 1024,
            cancellation: cancellation
        )
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
            throw LinuxGuestPythonProvisionError.pythonUnavailable(
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
            throw LinuxGuestPythonProvisionError.pythonUnavailable(
                "apt-get install \(packages.joined(separator: " ")) exited \(install.exitCode): " + boundedDetail(install.stderr.isEmpty ? install.stdout : install.stderr)
            )
        }
        return install
    }

    private func sitePackages(
        venvPython: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async -> String? {
        let result = try? await runner.run(
            environmentID: environmentID,
            argv: [venvPython, "-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard let result, result.exitCode == 0 else { return nil }
        let path = result.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private func pythonVersion(
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
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boundedDetail(_ text: String) -> String {
        String(text.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

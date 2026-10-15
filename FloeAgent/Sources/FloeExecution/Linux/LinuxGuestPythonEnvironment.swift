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
//
// First-use cost: `python3 -m venv --system-site-packages` boots pip through
// ensurepip, which is expensive under the TinyEMU interpreter (measured in
// the pinned image inside a real guest: 143.6 s on an Apple M5 Pro host and
// 255-259 s in the on-device run that motivated this). A fresh environment is
// therefore created without ensurepip in a private staging directory, the
// distro pip that `--system-site-packages` already exposes is wired in with a
// tiny venv-local `bin/pip` wrapper plus its standard `pip3` /
// `pip<major>.<minor>`-style aliases (`pip3.13` on this image's Python 3.13:
// the venv convention is `pip` + major + `.` + minor), so every usual
// entrypoint resolves to THIS venv instead of falling through to the PEP 668
// system pip), the copied activation scripts are rewritten from the staging
// path to the final one, the interpreter is validated (runs, same version as
// the distro `python3`, its site-packages live under the final path) and the
// directory is promoted with one atomic rename. Measured end to end: 0.6 s (host number, not a
// device claim). Any miss falls back to the historical ensurepip command,
// which also repairs an existing half-created venv in place; ensurePip below
// still runs the venv's own ensurepip when even the wrapper is missing.

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
        var creation = try await provisionVenv(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        if creation.exitCode != 0 {
            _ = try? await aptInstall(["python3-venv", "python3-pip"], environmentID: environmentID, runner: runner, cancellation: cancellation)
            creation = try await provisionVenv(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
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

    /// Creates the venv with the cheapest safe path and returns the creation
    /// result (the caller keeps the existing apt-repair retry and error
    /// handling). An existing venv directory — normally a half-created one
    /// from an interrupted attempt — keeps the historical in-place repair so
    /// whatever its `lib/` already holds is never discarded; a missing one
    /// takes the fast staging/validate/rename path.
    private func provisionVenv(
        _ venv: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let probe = try? await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", "test -d " + venv + " && echo venv-dir-present || echo venv-dir-absent"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        if let probe, probe.exitCode == 0, probe.stdout.contains("venv-dir-present") {
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }
        return try await createVenvFast(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
    }

    /// Fast path: `--without-pip` venv in a private staging directory, the
    /// distro pip exposed through a venv-local wrapper, activation scripts
    /// rewritten to the final path, interpreter/site-packages validation,
    /// then one atomic rename onto the final path. Any miss removes every
    /// private artifact and falls back to the in-place command, so an
    /// interrupted fast attempt can never be mistaken for a live venv.
    /// (`/floe/env` is this environment's writable layer: staging and the
    /// final venv stay inside it, never in the shared image, and no other
    /// environment can see either.)
    private func createVenvFast(
        _ venv: String,
        environmentID: String,
        runner: any LinuxCommandRunning,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let staging = LinuxGuestMountPoint.environment + "/python/.venv-staging"

        func removeStaging() async {
            _ = try? await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c", "rm -rf " + staging],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 60,
                maxOutputBytes: 4096,
                cancellation: cancellation
            )
        }
        // A staging directory from an interrupted attempt is never promoted:
        // it is private to this actor and removed before every attempt.
        await removeStaging()
        let create = try await runner.run(
            environmentID: environmentID,
            argv: ["python3", "-m", "venv", "--system-site-packages", "--without-pip", staging],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 300,
            maxOutputBytes: 64 * 1024,
            cancellation: cancellation
        )
        guard create.exitCode == 0 else {
            await removeStaging()
            return create
        }

        // The new interpreter must run and match the distro interpreter, and
        // the distro pip must be importable through --system-site-packages.
        let probe = try? await runner.run(
            environmentID: environmentID,
            argv: [staging + "/bin/python3", "-c",
                   "import sys, sysconfig, pip; print(sys.version.split()[0]); print(sysconfig.get_paths()['purelib'])"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 8192,
            cancellation: cancellation
        )
        let distro = try? await runner.run(
            environmentID: environmentID,
            argv: ["python3", "-c", "import sys; print(sys.version.split()[0])"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 30,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        let distroVersion = distro?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let probe, probe.exitCode == 0,
              let distro, distro.exitCode == 0, !distroVersion.isEmpty,
              probe.stdout.contains(distroVersion) else {
            await removeStaging()
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }

        // Relocatable wrapper: it resolves its own directory at run time, so
        // it stays correct through the rename and through the layer mount.
        let wrapper = "#!/bin/sh\nexec \"$(dirname \"$0\")/python3\" -m pip \"$@\"\n"
        let write = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c",
                   "printf '%s' '" + wrapper + "' > " + staging + "/bin/pip && chmod 755 " + staging + "/bin/pip"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard write.exitCode == 0 else {
            await removeStaging()
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }

        // Standard venv entrypoints: `pip`, `pip3` and the versioned alias
        // (`pip<major>.<minor>`, i.e. `pip3.13` on this image's Python 3.13)
        // must all resolve to the VENV interpreter. A missing `pip3` alias
        // would let an activated `pip3` fall through to `/usr/bin/pip3` and
        // hit its PEP 668 refusal while `pip` worked, so an alias failure
        // takes the historical in-place fallback (which creates every
        // entrypoint through ensurepip) exactly like the other steps.
        let aliasWrite = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c",
                   "cp " + staging + "/bin/pip " + staging + "/bin/pip3 && "
                   + "alias=$(" + staging + "/bin/python3 -c \"import sys; print('pip%d.%d' % sys.version_info[:2])\") && "
                   + "cp " + staging + "/bin/pip \"" + staging + "/bin/$alias\" && echo venv-pip-aliases"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard aliasWrite.exitCode == 0 else {
            await removeStaging()
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }

        // Activation scripts are generated at creation time with the staging
        // path baked in (`VIRTUAL_ENV=<staging>`); rewrite them to the final
        // path BEFORE the rename, so every later `activationPreamble()` puts
        // the real venv on PATH and the standard `python3`/`pip` names keep
        // resolving to this environment (a stale path would fall through to
        // the system interpreter and its PEP 668 refusal).
        let rewrite = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c",
                   "for f in " + staging + "/bin/activate " + staging + "/bin/activate.csh " + staging + "/bin/activate.fish; do "
                   + "[ -f \"$f\" ] && sed -i 's|" + staging + "|" + venv + "|g' \"$f\"; done; "
                   + "grep -q '" + venv + "' " + staging + "/bin/activate && "
                   + "sed -i 's|" + staging + "|" + venv + "|g' " + staging + "/pyvenv.cfg && "
                   + "echo venv-rewritten"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 8192,
            cancellation: cancellation
        )
        guard rewrite.exitCode == 0 else {
            await removeStaging()
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }

        // One atomic rename promotes the validated venv; `-T` refuses to nest
        // the staging directory if something appeared at the final path.
        let promote = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", "mv -T " + staging + " " + venv + " && echo venv-promoted"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard promote.exitCode == 0 else {
            await removeStaging()
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }

        // Post-promotion validation: the interpreter and its site-packages
        // must now live under the final path. A promoted venv that does not
        // validate is removed so the caller's retry cannot reuse it.
        let validate = try? await runner.run(
            environmentID: environmentID,
            argv: [venv + "/bin/python3", "-c",
                   "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 4096,
            cancellation: cancellation
        )
        guard let validate, validate.exitCode == 0, validate.stdout.contains(venv) else {
            _ = try? await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c", "rm -rf " + venv],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 60,
                maxOutputBytes: 4096,
                cancellation: cancellation
            )
            return try await createVenvInPlace(venv, environmentID: environmentID, runner: runner, cancellation: cancellation)
        }
        return promote
    }

    /// Historical creation command: runs in place, so it completes/repairs a
    /// venv directory that already exists (including one left by an
    /// interrupted run). ensurepip runs here unless the fast path wired the
    /// wrapper; ensurePip still repairs a missing `bin/pip` afterwards.
    private func createVenvInPlace(
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

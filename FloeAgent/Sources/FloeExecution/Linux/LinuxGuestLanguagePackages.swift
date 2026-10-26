// FloeExecution — package ownership for Linux environments.
//
// An environment whose `executionBackend` is `linuxVM` owns its language
// packages inside the guest, never on the iOS host:
//
//  - Python is the single shared venv at `/floe/env/python/venv` created by
//    `LinuxGuestPythonProvisioner`; installs/uninstalls/inspection run the
//    venv's real `python3 -m pip` in the guest with the environment's
//    configured index, so riscv64 wheels are allowed (the iOS wheelhouse
//    restriction belongs to the native CPython path only) and the shell,
//    `exec.localPython`, `python.packages` and the package UI all read back
//    the same site-packages.
//  - Node runs the guest's real npm/pnpm against the environment prefix
//    `/floe/env/usr` with the same staged, recoverable generation the native
//    managed installer uses (`var/floe-node-transaction` inside the layer),
//    producing `/floe/env/usr/lib/node_modules`. The iOS nodejs-mobile runtime
//    is never involved for a Linux environment.
//
// An environment owned by the Linux backend but with its guest stopped fails
// with the honest "start the Linux environment" error; it never falls back to
// host-side layer writes or the host Node runtime. Native environments never
// resolve here.

import Foundation
import FloeCore
import FloeTools

/// One Python distribution visible to the shared venv interpreter.
public struct LinuxGuestPythonDistribution: Sendable, Equatable {
    public var name: String
    public var version: String
    public var location: String
    /// True when the distribution lives in the environment's venv
    /// site-packages (the writable managed target), false for a system
    /// (guest image) distribution that is only visible through
    /// `--system-site-packages`.
    public var writable: Bool

    public init(name: String, version: String, location: String, writable: Bool) {
        self.name = name
        self.version = version
        self.location = location
        self.writable = writable
    }
}

/// One environment-level Node package read from the layer's
/// `usr/lib/node_modules` inside the guest.
public struct LinuxGuestNodePackage: Sendable, Equatable {
    public var name: String
    public var version: String
    public var path: String

    public init(name: String, version: String, path: String) {
        self.name = name
        self.version = version
        self.path = path
    }
}

/// Python/Node package operations for one injected Linux guest runner.
public struct LinuxGuestLanguagePackages: Sendable {
    /// Guest-side pip cache, kept inside the environment layer so a package is
    /// downloaded once and survives a guest restart. One path with the runner
    /// default (see LinuxGuestWritablePaths).
    public static let pythonCacheDirectory = LinuxGuestWritablePaths.pipCache
    /// Guest-side npm/pnpm caches and the Node transaction root.
    public static let nodeTransactionRoot = LinuxGuestNodeEnvironment.guestTransactionRoot

    /// App-wide shared download cache root, exported by the host as the
    /// optional `floe-cache` 9p share and mounted at `/floe/cache`. It holds
    /// only re-downloadable objects (pip wheels, npm tarballs); a package is
    /// downloaded once and reused across environments. It is used only after
    /// the guest itself reports a real mount, never assumed from a path.
    public static let sharedCacheRoot = "/floe/cache"

    private let runner: any LinuxCommandRunning

    public init(runner: any LinuxCommandRunning) {
        self.runner = runner
    }

    /// Resolves which guest cache directory an install must use. When the
    /// host exported the shared cache share and the running guest actually
    /// mounted it (`/proc/mounts`), the shared path wins; otherwise the
    /// per-environment layer cache stays in effect. This mirrors the runner
    /// PID-1 decision in `floe_exec.c`, so direct shell installs and managed
    /// installs cannot disagree about where downloads live.
    private func cacheDirectory(kind: String, environmentFallback: String,
                                environmentID: String, cancellation: CancellationToken?) async -> String {
        let shared = Self.sharedCacheRoot + "/" + kind
        guard await isSharedCacheMounted(environmentID: environmentID, cancellation: cancellation) else {
            return environmentFallback
        }
        return shared
    }

    /// One bounded read of /proc/mounts per decision. A failing or absent
    /// guest answers false (per-environment fallback), never an error that
    /// blocks an unrelated package operation. The mount point is the SECOND
    /// whitespace-separated field of a /proc/mounts row; the check compares
    /// that field exactly (awk's default splitting tolerates any single or
    /// repeated spaces/tabs), so an older guest without the share keeps its
    /// honest per-environment fallback instead of a literal that can never
    /// match. No guest is ever restarted for this decision.
    private func isSharedCacheMounted(environmentID: String, cancellation: CancellationToken?) async -> Bool {
        let result: LinuxCommandResult
        do {
            result = try await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c",
                       #"awk '$2=="/floe/cache"{found=1} END{exit found?0:1}' /proc/mounts && mkdir -p /floe/cache/pip /floe/cache/npm /floe/cache/xdg"#],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 15,
                maxOutputBytes: 1024,
                cancellation: cancellation
            )
        } catch {
            return false
        }
        return result.exitCode == 0
    }

    // MARK: - Ownership

    public func owns(environmentID: String) async -> Bool {
        await runner.ownsLinuxEnvironment(environmentID: environmentID)
    }

    public func isRunning(environmentID: String) async -> Bool {
        await runner.supports(environmentID: environmentID)
    }

    /// The second race-safe gate: a command must never reach a stopped guest.
    private func requireRunning(_ environmentID: String) async throws {
        guard await runner.ownsLinuxEnvironment(environmentID: environmentID) else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        guard await runner.supports(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
    }

    // MARK: - Python (real pip inside the shared venv)

    /// - Parameters:
    ///   - deadline: explicit execution deadline from the calling run. When
    ///     present it REPLACES the legacy bounded install budget (no hidden
    ///     command deadline remains on the default-unlimited exec.shell
    ///     packages path); `nil` keeps the historical bounded budget for the
    ///     package-UI and provisioning callers, which are separate confirmed
    ///     flows with their own progress/cancel UX.
    /// - Parameter findLinksGuestPath: optional ALREADY-MAPPED guest path of
    ///   the official dependency wheel store (a reviewed directory inside the
    ///   shared cache export). When provided, pip additionally consults those
    ///   verified local wheel files through `--find-links` before falling back
    ///   to the configured index; the exact pin and every other argument are
    ///   unchanged, and `nil` keeps the command byte-for-byte what it is
    ///   today. The store is an optimization only: a damaged or missing local
    ///   wheel never blocks the index path and never weakens the audit.
    /// - Parameter hashesBySpec: signed-lock sha256 pins keyed by the exact
    ///   `name==version` spec. When this map is non-empty EVERY spec must
    ///   carry at least one canonical lowercase sha256 and pip runs in its own
    ///   `--require-hashes` mode, refusing a silent different artifact at the
    ///   digest level — verified bytes, not just a version readback. pip only
    ///   accepts `--hash` INSIDE a requirements file (a CLI `--hash` is
    ///   rejected with exit 2 "no such option"), so each requirement line is
    ///   fed through the runner's standardInput to a pin-free guest wrapper
    ///   that materializes it as an owned temporary requirements file and
    ///   runs the venv's own pip with `--require-hashes` and `--requirement`
    ///   pointed at that real path; `/dev/stdin` is never assumed — the actual pinned guest
    ///   has no such path (2026-10-27 real-guest regression). The pins never
    ///   enter any argv. An empty map keeps the command byte-for-byte what
    ///   it is today with no stdin. A malformed digest, an unpinned or
    ///   injection-shaped spec, a duplicate project, an oversized pin set or
    ///   a contradictory pin map fails closed BEFORE any guest command (even
    ///   the readiness probe) is issued.
    public func pythonInstall(
        specs: [String],
        environment: ToolEnvironment,
        timeout: TimeInterval = 180,
        deadline: ShellExecutionDeadline? = nil,
        findLinksGuestPath: String? = nil,
        hashesBySpec: [String: [String]] = [:],
        cancellation: CancellationToken?
    ) async throws -> String {
        // Signed-lock hash mode is validated FIRST, before this call touches
        // the guest at all: pip's own grammar accepts `--hash` only inside a
        // requirements file, so every requirement-plus-pins line travels as
        // the runner's standardInput to the pin-free wrapper program below,
        // which materializes it inside the guest as an owned temporary
        // requirements file and runs the venv's own pip against that real
        // path. Identities are exact
        // `name==version` pins or the request fails closed — options,
        // whitespace, newlines, duplicate projects, oversized pin sets and
        // contradictory pin maps never reach the guest. With an empty pin map
        // the command below is byte-for-byte the plain one and stdin stays
        // nil, exactly as before hash mode existed.
        func isCanonicalSHA256(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            }
        }
        func exactPinSpec(_ value: String) -> Bool {
            // No whitespace/newline anywhere: NSRegularExpression's `$` also
            // matches just before a trailing line break, so the anchored
            // pattern alone could let "demo==1.0\n" through and smuggle a
            // second requirements line onto stdin.
            guard !value.isEmpty,
                  value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
            return value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9,._+-]+\])?==[A-Za-z0-9][A-Za-z0-9.+!_-]*$"#,
                options: .regularExpression) != nil
        }
        func projectName(_ value: String) -> String {
            let head = value.components(separatedBy: "==").first ?? value
            return (head.split(separator: "[", maxSplits: 1).first.map { String($0).lowercased() } ?? head.lowercased())
                .replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
        }
        let requireHashesMode = !hashesBySpec.isEmpty
        var requirementsInput: String? = nil
        if requireHashesMode {
            guard hashesBySpec.keys.allSatisfy({ specs.contains($0) }),
                  specs.allSatisfy({ !(hashesBySpec[$0] ?? []).isEmpty }) else {
                throw FloeError.validationFailed("hash mode requires a sha256 pin for every spec installed in one command")
            }
            guard specs.allSatisfy(exactPinSpec) else {
                throw FloeError.validationFailed("the pip hash-mode requirement must be an exact name==version pin; options, whitespace and newlines are rejected")
            }
            let names = specs.map(projectName)
            guard Set(names).count == names.count else {
                throw FloeError.validationFailed("hash mode refuses two requirements for the same project in one command")
            }
            var lines: [String] = []
            var totalBytes = 0
            for spec in specs {
                let digests = hashesBySpec[spec] ?? []
                guard digests.count <= 16 else {
                    throw FloeError.validationFailed("the pip hash pin set for \(spec) exceeds the 16-digest bound")
                }
                var line = spec
                for digest in digests {
                    guard isCanonicalSHA256(digest) else {
                        throw FloeError.validationFailed("the pip hash pin for \(spec) is not a canonical lowercase sha256 digest")
                    }
                    line += " --hash=sha256:" + digest
                }
                totalBytes += line.utf8.count + 1
                lines.append(line)
            }
            guard totalBytes <= 32 * 1024 else {
                throw FloeError.validationFailed("the pip hash-mode requirements input exceeds the 32768-byte bound")
            }
            requirementsInput = lines.joined(separator: "\n") + "\n"
        }
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let sources = try LanguagePackageSources.load(in: environment.writableLayerURL)
        let pipCache = await cacheDirectory(
            kind: "pip",
            environmentFallback: Self.pythonCacheDirectory,
            environmentID: environment.id,
            cancellation: cancellation
        )
        let variables: [String: String] = [
            "VIRTUAL_ENV": venv.venvPath,
            "PATH": venv.venvPath + "/bin:" + LinuxGuestNodeEnvironment.defaultGuestPath,
            "PYTHONUNBUFFERED": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_INPUT": "1",
            "PIP_CACHE_DIR": pipCache,
            // The user's explicit source configuration wins over any guest
            // pip configuration file; the iOS wheelhouse index never applies
            // to a Linux guest.
            "PIP_INDEX_URL": sources.pythonIndex,
            "PIP_EXTRA_INDEX_URL": "",
            "PIP_TRUSTED_HOST": ""
        ]
        let findLinks: [String] = {
            guard let findLinksGuestPath,
                  findLinksGuestPath.hasPrefix("/"), findLinksGuestPath.utf8.count <= 512,
                  !findLinksGuestPath.contains(".."), findLinksGuestPath.range(
                      of: #"^[A-Za-z0-9/._+-]+$"#, options: .regularExpression) != nil
            else { return [] }
            return ["--find-links", findLinksGuestPath]
        }()
        // The (already fully validated) hash-mode transport. The real pinned
        // guest has NO `/dev/stdin` symlink (2026-10-27 regression: pip exit 1
        // "Could not open requirements file: [Errno 2] No such file or
        // directory: '/dev/stdin'"), and pip opens requirements only by real
        // filesystem path, so the requirements bytes go to the runner's
        // standardInput and a fixed, pin-free wrapper program (passed with
        // `-c`, never containing a spec or a digest) reads fd 0, materializes
        // the payload as an owned 0600 temporary requirements file inside the
        // guest and runs THIS interpreter's own pip with
        // `--require-hashes --requirement <that real path>` — the identical
        // pip grammar, with the pins in no argv — propagating pip's exit code
        // and removing the file in finally, including under cancellation.
        // The no-hash command stays byte-for-byte the plain one.
        let pipProgram: [String]
        if requireHashesMode {
            pipProgram = [venv.pythonPath, "-c", Self.pythonHashTransportSource(findLinks: findLinks)]
        } else {
            pipProgram = [venv.pythonPath, "-m", "pip", "install",
                          "--disable-pip-version-check", "--no-input"] + findLinks + specs
        }
        let argv = ["/usr/bin/env"] + (LinuxGuestEnvironmentEncoding.argv(variables) ?? []) + pipProgram
        let result: LinuxCommandResult
        if let deadline {
            result = try await runner.run(
                environmentID: environment.id,
                argv: argv,
                workingDirectory: nil,
                standardInput: requirementsInput,
                deadline: deadline,
                maxOutputBytes: 256 * 1024,
                cancellation: cancellation
            )
        } else {
            let effectiveTimeout = min(600, max(timeout, 120))
            result = try await runner.run(
                environmentID: environment.id,
                argv: argv,
                workingDirectory: nil,
                standardInput: requirementsInput,
                timeout: effectiveTimeout,
                maxOutputBytes: 256 * 1024,
                cancellation: cancellation
            )
        }
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.pip_exit_code", result.exitCode) + bounded(output))
        }
        return output
    }

    /// The deterministic, pin-free guest-side transport program for pip
    /// hash mode. It is passed to the venv interpreter with `-c`; the
    /// requirement-plus-pins payload arrives separately on the runner's
    /// standardInput (fd 0) as exactly the bytes `pythonInstall` validated.
    /// The program re-checks that payload shape fail-closed (newline-
    /// terminated stream, every line still carrying its ` --hash=sha256:`
    /// pin — a broken transport can never silently install less than the
    /// signed closure), materializes it as an owned temporary file
    /// (`mkdtemp` 0700 + `O_CREAT|O_EXCL` 0600, fsynced) inside the guest,
    /// invokes pip with the identical grammar (`-m pip install
    /// --disable-pip-version-check --no-input --require-hashes
    /// [--find-links …] --requirement <real path>`) through the SAME
    /// interpreter (`sys.executable`), propagates pip's exit code, and
    /// deletes the file in `finally` — including when SIGINT/SIGTERM cancel
    /// the run. No `/dev/stdin` path and no spec or digest material ever
    /// appear in any argv; a payload that fails re-check exits 2 with the
    /// `floe-pip-hash-transport:` marker instead of reaching pip.
    /// `findLinks` is either empty or exactly the already-charset-validated
    /// `["--find-links", <guest path>]` (no quote, backslash or whitespace
    /// is possible), so the embedded Python literal needs no other surface.
    static func pythonHashTransportSource(findLinks: [String]) -> String {
        precondition(findLinks.isEmpty
                     || (findLinks.count == 2 && findLinks.first == "--find-links"))
        let findLinksLiteral = findLinks.isEmpty
            ? "[]"
            : "[\"--find-links\", \"\(findLinks[1])\"]"
        return """
        import os
        import signal
        import subprocess
        import sys
        import tempfile

        MARKER = "floe-pip-hash-transport"
        FIND_LINKS = \(findLinksLiteral)

        def refuse(reason):
            sys.stderr.write(MARKER + ": " + reason + "\\n")
            sys.stderr.flush()
            raise SystemExit(2)

        payload = sys.stdin.buffer.read()
        if not payload.strip():
            refuse("empty requirements payload")
        if not payload.endswith(b"\\n"):
            refuse("requirements payload is not newline terminated")
        lines = payload.split(b"\\n")[:-1]
        if not lines:
            refuse("requirements payload has no line")
        for line in lines:
            if b" --hash=sha256:" not in line:
                refuse("a requirements line lost its sha256 pin")

        directory = tempfile.mkdtemp(prefix="floe-pip-req-")
        path = os.path.join(directory, "requirements.txt")

        def cleanup():
            try:
                os.remove(path)
            except OSError:
                pass
            try:
                os.rmdir(directory)
            except OSError:
                pass

        def interrupt(signum, frame):
            raise SystemExit(128 + signum)

        for number in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(number, interrupt)
            except (OSError, ValueError):
                pass

        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            completed = subprocess.run([sys.executable, "-m", "pip", "install",
                                       "--disable-pip-version-check", "--no-input",
                                       "--require-hashes"] + FIND_LINKS
                                      + ["--requirement", path],
                                      stdin=subprocess.DEVNULL)
            raise SystemExit(completed.returncode)
        finally:
            cleanup()

        """
    }

    public func pythonUninstall(
        distribution: String,
        environment: ToolEnvironment,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken?
    ) async throws -> String {
        guard distribution.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.pip_uninstall_accepts_only_a_single"))
        }
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pipPath, "uninstall", "-y", distribution],
            workingDirectory: nil,
            standardInput: nil,
            timeout: min(600, max(timeout, 120)),
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.pip_uninstall_exit_code", result.exitCode) + bounded(output))
        }
        return output
    }

    /// Fixed inspection commands forwarded to the venv's own pip. The shell
    /// parser already restricts the accepted commands and arguments.
    public func pythonInspect(
        command: String,
        arguments: [String],
        environment: ToolEnvironment,
        timeout: TimeInterval = 60,
        cancellation: CancellationToken?
    ) async throws -> String {
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pythonPath, "-m", "pip", command] + arguments,
            workingDirectory: nil,
            standardInput: nil,
            timeout: min(600, max(timeout, 30)),
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        let output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.pip_exit_code_2", command, result.exitCode) + bounded(output))
        }
        return output
    }

    /// Distributions the shared venv sees, read back through the venv
    /// interpreter itself (never by scanning host directories).
    public func pythonInventory(
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> [LinuxGuestPythonDistribution] {
        try await requireRunning(environment.id)
        let venv = try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let result = try await runner.run(
            environmentID: environment.id,
            argv: [venv.pythonPath, "-c", Self.pythonInventoryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.failed_to_read_python_dependencies") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("floePythonInventory=") }) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.reading_python_dependencies_returned_no_manifest"))
        }
        let json = String(line.dropFirst("floePythonInventory=".count))
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.the_python_dependency_manifest_cannot_be"))
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return LinuxGuestPythonDistribution(
                name: name,
                version: row["version"] as? String ?? "",
                location: row["location"] as? String ?? "",
                writable: row["writable"] as? Bool ?? false
            )
        }
    }

    /// Names only, for the capability installer's installed-entry readback.
    public func pythonDistributionNames(environment: ToolEnvironment) async -> [String] {
        guard let rows = try? await pythonInventory(environment: environment, cancellation: nil) else { return [] }
        return rows.map(\.name)
    }

    /// Post-install verification line, resolved by the venv interpreter.
    public func pythonVerification(
        specs: [String],
        environment: ToolEnvironment
    ) async -> String {
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
        }
        let names = specs.map { spec -> String in
            spec.split(separator: "=", maxSplits: 1).first.map(String.init) ?? spec
        }
        guard let rows = try? await pythonInventory(environment: environment, cancellation: nil) else {
            return "installVerify=unavailable"
        }
        let wanted = Set(names.map(normalized))
        let matches = rows.filter { wanted.contains(normalized($0.name)) }
        let payload = matches.map { ["name": $0.name, "version": $0.version, "location": $0.location, "writable": $0.writable] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "installVerify=unavailable" }
        return "installVerify=" + json
    }

    // MARK: - Node (real npm/pnpm inside the guest)

    /// Current guest managers without installing anything. Used by the package
    /// UI's manager selection.
    public func nodeManagers(environmentID: String, cancellation: CancellationToken?) async -> LinuxGuestNodeManagers {
        await LinuxGuestNodeProvisioner.shared.probe(
            environmentID: environmentID,
            runner: runner,
            cancellation: cancellation
        )
    }

    /// Environment-level packages under `/floe/env/usr/lib/node_modules`.
    public func nodeInventory(
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> [LinuxGuestNodePackage] {
        try await requireRunning(environment.id)
        let result = try await runner.run(
            environmentID: environment.id,
            argv: ["/bin/sh", "-c", Self.nodeInventoryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.failed_to_read_node_dependencies") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return Self.parseNodePackages(result.stdout).map { LinuxGuestNodePackage(name: $0.name, version: $0.version, path: $0.path) }
    }

    /// One managed generation change, mirroring the native installer's staged,
    /// recoverable transaction — but executed entirely inside the guest with
    /// its real npm/pnpm and the layer's own directories.
    public func nodeChange(
        environment: ToolEnvironment,
        specifications: [String],
        remove: Bool,
        manager: NodePackageManager,
        timeout: TimeInterval = 180,
        cancellation: CancellationToken?
    ) async throws -> String {
        guard specifications.count <= 256 else { throw FloeError.validationFailed(FloeL10n.l("execution.node_package_manager_policy.at_most_256_dependencies_can_be")) }
        for specification in specifications {
            try NodePackageManagerPolicy.validateSpecification(specification, remove: remove)
        }
        try await requireRunning(environment.id)
        try await recoverNodeTransaction(environmentID: environment.id, cancellation: cancellation)
        let node = try await LinuxGuestNodeProvisioner.shared.ensure(
            environmentID: environment.id,
            runner: runner,
            cancellation: cancellation
        )
        let managerPath: String
        switch manager {
        case .npm:
            managerPath = node.npmPath
        case .pnpm:
            guard let pnpm = node.pnpmPath else {
                throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.pnpm_is_not_available_in_this"))
            }
            managerPath = pnpm
        }
        let registry = try LanguagePackageSources.load(in: environment.writableLayerURL).nodeRegistry

        let state = try await readNodeState(environmentID: environment.id, cancellation: cancellation)
        var dependencies = state.dependencies ?? [:]
        for specification in specifications {
            if remove {
                guard dependencies.removeValue(forKey: specification) != nil else {
                    throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.this_package_is_not_a_dependency"))
                }
            } else {
                let split = specification.dropFirst().lastIndex(of: "@")
                let name = split.map { String(specification[..<$0]) } ?? specification
                let version = split.map { String(specification[specification.index(after: $0)...]) } ?? "latest"
                dependencies[name] = version
            }
        }
        for (name, version) in dependencies {
            try NodePackageManagerPolicy.validateSpecification(name + "@" + version, remove: false)
        }
        let manifest: [String: Any] = [
            "name": "floe-managed-environment",
            "version": "1.0.0",
            "private": true,
            "dependencies": dependencies
        ]
        guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.the_node_dependency_manifest_could_not"))
        }
        let lockName = manager == .npm ? "package-lock.json" : "pnpm-lock.yaml"
        let stage = Self.nodeTransactionRoot + "/stage"
        let destination = LinuxGuestNodeEnvironment.guestNodeModules

        try await prepareNodeTransaction(environmentID: environment.id, cancellation: cancellation)
        try await writeGuestFile(
            environmentID: environment.id,
            path: stage + "/package.json",
            data: manifestData,
            cancellation: cancellation
        )
        if state.registry == registry, state.lockFiles.contains(lockName) {
            try await runShell(
                environmentID: environment.id,
                script: #"cp "$1" "$2""#,
                arguments: [destination + "/.floe-install/" + lockName, stage + "/" + lockName],
                cancellation: cancellation
            )
        }

        let output: String
        let npmCache = await cacheDirectory(
            kind: "npm",
            environmentFallback: LinuxGuestWritablePaths.npmCache,
            environmentID: environment.id,
            cancellation: cancellation
        )
        do {
            let variables: [String: String] = [
                "HOME": LinuxGuestMountPoint.environment + "/home",
                "TMPDIR": LinuxGuestWritablePaths.tmp,
                "TMP": LinuxGuestWritablePaths.tmp,
                "TEMP": LinuxGuestWritablePaths.tmp,
                "npm_config_cache": npmCache,
                "npm_config_store_dir": LinuxGuestMountPoint.environment + "/opt/pnpm-store",
                "npm_config_prefix": stage,
                "npm_config_global": "false",
                "npm_config_userconfig": Self.nodeTransactionRoot + "/empty.npmrc",
                "npm_config_globalconfig": Self.nodeTransactionRoot + "/empty-global.npmrc",
                "npm_config_manage_package_manager_versions": "false",
                "CI": "1",
                "PATH": node.pathDirectory + ":" + LinuxGuestNodeEnvironment.guestBin + ":" + LinuxGuestNodeEnvironment.defaultGuestPath,
                "NODE_PATH": destination
            ]
            // Linux environments keep real npm/pnpm semantics: lifecycle
            // scripts, bin links and Linux-native addons are allowed. Only
            // the staging location is Floe's convention, not the package
            // feature set (the iOS binary/script restrictions belong to the
            // native nodejs-mobile path and never apply here).
            let common = ["install", "--registry=" + registry]
            let options = manager == .npm
                ? ["--no-audit", "--no-fund"]
                : ["--config.node-linker=hoisted", "--package-import-method=copy", "--no-frozen-lockfile",
                   "--config.verify-deps-before-run=never"]
            let argv = ["/usr/bin/env"]
                + (LinuxGuestEnvironmentEncoding.argv(variables) ?? [])
                + [managerPath] + common + options
            let result = try await runner.run(
                environmentID: environment.id,
                argv: argv,
                workingDirectory: stage,
                standardInput: nil,
                timeout: min(600, max(timeout, 60)),
                maxOutputBytes: 256 * 1024,
                cancellation: cancellation
            )
            output = result.stderr.isEmpty ? result.stdout : result.stdout + "\n" + result.stderr
            guard result.exitCode == 0 else {
                throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.npm_exit_code", result.exitCode) + bounded(output))
            }
            try cancellation?.throwIfCancelled()
            try await writeNodeMetadata(
                environmentID: environment.id,
                stage: stage,
                dependencies: dependencies,
                manager: manager,
                registry: registry,
                lockName: lockName,
                cancellation: cancellation
            )
            try await commitNodeTransaction(
                environmentID: environment.id,
                nodePath: node.nodePath,
                cancellation: cancellation
            )
            return output
        } catch {
            do { try await recoverNodeTransaction(environmentID: environment.id, cancellation: nil) }
            catch { throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.the_npm_restore_did_not_finish", error.localizedDescription)) }
            throw error
        }
    }

    // MARK: - Guest scripts

    static let pythonInventoryScript = #"""
    import importlib.metadata as _metadata
    import json as _json
    import os as _os
    import re as _re
    import sysconfig as _sysconfig
    _target = _os.path.realpath(_sysconfig.get_paths()["purelib"])
    _rows = []
    _seen = set()
    for _distribution in _metadata.distributions():
        try:
            _name = _distribution.metadata.get("Name")
        except Exception:
            _name = None
        if not _name:
            continue
        _key = _re.sub(r"[-_.]+", "-", _name).lower()
        if _key in _seen:
            continue
        _seen.add(_key)
        try:
            _version = _distribution.version or ""
        except Exception:
            _version = ""
        _location = str(_distribution.locate_file(""))
        _real = _os.path.realpath(_location)
        _writable = _real == _target or _real.startswith(_target + _os.sep)
        _rows.append({"name": _name, "version": _version, "location": _location, "writable": _writable})
    print("floePythonInventory=" + _json.dumps(_rows, ensure_ascii=False))
    """#

    /// Reads the current generation: dependencies (or the legacy top-level
    /// packages), the registry the previous install used, the manager and any
    /// reusable lock file. Runs inside the guest.
    static let nodeStateScript = #"""
    dest=/floe/env/usr/lib/node_modules
    meta=$dest/.floe-install
    if [ -e "$dest" ]; then printf 'floeDest 1\n'; fi
    for name in dependencies.json registry manager; do
      f="$meta/$name"
      [ -f "$f" ] || continue
      printf 'floeMeta %s ' "$name"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    for lock in package-lock.json pnpm-lock.yaml; do
      if [ -f "$meta/$lock" ]; then printf 'floeLock %s\n' "$lock"; fi
    done
    for f in "$dest"/package.json "$dest"/*/package.json "$dest"/@*/*/package.json; do
      [ -f "$f" ] || continue
      printf 'floePkg %s ' "$f"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    """#

    static let nodeInventoryScript = #"""
    dest=/floe/env/usr/lib/node_modules
    for f in "$dest"/package.json "$dest"/*/package.json "$dest"/@*/*/package.json; do
      [ -f "$f" ] || continue
      printf 'floePkg %s ' "$f"
      base64 -w0 "$f" 2>/dev/null || base64 "$f" | tr -d '\n'
      printf '\n'
    done
    """#

    /// Restores the previous generation when an interrupted commit left a
    /// transaction behind, then removes the transaction. Prepared-only
    /// transactions have nothing to restore.
    static let nodeRecoveryScript = #"""
    tx=/floe/env/var/floe-node-transaction
    dest=/floe/env/usr/lib/node_modules
    if [ -d "$tx" ]; then
      phase=$(cat "$tx/journal" 2>/dev/null || echo none)
      if [ "$phase" = "committing" ]; then
        if [ -e "$tx/backup" ]; then
          rm -rf "$dest"
          mv "$tx/backup" "$dest"
        elif [ "$(cat "$tx/had_original" 2>/dev/null || echo 1)" = "0" ] && [ -e "$dest" ]; then
          rm -rf "$dest"
        fi
      fi
      rm -rf "$tx"
    fi
    """#

    /// Links top-level package CLIs into the environment bin directory after
    /// the generation is in place. npm/pnpm project installs only create
    /// `node_modules/.bin`, which is not on the guest PATH; the managed
    /// environment prefix must expose the same commands a global install
    /// would (`/floe/env/usr/bin/<command>`). Links are relative to the final
    /// module root, so a later generation swap keeps them valid; stale links
    /// that pointed into this module root are removed.
    static let nodeBinLinkScript = #"""
    const fs = require('fs');
    const path = require('path');
    const modules = process.argv[1];
    const binDir = process.argv[2];
    fs.mkdirSync(binDir, { recursive: true });
    const packages = [];
    const visit = (dir, prefix) => {
      let entries = [];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        if (entry.name.startsWith('.')) continue;
        if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
        const full = path.join(dir, entry.name);
        if (entry.name.startsWith('@') && prefix === '') { visit(full, entry.name + '/'); continue; }
        packages.push({ relative: prefix + entry.name, full });
      }
    };
    visit(modules, '');
    const linked = [];
    for (const pkg of packages) {
      let manifest;
      try { manifest = JSON.parse(fs.readFileSync(path.join(pkg.full, 'package.json'), 'utf8')); } catch { continue; }
      const bin = manifest.bin;
      if (!bin) continue;
      const entries = typeof bin === 'string'
        ? { [String(manifest.name || '').split('/').pop()]: bin }
        : bin;
      for (const [name, relative] of Object.entries(entries)) {
        if (!/^[A-Za-z0-9._-]+$/.test(name) || typeof relative !== 'string') continue;
        const target = path.join(modules, pkg.relative, relative);
        if (!fs.existsSync(target)) continue;
        try { fs.chmodSync(target, 0o755); } catch {}
        const dest = path.join(binDir, name);
        try { fs.rmSync(dest, { force: true }); } catch {}
        try { fs.symlinkSync(target, dest); }
        catch {
          const script = '#!/bin/sh\nexec /usr/bin/env node "' + target.replace(/"/g, '\\"') + '" "$@"\n';
          fs.writeFileSync(dest, script);
          fs.chmodSync(dest, 0o755);
        }
        linked.push(name);
      }
    }
    const wanted = new Set(linked);
    for (const entry of fs.readdirSync(binDir, { withFileTypes: true })) {
      if (wanted.has(entry.name)) continue;
      const full = path.join(binDir, entry.name);
      let target = null;
      try { if (entry.isSymbolicLink()) target = fs.realpathSync(full); } catch {
        try { if (entry.isSymbolicLink()) target = fs.readlinkSync(full); } catch {}
      }
      if (target && (target === modules || target.startsWith(modules + path.sep))) {
        try { fs.rmSync(full, { force: true }); } catch {}
      }
    }
    console.log('floeNodeBins=' + linked.sort().join(','));
    """#

    // MARK: - Guest helpers

    private func readNodeState(
        environmentID: String,
        cancellation: CancellationToken?
    ) async throws -> NodeState {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", Self.nodeStateScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 512 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.failed_to_read_node_dependency_status") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        var state = NodeState()
        var scanned: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            if line == "floeDest 1" { state.destinationExists = true; continue }
            if line.hasPrefix("floeLock ") {
                state.lockFiles.insert(String(line.dropFirst("floeLock ".count)))
                continue
            }
            if line.hasPrefix("floeMeta ") {
                let rest = line.dropFirst("floeMeta ".count)
                guard let space = rest.firstIndex(of: " ") else { continue }
                let name = String(rest[..<space])
                guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])) else { continue }
                switch name {
                case "dependencies.json":
                    state.dependencies = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
                case "registry":
                    state.registry = String(decoding: data, as: UTF8.self)
                case "manager":
                    state.manager = String(decoding: data, as: UTF8.self)
                default:
                    break
                }
                continue
            }
            if line.hasPrefix("floePkg ") {
                let rest = line.dropFirst("floePkg ".count)
                guard let space = rest.firstIndex(of: " ") else { continue }
                guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String else { continue }
                scanned[name] = json["version"] as? String ?? ""
            }
        }
        if state.dependencies == nil {
            // Legacy global installs kept no dependency record; every
            // top-level package was an explicit install.
            state.dependencies = scanned
        }
        return state
    }

    /// Parses `floePkg <path> <base64 package.json>` lines.
    static func parseNodePackages(_ stdout: String) -> [(name: String, version: String, path: String)] {
        var rows: [(name: String, version: String, path: String)] = []
        for line in stdout.split(separator: "\n") where line.hasPrefix("floePkg ") {
            let rest = line.dropFirst("floePkg ".count)
            guard let space = rest.firstIndex(of: " ") else { continue }
            let path = String(rest[..<space])
            guard let data = Data(base64Encoded: String(rest[rest.index(after: space)...])),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String, !name.isEmpty else { continue }
            rows.append((name: name, version: json["version"] as? String ?? "", path: path))
        }
        return rows
    }

    private func recoverNodeTransaction(environmentID: String, cancellation: CancellationToken?) async throws {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", Self.nodeRecoveryScript],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.node_transaction_restore_failed") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func prepareNodeTransaction(environmentID: String, cancellation: CancellationToken?) async throws {
        let script = #"""
        set -e
        dest=/floe/env/usr/lib/node_modules
        tx=/floe/env/var/floe-node-transaction
        rm -rf "$tx"
        mkdir -p "$tx/stage" /floe/env/usr/lib /floe/env/home /floe/env/tmp /floe/env/cache/npm /floe/env/cache/pip /floe/env/cache/xdg /floe/env/opt/pnpm-store
        : > "$tx/empty.npmrc"
        : > "$tx/empty-global.npmrc"
        printf 'prepared' > "$tx/journal"
        if [ -e "$dest" ]; then printf '1' > "$tx/had_original"; else printf '0' > "$tx/had_original"; fi
        """#
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.failed_to_prepare_the_node_staging") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func runShell(
        environmentID: String,
        script: String,
        arguments: [String],
        cancellation: CancellationToken?
    ) async throws {
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script] + arguments,
            workingDirectory: nil,
            standardInput: nil,
            timeout: 60,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.the_guest_command_failed") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    /// Writes a guest file in bounded base64 chunks so no single command can
    /// exceed the console channel's payload ceiling.
    private func writeGuestFile(
        environmentID: String,
        path: String,
        data: Data,
        cancellation: CancellationToken?
    ) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try await runShell(
            environmentID: environmentID,
            script: #"mkdir -p "$1" && : > "$2""#,
            arguments: [directory, path],
            cancellation: cancellation
        )
        let base64 = data.base64EncodedString()
        guard !base64.isEmpty else { return }
        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: min(16_384, base64.distance(from: offset, to: base64.endIndex)))
            let chunk = String(base64[offset..<end])
            try await runShell(
                environmentID: environmentID,
                script: #"printf %s "$1" | base64 -d >> "$2""#,
                arguments: [chunk, path],
                cancellation: cancellation
            )
            offset = end
        }
    }

    private func writeNodeMetadata(
        environmentID: String,
        stage: String,
        dependencies: [String: String],
        manager: NodePackageManager,
        registry: String,
        lockName: String,
        cancellation: CancellationToken?
    ) async throws {
        try await runShell(
            environmentID: environmentID,
            script: #"mkdir -p "$1" "$2""#,
            arguments: [stage + "/node_modules", stage + "/node_modules/.floe-install"],
            cancellation: cancellation
        )
        guard let dependenciesData = try? JSONSerialization.data(withJSONObject: dependencies, options: [.sortedKeys]) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.the_node_dependency_record_could_not"))
        }
        let metadata = stage + "/node_modules/.floe-install"
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/dependencies.json",
            data: dependenciesData,
            cancellation: cancellation
        )
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/manager",
            data: Data(manager.rawValue.utf8),
            cancellation: cancellation
        )
        try await writeGuestFile(
            environmentID: environmentID,
            path: metadata + "/registry",
            data: Data(registry.utf8),
            cancellation: cancellation
        )
        try await runShell(
            environmentID: environmentID,
            script: #"if [ -f "$1" ]; then cp "$1" "$2"; fi"#,
            arguments: [stage + "/" + lockName, metadata + "/" + lockName],
            cancellation: cancellation
        )
    }

    private func commitNodeTransaction(
        environmentID: String,
        nodePath: String,
        cancellation: CancellationToken?
    ) async throws {
        // The bin-link script lives beside the stage; it is written before the
        // swap and links the final (post-swap) module path into guestBin, so
        // installed CLIs are callable from the guest shell and services.
        try await writeGuestFile(
            environmentID: environmentID,
            path: Self.nodeTransactionRoot + "/bin-link.js",
            data: Data(Self.nodeBinLinkScript.utf8),
            cancellation: cancellation
        )
        let script = #"""
        set -e
        nodeBin="$1"
        tx=/floe/env/var/floe-node-transaction
        dest=/floe/env/usr/lib/node_modules
        stage=$tx/stage
        mkdir -p "$stage/node_modules"
        printf 'committing' > "$tx/journal"
        if [ -e "$dest" ]; then
          rm -rf "$tx/backup"
          mv "$dest" "$tx/backup"
        fi
        mkdir -p /floe/env/usr/lib
        mv "$stage/node_modules" "$dest"
        if [ -f "$tx/bin-link.js" ]; then
          "$nodeBin" "$tx/bin-link.js" "$dest" /floe/env/usr/bin
        fi
        printf 'committed' > "$tx/journal"
        rm -rf "$tx"
        """#
        let result = try await runner.run(
            environmentID: environmentID,
            argv: ["/bin/sh", "-c", script, "floe", nodePath],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 120,
            maxOutputBytes: 64 * 1024,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.node_transaction_commit_failed") + bounded(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    // MARK: - Debian apt (exact pins only: reviewed Skill dependency provisioning)

    /// The only apt shapes this channel accepts: a Debian identity with an
    /// optional exact Debian version. No arbitrary strings ever reach argv —
    /// `aptInstallExact` takes the identity and version separately, validates
    /// both against the frozen character classes, and then runs the guest's
    /// own single `apt-get install -y --no-install-recommends name=version`
    /// transaction followed by a fixed `dpkg-query` readback. This mirrors the
    /// proven provisioner repair shape (python3-venv self-heal) with one
    /// difference: the pin is exact, and a foreign installed version is
    /// reported honestly instead of being silently downgraded or upgraded.
    public func aptInstallExact(
        identity: String,
        version: String?,
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> String {
        guard LinuxGuestLanguagePackages.isValidAptIdentity(identity) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.invalid_package_spec", identity))
        }
        if let version {
            guard LinuxGuestLanguagePackages.isValidAptVersion(version) else {
                throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.invalid_package_spec", identity + "=" + version))
            }
        }
        try await requireRunning(environment.id)
        let update = try await runner.run(
            environmentID: environment.id,
            argv: ["apt-get", "update"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 600,
            maxOutputBytes: 128 * 1024,
            cancellation: cancellation
        )
        guard update.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.apt_get_update_failed") + bounded(update.stderr.isEmpty ? update.stdout : update.stderr))
        }
        let pin = version.map { "\(identity)=\($0)" } ?? identity
        let install = try await runner.run(
            environmentID: environment.id,
            argv: ["apt-get", "install", "-y", "--no-install-recommends", pin],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 900,
            maxOutputBytes: 256 * 1024,
            cancellation: cancellation
        )
        guard install.exitCode == 0 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.apt_get_install_failed") + bounded(install.stderr.isEmpty ? install.stdout : install.stderr))
        }
        return bounded(install.stdout.isEmpty ? install.stderr : install.stdout)
    }

    /// Fixed readback of one dpkg status line. Returns the exact installed
    /// version, or nil when the identity is not installed.
    public func aptReadback(
        identity: String,
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> String? {
        guard LinuxGuestLanguagePackages.isValidAptIdentity(identity) else {
            throw FloeError.validationFailed(FloeL10n.l("execution.linux_guest_language_packages.invalid_package_spec", identity))
        }
        try await requireRunning(environment.id)
        let result: LinuxCommandResult
        do {
            result = try await runner.run(
                environmentID: environment.id,
                argv: ["/usr/bin/dpkg-query", "-W", "-f=${Package} ${Version}\n", identity],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 60,
                maxOutputBytes: 8 * 1024,
                cancellation: cancellation
            )
        } catch {
            // dpkg-query exits 1 for an unknown identity; treat a non-zero
            // result as "not installed" rather than an error.
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(identity) else { continue }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The fixed, bounded CJK GLYPH-RENDERING probe. A path listing only
    /// proved bytes on disk; readiness of a font profile means the guest can
    /// actually rasterize CJK text. This verb runs the guest's own stdlib
    /// Python ctypes against the FreeType library (the Debian-provided native
    /// renderer — never a model-authored script, never a host execution):
    /// load libfreetype, `FT_Init_FreeType`, `FT_New_Face` on the frozen
    /// Noto CJK TTC locations, a NONZERO `FT_Get_Char_Index` for one Chinese
    /// (U+4E2D) and one Japanese (U+3072) codepoint, `FT_Set_Pixel_Sizes(32)`
    /// and an `FT_LOAD_RENDER` `FT_Load_Char` that must succeed, then face +
    /// library teardown. Missing renderer, missing fonts, zero glyphs or a
    /// render failure all answer false — honest not-ready, which the
    /// declared exact font pin (fontconfig + `fonts-noto-cjk`) closes. No
    /// path, pattern or code ever comes from JSON; the artifact this proves
    /// is glyph availability at 32 px, not visual quality of any produced
    /// document.
    public func cjkFontProbe(
        environment: ToolEnvironment,
        cancellation: CancellationToken?
    ) async throws -> Bool {
        try await requireRunning(environment.id)
        let result: LinuxCommandResult
        do {
            result = try await runner.run(
                environmentID: environment.id,
                argv: ["python3", "-c", Self.cjkFreeTypeProbeScript],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 120,
                maxOutputBytes: 8 * 1024,
                cancellation: cancellation
            )
        } catch {
            return false
        }
        return result.exitCode == 0
    }

    /// The frozen probe program. Python stdlib only (`ctypes`); the two TTC
    /// locations are the exact Debian `fonts-noto-cjk` install paths.
    static let cjkFreeTypeProbeScript = #"""
import sys
try:
    import ctypes
    import ctypes.util
except ImportError:
    sys.exit(1)
name = ctypes.util.find_library("freetype")
try:
    ft = ctypes.CDLL(name or "libfreetype.so.6")
except OSError:
    sys.exit(1)
ft.FT_Init_FreeType.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
ft.FT_New_Face.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.POINTER(ctypes.c_void_p)]
ft.FT_Get_Char_Index.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
ft.FT_Get_Char_Index.restype = ctypes.c_uint
ft.FT_Set_Pixel_Sizes.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
ft.FT_Load_Char.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]
ft.FT_Done_Face.argtypes = [ctypes.c_void_p]
ft.FT_Done_FreeType.argtypes = [ctypes.c_void_p]
lib = ctypes.c_void_p()
face = ctypes.c_void_p()
if ft.FT_Init_FreeType(ctypes.byref(lib)) != 0 or not lib.value:
    sys.exit(1)
opened = False
for path in (b"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
             b"/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc"):
    if ft.FT_New_Face(lib, path, 0, ctypes.byref(face)) == 0 and face.value:
        opened = True
        break
if not opened:
    ft.FT_Done_FreeType(lib)
    sys.exit(1)
ok = ft.FT_Set_Pixel_Sizes(face, 0, 32) == 0
for code in (0x4E2D, 0x3072):
    if ft.FT_Get_Char_Index(face, code) == 0:
        ok = False
if ok and ft.FT_Load_Char(face, 0x4E2D, 0x4) != 0:
    ok = False
ft.FT_Done_Face(face)
ft.FT_Done_FreeType(lib)
sys.exit(0 if ok else 1)
"""#

    /// Debian identity class `[a-z0-9][a-z0-9+._-]*` (ASCII strict).
    public static func isValidAptIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        let lower = UInt8(ascii: "a")...UInt8(ascii: "z")
        let digit = UInt8(ascii: "0")...UInt8(ascii: "9")
        func firstOK(_ b: UInt8) -> Bool { lower.contains(b) || digit.contains(b) }
        func restOK(_ b: UInt8) -> Bool {
            firstOK(b) || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
                || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
        }
        guard firstOK(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy(restOK)
    }

    /// Debian version class `([0-9]+:)?[A-Za-z0-9][A-Za-z0-9+.-~:]*` (epoch,
    /// revision, dfsg/tilde suffixes stay verbatim inside the pin), aligned
    /// with the approved descriptor contract (`SkillDependency.isValidAptVersion`):
    /// the version body must carry at least one ASCII digit AFTER any epoch,
    /// because every real Debian version body does — floating aliases
    /// (`latest`, `stable`, even `1:latest`) can never masquerade as an exact
    /// pin, while epoch/repack pins like `1:20240730+repack1-1` stay
    /// verbatim-installable.
    public static func isValidAptVersion(_ value: String) -> Bool {
        var body = Substring(value)
        if let colon = value.firstIndex(of: ":") {
            let epoch = value[value.startIndex..<colon]
            guard !epoch.isEmpty, epoch.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
                return false
            }
            body = value[value.index(after: colon)...]
        }
        let bytes = Array(body.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              bytes.contains(where: { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return false }
        let lower = UInt8(ascii: "a")...UInt8(ascii: "z")
        let upper = UInt8(ascii: "A")...UInt8(ascii: "Z")
        let digit = UInt8(ascii: "0")...UInt8(ascii: "9")
        func alnumOK(_ b: UInt8) -> Bool { lower.contains(b) || upper.contains(b) || digit.contains(b) }
        func restOK(_ b: UInt8) -> Bool {
            alnumOK(b) || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
                || b == UInt8(ascii: "-") || b == UInt8(ascii: "~") || b == UInt8(ascii: ":")
        }
        guard alnumOK(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy(restOK)
    }

    private func bounded(_ text: String) -> String {
        String(text.suffix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct NodeState {
        var destinationExists = false
        var dependencies: [String: String]?
        var registry: String?
        var manager: String?
        var lockFiles: Set<String> = []
    }
}

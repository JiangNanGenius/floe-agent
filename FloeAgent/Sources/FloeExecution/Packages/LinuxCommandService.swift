// FloeExecution — Linux command service injection boundary.
// The `apt`/`dpkg` command names mean real Linux distribution packages only.
// On this device there is no Linux package manager; when a selected
// environment is a Linux guest, the app injects a TinyEMU-backed
// implementation of `LinuxCommandRunning` and the shell forwards argv to the
// guest verbatim. When no implementation supports an environment, callers
// must say a Linux environment is required instead of faking availability.

import Foundation
import FloeCore
import FloeTools

/// Result of one command executed inside a Linux guest.
public struct LinuxCommandResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Runs commands inside the Linux guest that owns an environment. The app
/// layer supplies the implementation (TinyEMU backend); this module only
/// consumes it. Implementations execute argv with native guest semantics —
/// they never rewrite command names or re-parse arguments — and must
/// interrupt the guest process when the cancellation token fires.
public protocol LinuxCommandRunning: Sendable {
    /// True only when the environment is a Linux guest this service owns and
    /// that guest is running. Anything else must return false so callers
    /// report "a Linux environment is required" honestly.
    func supports(environmentID: String) async -> Bool
    /// Executes argv inside the environment's Linux guest with bounded output.
    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult
}

/// Shell-facing router for the Linux package command names. It owns the
/// apt/dpkg command surface and nothing else: Python, Node and signed WASM
/// capabilities have their own entries and are never resolved here.
public struct LinuxShellCommandRouter: Sendable {
    /// Command names this router accepts, in deterministic registration
    /// order. `pkg` stays a Floe alias for `apt`.
    public static let routedCommandNames: [String] = [
        "apt", "apt-cache", "apt-get", "apt-mark", "dpkg", "dpkg-deb", "pkg"
    ]

    private let service: (any LinuxCommandRunning)?

    public init(service: (any LinuxCommandRunning)?) {
        self.service = service
    }

    public func handles(_ command: String) -> Bool {
        Self.routedCommandNames.contains(command)
    }

    /// The guest argv for a routed invocation: the real command name plus the
    /// user's arguments, unmodified.
    public static func guestArgv(command: String, arguments: [String]) -> [String] {
        let resolved = command == "pkg" ? "apt" : command
        return [resolved] + Array(arguments.dropFirst())
    }

    /// Runs the command in the environment's Linux guest when an injected
    /// service supports that environment. Returns nil when the command is not
    /// routed or no Linux guest backs the environment, so the caller can pick
    /// its own honest fallback.
    public func runIfSupported(
        command: String,
        arguments: [String],
        environmentID: String?,
        workingDirectory: String?,
        standardInput: String? = nil,
        timeout: TimeInterval = 300,
        maxOutputBytes: Int = 256 * 1024,
        cancellation: CancellationToken? = nil
    ) async -> LinuxCommandResult? {
        guard handles(command), let environmentID, let service,
              await service.supports(environmentID: environmentID) else { return nil }
        do {
            return try await service.run(
                environmentID: environmentID,
                argv: Self.guestArgv(command: command, arguments: arguments),
                workingDirectory: workingDirectory,
                standardInput: standardInput,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        } catch is CancellationError {
            return LinuxCommandResult(stdout: "", stderr: "\(command): cancelled", exitCode: 130)
        } catch FloeError.cancelled {
            return LinuxCommandResult(stdout: "", stderr: "\(command): cancelled", exitCode: 130)
        } catch {
            return LinuxCommandResult(stdout: "", stderr: "\(command): \(error.localizedDescription)", exitCode: 100)
        }
    }

    /// Honest answer for the apt command family when no Linux guest backs the
    /// current environment. It names the real per-family entries instead of
    /// pretending anything was or could be installed here.
    public static func linuxRequiredOutput(command: String) -> LinuxCommandResult {
        let message = """
        \(command): Debian packages are managed only inside a Floe Linux environment, and no Linux environment is available for this shell yet. \
        On this device the package entries are separate: Python packages install with the python.packages tool or the exec.localPython/exec.shell `packages` argument, \
        Node packages with npm/pnpm, and signed WASI commands with the wasm.packages tool.
        """
        return LinuxCommandResult(stdout: "", stderr: message, exitCode: 100)
    }
}

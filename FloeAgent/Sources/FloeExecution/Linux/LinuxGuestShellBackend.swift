// FloeExecution — Linux guest shell backend.
//
// exec.shell in a Floe Linux environment runs inside the environment's
// guest, on the same interpreter/channel that serves apt/dpkg, localPython
// and localService. The shell command string is handed to the guest's own
// /bin/sh unchanged (no host re-parsing, no native callback interception);
// the host only frames argv for the console channel.
//
// Interactive terminal sessions over the serial console are not wired yet,
// so openSession fails honestly instead of opening a native session that
// would silently escape the guest.

import Foundation
import FloeCore
import FloeTools

public struct LinuxGuestShellBackend: LocalShellBackend {
    private let runner: any LinuxCommandRunning
    private let limits: LinuxGuestLimits

    public init(runner: any LinuxCommandRunning, limits: LinuxGuestLimits = .standard) {
        self.runner = runner
        self.limits = limits
    }

    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        guard let environmentID = request.toolEnvironment?.id else {
            return .failed(message: "Linux shell execution requires an environment id")
        }
        guard await runner.supports(environmentID: environmentID) else {
            guard await runner.ownsLinuxEnvironment(environmentID: environmentID) else {
                return .failed(message: LinuxGuestError.notOwned(environmentID: environmentID).localizedDescription)
            }
            return .failed(message: LinuxGuestError.notRunning(environmentID: environmentID).localizedDescription)
        }

        let started = Date()
        let timeout = limits.clampedTimeout(request.timeout)
        let maxOutput = limits.clampedOutputBytes(request.maxOutputBytes)
        do {
            let result = try await runner.run(
                environmentID: environmentID,
                argv: ["/bin/sh", "-c", request.command],
                workingDirectory: request.cwd,
                standardInput: request.stdin,
                timeout: timeout,
                maxOutputBytes: maxOutput,
                cancellation: cancellation
            )
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return .exited(
                code: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                truncated: false,
                stderrTruncated: false,
                durationMs: durationMs
            )
        } catch FloeError.cancelled {
            return .cancelled
        } catch let error as LinuxGuestError {
            if case .timedOut(let seconds) = error {
                return .timedOut(partialStdout: "", partialStderr: "", durationMs: Int(seconds * 1000))
            }
            return .failed(message: error.localizedDescription)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        throw LinuxGuestError.consoleUnavailable(
            "interactive shell sessions inside the Linux guest are not wired yet; use exec.shell one-shot commands"
        )
    }

    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        throw LinuxGuestError.consoleUnavailable("no interactive Linux guest session exists")
    }

    public func closeSession(sessionID: String) async {}
    public func signalSession(sessionID: String, signal: ShellSignal) async {}
    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
}

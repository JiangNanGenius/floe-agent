// FloeSSH — Bounded command execution with streamed output.
// See docs/ARCHITECTURE_EXECUTION.md §3.2/§7.2: stdin-based script feeding
// is NOT possible on iOS — Citadel's `withExec` is @available(macOS 15.0,
// *), `executeCommandStream` does not expose the channel, and the
// underlying `client.session` handle is internal. The only public exec API
// is `executeCommandStream(command)`. Scripts are therefore delivered via
// the documented fallback: a base64-wrapped `python3 -c` one-liner (no
// shell quoting issues, script bytes travel verbatim-encoded).
//
// The exec channel is closed on timeout/cancellation via
// `client.session.channel.close()` (the session channel IS reachable),
// which terminates the in-flight exec.

import Foundation
import Citadel
import NIOCore
import FloeCore
import FloeTools

/// Errors specific to bounded exec runs.
public enum SSHExecError: Error, Sendable, Equatable {
    case timedOut
    case cancelled
}

/// Outcome of one bounded command run.
public struct SSHExecResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    /// True when stdout exceeded `maxOutputBytes` (further output dropped).
    public var truncated: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, truncated: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.truncated = truncated
    }
}

public extension SSHSessionHandle {

    /// Runs `command` on the target host, collecting stdout/stderr up to
    /// `maxOutputBytes`. Non-zero exit surfaces as `exitCode` (the
    /// CommandFailed error is unwrapped so callers read data, not throws).
    /// Cancellation and timeout close the session channel and throw.
    func executeBounded(
        _ command: String,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken? = nil
    ) async throws -> SSHExecResult {
        if cancellation?.isCancelled == true { throw SSHExecError.cancelled }

        let client = targetClient
        let stream = try await client.executeCommandStream(command)
        let limit = max(0.05, timeout)

        let collect = Task { () -> SSHExecResult in
            var stdout = ""
            var stderr = ""
            var truncated = false
            var exitCode: Int32 = 0
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer):
                        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
                        if stdout.utf8.count + text.utf8.count <= maxOutputBytes {
                            stdout += text
                        } else {
                            truncated = true
                        }
                    case .stderr(let buffer):
                        stderr += String(decoding: buffer.readableBytesView, as: UTF8.self)
                    }
                }
            } catch let error as SSHClient.CommandFailed {
                exitCode = Int32(error.exitCode)
            }
            return SSHExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode, truncated: truncated)
        }

        let watchdog = Task { () -> SSHExecError in
            try? await Task.sleep(for: .seconds(limit))
            return .timedOut
        }
        let cancelWatch = Task { () -> SSHExecError in
            while cancellation?.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return .cancelled
        }

        return try await withCheckedThrowingContinuation { continuation in
            let arbiter = ExecRaceArbiter(continuation: continuation)
            // Box the non-Sendable captures once so the watcher closures
            // cross the task boundary as a single @unchecked-Sendable box
            // (Swift 6 sending-parameter rule).
            let context = ExecWatchContext(client: client, collect: collect, arbiter: arbiter)

            Task {
                do {
                    let result = try await collect.value
                    arbiter.win(.success(result))
                } catch {
                    arbiter.win(.failure(error))
                }
            }
            Task {
                if let error = try? await watchdog.value {
                    await context.abort(with: error)
                }
            }
            Task {
                if let error = try? await cancelWatch.value {
                    await context.abort(with: error)
                }
            }
        }
    }
}

/// Bundles the non-Sendable captures (SSHClient, the collecting Task, the
/// arbiter) so watcher closures capture one @unchecked-Sendable box
/// instead of individually sending non-Sendable values across the task
/// boundary.
private final class ExecWatchContext: @unchecked Sendable {
    private let client: SSHClient
    private let collect: Task<SSHExecResult, Error>
    private let arbiter: ExecRaceArbiter

    init(client: SSHClient, collect: Task<SSHExecResult, Error>, arbiter: ExecRaceArbiter) {
        self.client = client
        self.collect = collect
        self.arbiter = arbiter
    }

    /// Records a timeout/cancellation: tears down the client (the remote
    /// process is not left running), cancels collection, and resolves.
    func abort(with error: SSHExecError) async {
        try? await client.close()
        collect.cancel()
        arbiter.win(.failure(error))
    }
}

/// One-shot race arbiter: only the first completion resumes the
/// continuation.
private final class ExecRaceArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<SSHExecResult, Error>

    init(continuation: CheckedContinuation<SSHExecResult, Error>) {
        self.continuation = continuation
    }

    func win(_ outcome: Result<SSHExecResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: outcome)
    }
}

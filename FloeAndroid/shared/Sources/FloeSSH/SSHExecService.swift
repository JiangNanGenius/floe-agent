// FloeSSH — bounded command execution with streamed output (Android port).
//
// Ported from the fixed public donor
// FloeAgent/Sources/FloeSSH/SSHExecService.swift @
// a59b4d4005f616c611df67fab7620e9853c525b9. The donor's bounded and
// streaming helpers are retained unchanged. One Android-port addition is
// required by C05's host-terminal contract:
//
//   `openExec` runs ONE command on a channel it owns. Cancelling it closes
//   only that exec channel (Citadel `withExec`), never the whole SSH client,
//   so a cancelled command cannot kill a sibling terminal or tunnel.
//
// Scripts are delivered via the documented base64-wrapped `python3 -c`
// fallback: Citadel's pinned public API does not expose exec stdin on this
// revision. No host `ssh` process is ever spawned.

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
    /// True when the combined stdout/stderr budget was exceeded.
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
            var collectedBytes = 0
            var exitCode: Int32 = 0
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer):
                        let bytes = Data(buffer.readableBytesView)
                        let remaining = max(0, maxOutputBytes - collectedBytes)
                        let accepted = bytes.prefix(remaining)
                        stdout += String(decoding: accepted, as: UTF8.self)
                        collectedBytes += accepted.count
                        if accepted.count < bytes.count { truncated = true }
                    case .stderr(let buffer):
                        let bytes = Data(buffer.readableBytesView)
                        let remaining = max(0, maxOutputBytes - collectedBytes)
                        let accepted = bytes.prefix(remaining)
                        stderr += String(decoding: accepted, as: UTF8.self)
                        collectedBytes += accepted.count
                        if accepted.count < bytes.count { truncated = true }
                    }
                }
            } catch let error as SSHClient.CommandFailed {
                exitCode = Int32(error.exitCode)
            }
            return SSHExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode, truncated: truncated)
        }

        let watchdog = Task { () -> SSHExecError? in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return nil }
            return .timedOut
        }
        let cancelWatch: Task<SSHExecError?, Never>? = cancellation.map { token in
            Task {
                while !Task.isCancelled, !token.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard !Task.isCancelled else { return nil }
                return .cancelled
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let arbiter = ExecRaceArbiter(continuation: continuation)
            let context = ExecWatchContext(client: client, collect: collect, arbiter: arbiter)

            Task {
                do {
                    let result = try await collect.value
                    watchdog.cancel()
                    cancelWatch?.cancel()
                    arbiter.win(.success(result))
                } catch {
                    watchdog.cancel()
                    cancelWatch?.cancel()
                    arbiter.win(.failure(error))
                }
            }
            Task {
                if let error = await watchdog.value {
                    await context.abort(with: error)
                }
            }
            if let cancelWatch {
                Task {
                    if let error = await cancelWatch.value {
                        await context.abort(with: error)
                    }
                }
            }
        }
    }
}

/// Bundles the non-Sendable captures for the bounded-exec watcher.
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

/// One-shot race arbiter: only the first completion resumes the continuation.
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

// MARK: - Unlimited/streaming exec seam

/// Deadline supplied to the streaming exec seam. `.unlimited` is a real
/// policy case, never `Double.infinity`, `0` or a fake large cap.
public enum SSHStreamExecDeadline: Sendable, Equatable {
    case unlimited
    case seconds(TimeInterval)
}

public enum SSHStreamChannel: String, Sendable, Equatable {
    case stdout
    case stderr
}

/// One streaming run. Previews are bounded; the total byte counters describe
/// what was actually observed. `exitCode` is the remote command's status
/// (0 when the stream ended normally).
public struct SSHStreamExecResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdoutPreview: Data
    public var stderrPreview: Data
    public var stdoutBytes: Int64
    public var stderrBytes: Int64
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        exitCode: Int32 = 0,
        stdoutPreview: Data = Data(),
        stderrPreview: Data = Data(),
        stdoutBytes: Int64 = 0,
        stderrBytes: Int64 = 0,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdoutPreview = stdoutPreview
        self.stderrPreview = stderrPreview
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

/// Typed streaming failure. `.interrupted` and `.sinkFailed` mean the command
/// MAY have run: callers must inspect the saved job, never rerun it as if it
/// had not started.
public enum SSHStreamExecFailure: Error, Sendable, Equatable {
    case timedOut
    case cancelled
    case interrupted(String)
    case sinkFailed(String)
}

public extension SSHSessionHandle {

    /// Streams one command's stdout/stderr to `onOutput` and returns the real
    /// exit status. Memory is bounded by the preview limit; the sink sees the
    /// full output. The existing client is closed on timeout/cancellation so
    /// no remote process is intentionally left running.
    func executeStreaming(
        _ command: String,
        deadline: SSHStreamExecDeadline,
        cancellation: CancellationToken? = nil,
        maxPreviewBytes: Int = 64 * 1024,
        onOutput: @escaping @Sendable (SSHStreamChannel, Data) async throws -> Void
    ) async throws -> SSHStreamExecResult {
        if cancellation?.isCancelled == true { throw SSHStreamExecFailure.cancelled }
        try Task.checkCancellation()

        if case .seconds(let seconds) = deadline, !(seconds.isFinite && seconds > 0) {
            throw SSHStreamExecFailure.timedOut
        }
        guard isConnected else {
            throw SSHStreamExecFailure.interrupted("The SSH session is not connected")
        }

        let previewLimit = max(1, min(maxPreviewBytes, 1024 * 1024))
        let client = targetClient
        let clientBox = SSHStreamClientBox(client: client)
        let gate = SSHStreamAbortGate()

        let watchdog: Task<Void, Never>?
        switch deadline {
        case .unlimited:
            watchdog = nil
        case .seconds(let seconds):
            watchdog = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                if gate.record(.timedOut) { await clientBox.close() }
            }
        }
        let cancelWatch: Task<Void, Never>? = cancellation.map { token in
            Task {
                while !Task.isCancelled, !token.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard !Task.isCancelled else { return }
                if gate.record(.cancelled) { await clientBox.close() }
            }
        }
        defer {
            watchdog?.cancel()
            cancelWatch?.cancel()
        }

        let stream: AsyncThrowingStream<ExecCommandOutput, Error>
        do {
            stream = try await client.executeCommandStream(command)
        } catch let error as SSHClient.CommandFailed {
            if let reason = gate.reason { throw reason }
            if Task.isCancelled { throw SSHStreamExecFailure.cancelled }
            return SSHStreamExecResult(exitCode: Int32(error.exitCode))
        } catch {
            if let reason = gate.reason { throw reason }
            if Task.isCancelled { throw SSHStreamExecFailure.cancelled }
            throw SSHStreamExecFailure.interrupted(SecretRedactor.redact(error.localizedDescription))
        }

        let collect = Task { () throws -> SSHStreamExecResult in
            var result = SSHStreamExecResult()
            var previewBytes = 0
            do {
                for try await chunk in stream {
                    if let reason = gate.reason { throw reason }
                    switch chunk {
                    case .stdout(let buffer):
                        let data = Data(buffer.readableBytesView)
                        guard !data.isEmpty else { continue }
                        result.stdoutBytes += Int64(data.count)
                        SSHStreamPreview.append(
                            data, to: &result.stdoutPreview,
                            limit: previewLimit, used: &previewBytes,
                            truncated: &result.stdoutTruncated)
                        try await SSHStreamSupport.emit(
                            .stdout, data, onOutput: onOutput,
                            gate: gate, client: clientBox, cancellation: cancellation)
                    case .stderr(let buffer):
                        let data = Data(buffer.readableBytesView)
                        guard !data.isEmpty else { continue }
                        result.stderrBytes += Int64(data.count)
                        SSHStreamPreview.append(
                            data, to: &result.stderrPreview,
                            limit: previewLimit, used: &previewBytes,
                            truncated: &result.stderrTruncated)
                        try await SSHStreamSupport.emit(
                            .stderr, data, onOutput: onOutput,
                            gate: gate, client: clientBox, cancellation: cancellation)
                    }
                }
            } catch let failure as SSHStreamExecFailure {
                throw failure
            } catch let error as SSHClient.CommandFailed {
                if let reason = gate.reason { throw reason }
                result.exitCode = Int32(error.exitCode)
            } catch {
                if let reason = gate.reason { throw reason }
                throw SSHStreamExecFailure.interrupted(SecretRedactor.redact(error.localizedDescription))
            }
            if let reason = gate.reason { throw reason }
            return result
        }

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let arbiter = SSHStreamRaceArbiter(continuation: continuation)
                    let context = SSHStreamWatchContext(
                        client: clientBox, collect: collect, gate: gate, arbiter: arbiter)
                    let watcher = Task {
                        while !Task.isCancelled {
                            if let reason = gate.reason {
                                await context.abort(with: reason)
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                    }
                    Task {
                        do {
                            arbiter.win(.success(try await collect.value))
                        } catch {
                            arbiter.win(.failure(error))
                        }
                        watcher.cancel()
                        watchdog?.cancel()
                        cancelWatch?.cancel()
                    }
                }
            },
            onCancel: {
                if gate.record(.cancelled) {
                    Task { await clientBox.close() }
                }
            }
        )
    }
}

private enum SSHStreamPreview {
    static func append(
        _ data: Data,
        to preview: inout Data,
        limit: Int,
        used: inout Int,
        truncated: inout Bool
    ) {
        let remaining = max(0, limit - used)
        guard remaining > 0 else {
            truncated = true
            return
        }
        let accepted = data.prefix(remaining)
        preview.append(contentsOf: accepted)
        used += accepted.count
        if accepted.count < data.count { truncated = true }
    }
}

private enum SSHStreamSupport {
    static func emit(
        _ channel: SSHStreamChannel,
        _ data: Data,
        onOutput: @escaping @Sendable (SSHStreamChannel, Data) async throws -> Void,
        gate: SSHStreamAbortGate,
        client: SSHStreamClientBox,
        cancellation: CancellationToken?
    ) async throws {
        do {
            try await onOutput(channel, data)
        } catch {
            if let reason = gate.reason { throw reason }
            if Task.isCancelled || cancellation?.isCancelled == true {
                throw SSHStreamExecFailure.cancelled
            }
            let failure = SSHStreamExecFailure.sinkFailed(
                SecretRedactor.redact(error.localizedDescription))
            gate.record(failure)
            await client.close()
            throw gate.reason ?? failure
        }
    }
}

/// First-writer-wins abort reason shared by the watchdog, cancellation watcher
/// and collection task.
private final class SSHStreamAbortGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SSHStreamExecFailure?

    var reason: SSHStreamExecFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func record(_ reason: SSHStreamExecFailure) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return false }
        stored = reason
        return true
    }
}

/// Boxes the non-Sendable Citadel client for abort closures.
private final class SSHStreamClientBox: @unchecked Sendable {
    private let client: SSHClient
    private let lock = NSLock()
    private var closed = false

    init(client: SSHClient) { self.client = client }

    func close() async {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose { try? await client.close() }
    }
}

/// Stops collection and resolves the continuation. Used by the abort poller.
private final class SSHStreamWatchContext: @unchecked Sendable {
    private let client: SSHStreamClientBox
    private let collect: Task<SSHStreamExecResult, Error>
    private let gate: SSHStreamAbortGate
    private let arbiter: SSHStreamRaceArbiter

    init(
        client: SSHStreamClientBox,
        collect: Task<SSHStreamExecResult, Error>,
        gate: SSHStreamAbortGate,
        arbiter: SSHStreamRaceArbiter
    ) {
        self.client = client
        self.collect = collect
        self.gate = gate
        self.arbiter = arbiter
    }

    func abort(with reason: SSHStreamExecFailure) async {
        gate.record(reason)
        let effective = gate.reason ?? reason
        collect.cancel()
        await client.close()
        arbiter.win(.failure(effective))
    }
}

/// One-shot race arbiter: only the first completion resumes the continuation.
private final class SSHStreamRaceArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<SSHStreamExecResult, Error>

    init(continuation: CheckedContinuation<SSHStreamExecResult, Error>) {
        self.continuation = continuation
    }

    func win(_ outcome: Result<SSHStreamExecResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: outcome)
    }
}

// MARK: - Independently-owned exec channel (C05)

/// One live command channel. Cancelling closes only this exec channel.
public final class SSHExecStreamHandle: SSHSessionExec, @unchecked Sendable {
    public let events: AsyncThrowingStream<SSHExecEvent, Error>
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(events: AsyncThrowingStream<SSHExecEvent, Error>, task: Task<Void, Never>) {
        self.events = events
        self.task = task
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        task.cancel()
    }

    /// Test/diagnostic only. Production must not block a host request on a
    /// remote channel's teardown; cancellation is asynchronous by design.
    public func waitForTermination() async {
        _ = await task.value
    }
}

/// Boxes the non-Sendable Citadel client for the owned exec task.
private final class SSHExecClientBox: @unchecked Sendable {
    let client: SSHClient
    init(_ client: SSHClient) { self.client = client }
}

public extension SSHSessionHandle {

    /// Opens one command on its own SSH channel. The returned stream yields
    /// real stdout/stderr bytes and a final `.exited` status; cancellation
    /// closes the channel without touching sibling channels.
    func openExec(_ command: String) async throws -> any SSHSessionExec {
        let (stream, continuation) = AsyncThrowingStream<SSHExecEvent, Error>.makeStream()
        let box = SSHExecClientBox(targetClient)

        let task = Task { [box] in
            do {
                try await box.client.withExec(command) { inbound, _ in
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            let data = Data(buffer.readableBytesView)
                            if !data.isEmpty { continuation.yield(.stdout(data)) }
                        case .stderr(let buffer):
                            let data = Data(buffer.readableBytesView)
                            if !data.isEmpty { continuation.yield(.stderr(data)) }
                        }
                    }
                }
                continuation.yield(.exited(0))
                continuation.finish()
            } catch let error as SSHClient.CommandFailed {
                continuation.yield(.exited(Int32(error.exitCode)))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: SSHExecError.cancelled)
            } catch {
                if Task.isCancelled {
                    continuation.finish(throwing: SSHExecError.cancelled)
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        return SSHExecStreamHandle(events: stream, task: task)
    }
}

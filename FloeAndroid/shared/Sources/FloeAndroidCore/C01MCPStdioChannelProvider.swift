// SPDX-License-Identifier: MPL-2.0
//
// C01MCPStdioChannelProvider — the REAL C01 implementation of the C02
// separated-stdio channel contract.
//
// Composition (Main): one provider is passed to
// `C02MCPSetupStdioClientFactory(epoch:provider:)` and to
// `C02MCPSetupIntegration.makeInstallation(... stdioChannelProvider: ...)`.
// The provider never flips a qualification flag by itself.
//
// The provider's job is to prove the configuration is admissible for the ONE
// accepted generation, then let `C01ManagedServiceDomain` start the owned
// runtime process and return a channel over the three distinct pipes. The
// channel object below is a strict, bounded byte-pipe consumer:
//
// * stdout is line-framed HERE (chunks may split UTF-8/JSON anywhere); a
//   complete line is returned without its trailing LF (and an optional CR is
//   stripped). `nil` means real EOF, `C02MCPSetupFailure(.stdioTimeout)`
//   means the bounded wait expired.
// * stderr is drained separately into a bounded diagnostic ring and is never
//   returned as protocol data or merged into stdout.
// * writes are serialized by the actor and paged at the engine's 16 KiB
//   bound with bounded partial-write retries; a fatal errno is honest.
// * a stdout/stderr gap, an overlong line or an EOF in the middle of a line is
//   a closed protocol failure — the channel is killed and never resynchronized.
// * `close()` requests the exact owned stop, waits (bounded) for the runtime's
//   real `leaseReleased`, then releases the domain record. A late reply after
//   close can never restore the channel: `closed` fences every operation and
//   ownership remains retained if real release is not yet proven.
//
// No host process, no PTY, no shell interpretation and no model-visible tool
// name exists on any path through this file.

import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeAndroidShellTools

// MARK: - Execution context (trusted App/Main seam)

/// The trusted execution context an MCP stdio channel may be opened under:
/// exactly one LIVE run of the bound task plus that task's resolved workspace.
/// This is composition input, never a model/provider value.
public struct C01LinuxStdioExecutionContext: Sendable, Equatable {
    public let runID: UUID
    public let conversationID: UUID
    public let workspaceID: UUID
    public let workspaceRootURL: URL

    public init(runID: UUID, conversationID: UUID, workspaceID: UUID,
                workspaceRootURL: URL) {
        self.runID = runID
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.workspaceRootURL = workspaceRootURL
    }
}

/// Main may inject a stricter provider (for example the C02 setup execution
/// context). The default resolver below uses ONLY the ORIGINAL run store and
/// workspace authority; an absent/ambiguous context refuses instead of
/// inventing a run or choosing the first project/temporary root.
public protocol C01LinuxStdioExecutionContextProviding: Sendable {
    func liveContext(forTask taskID: UUID, projectID: UUID) async
        -> C01LinuxStdioExecutionContext?
}

public struct C01LinuxStdioLiveRunContext: C01LinuxStdioExecutionContextProviding {
    public init() {}

    public func liveContext(forTask taskID: UUID, projectID: UUID) async
        -> C01LinuxStdioExecutionContext? {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return nil
        }
        let runs: [RunRecord]
        do {
            runs = try await composition.cluster.runStore.nonTerminalRuns()
        } catch {
            return nil
        }
        let matches = runs.filter { $0.conversationID == taskID }
        // Ambiguous or absent live ownership is never resolved by "first".
        guard matches.count == 1, let run = matches.first else { return nil }
        guard let resolved = await LinuxWorkspaceAuthority.resolveWorkspace(
            conversationID: taskID) else { return nil }
        guard Self.isManagedProjectRoot(resolved.rootURL, projectID: projectID) else {
            return nil
        }
        return C01LinuxStdioExecutionContext(
            runID: run.id, conversationID: taskID,
            workspaceID: resolved.workspaceID, workspaceRootURL: resolved.rootURL)
    }

    static func isManagedProjectRoot(_ rootURL: URL, projectID: UUID) -> Bool {
        let standardized = rootURL.standardizedFileURL
        return standardized.lastPathComponent == projectID.uuidString &&
            standardized.deletingLastPathComponent().lastPathComponent == "Projects"
    }
}

/// The live persisted configuration digest for one MCP server. Installing one
/// makes a replaced configuration close the old channel and make in-flight
/// replies stale (the same rule the HTTP refresh lane already applies). With
/// no provider installed, the transport lifecycle (refresh disconnects the
/// previous client) remains the authority; this file never guesses a digest.
public protocol C01LinuxStdioConfigRevisionProviding: Sendable {
    func currentConfigDigest(serverID: UUID) async -> String?
}

// MARK: - Provider

public struct C01MCPStdioChannelProvider: C02MCPSetupStdioChannelProviding {
    private let epoch: UInt64?
    private let domain: C01ManagedServiceDomain
    private let transport: (any C01LinuxStdioTransporting)?
    private let executionContexts: any C01LinuxStdioExecutionContextProviding
    private let configRevisions: (any C01LinuxStdioConfigRevisionProviding)?

    public init(epoch: UInt64? = nil,
                domain: C01ManagedServiceDomain = .shared,
                transport: (any C01LinuxStdioTransporting)? = nil,
                executionContexts: any C01LinuxStdioExecutionContextProviding = C01LinuxStdioLiveRunContext(),
                configRevisions: (any C01LinuxStdioConfigRevisionProviding)? = nil) {
        self.epoch = epoch
        self.domain = domain
        self.transport = transport
        self.executionContexts = executionContexts
        self.configRevisions = configRevisions
    }

    private static func map(_ failure: C01LinuxStdioFailure) -> C02MCPSetupFailure {
        switch failure.code {
        case .timedOut:
            return C02MCPSetupFailure(.stdioTimeout, message: failure.message,
                                      retryable: failure.retryable)
        case .lineTooLong, .streamDesynchronized, .pipeClosed, .protocolViolation:
            return C02MCPSetupFailure(.stdioResponseInvalid, message: failure.message,
                                      retryable: failure.retryable)
        case .unavailable, .staleGeneration, .invalidConfiguration,
             .workspaceMismatch, .executionContextUnavailable, .writeFailed:
            return C02MCPSetupFailure(.stdioUnavailable, message: failure.message,
                                      retryable: failure.retryable)
        }
    }

    public func openChannel(
        for configuration: MCPServerConfiguration
    ) async throws -> any C02MCPSetupStdioChannel {
        try configuration.validate()
        guard configuration.transport == .stdio else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "This configuration is not an MCP stdio server.",
                                     retryable: false)
        }
        guard let saved = configuration.stdioBinding else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The saved stdio command has no current project/task binding.",
                                     retryable: false)
        }
        guard let taskID = saved.taskID else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The saved stdio server has no task binding.",
                                     retryable: false)
        }
        let liveEpoch = epoch ?? RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard liveEpoch > 0,
              RuntimeFacadeLinuxBindings.shared.boundNativeEpoch == liveEpoch,
              G02NativeRootEpoch.readback() == liveEpoch else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux generation is not bound; open the runtime setup and retry.",
                                     retryable: true)
        }
        guard RuntimeFacadeLinuxBindings.shared.isCapabilityQualified,
              RuntimeFacadeLinuxBindings.shared.components != nil else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux engine is not qualified for separated stdio.",
                                     retryable: true)
        }
        guard let context = await executionContexts.liveContext(
            forTask: taskID, projectID: saved.projectID) else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "No single live task run can own this stdio server; start the task and retry.",
                                     retryable: true)
        }
        guard context.conversationID == taskID else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The live execution context belongs to a different task.",
                                     retryable: false)
        }
        guard let resolved = await LinuxWorkspaceAuthority.resolveWorkspace(
            conversationID: taskID),
              resolved.workspaceID == context.workspaceID,
              resolved.rootURL.standardizedFileURL.path
                == context.workspaceRootURL.standardizedFileURL.path else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The task workspace changed; reopen the server binding.",
                                     retryable: true)
        }
        let rootURL = resolved.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard C01LinuxStdioLiveRunContext.isManagedProjectRoot(rootURL, projectID: saved.projectID) else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The selected workspace is not the bound project.",
                                     retryable: false)
        }
        // The C02 project root identity is the SHA256 of the canonical path.
        // Recompute it rather than trusting the saved string.
        let rootIdentity = C02MCPSetupWorkspaceStager.projectRootIdentity(rootURL)
        guard rootIdentity == saved.rootIdentity.lowercased(),
              saved.command == (configuration.stdioDefinition?.command ?? saved.command),
              saved.arguments == (configuration.stdioDefinition?.arguments ?? saved.arguments),
              saved.workingDirectory == (configuration.stdioDefinition?.workingDirectory
                                            ?? saved.workingDirectory) else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The saved stdio binding does not match its command definition.",
                                     retryable: false)
        }
        let configDigest = MCPServerConfigHash.digest(of: configuration)
        if let configRevisions {
            let current = await configRevisions.currentConfigDigest(serverID: configuration.id)
            guard current == configDigest else {
                throw C02MCPSetupFailure(.stdioUnavailable,
                                         message: "The server configuration changed before the channel opened.",
                                         retryable: true)
            }
        }
        let transport = self.transport ?? MailboxC01LinuxStdioTransport()
        let capability = await transport.capability(epoch: liveEpoch)
        guard capability.stdioAvailable,
              capability.serviceRoleAvailable,
              capability.stdioContractVersion == C01ManagedServiceDomain.stdioContractVersion else {
            throw C02MCPSetupFailure(
                .stdioUnavailable,
                message: "The running Linux helper does not provide the separated stdio component"
                    + (capability.detail.isEmpty ? "." : " (\(capability.detail))."),
                retryable: true)
        }
        let binding = C01LinuxStdioBinding(
            projectID: saved.projectID,
            engineProjectID: LinuxShellProjectMapping.projectID(
                forCanonicalCoreWorkspaceRoot: rootURL),
            environmentID: saved.environmentID,
            rootIdentity: rootIdentity,
            taskID: taskID,
            runID: context.runID,
            conversationID: context.conversationID,
            workspaceID: resolved.workspaceID,
            workspaceRootURL: rootURL,
            serverRevision: saved.revision,
            configDigest: configDigest,
            displayName: configuration.displayName,
            command: saved.command,
            arguments: saved.arguments,
            cwdRelative: saved.workingDirectory,
            acceptedEpoch: liveEpoch)
        let handle: C01LinuxStdioServiceHandle
        do {
            handle = try await domain.startStdioService(
                C01LinuxStdioStartRequest(binding: binding, timeoutSeconds: 86_400),
                transport: transport)
        } catch let failure as C01LinuxStdioFailure {
            throw Self.map(failure)
        } catch {
            // Domain refusals are typed FloeError values. They are surfaced as
            // the same stdio-unavailable code the C02 client already handles;
            // the message is bounded and contains no secret/path content.
            throw C02MCPSetupFailure(
                .stdioUnavailable,
                message: String(((error as? LocalizedError)?.errorDescription
                    ?? "The Linux separated stdio service was refused.").prefix(512)),
                retryable: true)
        }
        let validity: @Sendable () -> Bool = { [domain] in
            G02NativeRootEpoch.readback() == liveEpoch &&
                RuntimeFacadeLinuxBindings.shared.boundNativeEpoch == liveEpoch &&
                RuntimeFacadeLinuxBindings.shared.isCapabilityQualified &&
                domain.isStdioSessionCurrent(sessionID: handle.sessionID)
        }
        return C01MCPStdioChannel(
            configurationID: configuration.id,
            binding: binding,
            sessionID: handle.sessionID,
            transport: transport,
            validity: validity,
            configRevisions: configRevisions,
            onClosed: { [domain] sessionID, released in
                if released {
                    await domain.releaseStdioService(sessionID: sessionID)
                } else {
                    domain.continueStdioDrain(sessionID: sessionID)
                }
            })
    }
}

// MARK: - Channel

public actor C01MCPStdioChannel: C02MCPSetupStdioChannel, C02MCPSetupInvocationValidatingChannel {
    private let configurationID: UUID
    private let binding: C01LinuxStdioBinding
    private let sessionID: String
    private let transport: any C01LinuxStdioTransporting
    private let validity: @Sendable () -> Bool
    private let configRevisions: (any C01LinuxStdioConfigRevisionProviding)?
    private let onClosed: @Sendable (String, Bool) async -> Void
    private let closeReleaseBudget: TimeInterval

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrTruncated = false
    private var stdoutCursor: UInt64 = 0
    private var stderrCursor: UInt64 = 0
    private var stdoutEOF = false
    private var stderrEOF = false
    private var closed = false
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var readingLine = false
    private var polling = false
    private var pollWaiters: [CheckedContinuation<Void, Never>] = []

    private static let maximumStderrRetained = C02MCPSetupLimits.maximumStderrBytes
    private static let maximumStderrPage = 16_384
    private static let maximumWriteAttempts = 64
    private static let readPollNanos: UInt64 = 15_000_000

    public init(configurationID: UUID,
                binding: C01LinuxStdioBinding,
                sessionID: String,
                transport: any C01LinuxStdioTransporting,
                validity: @escaping @Sendable () -> Bool,
                configRevisions: (any C01LinuxStdioConfigRevisionProviding)? = nil,
                closeReleaseBudget: TimeInterval = 6,
                onClosed: @escaping @Sendable (String, Bool) async -> Void) {
        self.configurationID = configurationID
        self.binding = binding
        self.sessionID = sessionID
        self.transport = transport
        self.validity = validity
        self.configRevisions = configRevisions
        self.closeReleaseBudget = min(max(closeReleaseBudget, 0), 30)
        self.onClosed = onClosed
    }

    // MARK: C02MCPSetupStdioChannel

    public func write(_ data: Data) async throws {
        guard writeWaiters.count < 64 else {
            throw C02MCPSetupFailure(.stdioUnavailable, message: "The stdio write queue is busy.", retryable: true)
        }
        await acquireWrite()
        defer { releaseWrite() }
        try Task.checkCancellation()
        try await assertUsable()
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + MailboxC01LinuxStdioTransport.maximumWriteBytes, data.count)
            let page = data.subdata(in: offset..<end)
            var pageSent = 0
            var attempts = 0
            while pageSent < page.count {
                try Task.checkCancellation()
                try await assertUsable()
                let chunk = page.subdata(in: pageSent..<page.count)
                let reply = try await writePage(chunk)
                guard reply.acceptedBytes >= 0, reply.acceptedBytes <= chunk.count else {
                    await failClosed()
                    throw C02MCPSetupFailure(.stdioResponseInvalid, message: "The stdio write receipt is invalid.", retryable: false)
                }
                if let errno = reply.errnoCode, errno != 0 && errno != 11 {
                    throw C02MCPSetupFailure(
                        .stdioUnavailable,
                        message: "The Linux stdio stdin pipe is closed (errno \(errno)).",
                        retryable: true)
                }
                if reply.acceptedBytes > 0 {
                    pageSent += reply.acceptedBytes
                    attempts = 0
                    continue
                }
                attempts += 1
                if attempts > Self.maximumWriteAttempts {
                    throw C02MCPSetupFailure(
                        .stdioTimeout,
                        message: "The Linux stdio stdin pipe accepted no bytes within the bounded retry window.",
                        retryable: true)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            offset = end
        }
    }

    private func acquireWrite() async {
        if !writing { writing = true; return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func releaseWrite() {
        if writeWaiters.isEmpty { writing = false }
        else { writeWaiters.removeFirst().resume() }
    }

    public func readLine(maxBytes: Int, timeout: TimeInterval) async throws -> Data? {
        guard !readingLine else {
            throw C02MCPSetupFailure(.stdioUnavailable, message: "A stdio reader is already waiting.", retryable: true)
        }
        readingLine = true
        defer { readingLine = false }
        let cap = min(max(maxBytes, 1), C02MCPSetupLimits.maximumStdioLineBytes)
        let deadline = Date().addingTimeInterval(max(0.05, min(timeout, 120)))
        while true {
            try await assertUsable()
            if let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
                stdoutBuffer.removeFirst(stdoutBuffer.distance(
                    from: stdoutBuffer.startIndex, to: newline) + 1)
                if line.count > cap {
                    await failClosed()
                    throw C02MCPSetupFailure(.stdioResponseInvalid,
                                             message: "A stdio reply line exceeded the supported bound.",
                                             retryable: false)
                }
                return Self.stripCarriageReturn(line)
            }
            if stdoutEOF {
                if stdoutBuffer.isEmpty { return nil }
                await failClosed()
                throw C02MCPSetupFailure(
                    .stdioResponseInvalid,
                    message: "The stdio peer closed stdout in the middle of a reply line.",
                    retryable: false)
            }
            if stdoutBuffer.count > cap {
                await failClosed()
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "A stdio reply line exceeded the supported bound.",
                                         retryable: false)
            }
            if Date() >= deadline {
                throw C02MCPSetupFailure(.stdioTimeout,
                                         message: "The stdio server did not reply within the request timeout.",
                                         retryable: true)
            }
            let poll: C01LinuxStdioPollReply
            do {
                poll = try await pollStreams(C01LinuxStdioPollRequest(
                    sessionID: sessionID,
                    stdoutCursor: stdoutCursor,
                    stderrCursor: stderrCursor,
                    maxBytes: min(MailboxC01LinuxStdioTransport.maximumPageBytes, cap)))
            } catch {
                // A desynchronized stdout can never be resynchronized: stop the
                // owned process, fence the channel and surface the failure.
                await failClosed()
                throw error
            }
            if poll.leaseReleased {
                // The real terminal was proven: the next iteration returns a
                // complete buffered line or a real EOF. Never fabricate bytes.
                stdoutEOF = true
                stderrEOF = true
            }
            if poll.stdout.isEmpty && poll.stderr.isEmpty && !poll.leaseReleased {
                try? await Task.sleep(nanoseconds: Self.readPollNanos)
            }
        }
    }

    public func drainStderr(maxBytes: Int) async -> Data {
        let cap = min(max(maxBytes, 1), C02MCPSetupLimits.maximumStderrBytes)
        // Drain a few nonblocking pages so diagnostics written while the
        // caller was idle are not silently lost. This never blocks the close.
        for _ in 0..<4 {
            do {
                let poll = try await pollStreams(C01LinuxStdioPollRequest(
                    sessionID: sessionID,
                    stdoutCursor: stdoutCursor,
                    stderrCursor: stderrCursor,
                    maxBytes: Self.maximumStderrPage))
                if poll.leaseReleased {
                    stdoutEOF = true
                    stderrEOF = true
                }
                if poll.stderr.isEmpty || poll.stderrEOF { break }
            } catch {
                await failClosed()
                break
            }
        }
        let take = min(cap, stderrBuffer.count)
        let value = stderrBuffer.prefix(take)
        stderrBuffer.removeFirst(take)
        return Data(value)
    }

    public func validateInvocation(runID: UUID, taskID: UUID) async throws {
        try await assertUsable()
        guard binding.runID == runID, binding.conversationID == taskID else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                message: "This MCP process belongs to another task run. Reconnect it in the current task.", retryable: true)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        // Release stdin first (real EOF) and request the exact owned stop.
        _ = try? await closeStdinPipe()
        try? await requestOwnedStop()
        let deadline = Date().addingTimeInterval(closeReleaseBudget)
        var released = false
        while Date() < deadline {
            do {
                let poll = try await pollStreams(C01LinuxStdioPollRequest(
                    sessionID: sessionID,
                    stdoutCursor: stdoutCursor,
                    stderrCursor: stderrCursor,
                    maxBytes: 1))
                stdoutCursor = poll.stdoutCursor
                stderrCursor = poll.stderrCursor
                if poll.leaseReleased { released = true; break }
            } catch {
                // The generation may already be fenced: the domain record and
                // root drain retain the real ownership. A close NEVER claims a
                // stop it could not prove.
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await onClosed(sessionID, released)
    }

    /// True when the bounded diagnostic ring had to discard older stderr
    /// bytes. Diagnostic only; stderr never becomes protocol data.
    public var stderrWasTruncated: Bool { stderrTruncated }

    // MARK: Typed transport wrappers

    private func writePage(_ data: Data) async throws -> C01LinuxStdioWriteReply {
        do {
            return try await transport.write(sessionID: sessionID, data: data)
        } catch let failure as C01LinuxStdioFailure {
            throw Self.map(failure)
        } catch {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio write did not settle.",
                                     retryable: true)
        }
    }

    private func pollStreams(_ request: C01LinuxStdioPollRequest) async throws
        -> C01LinuxStdioPollReply {
        guard pollWaiters.count < 64 else {
            throw C02MCPSetupFailure(.stdioUnavailable, message: "The stdio read queue is busy.", retryable: true)
        }
        if polling { await withCheckedContinuation { pollWaiters.append($0) } }
        else { polling = true }
        defer {
            if pollWaiters.isEmpty { polling = false }
            else { pollWaiters.removeFirst().resume() }
        }
        do {
            let current = C01LinuxStdioPollRequest(sessionID: sessionID,
                stdoutCursor: stdoutCursor, stderrCursor: stderrCursor, maxBytes: request.maxBytes)
            let reply = try await transport.poll(current)
            guard reply.sessionID == sessionID else {
                throw C02MCPSetupFailure(.stdioResponseInvalid, message: "A stdio reply addressed a different session.", retryable: false)
            }
            if closed {
                stdoutCursor = reply.stdoutCursor
                stderrCursor = reply.stderrCursor
            } else {
                try consume(reply)
            }
            return reply
        } catch let failure as C02MCPSetupFailure {
            throw failure
        } catch let failure as C01LinuxStdioFailure {
            throw Self.map(failure)
        } catch {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio read did not settle.",
                                     retryable: true)
        }
    }

    private func closeStdinPipe() async throws -> C01LinuxStdioStdinEofReply {
        do {
            return try await transport.closeStdin(sessionID: sessionID)
        } catch let failure as C01LinuxStdioFailure {
            throw Self.map(failure)
        } catch {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio stdin close did not settle.",
                                     retryable: true)
        }
    }

    private func requestOwnedStop() async throws {
        do {
            try await transport.requestStop(sessionID: sessionID)
        } catch let failure as C01LinuxStdioFailure {
            throw Self.map(failure)
        } catch {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio stop request did not settle.",
                                     retryable: true)
        }
    }

    private static func map(_ failure: C01LinuxStdioFailure) -> C02MCPSetupFailure {
        switch failure.code {
        case .timedOut:
            return C02MCPSetupFailure(.stdioTimeout, message: failure.message,
                                      retryable: failure.retryable)
        case .lineTooLong, .streamDesynchronized, .pipeClosed, .protocolViolation:
            return C02MCPSetupFailure(.stdioResponseInvalid, message: failure.message,
                                      retryable: failure.retryable)
        case .unavailable, .staleGeneration, .invalidConfiguration,
             .workspaceMismatch, .executionContextUnavailable, .writeFailed:
            return C02MCPSetupFailure(.stdioUnavailable, message: failure.message,
                                      retryable: failure.retryable)
        }
    }

    // MARK: Internals

    private func assertUsable() async throws {
        guard !closed else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio channel is closed.",
                                     retryable: true)
        }
        guard validity() else {
            await failClosed()
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux generation changed while the stdio channel was open.",
                                     retryable: true)
        }
        if let configRevisions {
            let current = await configRevisions.currentConfigDigest(serverID: configurationID)
            guard !closed, validity(), current == binding.configDigest else {
                await failClosed()
                throw C02MCPSetupFailure(.stdioUnavailable,
                                         message: "The server configuration changed; this stdio channel is stale.",
                                         retryable: true)
            }
        }
    }

    private func consume(_ poll: C01LinuxStdioPollReply) throws {
        guard poll.sessionID == sessionID else {
            throw C02MCPSetupFailure(.stdioResponseInvalid,
                                     message: "A stdio reply addressed a different session.",
                                     retryable: false)
        }
        if poll.stdoutGapBytes > 0 {
            throw C02MCPSetupFailure(
                .stdioResponseInvalid,
                message: "The stdout stream lost bytes; the reply framing cannot be trusted.",
                retryable: false)
        }
        if !poll.stdout.isEmpty {
            guard stdoutBuffer.count <= C02MCPSetupLimits.maximumStdioLineBytes * 2 - poll.stdout.count else {
                throw C02MCPSetupFailure(.stdioResponseInvalid, message: "The stdio receive buffer is full.", retryable: false)
            }
            stdoutBuffer.append(poll.stdout)
        }
        stdoutCursor = poll.stdoutCursor
        stdoutEOF = stdoutEOF || poll.stdoutEOF
        if !poll.stderr.isEmpty {
            appendStderr(poll.stderr)
        }
        stderrCursor = poll.stderrCursor
        stderrEOF = stderrEOF || poll.stderrEOF
        if poll.stderrGapBytes > 0 {
            // stderr is a bounded diagnostic stream, not protocol: a gap is
            // surfaced as truncation, never as fatal desynchronization.
            stderrTruncated = true
        }
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.maximumStderrRetained {
            let excess = stderrBuffer.count - Self.maximumStderrRetained
            stderrBuffer.removeFirst(excess)
            stderrTruncated = true
        }
    }

    private static func stripCarriageReturn(_ line: Data) -> Data {
        guard line.last == 0x0D else { return line }
        var copy = line
        copy.removeLast()
        return copy
    }

    /// Close the owned process and fence the channel. The domain record is
    /// retained until the runtime proves release; a failed read or stop
    /// request cannot erase ownership of a process that may still be running.
    private func failClosed() async {
        guard !closed else { return }
        closed = true
        try? await requestOwnedStop()
        await onClosed(sessionID, false)
    }
}

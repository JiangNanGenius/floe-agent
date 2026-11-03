// SPDX-License-Identifier: MPL-2.0
//
// C02 — production composition for the guided MCP setup domain.
//
// Main calls `install` once per accepted root generation from its OWN
// composition (after the MCP domain, durable job service, environment
// authority and qualified transport admission exist). This file creates no
// second registry, no second database, no second MCP client and no service
// subprocess:
//
//   * dependency/build phases submit the ORIGINAL `exec.shell` durable job
//     through `BackgroundJobService.submit` with `.nativeService`, the
//     caller's real run/conversation identity, the explicit environmentID
//     and the project workspace root;
//   * verification constructs the ORIGINAL transport-neutral
//     `MCPClientMaking` client (HTTP or the stdio adapter) and obeys the SAME
//     transport admission;
//   * the C02 stdio adapter conforms to the ORIGINAL `MCPClientTransporting`
//     surface, so discovery/tools/call/cancel run through the same
//     `MCPDomain`/`MCPRemoteToolSource` lifecycle. The adapter is selected by
//     `OriginalMCPClientFactory` only for a `.stdio` configuration;
//   * the final connection commit rides the ORIGINAL `MCPDomain.save`
//     no-secret clear/create path (auth-free loopback server);
//   * the long-lived Linux service process/readiness and the separated
//     stdin/stdout/stderr pipe remain explicit C01 capabilities. When absent
//     they stay typed unavailable; nothing here fabricates a running service
//     or a PTY-backed JSON-RPC peer.
import Foundation
import FloeCore
import FloeTools
import FloeSkills
import FloeEnvironments
import FloePersistence
import FloeAndroidJobTools

// MARK: - Trusted setup execution context

/// A real App-owned setup run in the selected project environment. It is
/// minted by the trusted composition (C01/Main), never by the model or the
/// feature UI. The domain refuses to submit a job without it.
public struct C02MCPSetupExecutionContext: Sendable {
    public let runID: UUID
    public let conversationID: UUID
    public let workspaceRootURL: URL
    public let environmentID: String
    public let cancellation: CancellationToken

    public init(runID: UUID, conversationID: UUID, workspaceRootURL: URL,
                environmentID: String, cancellation: CancellationToken) {
        self.runID = runID
        self.conversationID = conversationID
        self.workspaceRootURL = workspaceRootURL
        self.environmentID = environmentID
        self.cancellation = cancellation
    }
}

public protocol C02MCPSetupExecutionContextProviding: Sendable {
    func prepare(binding: C02MCPSetupBinding, expectedProjectRevision: String) async throws -> String?
    func context(for binding: C02MCPSetupBinding) async throws -> C02MCPSetupExecutionContext
    func submissionStarted(recordID: UUID) async throws
    func submissionFinished(recordID: UUID, jobID: UUID?) async
    func finish(recordID: UUID) async throws
}

public extension C02MCPSetupExecutionContextProviding {
    func prepare(binding: C02MCPSetupBinding, expectedProjectRevision: String) async throws -> String? { nil }
    func submissionStarted(recordID: UUID) async throws {}
    func submissionFinished(recordID: UUID, jobID: UUID?) async {}
    func finish(recordID: UUID) async throws {}
}

// MARK: - Job-backed dependency executor

public struct C02MCPSetupJobCommandExecutor: C02MCPSetupCommandExecuting {
    private let jobs: BackgroundJobService
    private let contexts: any C02MCPSetupExecutionContextProviding

    public init(jobs: BackgroundJobService,
                contexts: any C02MCPSetupExecutionContextProviding) {
        self.jobs = jobs
        self.contexts = contexts
    }

    public func prepare(binding: C02MCPSetupBinding, expectedProjectRevision: String) async throws -> String? {
        try await contexts.prepare(binding: binding, expectedProjectRevision: expectedProjectRevision)
    }

    public func finish(recordID: UUID) async throws {
        try await contexts.finish(recordID: recordID)
    }

    public func submit(recordID: UUID, step: C02MCPSetupStep, payload: Data,
                       binding: C02MCPSetupBinding) async throws -> C02MCPSetupCommandHandle {
        let context = try await contexts.context(for: binding)
        let contextRoot = context.workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let bindingRoot = binding.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard context.environmentID == binding.environmentID,
              contextRoot.path == bindingRoot.path else {
            throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                     message: "The setup execution context is not bound to this project environment.",
                                     retryable: false)
        }
        guard C02MCPSetupBuildPlan.expectedPayload(
            recordID: recordID, step: step.name,
            workspaceRelativePath: binding.workspaceRelativePath)
            .map({ C02MCPSetupBuildPlan.payloadMatches(payload, expected: $0) }) == true else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The dependency command does not match the reviewed build step.",
                                     retryable: false)
        }
        try await contexts.submissionStarted(recordID: recordID)
        let job: BackgroundJob
        do {
            job = try await jobs.submit(
                runID: context.runID,
                toolCallID: step.callID,
                targetTool: "exec.shell",
                payloadJSON: payload,
                scope: .local,
                workspaceRootURL: context.workspaceRootURL,
                allowedWorkspacePaths: [],
                environmentID: context.environmentID,
                allowedToolNames: nil,
                submissionSource: .nativeService,
                waitForCompletion: false)
        } catch {
            await contexts.submissionFinished(recordID: recordID, jobID: nil)
            throw C02MCPSetupFailure(.buildStepFailed,
                                     message: "The Linux dependency job could not be submitted.",
                                     retryable: true)
        }
        await contexts.submissionFinished(recordID: recordID, jobID: job.id)
        guard job.runID == context.runID,
              job.conversationID == context.conversationID,
              job.environmentID == context.environmentID,
              job.targetTool == "exec.shell",
              job.toolCallID == step.callID,
              job.workspaceRootPath == contextRoot.path,
              actualPayloadMatches(job.payloadJSON, expected: payload) else {
            throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                     message: "The dependency job did not bind this setup record.",
                                     retryable: false)
        }
        return C02MCPSetupCommandHandle(
            recordID: recordID,
            jobID: job.id,
            callID: step.callID,
            runID: context.runID,
            conversationID: context.conversationID,
            environmentID: context.environmentID,
            rootIdentity: binding.rootIdentity,
            workspaceRootPath: contextRoot.path,
            payloadDigest: SignedContentArchive.sha256Hex(payload))
    }

    public func state(_ handle: C02MCPSetupCommandHandle) async -> C02MCPSetupCommandResult {
        let job: BackgroundJob?
        do {
            job = try await jobs.job(id: handle.jobID)
        } catch {
            return failed(.jobOwnershipMismatch, "The dependency job could not be read.")
        }
        guard let job,
              job.runID == handle.runID,
              job.conversationID == handle.conversationID,
              job.environmentID == handle.environmentID,
              job.workspaceRootPath == handle.workspaceRootPath,
              job.targetTool == "exec.shell",
              job.toolCallID == handle.callID,
              SignedContentArchive.sha256Hex(job.payloadJSON) == handle.payloadDigest else {
            return failed(.jobOwnershipMismatch, "The dependency job is no longer owned by this setup record.")
        }
        let exit = Self.parseExit(job.resultSummary)
        let summary = job.resultSummary ?? ""
        switch job.state {
        case .queued:
            return C02MCPSetupCommandResult(
                state: .queued, exitCode: nil, summary: summary,
                outputDigest: job.resultDigest, outputBytes: job.outputBytes,
                errorCode: nil, errorMessage: nil)
        case .running:
            return C02MCPSetupCommandResult(
                state: .running, exitCode: nil, summary: summary,
                outputDigest: job.resultDigest, outputBytes: job.outputBytes,
                errorCode: nil, errorMessage: nil)
        case .completed:
            return C02MCPSetupCommandResult(
                state: .completed, exitCode: exit, summary: summary,
                outputDigest: job.resultDigest ?? SignedContentArchive.sha256Hex(Data(summary.utf8)),
                outputBytes: job.outputBytes ?? summary.utf8.count,
                errorCode: nil, errorMessage: nil)
        case .cancelled:
            return C02MCPSetupCommandResult(
                state: .cancelled, exitCode: exit, summary: summary,
                outputDigest: job.resultDigest, outputBytes: job.outputBytes,
                errorCode: "cancelled", errorMessage: nil)
        case .failed, .interrupted:
            return C02MCPSetupCommandResult(
                state: .failed, exitCode: exit, summary: summary,
                outputDigest: job.resultDigest, outputBytes: job.outputBytes,
                errorCode: job.state.rawValue,
                errorMessage: "The dependency job did not complete.")
        }
    }

    public func cancel(_ handle: C02MCPSetupCommandHandle) async throws {
        guard let job = try? await jobs.job(id: handle.jobID),
              job.runID == handle.runID,
              job.conversationID == handle.conversationID,
              job.environmentID == handle.environmentID,
              job.workspaceRootPath == handle.workspaceRootPath,
              job.toolCallID == handle.callID,
              SignedContentArchive.sha256Hex(job.payloadJSON) == handle.payloadDigest else {
            throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                     message: "The dependency job is no longer owned by this setup record.",
                                     retryable: false)
        }
        _ = try? await jobs.cancel(id: handle.jobID)
        // Cancellation is a REQUEST until the processor acknowledges. Do not
        // let the setup UI claim "stopped" while the job is still live.
        for _ in 0..<150 {
            if let current = try? await jobs.job(id: handle.jobID),
               current.state.isTerminal {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                 message: "The dependency job did not drain after cancellation.",
                                 retryable: true)
    }

    private func failed(_ code: C02MCPSetupFailure.Code,
                        _ message: String) -> C02MCPSetupCommandResult {
        C02MCPSetupCommandResult(
            state: .failed, exitCode: nil, summary: "",
            outputDigest: nil, outputBytes: nil,
            errorCode: code.rawValue, errorMessage: message)
    }

    private func actualPayloadMatches(_ data: Data, expected: Data) -> Bool {
        C02MCPSetupBuildPlan.payloadMatches(data, expected: expected)
    }

    static func parseExit(_ summary: String?) -> Int? {
        guard let summary else { return nil }
        for token in summary.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if token.hasPrefix("exit=") {
                return Int(token.dropFirst(5).prefix(8))
            }
        }
        return nil
    }
}

// MARK: - ORIGINAL MCP client verification

public struct C02MCPSetupMCPDiscoveryProbe: C02MCPSetupDiscoveryProbing {
    private let factory: any MCPClientMaking
    private let admission: any MCPTransportAdmitting

    public init(factory: any MCPClientMaking,
                admission: any MCPTransportAdmitting) {
        self.factory = factory
        self.admission = admission
    }

    public func verify(endpoint: URL, displayName: String) async throws -> C02MCPSetupVerification {
        guard admission.admitsMCPNetwork else {
            throw C02MCPSetupFailure(.verificationFailed,
                                     message: "MCP network transport is not admitted in this build.",
                                     retryable: true)
        }
        let configuration = MCPServerConfiguration(
            displayName: displayName,
            endpoint: endpoint,
            enabled: true,
            allowInCanvas: false,
            allowInsecureHTTP: true,
            authentication: .none,
            timeoutSeconds: 30)
        do {
            try configuration.validate()
        } catch {
            throw C02MCPSetupFailure(.verificationFailed,
                                     message: "The loopback MCP endpoint is not a valid configuration.",
                                     retryable: false)
        }
        let client: any MCPClientTransporting
        do {
            client = try await factory.make(configuration: configuration, credential: nil)
        } catch {
            throw C02MCPSetupFailure(.verificationFailed,
                                     message: "The MCP client could not be created.",
                                     retryable: true)
        }
        do {
            let tools = try await client.discoverTools()
            guard let status = tools.first(where: { $0.remoteName == "service_status" }),
                  status.readOnlyHint, !status.destructiveHint else {
                await client.disconnectTransport()
                throw C02MCPSetupFailure(.smokeTestFailed,
                                         message: "The MCP service did not advertise its fixed read-only status tool.",
                                         retryable: false)
            }
            let output = try await client.callTool(
                name: "service_status",
                argumentsJSON: Data(#"{"label":"floe-native-verification"}"#.utf8))
            guard output.exitStatus == 0,
                  let value = try JSONSerialization.jsonObject(
                    with: Data(output.summary.utf8)) as? [String: String],
                  value["status"] == "ready",
                  value["service"] == "floe-mcp-service",
                  value["label"] == "floe-native-verification" else {
                await client.disconnectTransport()
                throw C02MCPSetupFailure(.smokeTestFailed,
                                         message: "The MCP service did not pass its real client smoke test.",
                                         retryable: false)
            }
            await client.disconnectTransport()
            return C02MCPSetupVerification(
                endpoint: endpoint.absoluteString,
                toolNames: tools.map(\.remoteName),
                smokeTool: "service_status",
                smokeDigest: output.fullOutputSHA256,
                protocolEra: "streamable-http")
        } catch let failure as C02MCPSetupFailure {
            await client.disconnectTransport()
            throw failure
        } catch {
            await client.disconnectTransport()
            throw C02MCPSetupFailure(.verificationFailed,
                                     message: (error as? LocalizedError)?.errorDescription
                                        ?? "The MCP client could not verify the service.",
                                     retryable: true)
        }
    }
}

// MARK: - C01 separated stdio pipe (original MCP transport)

/// The C01 Linux session lane owns the real child process and its three
/// distinct byte streams. C02 never starts a process, never allocates a PTY
/// and never merges stderr into stdout. An implementation must fence the
/// channel to the exact project/environment/root/task/revision binding in the
/// configuration; closing or replacing that binding makes every in-flight
/// reply stale.
public protocol C02MCPSetupStdioChannelProviding: Sendable {
    func openChannel(
        for configuration: MCPServerConfiguration
    ) async throws -> any C02MCPSetupStdioChannel
}

/// Honest absence of the C01 lane. It answers the same typed code the setup
/// surface uses; no host subprocess or `exec.localService` fallback exists.
public struct C02MCPSetupStdioUnavailable: C02MCPSetupStdioChannelProviding {
    public init() {}

    public func openChannel(
        for configuration: MCPServerConfiguration
    ) async throws -> any C02MCPSetupStdioChannel {
        throw C02MCPSetupFailure(.stdioUnavailable,
                                 message: "The Linux separated stdio pipe is not available in this build.",
                                 retryable: true)
    }
}

/// Adapts the ORIGINAL MCP client lifecycle (`discoverTools`/`callTool`/
/// cancel) onto the newline-delimited JSON-RPC client over the C01 pipe.
/// The actor serializes initialization, cancellation and close; a late
/// reply after close is refused by the C02 client's closed/live checks.
public actor C02MCPStdioTransport: MCPClientTransporting, MCPExecutionContextValidating {
    private let invocationChannel: any C02MCPSetupStdioChannel
    private let client: C02MCPStdioClient
    private let timeoutSeconds: TimeInterval
    private var initialized = false
    private var disconnected = false

    public init(configuration: MCPServerConfiguration,
                binding: MCPServerConfiguration.StdioBinding,
                channel: any C02MCPSetupStdioChannel,
                isLive: @escaping @Sendable () -> Bool) throws {
        guard configuration.transport == .stdio else {
            throw FloeError.invalidConfiguration("A stdio channel requires the stdio transport")
        }
        guard configuration.authentication == .none else {
            throw FloeError.invalidConfiguration(
                "MCP stdio servers do not accept transport credentials")
        }
        let stdioConfig = C02MCPSetupStdioConfig(
            projectID: binding.projectID,
            environmentID: binding.environmentID,
            rootIdentity: binding.rootIdentity,
            taskID: binding.taskID,
            serverRevision: binding.revision,
            displayName: configuration.displayName,
            command: binding.command,
            arguments: binding.arguments,
            cwdRelative: binding.workingDirectory)
        self.invocationChannel = channel
        self.client = C02MCPStdioClient(config: stdioConfig,
                                        channel: channel,
                                        isLive: isLive)
        self.timeoutSeconds = configuration.timeoutSeconds
    }

    public func validateInvocation(context: ToolContext) async throws {
        guard !disconnected, let taskID = context.conversationID,
              let validator = invocationChannel as? any C02MCPSetupInvocationValidatingChannel else {
            throw MCPClientError.transportUnavailable("The local MCP execution binding is unavailable.")
        }
        try await validator.validateInvocation(runID: context.runID, taskID: taskID)
    }

    public func discoverTools() async throws -> [MCPDiscoveredTool] {
        guard !disconnected else { throw MCPClientError.disconnected }
        do {
            try await initializeIfNeeded()
            return try await client.listTools(timeout: timeoutSeconds)
        } catch let failure as C02MCPSetupFailure {
            throw Self.map(failure)
        }
    }

    public func callTool(name: String, argumentsJSON: Data) async throws -> ToolExecutionOutput {
        guard !disconnected else { throw MCPClientError.disconnected }
        do {
            try await initializeIfNeeded()
            return try await client.callTool(name: name, argumentsJSON: argumentsJSON,
                                             timeout: timeoutSeconds)
        } catch let failure as C02MCPSetupFailure {
            throw Self.map(failure)
        }
    }

    public func disconnectTransport() async {
        guard !disconnected else { return }
        disconnected = true
        initialized = false
        await client.close()
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        _ = try await client.initialize(timeout: timeoutSeconds)
        initialized = true
    }

    private static func map(_ failure: C02MCPSetupFailure) -> MCPClientError {
        switch failure.code {
        case .stdioUnavailable:
            return .transportUnavailable(failure.message)
        case .stdioTimeout:
            return .timedOut(phase: "stdio")
        case .stdioProtocolMismatch, .stdioResponseInvalid:
            return .invalidResponse(failure.message)
        case .invalidRequest:
            return .invalidResponse(failure.message)
        default:
            return .invalidResponse(failure.message)
        }
    }
}

/// The ORIGINAL `MCPStdioClientMaking` implementation. It is constructed by
/// Main's trusted composition with the C01 channel provider and the accepted
/// root epoch; the `OriginalMCPClientFactory` selects it only for a stdio
/// configuration. With no provider the configuration stays persisted but
/// every connect fails closed with `transportUnavailable`.
public struct C02MCPSetupStdioClientFactory: MCPStdioClientMaking {
    private let epoch: UInt64
    private let provider: (any C02MCPSetupStdioChannelProviding)?

    public init(epoch: UInt64,
                provider: (any C02MCPSetupStdioChannelProviding)? = nil) {
        self.epoch = epoch
        self.provider = provider
    }

    public func makeClient(
        configuration: MCPServerConfiguration,
        credential: String?
    ) async throws -> any MCPClientTransporting {
        guard configuration.transport == .stdio else {
            throw FloeError.invalidConfiguration("MCP server is not a stdio configuration")
        }
        guard let binding = configuration.stdioBinding else {
            throw MCPClientError.transportUnavailable(
                "The saved MCP stdio command has no current project environment binding.")
        }
        try configuration.validate()
        guard configuration.authentication == .none,
              credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw FloeError.invalidConfiguration(
                "MCP stdio servers do not accept transport credentials")
        }
        guard let provider else {
            throw MCPClientError.transportUnavailable(
                "The Linux separated stdio pipe is not available in this build.")
        }
        let channel: any C02MCPSetupStdioChannel
        do {
            channel = try await provider.openChannel(for: configuration)
        } catch let failure as C02MCPSetupFailure {
            throw MCPClientError.transportUnavailable(failure.message)
        }
        return try C02MCPStdioTransport(
            configuration: configuration,
            binding: binding,
            channel: channel,
            isLive: { G02NativeRootEpoch.readback() == epoch })
    }
}

// MARK: - ORIGINAL MCP domain save

public struct C02MCPSetupMCPDomainCommitter: C02MCPSetupConnectionCommitting {
    private let domain: MCPDomain

    public init(domain: MCPDomain) {
        self.domain = domain
    }

    public func commit(_ configuration: MCPServerConfiguration) async throws -> C02MCPSetupConnectionReceipt {
        guard configuration.transport == .streamableHTTP,
              let committedEndpoint = configuration.endpoint else {
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "Only an auth-free loopback HTTP MCP service is committed by this setup flow.",
                                     retryable: false)
        }
        if let existing = await existingRevision(for: configuration.id) {
            if existing.endpoint == committedEndpoint,
               existing.authentication == .none,
               existing.allowInsecureHTTP,
               existing.enabled {
                return C02MCPSetupConnectionReceipt(
                    serverID: configuration.id, revision: existing.revision)
            }
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "An MCP server with this identity already exists with different settings.",
                                     retryable: false)
        }
        let candidate: [String: Any] = [
            "id": configuration.id.uuidString,
            "displayName": configuration.displayName,
            "endpoint": committedEndpoint.absoluteString,
            "enabled": configuration.enabled,
            "allowInCanvas": configuration.allowInCanvas,
            "allowInsecureHTTP": configuration.allowInsecureHTTP,
            "authentication": configuration.authentication.rawValue,
            "credentialHeaderName": configuration.credentialHeaderName,
            "timeoutSeconds": configuration.timeoutSeconds,
            "disabledRemoteToolNames": [String](),
            "createIntent": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]) else {
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "The MCP connection candidate could not be encoded.",
                                     retryable: false)
        }
        let reply = await domain.save(candidateJSON: data, secretIntent: "clear",
                                      envelopeRevision: nil)
        if let reason = (reply["reason"] as? String) ?? (reply["errorCode"] as? String) {
            // A concurrent/replayed save may have committed first. Re-read
            // the real row; never claim success from the error string.
            if let existing = await existingRevision(for: configuration.id),
               existing.endpoint == committedEndpoint,
               existing.authentication == .none,
               existing.allowInsecureHTTP {
                return C02MCPSetupConnectionReceipt(
                    serverID: configuration.id, revision: existing.revision)
            }
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "The MCP connection could not be saved (\(String(reason.prefix(64)))).",
                                     retryable: false)
        }
        guard reply["state"] as? String == "committed",
              let serverIDString = reply["serverID"] as? String,
              UUID(uuidString: serverIDString) == configuration.id else {
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "The MCP connection save did not return the committed identity.",
                                     retryable: true)
        }
        let revision = (reply["revision"] as? [String: Any])?["version"] as? String
        return C02MCPSetupConnectionReceipt(
            serverID: configuration.id, revision: revision)
    }

    private func existingRevision(for id: UUID) async -> (endpoint: URL, authentication: MCPServerConfiguration.Authentication, allowInsecureHTTP: Bool, enabled: Bool, revision: String?)? {
        let reply = (try? await domain.list(cursor: nil)) ?? [:]
        guard let servers = reply["servers"] as? [[String: Any]] else { return nil }
        for row in servers {
            guard (row["id"] as? String) == id.uuidString,
                  let endpointString = row["endpoint"] as? String,
                  let endpoint = URL(string: endpointString),
                  let authenticationString = row["authentication"] as? String,
                  let authentication = MCPServerConfiguration.Authentication(rawValue: authenticationString) else {
                continue
            }
            let revision = (row["revision"] as? [String: Any])?["version"] as? String
            return (endpoint, authentication,
                    (row["allowInsecureHTTP"] as? Bool) ?? false,
                    (row["enabled"] as? Bool) ?? false,
                    revision)
        }
        return nil
    }
}

// MARK: - Explicit project/environment catalogs (no first-project fallback)

public protocol C02MCPSetupEnvironmentListing: Sendable {
    func environments(ownerID: String) async -> [C02MCPSetupEnvironmentFacts]
    func environments(project: C02MCPSetupProject) async -> [C02MCPSetupEnvironmentFacts]
}

public extension C02MCPSetupEnvironmentListing {
    func environments(project: C02MCPSetupProject) async -> [C02MCPSetupEnvironmentFacts] {
        await environments(ownerID: C02MCPSetupWorkspaceStager.projectRootIdentity(project.rootURL))
    }
}

/// Honest absence of the C01 Linux environment registry. Project listing
/// still works through the C01 project library; environment selection remains
/// empty until the trusted composition supplies the real registry.
public struct C02MCPSetupUnavailableEnvironmentProvider: C02MCPSetupEnvironmentListing,
    C02MCPSetupEnvironmentProviding {
    public init() {}

    public func environment(id: String) async -> C02MCPSetupEnvironmentFacts? { nil }

    public func environments(ownerID: String) async -> [C02MCPSetupEnvironmentFacts] { [] }
}

/// Honest absence of the App-owned setup run/conversation context. Build
/// phases fail typed before any job is submitted; this is not a success.
public struct C02MCPSetupUnavailableExecutionContextProvider:
    C02MCPSetupExecutionContextProviding {
    public init() {}

    public func context(for binding: C02MCPSetupBinding) async throws
        -> C02MCPSetupExecutionContext {
        throw C02MCPSetupFailure(.buildStepFailed,
                                 message: "The App-owned MCP setup execution context is not available in this build.",
                                 retryable: true)
    }
}

/// Reads the ORIGINAL `EnvironmentRegistry` records. It never creates,
/// boots or mutates an environment, and only the explicit project-owner set
/// is returned to the wizard.
public struct C02MCPSetupEnvironmentRegistryProvider: C02MCPSetupEnvironmentListing,
    C02MCPSetupEnvironmentProviding {
    private let registry: EnvironmentRegistry

    public init(registry: EnvironmentRegistry) {
        self.registry = registry
    }

    public func environment(id: String) async -> C02MCPSetupEnvironmentFacts? {
        guard let record = await registry.record(id: id) else { return nil }
        return Self.facts(record)
    }

    public func environments(ownerID: String) async -> [C02MCPSetupEnvironmentFacts] {
        await registry.all()
            .filter {
                $0.kind == .project && $0.ownerID == ownerID &&
                $0.state == .active && !$0.requiresRebuild &&
                $0.effectiveExecutionBackend == .linuxPRoot
            }
            .map(Self.facts)
    }

    private static func facts(_ record: ContainerRecord) -> C02MCPSetupEnvironmentFacts {
        C02MCPSetupEnvironmentFacts(
            id: record.id,
            label: record.name ?? record.id,
            kind: record.kind.rawValue,
            ownerID: record.ownerID,
            state: record.state.rawValue,
            requiresRebuild: record.requiresRebuild,
            backend: record.effectiveExecutionBackend.rawValue,
            containerID: record.id,
            baseRevision: record.baseRevision,
            layerFormat: record.layerFormat)
    }
}

/// Reads explicit managed projects from the ORIGINAL C01 project library and
/// computes each project's managed root. The root path is never persisted in
/// setup records; only its SHA-256 identity is.
public struct C02MCPSetupProjectCatalogAdapter: C02MCPSetupProjectProviding {
    private let library: C01ProjectLibrary
    private let rootPath: String
    private let environments: any C02MCPSetupEnvironmentListing

    public init(library: C01ProjectLibrary, rootPath: String,
                environments: any C02MCPSetupEnvironmentListing) {
        self.library = library
        self.rootPath = rootPath
        self.environments = environments
    }

    public func projects() async throws -> [C02MCPSetupProject] {
        let rows = try await library.list(limit: C01ProjectLibrary.maximumPageLimit)
        return rows.map { row in
            C02MCPSetupProject(
                id: row.id,
                name: row.name,
                rootURL: URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
                    rootPath: rootPath, projectID: row.id), isDirectory: true),
                revision: row.revision)
        }
    }

    public func project(id: UUID) async throws -> C02MCPSetupProject? {
        let detail = try await library.get(projectID: id)
        return C02MCPSetupProject(
            id: detail.project.id,
            name: detail.project.name,
            rootURL: URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
                rootPath: rootPath, projectID: detail.project.id), isDirectory: true),
            revision: detail.project.revision)
    }

    public func tasks(project: C02MCPSetupProject) async throws -> [C02MCPSetupTaskChoice] {
        let detail = try await library.get(projectID: project.id)
        return detail.tasks.filter { $0.purpose == "ordinary" && !$0.isArchived }
            .map { C02MCPSetupTaskChoice(id: $0.id, title: $0.title) }
    }

    public func environments(project: C02MCPSetupProject) async throws -> [C02MCPSetupEnvironmentOption] {
        return await self.environments.environments(project: project).map { fact in
            C02MCPSetupEnvironmentOption(
                id: fact.id,
                label: fact.label,
                backend: fact.backend,
                containerID: fact.containerID,
                baseRevision: fact.baseRevision,
                layerFormat: fact.layerFormat)
        }
    }
}

// MARK: - App-owned record sidecar (bounded, atomic, no database table)

public actor C02MCPSetupFileRecordStore: C02MCPSetupRecordStoring {
    private let root: URL
    private let maximumRecordBytes = 131_072

    public init(root: URL) {
        self.root = root
    }

    public func load() async throws -> [C02MCPSetupRecord] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        var records: [C02MCPSetupRecord] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == "json" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? Int.max) <= maximumRecordBytes,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(C02MCPSetupRecord.self, from: data) else {
                continue
            }
            records.append(record)
            if records.count >= C02MCPSetupLimits.maximumRecords { break }
        }
        return records
    }

    public func save(_ record: C02MCPSetupRecord) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumRecordBytes else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The MCP setup record exceeded its storage bound.",
                                     retryable: false)
        }
        let url = root.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(id: UUID) async throws {
        let url = root.appendingPathComponent(id.uuidString.lowercased() + ".json")
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Composition

public struct C02MCPSetupInstallation: Sendable {
    public let epoch: UInt64
    public let appSupportRoot: URL
    public let projects: any C02MCPSetupProjectProviding
    public let environments: any C02MCPSetupEnvironmentProviding
    public let jobs: BackgroundJobService
    public let jobContexts: any C02MCPSetupExecutionContextProviding
    public let mcpFactory: any MCPClientMaking
    public let mcpAdmission: any MCPTransportAdmitting
    public let mcpDomain: MCPDomain
    public let generation: (any C02MCPSetupGenerationRunning)?
    public let serviceHost: (any C02MCPSetupServiceHosting)?
    public let stdioChannelProvider: (any C02MCPSetupStdioChannelProviding)?
    public let templateAssetAvailable: Bool
    /// True only when a real C01 separated-pipe provider was injected. A
    /// caller-supplied bool can never advertise the lane without the port.
    public let stdioLaneAvailable: Bool
    public let liveEpoch: @Sendable () -> UInt64

    public init(epoch: UInt64, appSupportRoot: URL,
                projects: any C02MCPSetupProjectProviding,
                environments: any C02MCPSetupEnvironmentProviding,
                jobs: BackgroundJobService,
                jobContexts: any C02MCPSetupExecutionContextProviding,
                mcpFactory: any MCPClientMaking,
                mcpAdmission: any MCPTransportAdmitting,
                mcpDomain: MCPDomain,
                generation: (any C02MCPSetupGenerationRunning)? = nil,
                serviceHost: (any C02MCPSetupServiceHosting)? = nil,
                stdioChannelProvider: (any C02MCPSetupStdioChannelProviding)? = nil,
                templateAssetAvailable: Bool,
                stdioLaneAvailable: Bool = false,
                liveEpoch: @escaping @Sendable () -> UInt64) {
        self.epoch = epoch
        self.appSupportRoot = appSupportRoot
        self.projects = projects
        self.environments = environments
        self.jobs = jobs
        self.jobContexts = jobContexts
        self.mcpFactory = mcpFactory
        self.mcpAdmission = mcpAdmission
        self.mcpDomain = mcpDomain
        self.generation = generation
        self.serviceHost = serviceHost
        self.stdioChannelProvider = stdioChannelProvider
        self.templateAssetAvailable = templateAssetAvailable
        self.stdioLaneAvailable = stdioLaneAvailable && stdioChannelProvider != nil
        self.liveEpoch = liveEpoch
    }
}

public final class C02MCPSetupRuntime: @unchecked Sendable {
    public let epoch: UInt64
    public let center: C02MCPSetupCenter
    public let bridge: C02MCPSetupBridgeRuntime

    init(epoch: UInt64, center: C02MCPSetupCenter,
         bridge: C02MCPSetupBridgeRuntime) {
        self.epoch = epoch
        self.center = center
        self.bridge = bridge
    }

    public func isLive() -> Bool { bridge.isLive() }

    public func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        C02MCPSetupBridge.handle(requestData: requestData,
                                 fallbackRequestID: fallbackRequestID,
                                 runtime: bridge)
    }
}

public enum C02MCPSetupIntegration {
    /// Convenience builder for the trusted Linux/Main composition. It wires
    /// the ORIGINAL project library + environment registry into the explicit
    /// catalog adapters; it adds no store or process.
    public static func makeInstallation(
        epoch: UInt64,
        appSupportRoot: URL,
        projectLibrary: C01ProjectLibrary,
        storageRootPath: String,
        environmentRegistry: EnvironmentRegistry?,
        runtimeEnvironments: (any C02MCPSetupEnvironmentListing & C02MCPSetupEnvironmentProviding)? = nil,
        jobs: BackgroundJobService,
        jobContexts: (any C02MCPSetupExecutionContextProviding)?,
        mcpDomain: MCPDomain,
        mcpFactory: any MCPClientMaking,
        mcpAdmission: any MCPTransportAdmitting,
        generation: (any C02MCPSetupGenerationRunning)? = nil,
        serviceHost: (any C02MCPSetupServiceHosting)? = nil,
        stdioChannelProvider: (any C02MCPSetupStdioChannelProviding)? = nil,
        templateAssetAvailable: Bool,
        stdioLaneAvailable: Bool = false,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) -> C02MCPSetupInstallation {
        let environments: any C02MCPSetupEnvironmentListing & C02MCPSetupEnvironmentProviding
        if let runtimeEnvironments {
            environments = runtimeEnvironments
        } else if let environmentRegistry {
            environments = C02MCPSetupEnvironmentRegistryProvider(
                registry: environmentRegistry)
        } else {
            environments = C02MCPSetupUnavailableEnvironmentProvider()
        }
        let projects = C02MCPSetupProjectCatalogAdapter(
            library: projectLibrary,
            rootPath: storageRootPath,
            environments: environments)
        return C02MCPSetupInstallation(
            epoch: epoch,
            appSupportRoot: appSupportRoot,
            projects: projects,
            environments: environments,
            jobs: jobs,
            jobContexts: jobContexts ?? C02MCPSetupUnavailableExecutionContextProvider(),
            mcpFactory: mcpFactory,
            mcpAdmission: mcpAdmission,
            mcpDomain: mcpDomain,
            generation: generation,
            serviceHost: serviceHost,
            stdioChannelProvider: stdioChannelProvider,
            templateAssetAvailable: templateAssetAvailable,
            stdioLaneAvailable: stdioLaneAvailable,
            liveEpoch: liveEpoch)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var runtime: C02MCPSetupRuntime?
        func get() -> C02MCPSetupRuntime? {
            lock.lock(); defer { lock.unlock() }; return runtime
        }
        func set(_ value: C02MCPSetupRuntime?) {
            lock.lock(); runtime = value; lock.unlock()
        }
        func clear(epoch: UInt64) {
            lock.withLock {
                guard runtime?.epoch == epoch else { return }
                runtime = nil
            }
        }
    }

    private static let box = Box()

    @discardableResult
    public static func install(_ installation: C02MCPSetupInstallation) -> C02MCPSetupRuntime {
        let records = C02MCPSetupFileRecordStore(
            root: installation.appSupportRoot.appendingPathComponent("MCPSetup/Records",
                                                                      isDirectory: true))
        let commands = C02MCPSetupJobCommandExecutor(
            jobs: installation.jobs, contexts: installation.jobContexts)
        let discovery = C02MCPSetupMCPDiscoveryProbe(
            factory: installation.mcpFactory,
            admission: installation.mcpAdmission)
        let connections = C02MCPSetupMCPDomainCommitter(domain: installation.mcpDomain)
        let dependencies = C02MCPSetupDependencies(
            epoch: installation.epoch,
            appSupportRoot: installation.appSupportRoot,
            projects: installation.projects,
            environments: installation.environments,
            commands: commands,
            serviceHost: installation.serviceHost,
            discovery: discovery,
            connections: connections,
            generation: installation.generation,
            records: records,
            liveEpoch: installation.liveEpoch,
            templateAssetAvailable: installation.templateAssetAvailable,
            stdioLaneAvailable: installation.stdioLaneAvailable)
        let center = C02MCPSetupCenter(dependencies: dependencies)
        let bridge = C02MCPSetupBridgeRuntime(
            epoch: installation.epoch,
            center: center,
            templateAssetAvailable: installation.templateAssetAvailable,
            stdioLaneAvailable: installation.stdioLaneAvailable,
            liveEpoch: installation.liveEpoch)
        let runtime = C02MCPSetupRuntime(epoch: installation.epoch,
                                          center: center, bridge: bridge)
        box.set(runtime)
        return runtime
    }

    public static var current: C02MCPSetupRuntime? { box.get() }

    /// Clears only the retiring generation's bridge. A late retirement
    /// callback can never clear a newer runtime.
    public static func uninstall(epoch: UInt64) {
        box.clear(epoch: epoch)
    }
}

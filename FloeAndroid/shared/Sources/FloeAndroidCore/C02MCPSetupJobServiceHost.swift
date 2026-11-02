// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloePersistence
import FloeAndroidJobTools
import FloeAndroidShellTools

/// The existing durable exec.shell job owns the Node service. Starting a
/// record is not listener readiness; only C01's owned-socket proof is ready.
public struct C02MCPSetupJobServiceHost: C02MCPSetupServiceHosting {
    private let jobs: BackgroundJobService
    private let contexts: any C02MCPSetupExecutionContextProviding
    private let services: C01ManagedServiceDomain

    public init(jobs: BackgroundJobService, contexts: any C02MCPSetupExecutionContextProviding,
                services: C01ManagedServiceDomain = .shared) {
        self.jobs = jobs; self.contexts = contexts; self.services = services
    }

    public func start(binding: C02MCPSetupBinding, recordID: UUID,
                      projectRelativePath: String) async throws -> C02MCPSetupServiceHandle {
        guard binding.recordID == recordID, binding.workspaceRelativePath == projectRelativePath else {
            throw failure("The service workspace changed.")
        }
        let context = try await contexts.context(for: binding)
        let declaration = C01ManagedServiceDeclaration(runtime: .node,
            entry: projectRelativePath + "/node-http/" + C02MCPSetupLimits.launcherName,
            cwd: ".", port: binding.port)
        let payload = try services.makeExecShellPayload(innerArguments: Data("{}".utf8), declaration: declaration)
        try await contexts.submissionStarted(recordID: recordID)
        let job: BackgroundJob
        do {
            job = try await jobs.submit(runID: context.runID,
                toolCallID: "mcp.setup.service." + recordID.uuidString,
                targetTool: "exec.shell", payloadJSON: payload, scope: .local,
                workspaceRootURL: context.workspaceRootURL, allowedWorkspacePaths: [],
                environmentID: context.environmentID, allowedToolNames: nil,
                submissionSource: .nativeService, waitForCompletion: false)
        } catch {
            await contexts.submissionFinished(recordID: recordID, jobID: nil)
            throw error
        }
        await contexts.submissionFinished(recordID: recordID, jobID: job.id)
        guard job.runID == context.runID, job.conversationID == context.conversationID,
              job.environmentID == binding.environmentID,
              job.workspaceRootPath == context.workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path,
              job.targetTool == "exec.shell",
              job.payloadJSON == payload else { throw failure("The service job ownership did not match.") }
        return C02MCPSetupServiceHandle(id: job.id, endpoint: try endpoint(binding.port), startedAt: job.createdAt)
    }

    public func status(_ handle: C02MCPSetupServiceHandle,
                       binding: C02MCPSetupBinding) async -> C02MCPSetupServiceStatus {
        guard let context = try? await contexts.context(for: binding),
              let expected = try? endpoint(binding.port), handle.endpoint == expected,
              let job = try? await jobs.job(id: handle.id),
              job.runID == context.runID, job.conversationID == context.conversationID,
              job.environmentID == binding.environmentID else { return .failed("The service binding is no longer current.") }
        if let snapshot = services.snapshot(jobID: job.id) {
            guard snapshot.conversationID == context.conversationID,
                  snapshot.environmentID == binding.environmentID,
                  snapshot.port == binding.port else { return .failed("The service owner changed.") }
            switch snapshot.state {
            case .ready:
                // C01 marks ready only after owned-listener proof. Browser
                // preview availability is independent of the MCP transport.
                return .running(expected)
            case .starting, .running: return .starting
            case .stopping: return .starting
            case .stopped: return .stopped
            case .failed, .interruptedUnknown: return .failed(snapshot.detail)
            }
        }
        return job.state.isTerminal ? .stopped : .starting
    }

    public func stop(_ handle: C02MCPSetupServiceHandle,
                     binding: C02MCPSetupBinding) async throws {
        // Stop must remain possible after the shared context was cancelled.
        guard let job = try await jobs.job(id: handle.id),
              job.environmentID == binding.environmentID,
              job.toolCallID == "mcp.setup.service." + binding.recordID.uuidString,
              job.workspaceRootPath == binding.rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
              handle.endpoint == (try endpoint(binding.port)) else {
            throw failure("The service job is no longer owned by this record.")
        }
        if !job.state.isTerminal { _ = try await jobs.cancel(id: job.id) }
        for _ in 0..<150 {
            if let current = try? await jobs.job(id: job.id), current.state.isTerminal,
               !services.hasLiveService(jobID: job.id),
               !LinuxShellMailbox.shared.hasLiveTickets(runID: job.runID) { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw C02MCPSetupFailure(.serviceStopFailed,
            message: "The service is still stopping. Its process has not released yet.", retryable: true)
    }

    private func endpoint(_ port: Int) throws -> URL {
        guard C02MCPSetupLimits.portRange.contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw failure("The local service port is invalid.")
        }
        return url
    }
    private func failure(_ text: String) -> C02MCPSetupFailure {
        C02MCPSetupFailure(.serviceStartFailed, message: text, retryable: true)
    }
}

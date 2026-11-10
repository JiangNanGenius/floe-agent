// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace

/// Copies a persisted, same-task user output into the task's explicit local
/// workspace. Model arguments identify evidence, never a private source path
/// or a claimed digest. The immutable source snapshot is never modified.
struct WorkspaceImportOutputTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let runID: UUID
        let outputID: String
        let path: String
        init(runID: UUID, outputID: String, path: String) {
            self.runID = runID; self.outputID = outputID; self.path = path
        }
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard container.allKeys.allSatisfy({ ["runID", "outputID", "path"].contains($0.stringValue) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Only runID, outputID and destination path are accepted"))
            }
            runID = try container.decode(UUID.self, forKey: Key(stringValue: "runID")!)
            outputID = try container.decode(String.self, forKey: Key(stringValue: "outputID")!)
            path = try container.decode(String.self, forKey: Key(stringValue: "path")!)
        }
    }
    static let name = "workspace.importOutput"
    static let toolDescription = "Copy a verified saved output file from this task into its local task workspace. Use runID and outputID from actual outputFiles receipts or chat.content.list output references, and choose a new workspace-relative path. The source snapshot is retained and an existing destination is never overwritten. Files from another task, failed or uncertain results, unverified bytes, empty files and network destinations are refused. This copies bytes only; it does not execute, install, decode or re-render media."
    static let parametersJSON = #"{"type":"object","properties":{"runID":{"type":"string","format":"uuid","description":"Source run ID from this same task's actual saved output"},"outputID":{"type":"string","pattern":"^[0-9a-f]{64}$","description":"Exact saved output identity; never a source path or digest override"},"path":{"type":"string","maxLength":4096,"description":"New workspace-relative local destination; must not already exist"}},"required":["runID","outputID","path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true

    let conversations: any ConversationStore
    let runs: any RunStore
    /// Native test injection only. No model-facing root or receipt override.
    var artifactRoot: URL? = nil

    func validate(_ args: Arguments) throws {
        guard RunOutputFile.isValidSHA256Hex(args.outputID), args.outputID == args.outputID.lowercased(),
              !args.path.isEmpty, args.path.utf8.count <= 4096,
              !args.path.hasPrefix("/"), !args.path.hasPrefix("~"),
              !args.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FloeError.validationFailed("Use an actual output ID and a new relative workspace path")
        }
        let parts = args.path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), parts.contains(where: { $0 != "." }),
              parts.first(where: { $0 != "." }) != "Network" else {
            throw FloeError.validationFailed("Choose a new local workspace file; network destinations are not supported")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard context.executionToolName == Self.name,
              context.toolCallID?.isEmpty == false, context.approvalGrantID != nil,
              !context.temporaryReadOnly, !context.publicWebOnly,
              context.allowedToolNames?.contains(Self.name) != false,
              context.frozenEffectiveCatalogNames?.contains(Self.name) != false,
              case .local = context.scope,
              let taskID = context.conversationID else {
            throw FloeError.unauthorized
        }
        guard let root = context.workspaceRootURL, root.isFileURL, root.path.hasPrefix("/") else {
            throw FloeError.validationFailed("This task has no local workspace; open its workspace before importing an output")
        }
        if let child = context.childExecution, child.identity.rootTaskID != taskID {
            throw FloeError.unauthorized
        }
        if let origin = context.callOrigin {
            guard origin.runID == context.runID, origin.callID == context.toolCallID,
                  origin.toolName == Self.name else { throw FloeError.unauthorized }
            if origin.kind == .delegatedChild, origin.rootTaskID != taskID { throw FloeError.unauthorized }
        }
        try context.authorizeWorkspacePath(args.path)
        try await requireCaller(runID: context.runID, taskID: taskID)
        guard let reference = ChatContentReference(kind: .output, ownerID: args.runID, contentID: args.outputID),
              case .output(let receipt, _) = try await ChatInlineContentResolver.resolve(reference,
                scope: .init(conversationID: taskID, isTemporary: false), conversations: conversations, runs: runs),
              receipt.role == .userFile, receipt.runID == args.runID, receipt.outputID == args.outputID,
              receipt.taskID == taskID, receipt.isCanonicalForCurrentRun, receipt.hasRuntimeConsistentIdentity else {
            throw FloeError.unauthorized
        }
        guard receipt.byteCount > 0 else {
            throw FloeError.validationFailed("Empty output files cannot be imported yet")
        }
        guard receipt.byteCount <= RunOutputCaps.standard.perFileBytes else {
            throw FloeError.validationFailed("This output exceeds the supported copy size")
        }
        // An async lookup must not retarget this operation to current UI state.
        // Recheck durable ownership and keep the immutable context root below.
        try await requireCaller(runID: context.runID, taskID: taskID)
        guard try await runs.run(id: receipt.runID)?.conversationID == taskID else { throw FloeError.unauthorized }
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()

        let environment = WorkspaceToolEnvironment(rootProvider: { nil })
        let service = try environment.makeService(context: context)
        guard service.guardResolver.rootURL.standardizedFileURL.resolvingSymlinksInPath()
                == root.standardizedFileURL.resolvingSymlinksInPath() else { throw FloeError.unauthorized }
        let token = context.cancellation.derived(), snapshotRoot = artifactRoot
        let worker = Task.detached(priority: .userInitiated) {
            try token.throwIfCancelled(); try Task.checkCancellation()
            let verification = RunOutputSnapshotStore.verify(receipt, artifactRoot: snapshotRoot)
            try token.throwIfCancelled(); try Task.checkCancellation()
            guard case .verified(let source) = verification else {
                throw FloeError.validationFailed("The saved output is missing or changed; generate it again")
            }
            // Verified snapshot bytes, not arbitrary model-authored payload,
            // cross the existing streaming import boundary. All destination
            // path/freeze/cancellation/no-overwrite checks stay in that service.
            return try service.importUserFile(from: source, to: args.path,
                expectedSHA256: receipt.sha256, cancellation: token)
        }
        let outcome = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            // Own derived token only: no parent/sibling cancellation.
            token.cancel(); worker.cancel()
        }
        struct Result: Encodable {
            let importedPath: String
            let sourceRunID: UUID
            let outputID: String
            let byteCount: Int
            let sha256: String
            let mimeType: String
            let sourcePreserved: Bool
        }
        let result = Result(importedPath: args.path, sourceRunID: receipt.runID, outputID: receipt.outputID,
            byteCount: outcome.bytesWritten, sha256: outcome.sha256, mimeType: receipt.mimeType, sourcePreserved: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return ToolExecutionOutput(digesting: String(decoding: try encoder.encode(result), as: UTF8.self),
            exitStatus: 0, maximumSummaryCharacters: 16_384)
    }

    private func requireCaller(runID: UUID, taskID: UUID) async throws {
        guard let caller = try await runs.run(id: runID), caller.conversationID == taskID,
              let conversation = try await conversations.conversation(id: taskID),
              conversation.purpose != .temporary else { throw FloeError.unauthorized }
    }
}

func registerWorkspaceImportOutputTool(conversations: any ConversationStore, runs: any RunStore,
                                       registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(WorkspaceImportOutputTool.self)
    registry.register(WorkspaceImportOutputTool(conversations: conversations, runs: runs))
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloeTools
import FloeGISKit
import FloeHeavyEditorSupport
import FloeHeavyEditorsHostAdapter

/// Routed by the ONE shared 18-tool bridge. This domain never registers a
/// second bridge, edits a ToolContext, or adopts a model-supplied owner/path.
@MainActor struct GISProductionHost {
    static let names: Set<String> = ["gis.create", "gis.describe", "gis.query", "gis.invoke", "gis.import", "gis.export"]
    let coordinator: StudioCoordinator

    private func library(_ context: ToolContext) async throws -> PersonalContentLibrary {
        let value = try await PersonalContentService.shared.library()
        let root = await value.root
        guard TypedMutationContract.nativeStudioContainerPath(serviceStorePaths: context.serviceStorePaths) == root.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw FloeError.validationFailed("This task is not bound to the actual native Personal Library")
        }
        return value
    }
    func grant(_ context: ToolContext) async throws -> HeavyEditorTaskGrant {
        let conversation = try await coordinator.savedConversation(context)
        let authority = try coordinator.access.get()
        let ids = Set(try await authority.projectIDs(conversationID: conversation))
        let records = try await library(context).records().filter { ids.contains($0.id) && $0.kind == .geography && !$0.needsRecovery }
        var readable = Set<UUID>(), writable = Set<UUID>()
        for record in records {
            if try await authority.canAccess(conversationID: conversation, projectID: record.id, editing: false) { readable.insert(record.id) }
            if try await authority.canAccess(conversationID: conversation, projectID: record.id, editing: true) { writable.insert(record.id) }
        }
        let writesExisting = ["gis.invoke", "gis.import", "gis.export"].contains(context.executionToolName ?? "")
        let canCreate = context.allowedToolNames?.contains("gis.create") != false
        try context.cancellation.throwIfCancelled()
        // Creation remains available for a new work in an ordinary saved task;
        // that does not turn its existing read-only bindings into write grants.
        return .init(enabledKinds: readable.isEmpty && !canCreate ? [] : [.gis], projects: writesExisting ? writable : readable,
                     canCreate: canCreate, readOnly: writable.isEmpty && !canCreate)
    }
    private func location(_ id: UUID, context: ToolContext, editing: Bool) async throws -> (record: PersonalContentRecord, url: URL) {
        _ = try await library(context)
        if editing, context.approvalGrantID == nil { throw FloeError.validationFailed("The task's existing approval grant is required") }
        let value = try await coordinator.location(id, context: context, editing: editing, allowedNames: Self.names)
        guard value.record.kind == .geography, !value.record.needsRecovery else { throw PersonalContentError.invalidProject }
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        return value
    }
    func resolveFile(_ fileID: String, context: ToolContext) async throws -> HeavyEditorArtifact {
        guard context.executionToolName == "gis.import", context.approvalGrantID != nil,
              let environment = coordinator.environment else { throw HeavyEditorError.invalidCommand }
        return try await HeavyEditorTaskFileResolver.resolve(fileID, context: context, environment: environment,
            allowedExtensions: Set(GISWorkbench.descriptor.importExtensions), validate: {
                _ = try await self.coordinator.conversation(context, allowedNames: Self.names)
                _ = try await self.library(context)
                try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            })
    }
    func create(_ request: HeavyEditorCreationRequest, context: ToolContext,
                authorize: @escaping HeavyEditorCallAuthorization) async throws -> UUID {
        guard request.kind == .gis, context.executionToolName == "gis.create", context.approvalGrantID != nil,
              let call = context.toolCallID, !call.isEmpty else { throw HeavyEditorError.invalidCommand }
        try await authorize()
        let conversation = try await coordinator.conversation(context, allowedNames: Self.names)
        let authority = try coordinator.access.get(), library = try await library(context)
        let digest = StudioToolOutput.hash(try StudioToolOutput.data(["geography", request.title]))
        let id = try await authority.reserveCreation(operationKey: "\(context.runID)/\(request.requestID)", digest: digest)
        try await authorize(); try context.cancellation.throwIfCancelled()
        let record = try await library.create(kind: .geography, title: request.title, id: id) { directory, newID in
            try await authorize(); try context.cancellation.throwIfCancelled()
            try await GISProjectOriginal.create(id: newID, title: request.title, directory: directory)
            try await authorize(); try context.cancellation.throwIfCancelled()
        }
        try await authorize()
        guard record.id == id, record.kind == .geography else { throw HeavyEditorError.wrongDocument }
        let actual = try await library.resolve(id)
        _ = try await personalPreviewOffMain { try GISProjectOriginal.read(id: id, directory: actual.url) }
        try await authorize(); try context.cancellation.throwIfCancelled()
        try await authority.finishCreation(conversationID: conversation, projectID: id)
        NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
        return id
    }
    func open(_ id: UUID, action: HeavyEditorToolAction, context: ToolContext,
              authorize: @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorToolLease {
        try await authorize()
        let value = try await location(id, context: context, editing: !action.isReadOnly)
        let library = try await library(context), root = await library.root
        let usage = try PersonalLibraryFileActions.acquireUse(id: id, directory: value.url, libraryRoot: root)
        do {
            let session = try await GISProjectSession.open(id: id, directory: value.url)
            let token = try session.retainModelUse()
            let expectedDirectory = value.url
            let scoped: HeavyEditorOperationAuthorizer = { request in
                try await authorize(); try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
                guard request.documentID == id, request.owner == .space(id) else { throw HeavyEditorError.wrongDocument }
                let editing = request.access != .read
                if action.isReadOnly, editing { throw HeavyEditorError.invalidCommand }
                let current = try await self.location(id, context: context, editing: editing)
                guard current.url == expectedDirectory else { throw PersonalContentError.changedDocument }
                try await session.requireOriginal()
                guard await session.controller.document.revision == request.revision else { throw HeavyEditorError.revisionConflict }
                try await authorize(); try context.cancellation.throwIfCancelled()
            }
            let model = HeavyEditorModelLease(controller: session.controller, authorize: scoped, release: {
                await session.releaseModelUse(token); await usage.release()
            })
            return HeavyEditorToolLease(model: model, complete: { result, actualContext in
                guard actualContext.runID == context.runID, actualContext.conversationID == context.conversationID,
                      actualContext.toolCallID == context.toolCallID, actualContext.executionToolName == context.executionToolName,
                      actualContext.environmentID == context.environmentID else { throw HeavyEditorError.invalidCommand }
                return try await self.complete(result, session: session, context: actualContext, authorize: authorize)
            })
        } catch { usage.release(); throw error }
    }
    private func complete(_ result: EditorJSON, session: GISProjectSession, context: ToolContext,
                          authorize: @escaping HeavyEditorCallAuthorization) async throws -> ToolExecutionOutput {
        try await authorize(); try context.cancellation.throwIfCancelled()
        _ = try await location(session.id, context: context, editing: !result["exports"].array.isEmpty)
        try await session.requireOriginal()
        var outputFiles: [RunOutputFile] = []
        var canonicalExports: [EditorJSON] = []
        for (index, object) in result["exports"].array.enumerated() {
            try await authorize(); try context.cancellation.throwIfCancelled()
            let receipt = try JSONDecoder().decode(HeavyEditorExportReceipt.self, from: object.data())
            let url = try session.exportFile(receipt)
            let saved = try PersonalPreviewFile(root: session.directory, url: url, maximumBytes: RunOutputCaps.standard.perFileBytes)
            guard saved.identity.size == receipt.byteCount else { throw PersonalContentError.changedDocument }
            try saved.verifyHash(receipt.sha256)
            guard let producer = context.executionToolName, Self.names.contains(producer) else { throw HeavyEditorError.invalidCommand }
            let fileType = UTType(filenameExtension: (receipt.name as NSString).pathExtension)
            let request = RunOutputSnapshotRequest(producerTool: producer, slot: "gis-export-\(index)",
                commit: .init(sourceURL: url, sha256: receipt.sha256, byteCount: receipt.byteCount,
                    displayName: receipt.name, mimeType: fileType?.preferredMIMEType ?? "application/octet-stream", uti: fileType?.identifier))
            try await authorize(); try saved.validate(); try context.cancellation.throwIfCancelled()
            let file = try await personalPreviewOffMain { try RunOutputSnapshotStore.publish(request, using: context) }
            guard file.runID == context.runID, file.producerCallID == context.toolCallID,
                  file.producerTool == producer, file.displayName == receipt.name,
                  file.sha256 == receipt.sha256, file.byteCount == receipt.byteCount else { throw HeavyEditorError.invalidDocument }
            // A published frozen output remains durable even if a later task
            // fence fails; its receipt is never fabricated from this local ID.
            try await authorize(); try await session.requireOriginal(); try saved.validate()
            outputFiles.append(file)
            canonicalExports.append(.object(["fileID": .string("output:\(file.runID.uuidString):\(file.outputID)"),
                "managedFileID": .string(receipt.fileID), "name": .string(file.displayName),
                "byteCount": .number(Double(file.byteCount)), "sha256": .string(file.sha256)]))
        }
        guard case .object(var body) = result else { throw HeavyEditorError.invalidDocument }
        body["exports"] = .array(canonicalExports)
        body["sourceSHA256"] = .string(try session.originalSHA256())
        let conversation = try await coordinator.savedConversation(context)
        let canEdit = try await coordinator.access.get().canAccess(conversationID: conversation, projectID: session.id, editing: true)
        body["access"] = .object(["canRead": .bool(true), "canEdit": .bool(canEdit)])
        if context.executionToolName == "gis.describe", let environment = coordinator.environment {
            body["inputFiles"] = try await HeavyEditorTaskFileResolver.inventory(context: context, environment: environment,
                allowedExtensions: Set(GISWorkbench.descriptor.importExtensions), validate: {
                    try await authorize()
                    _ = try await self.location(session.id, context: context, editing: false)
                    try await session.requireOriginal(); try context.cancellation.throwIfCancelled()
                })
        }
        try await authorize(); try await session.requireOriginal(); try context.cancellation.throwIfCancelled()
        _ = try await location(session.id, context: context, editing: !canonicalExports.isEmpty)
        let text = try EditorJSON.object(body).text()
        var output = ToolExecutionOutput(digesting: text, exitStatus: 0, capturedOutput: text)
        output.outputFiles = outputFiles
        return output
    }
}

/// Main's shared registration owner keeps this bridge for per-run discovery,
/// and calls register(in:kinds:[.gis]) exactly once beside Score and Font.
@MainActor func makeGISProductionToolBridge(environment: AppEnvironment) -> HeavyEditorToolBridge {
    let host = GISProductionHost(coordinator: environment.studioCoordinator)
    return HeavyEditorToolBridge(grant: { context in try await host.grant(context) },
        open: { id, action, context, authorize in try await host.open(id, action: action, context: context, authorize: authorize) },
        create: { request, context, authorize in try await host.create(request, context: context, authorize: authorize) },
        resolveFile: { fileID, context in try await host.resolveFile(fileID, context: context) })
}
#endif

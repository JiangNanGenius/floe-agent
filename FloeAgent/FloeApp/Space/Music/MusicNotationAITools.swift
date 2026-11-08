// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeHeavyEditorSupport
import FloeHeavyEditorsHostAdapter
import FloeScoreKit

/// Six Score names from the existing 18-tool adapter. Every selector is resolved
/// through Studio's real saved-task binding. No model argument can choose a root,
/// owner, audio session, authorization callback, or publication identity.
@MainActor final class MusicNotationAITools {
    static let names: Set<String> = ["score.create", "score.describe", "score.query", "score.invoke", "score.import", "score.export"]
    private weak var environment: AppEnvironment?
    private let coordinator: StudioCoordinator
    private lazy var bridge = HeavyEditorToolBridge(grant: { [weak self] context in
        guard let self else { throw HeavyEditorError.unavailable }
        return try await self.grant(context)
    }, open: { [weak self] id, operation, context, authorize in
        guard let self else { throw HeavyEditorError.unavailable }
        return try await self.open(id, operation: operation, context: context, authorize: authorize)
    }, create: { [weak self] request, context, authorize in
        guard let self else { throw HeavyEditorError.unavailable }
        return try await self.create(request, context: context, authorize: authorize)
    }, resolveFile: { [weak self] fileID, context in
        guard let self else { throw HeavyEditorError.unavailable }
        return try await self.source(fileID, context: context)
    })

    init(environment: AppEnvironment) {
        self.environment = environment; coordinator = environment.studioCoordinator
    }
    func descriptors(for context: ToolContext) async throws -> [ToolCatalog.Descriptor] {
        try await bridge.descriptors(for: context)
    }
    func register(in registry: ToolRunnerRegistry = .shared) throws {
        try bridge.register(in: registry, kinds: [.score])
    }
    private func grant(_ context: ToolContext) async throws -> HeavyEditorTaskGrant {
        let conversationID = try await coordinator.savedConversation(context)
        let access = try coordinator.access.get()
        let ids = Set(try await access.projectIDs(conversationID: conversationID))
        let records = try await PersonalContentService.shared.library().records()
        let music = records.filter { ids.contains($0.id) && $0.kind == .music }
        var readable = Set<UUID>(), editable = Set<UUID>()
        for record in music {
            if try await access.canAccess(conversationID: conversationID, projectID: record.id, editing: false) { readable.insert(record.id) }
            if try await access.canAccess(conversationID: conversationID, projectID: record.id, editing: true) { editable.insert(record.id) }
        }
        let assistant = try await access.assistantProject(conversationID: conversationID)
        return .init(enabledKinds: readable.isEmpty ? [] : [.score], projects: readable,
            canCreate: assistant.map { editable.contains($0) } ?? false, readOnly: editable.isEmpty)
    }
    private func location(_ id: UUID, operation: HeavyEditorToolAction, context: ToolContext) async throws -> (record: PersonalContentRecord, url: URL) {
        let effectful = operation != .describe && operation != .query
        if effectful {
            guard context.approvalGrantID != nil else { throw FloeError.validationFailed("Use the task's existing approved Score call.") }
        }
        let value = try await coordinator.location(id, context: context, editing: effectful, allowedNames: Self.names)
        guard value.record.kind == .music else { throw HeavyEditorError.wrongDocument }
        // An AI read cannot become a crash-recovery directory exchange.
        // The native parent workspace owns completion of a pending restore.
        guard !FileManager.default.fileExists(atPath: value.url.appendingPathComponent(MusicNotationPackage.journalName).path) else { throw PersonalContentError.changedDocument }
        return value
    }
    private func create(_ request: HeavyEditorCreationRequest, context: ToolContext,
                        authorize: @escaping HeavyEditorCallAuthorization) async throws -> UUID {
        guard request.kind == .score, let environment else { throw HeavyEditorError.wrongDocument }
        let conversationID = try await coordinator.conversation(context, allowedNames: Self.names)
        let authority = try coordinator.access.get()
        guard let id = try await authority.assistantProject(conversationID: conversationID) else { throw HeavyEditorError.wrongDocument }
        let selected = try await location(id, operation: .create, context: context)
        try await authorize()
        let digest = StudioToolOutput.hash(try StudioToolOutput.data([id.uuidString.lowercased(), request.kind.rawValue, request.title]))
        try await authority.reserveCompanionCreation(operationKey: "score/\(context.runID)/\(request.requestID)", digest: digest, parentID: id)
        let use = try PersonalLibraryFileActions.acquireUse(id: id, directory: selected.url)
        defer { use.release() }
        let root = selected.url.appendingPathComponent("Music").standardizedFileURL
        let directoryID = try MusicNotationPackage.directoryIdentity(root)
        let session = try await MusicProjectSession.open(id: id, directory: root, environment: environment)
        guard session.root == root else { throw PersonalContentError.changedDocument }
        let service = try await session.openNotation(), generation = service.identity
        let validate: @MainActor @Sendable () async throws -> Void = { [self, weak session, weak service] in
            try await authorize()
            let current = try await location(id, operation: .create, context: context)
            guard let session, let service, current.record.relativePath == selected.record.relativePath,
                  current.url.standardizedFileURL == selected.url.standardizedFileURL,
                  session.notation === service, service.identity == generation, session.root == root else { throw PersonalContentError.changedDocument }
            let currentID = try MusicNotationPackage.directoryIdentity(root)
            guard currentID.0 == directoryID.0, currentID.1 == directoryID.1 else { throw PersonalContentError.changedDocument }
        }
        try await validate()
        // Existing scores are returned unchanged. A different retry payload
        // conflicts at the native reservation instead of overwriting the UI.
        _ = try await service.openController(allowCreation: true, initialTitle: request.title, refreshTransport: false, authorizeCreation: validate)
        try await validate()
        _ = try MusicNotationPackage.readOriginal(root: root, parentID: id)
        return id
    }
    private func open(_ id: UUID, operation: HeavyEditorToolAction, context: ToolContext,
                      authorize: @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorToolLease {
        guard let environment else { throw HeavyEditorError.unavailable }
        try await authorize()
        let selected = try await location(id, operation: operation, context: context)
        let use = try PersonalLibraryFileActions.acquireUse(id: id, directory: selected.url)
        do {
            let root = selected.url.appendingPathComponent("Music").standardizedFileURL
            let directoryID = try MusicNotationPackage.directoryIdentity(root)
            // Read/describe/import/invoke cannot implicitly create or repair a
            // missing original. Only score.create or the native UI can do that.
            guard try MusicNotationPackage.readOriginal(root: root, parentID: id) != nil else { throw PersonalContentError.missingDocument }
            let session = try await MusicProjectSession.open(id: id, directory: root, environment: environment)
            guard session.root == root else { throw PersonalContentError.changedDocument }
            let service = try await session.openNotation(), generation = service.identity
            let controller = try await service.openController(allowCreation: false, refreshTransport: false)
            let validate: @MainActor @Sendable () async throws -> Void = { [self, weak session, weak service, weak controller] in
                try await authorize()
                let current = try await location(id, operation: operation, context: context)
                guard let session, let service, let controller,
                      current.record.relativePath == selected.record.relativePath,
                      current.url.standardizedFileURL == selected.url.standardizedFileURL,
                      session.root == root, session.notation === service, service.identity == generation,
                      service.controller === controller, controller.document.id == id, controller.descriptor.kind == .score else {
                    throw PersonalContentError.changedDocument
                }
                let currentID = try MusicNotationPackage.directoryIdentity(root)
                guard currentID.0 == directoryID.0, currentID.1 == directoryID.1,
                      let original = try MusicNotationPackage.readOriginal(root: root, parentID: id),
                      original.document == controller.document else { throw PersonalContentError.changedDocument }
            }
            try await validate()
            let model = HeavyEditorModelLease(controller: controller, authorize: { request in
                guard request.documentID == id, request.owner == .music(id) else { throw HeavyEditorError.wrongDocument }
                try await validate()
            }, release: { await MainActor.run { use.release() } })
            return HeavyEditorToolLease(model: model, complete: { [self, weak service] result, actualContext in
                guard actualContext.runID == context.runID, actualContext.conversationID == context.conversationID,
                      actualContext.toolCallID == context.toolCallID, actualContext.executionToolName == context.executionToolName else { throw HeavyEditorError.wrongDocument }
                try await validate()
                guard let service else { throw PersonalContentError.changedDocument }
                return try await complete(result, id: id, operation: operation, service: service,
                    projectRoot: selected.url, context: actualContext, validate: validate)
            })
        } catch { use.release(); throw error }
    }
    private func complete(_ value: EditorJSON, id: UUID, operation: HeavyEditorToolAction,
                          service: MusicNotationSession, projectRoot: URL, context: ToolContext,
                          validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        var result = value
        var files: [RunOutputFile] = []
        var reusableExports: [EditorJSON] = []
        if operation == .export {
            guard context.executionToolName == "score.export", value["exports"].array.count <= RunOutputCaps.standard.perRunFiles else { throw HeavyEditorError.invalidCommand }
            var seen = Set<String>()
            for (index, item) in value["exports"].array.enumerated() {
                try await validate()
                let receipt = try JSONDecoder().decode(HeavyEditorExportReceipt.self, from: item.data())
                guard seen.insert(receipt.fileID).inserted else { throw HeavyEditorError.invalidDocument }
                let url = try service.exportURL(fileID: receipt.fileID), token = context.cancellation
                let original = try PersonalPreviewFile(root: projectRoot, url: url, maximumBytes: RunOutputCaps.standard.perFileBytes)
                guard original.url.lastPathComponent == receipt.name, original.identity.size == receipt.byteCount else { throw HeavyEditorError.invalidDocument }
                let digest = try await personalPreviewOffMain { try original.sha256 { try token.throwIfCancelled(); try Task.checkCancellation() } }
                guard digest == receipt.sha256 else { throw PersonalContentError.changedDocument }
                let type = UTType(filenameExtension: original.url.pathExtension)
                let publication = RunOutputSnapshotRequest(producerTool: "score.export", slot: "score-export-\(index)",
                    commit: .init(sourceURL: original.url, sha256: receipt.sha256, byteCount: receipt.byteCount,
                        displayName: receipt.name, mimeType: type?.preferredMIMEType ?? "application/octet-stream", uti: type?.identifier))
                try await validate(); try original.validate()
                let file = try await personalPreviewOffMain { try RunOutputSnapshotStore.publish(publication, using: context) }
                try await validate(); try original.validate()
                guard file.sha256 == receipt.sha256, file.byteCount == receipt.byteCount,
                      case .verified = RunOutputSnapshotStore.verify(file) else { throw PersonalContentError.changedDocument }
                files.append(file)
                reusableExports.append(.object(["fileID": .string("output:\(file.runID.uuidString):\(file.outputID)"),
                    "managedFileID": .string(receipt.fileID), "name": .string(file.displayName),
                    "byteCount": .number(Double(file.byteCount)), "sha256": .string(file.sha256),
                    "outputID": .string(file.outputID), "mimeType": .string(file.mimeType)]))
            }
            guard case .object(var object) = result, reusableExports.count == files.count else { throw HeavyEditorError.invalidDocument }
            object["exports"] = .array(reusableExports); result = .object(object)
        } else if !value["exports"].array.isEmpty { throw HeavyEditorError.invalidCommand }
        if operation == .describe, case .object(var object) = result {
            object["revisionScope"] = .string("score")
            object["parentMusicID"] = .string(id.uuidString)
            object["inputFiles"] = try await inputs(context: context)
            result = .object(object)
        }
        try await validate()
        guard try result.data().count <= 512 * 1024 else { throw HeavyEditorError.engine("Use a narrower command or parameter discovery page.") }
        let text = try result.text()
        return ToolExecutionOutput(digesting: text, exitStatus: 0, outputFiles: files, capturedOutput: text)
    }
    private func source(_ fileID: String, context: ToolContext) async throws -> HeavyEditorArtifact {
        guard let environment else { throw HeavyEditorError.unavailable }
        return try await HeavyEditorTaskFileResolver.resolve(fileID, context: context, environment: environment,
            allowedExtensions: Set(ScoreWorkbench.descriptor.importExtensions), validate: { [coordinator] in
                _ = try await coordinator.conversation(context, allowedNames: Self.names)
            })
    }
    private func inputs(context: ToolContext) async throws -> EditorJSON {
        guard let environment else { throw HeavyEditorError.unavailable }
        return try await HeavyEditorTaskFileResolver.inventory(context: context, environment: environment,
            allowedExtensions: Set(ScoreWorkbench.descriptor.importExtensions), validate: { [coordinator] in
                _ = try await coordinator.conversation(context, allowedNames: Self.names)
            })
    }
}
#endif

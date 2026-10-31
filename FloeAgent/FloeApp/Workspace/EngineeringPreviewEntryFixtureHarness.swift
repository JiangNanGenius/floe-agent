// SPDX-License-Identifier: MPL-2.0
// FloeApp — DEBUG-only qualification fixture for the six native engineering
// preview entry routes.
//
// Launch with `-ui-testing --ui-test-engineering-entry-fixture
// --ui-test-engineering-entry-route=<route>` and pass ONE owned, real CAD
// GLB export as base64 through `FLOE_ENGINEERING_ENTRY_GLB_B64` (plus its
// lowercase SHA-256 in `FLOE_ENGINEERING_ENTRY_GLB_SHA256`). The fixture:
//   1. seeds a synthetic task conversation/workspace and writes the model;
//   2. seeds the ordinary attachment copy and its persisted message part;
//   3. seeds a verified run-output snapshot/receipt through the production
//      snapshot store and persists the real tool-result event;
//   4. registers one Files-tab recent attachment through FilesCenter;
//   5. imports the same bytes into the production material library and adds
//      ONE canvas file node through the canvas project writer;
//   6. presents the REAL product surface for the requested route.
//
// It never creates a viewer-success mock, never enters .floecad, never calls
// a provider and never deletes user/test-app data. The fixed identities own
// only the synthetic fixture workspace/canvas created here.
#if DEBUG
import SwiftUI
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace

/// Route selection for the six qualification surfaces.
enum EngineeringPreviewEntryRoute: String, CaseIterable {
    case attachment
    case toolOutput
    case files
    case workspace
    case ide
    case canvas
}

/// Observable fixture state, written by the bootstrap seed and read by the
/// DEBUG harness after the App's real services are ready.
@MainActor
final class EngineeringPreviewEntryFixtureStore: ObservableObject {
    static let shared = EngineeringPreviewEntryFixtureStore()

    @Published private(set) var seeded = false
    @Published private(set) var error: String?
    @Published private(set) var manifestURL: URL?

    private init() {}

    func publish(seeded: Bool = false, error: String? = nil, manifestURL: URL? = nil) {
        self.seeded = seeded
        self.error = error
        self.manifestURL = manifestURL
    }
}

@MainActor
enum EngineeringPreviewEntryFixture {
    static let launchArgument = "--ui-test-engineering-entry-fixture"
    static let routePrefix = "--ui-test-engineering-entry-route="
    static let assetEnvironmentKey = "FLOE_ENGINEERING_ENTRY_GLB_B64"
    static let assetSHAEnvironmentKey = "FLOE_ENGINEERING_ENTRY_GLB_SHA256"

    // Fixed synthetic identities. They never overlap ordinary user records.
    static let conversationID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E01")!
    static let messageID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E02")!
    static let attachmentID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E03")!
    static let runID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E04")!
    static let callID = "call-fixture-engineering-preview"
    static let toolName = "ui.fixture.engineeringPreview"
    static let canvasID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E05")!
    static let canvasNodeID = UUID(uuidString: "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E06")!

    static let conversationTitle = "Engineering preview entry fixture"
    static let displayName = "EngineeringEntryPlate.glb"
    static let workspaceRelativePath = "EngineeringEntryPlate.glb"

    static var requestedRoute: EngineeringPreviewEntryRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.first(where: { $0.hasPrefix(routePrefix) })?
            .dropFirst(routePrefix.count),
              let route = EngineeringPreviewEntryRoute(rawValue: String(raw))
        else { return nil }
        return route
    }

    private struct FixtureAsset {
        let data: Data
        let sha256: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let generatedAt: String
        let route: String
        let fixtureOrigin: String
        let fixtureSHA256: String
        let fixtureByteCount: Int
        let modelAbsolutePath: String
        let modelSHA256: String
        let workspaceAbsolutePath: String
        let attachmentWorkspaceAbsolutePath: String
        let attachmentWorkspaceSHA256: String
        let attachmentStagingAbsolutePath: String?
        let attachmentStagingSHA256: String?
        let materialAbsolutePath: String?
        let materialSHA256: String?
        let runOutputAbsolutePath: String?
        let runOutputSHA256: String?
        let canvasProjectAbsolutePath: String?
        let canvasProjectSHA256: String?
        let canvasNodeID: String
        let attachmentID: String
        let runID: String
        let producerTool: String
        let producerCallID: String
        let note: String
    }

    private enum FixtureError: LocalizedError {
        case missingAsset
        case assetDigestMismatch
        case runOutputSeal
        case canvasProject

        var errorDescription: String? {
            switch self {
            case .missingAsset:
                return "The owned engineering fixture bytes were not supplied."
            case .assetDigestMismatch:
                return "The fixture model digest does not match its declared SHA-256."
            case .runOutputSeal:
                return "The production run-output seal rejected the fixture receipt."
            case .canvasProject:
                return "The fixture canvas project could not be prepared."
            }
        }
    }

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        guard let route = requestedRoute else {
            EngineeringPreviewEntryFixtureStore.shared.publish(
                error: "Missing --ui-test-engineering-entry-route=<route>.")
            return
        }
        do {
            let asset = try loadAsset()
            let manifestURL = try await seed(environment: environment,
                                             route: route,
                                             asset: asset)
            EngineeringPreviewEntryFixtureStore.shared.publish(
                seeded: true, manifestURL: manifestURL)
        } catch {
            EngineeringPreviewEntryFixtureStore.shared.publish(
                error: error.localizedDescription)
        }
        #else
        EngineeringPreviewEntryFixtureStore.shared.publish(
            error: "The engineering preview fixture is simulator-only.")
        #endif
    }

    private static func loadAsset() throws -> FixtureAsset {
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment[assetEnvironmentKey],
              let packed = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !packed.isEmpty,
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data,
              !data.isEmpty,
              let declared = environment[assetSHAEnvironmentKey]?.lowercased()
        else { throw FixtureError.missingAsset }
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == declared else { throw FixtureError.assetDigestMismatch }
        return FixtureAsset(data: data, sha256: actual)
    }

    private static func seed(environment: AppEnvironment,
                             route: EngineeringPreviewEntryRoute,
                             asset: FixtureAsset) async throws -> URL {
        let conversationStore = SQLiteConversationStore(database: environment.database)
        if (try? await conversationStore.conversation(id: conversationID)) == nil {
            try await conversationStore.saveConversation(ConversationRecord(
                id: conversationID, title: conversationTitle,
                createdAt: Date(), updatedAt: Date()))
        }

        let workspaceRecord = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: conversationTitle)
        try await environment.workspaceCenter.openTaskWorkspace(conversationID: conversationID)
        let lease = try await environment.workspaceCenter.acquireTaskRoot(
            workspaceRecord, conversationID: conversationID)
        defer { lease.release() }

        let modelURL = lease.url.appendingPathComponent(workspaceRelativePath)
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try asset.data.write(to: modelURL, options: .atomic)

        // The ordinary attachment route copies the attachment into the task
        // workspace before preview. Seed that exact canonical copy through the
        // fixture so opening the preview does not create a second copy.
        let attachmentRelativePath = "Attachments/\(attachmentID.uuidString)/\(displayName)"
        let attachmentURL = lease.url.appendingPathComponent(attachmentRelativePath)
        try FileManager.default.createDirectory(
            at: attachmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try asset.data.write(to: attachmentURL, options: .atomic)
        let bookmark = try modelURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let attachment = AttachmentRef(
            id: attachmentID,
            conversationID: conversationID,
            messageID: messageID,
            kind: .document,
            displayName: displayName,
            uti: UTType(filenameExtension: "glb")?.identifier ?? "org.khronos.glb",
            byteCount: asset.data.count,
            sha256: asset.sha256,
            storage: .securityScopedBookmark,
            urlBookmark: bookmark,
            relativePath: nil,
            createdAt: Date())
        try await conversationStore.saveAttachment(attachment)

        let existingMessages = (try? await conversationStore.messages(
            conversationID: conversationID)) ?? []
        if !existingMessages.contains(where: { $0.id == messageID }) {
            try await conversationStore.appendMessage(PersistedMessage(
                id: messageID,
                conversationID: conversationID,
                role: "user",
                content: "Preview the attached fixture model.",
                createdAt: Date(),
                parts: [MessagePart(
                    messageID: messageID,
                    partIndex: 0,
                    kind: .file,
                    text: displayName,
                    attachmentID: attachmentID,
                    metadata: [
                        "name": displayName,
                        "mimeType": UTType(filenameExtension: "glb")?
                            .preferredMIMEType ?? "model/gltf-binary",
                    ])],
                runID: nil))
        }

        let stagingURL = try await registerFilesFixture(
            environment: environment, modelURL: modelURL)
        let runOutputURL = try await seedRunOutput(
            environment: environment, modelURL: modelURL, asset: asset)
        let (canvasProjectURL, materialURL) = try await seedCanvas(
            environment: environment, modelURL: modelURL, asset: asset)
        let attachmentWorkspaceSHA256 = try sha256(of: attachmentURL)
        let attachmentStagingSHA256: String?
        if let stagingURL {
            attachmentStagingSHA256 = try sha256(of: stagingURL)
        } else {
            attachmentStagingSHA256 = nil
        }
        let materialSHA256: String?
        if let materialURL {
            materialSHA256 = try sha256(of: materialURL)
        } else {
            materialSHA256 = nil
        }
        let runOutputSHA256: String?
        if let runOutputURL {
            runOutputSHA256 = try sha256(of: runOutputURL)
        } else {
            runOutputSHA256 = nil
        }
        let canvasProjectSHA256: String?
        if let canvasProjectURL {
            canvasProjectSHA256 = try sha256(of: canvasProjectURL)
        } else {
            canvasProjectSHA256 = nil
        }

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let root = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("EngineeringPreviewEntryFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = Manifest(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            route: route.rawValue,
            fixtureOrigin: "Local/Private/providers-cad-20261030/qa/unit-20261029T192524Z/native-artifacts/plate-workflow-hole8-fillet.glb (existing FloeCAD GLB export)",
            fixtureSHA256: asset.sha256,
            fixtureByteCount: asset.data.count,
            modelAbsolutePath: modelURL.path,
            modelSHA256: asset.sha256,
            workspaceAbsolutePath: lease.url.path,
            attachmentWorkspaceAbsolutePath: attachmentURL.path,
            attachmentWorkspaceSHA256: attachmentWorkspaceSHA256,
            attachmentStagingAbsolutePath: stagingURL?.path,
            attachmentStagingSHA256: attachmentStagingSHA256,
            materialAbsolutePath: materialURL?.path,
            materialSHA256: materialSHA256,
            runOutputAbsolutePath: runOutputURL?.path,
            runOutputSHA256: runOutputSHA256,
            canvasProjectAbsolutePath: canvasProjectURL?.path,
            canvasProjectSHA256: canvasProjectSHA256,
            canvasNodeID: canvasNodeID.uuidString,
            attachmentID: attachmentID.uuidString,
            runID: runID.uuidString,
            producerTool: toolName,
            producerCallID: callID,
            note: "All paths are app-owned fixture copies. Compare their SHA-256 after the UI run to prove the preview never rewrote source bytes.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        await environment.conversationCenter.reload()
        return manifestURL
    }

    /// Files tab receives a normal production-picked recent attachment.
    /// Returns the resolved staging URL for the manifest.
    private static func registerFilesFixture(environment: AppEnvironment,
                                             modelURL: URL) async throws -> URL? {
        if let existing = environment.filesCenter.recentFiles.first(where: {
            $0.displayName == displayName
        }) {
            return try? environment.filesCenter.resolveURL(for: existing)
        }
        let attachment = try await environment.filesCenter.registerPickedDocument(
            url: modelURL, displayName: displayName)
        // FilesCenter stages the picked bytes but does not recompute the
        // digest. The fixture records the real source identity on its OWN
        // recent row so the Files entry is not an unverifiable label.
        let digest = try sha256(of: modelURL)
        if let index = environment.filesCenter.recentFiles.firstIndex(where: {
            $0.id == attachment.id
        }) {
            environment.filesCenter.recentFiles[index].sha256 = digest
            environment.filesCenter.recentFiles[index].byteCount = (try? Data(
                contentsOf: modelURL, options: .mappedIfSafe).count) ?? attachment.byteCount
        }
        return try? environment.filesCenter.resolveURL(for: attachment)
    }

    private static func seedRunOutput(environment: AppEnvironment,
                                      modelURL: URL,
                                      asset: FixtureAsset) async throws -> URL? {
        let runStore = SQLiteRunStore(database: environment.database)
        if (try? await runStore.run(id: runID)) == nil {
            try await runStore.saveRun(RunRecord(
                id: runID,
                conversationID: conversationID,
                state: "completed",
                goal: "Qualify the native 3D preview tool-output entry.",
                startedAt: Date().addingTimeInterval(-30),
                endedAt: Date()))
        }
        let events = (try? await runStore.events(runID: runID)) ?? []
        guard let receipt = try makeSealedReceipt(modelURL: modelURL, asset: asset) else {
            throw FixtureError.runOutputSeal
        }
        if events.isEmpty {
            let receiptData = try JSONEncoder().encode([receipt])
            let receiptJSON = String(decoding: receiptData, as: UTF8.self)
            _ = try await runStore.appendEvent(
                runID: runID, kind: .toolRequest,
                payloadJSON: try json([
                    "tool": toolName,
                    "id": callID,
                    "input": "{\"model\":\"\(displayName)\"}",
                    "status": "pending",
                ]))
            _ = try await runStore.appendEvent(
                runID: runID, kind: .toolResult,
                payloadJSON: try json([
                    "tool": toolName,
                    "id": callID,
                    "status": "ok",
                    "summary": "Fixture engineering output was published through RunOutputSnapshotStore.",
                    "outputFilesJSON": receiptJSON,
                ]))
            _ = try await runStore.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: try json(["state": "completed", "reason": "fixture"]))
        }
        switch RunOutputSnapshotStore.verify(receipt) {
        case .verified(let url): return url
        case .missing, .changed, .oversized, .rejected: return nil
        }
    }

    private static func makeSealedReceipt(modelURL: URL,
                                          asset: FixtureAsset) throws -> RunOutputFile? {
        let mime = UTType(filenameExtension: "glb")?.preferredMIMEType ?? "model/gltf-binary"
        let uti = UTType(filenameExtension: "glb")?.identifier ?? "org.khronos.glb"
        let context = ToolContext(
            runID: runID,
            toolCallID: callID,
            cancellation: CancellationToken(),
            conversationID: conversationID)
        let draft = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: toolName,
                slot: "model",
                commit: RunOutputCommit(
                    sourceURL: modelURL,
                    sha256: asset.sha256,
                    byteCount: asset.data.count,
                    displayName: displayName,
                    mimeType: mime,
                    uti: uti)),
            using: context)
        switch RunOutputSnapshotStore.seal(
            drafts: [draft],
            runID: runID,
            taskID: conversationID,
            environmentID: nil,
            callID: callID,
            toolName: toolName) {
        case .sealed(let receipts):
            return receipts.first
        case .rejected:
            return nil
        }
    }

    private static func seedCanvas(environment: AppEnvironment,
                                   modelURL: URL,
                                   asset: FixtureAsset) async throws -> (URL?, URL?) {
        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "Engineering preview entry fixture",
            workspaceID: nil)
        let record = try await CreativeAssetIngestionService(
            assetStore: environment.creativeAssetStore)
            .importLocalFile(modelURL, displayName: "EngineeringEntryPlate")
        guard let localRelativePath = record.localRelativePath else {
            throw FixtureError.canvasProject
        }
        var project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let expectedRevision = project.revision
        guard let documentIndex = project.documents.firstIndex(where: {
            $0.id == project.selectedDocumentID
        }) ?? project.documents.indices.first else {
            throw FixtureError.canvasProject
        }
        let reference = CanvasAssetReference(
            id: record.id,
            contentHash: record.contentHash,
            localRelativePath: localRelativePath,
            cloudRecordName: record.cloudRecordName,
            mimeType: record.mimeType,
            byteCount: record.byteCount,
            sourceURL: record.sourceURL,
            license: record.license)
        let node = CanvasNode(
            id: canvasNodeID,
            kind: .file,
            title: "Engineering entry plate",
            text: "Engineering entry plate",
            position: CanvasPoint(x: 420, y: 320),
            size: CanvasSize(width: 380, height: 300),
            asset: reference,
            metadata: [
                "fixture": "engineering-preview-entry",
                "sourceSHA256": asset.sha256,
            ])
        if let index = project.documents[documentIndex].nodes.firstIndex(where: {
            $0.id == canvasNodeID
        }) {
            project.documents[documentIndex].nodes[index] = node
        } else {
            project.documents[documentIndex].nodes.append(node)
        }
        project.documents[documentIndex].updatedAt = Date()
        project.updatedAt = Date()
        project.revision = expectedRevision + 1
        let projectURL = try WorkspaceCanvasRegistry.projectURL(
            canvasID: canvasID, createDirectory: false)
        try CanvasProjectFileWriter.shared.compareAndSwap(
            project, at: projectURL, expectedRevision: expectedRevision)
        let materialURL = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(localRelativePath)
        return (projectURL, materialURL)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func json(_ values: [String: String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: values, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// The DEBUG route harness. Every branch mounts a REAL product surface; the
/// only qualification-specific additions are stable accessibility selectors
/// on those same views.
struct EngineeringPreviewEntryFixtureHarness: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = EngineeringPreviewEntryFixtureStore.shared

    var body: some View {
        Group {
            if let error = store.error {
                ContentUnavailableView {
                    Label("Engineering entry fixture failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .accessibilityIdentifier("engineeringEntryFixture.error")
            } else if store.seeded,
                      let route = EngineeringPreviewEntryFixture.requestedRoute {
                routeView(route)
            } else {
                ProgressView("Preparing engineering entry fixture…")
                    .accessibilityIdentifier("engineeringEntryFixture.loading")
            }
        }
        .accessibilityIdentifier("engineeringEntryFixture")
    }

    @ViewBuilder
    private func routeView(_ route: EngineeringPreviewEntryRoute) -> some View {
        switch route {
        case .attachment, .toolOutput:
            NavigationStack {
                ThreadDetailView(
                    conversationID: EngineeringPreviewEntryFixture.conversationID,
                    center: environment.conversationCenter)
            }
        case .files:
            NavigationStack {
                FilesView(center: environment.filesCenter)
            }
        case .workspace:
            NavigationStack {
                FileInspectorView(center: environment.workspaceCenter)
            }
        case .ide:
            WorkspaceIDEView(
                initialRelativePath: EngineeringPreviewEntryFixture.workspaceRelativePath,
                center: environment.workspaceCenter)
        case .canvas:
            WorkspaceCanvasView(
                canvasID: EngineeringPreviewEntryFixture.canvasID,
                name: "Engineering preview entry fixture",
                workspace: nil)
        }
    }
}
#endif

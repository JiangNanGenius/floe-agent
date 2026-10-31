// FloeApp — DEBUG-only multi-image artifact gallery UI qualification fixture.
//
// SPDX-License-Identifier: MPL-2.0
//
// Seeds ONE clearly synthetic saved conversation whose completed run carries a
// real image tool result with TWO locally rendered PNG files in the app-owned
// GeneratedImages store. The ordinary chat thread renders the production
// ToolCallCardView, its digest-verified ArtifactImageGallery and the
// full-screen preview — no separate gallery renderer and no ready UIImage is
// injected into production state.
//
// Scope: this proves native display/preview of controlled local bytes. It does
// NOT prove paid image generation, provider entitlement, batching or account
// behavior; the existing provider/controller fixtures cover those separately.
//
// Gated on `-ui-testing` + `--ui-test-multi-image-gallery-fixture`, simulator
// only. Nothing else in the App is read, changed or deleted.
#if DEBUG
import Foundation
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

@MainActor
enum MultiImageArtifactUITestFixture {
    static let launchArgument = "--ui-test-multi-image-gallery-fixture"

    // Fixed synthetic identities. The conversation/run/message are owned by
    // the fixture; no real user history shares these UUIDs.
    static let conversationID = UUID(uuidString: "7B9C1D20-3E4F-4A61-9B72-5C8D1E2F3A10")!
    static let runID = UUID(uuidString: "7B9C1D20-3E4F-4A61-9B72-5C8D1E2F3A20")!
    static let userMessageID = UUID(uuidString: "7B9C1D20-3E4F-4A61-9B72-5C8D1E2F3A30")!
    static let callID = "call-fixture-multi-image"
    static let title = "多图产物显示验收"

    private static let redArtifactID = UUID(uuidString: "6D3A5E10-9C2B-4E71-8A44-0B7F2C9D1A01")!
    private static let blueArtifactID = UUID(uuidString: "6D3A5E10-9C2B-4E71-8A44-0B7F2C9D1A02")!

    private struct LocalArtwork {
        let id: UUID
        let data: Data
    }

    /// Seeds the fixture, reloads the visible conversation list and opens the
    /// exact synthetic run through the real router. A preparation failure
    /// leaves the App on its normal path instead of presenting a fake gallery.
    static func prepareIfRequested(environment: AppEnvironment, router: AppRouter) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        do {
            try await prepare(environment: environment)
        } catch {
            FloeLogger(category: .app).error(
                "multiImageGalleryFixtureFailed errorType=\(String(describing: type(of: error)))")
            return
        }
        await environment.conversationCenter.reload()
        router.openConversation(conversationID, runID: runID)
        #endif
    }

    private static func prepare(environment: AppEnvironment) async throws {
        let conversationStore = SQLiteConversationStore(database: environment.database)
        let runStore = SQLiteRunStore(database: environment.database)
        let existing = try await conversationStore.conversation(id: conversationID)
        if let existing, existing.title != title {
            throw FloeError.validationFailed("The fixture identity belongs to a different conversation.")
        }
        let root = try FloeArtifactStore.root()
        let directory = root.appendingPathComponent("GeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let artworks = [
            LocalArtwork(
                id: redArtifactID,
                data: try artworkData(
                    background: UIColor(red: 0.82, green: 0.14, blue: 0.10, alpha: 1),
                    accent: UIColor(red: 0.98, green: 0.93, blue: 0.85, alpha: 1),
                    variant: 0)
            ),
            LocalArtwork(
                id: blueArtifactID,
                data: try artworkData(
                    background: UIColor(red: 0.08, green: 0.27, blue: 0.76, alpha: 1),
                    accent: UIColor(red: 0.80, green: 0.90, blue: 1.00, alpha: 1),
                    variant: 1)
            )
        ]

        // Write real bytes and derive the receipt from those exact bytes. The
        // production verifier is then run over every reference, so a corrupt
        // fixture cannot masquerade as a successful gallery.
        var references: [ToolArtifactReference] = []
        for artwork in artworks {
            let relativePath = "GeneratedImages/\(artwork.id.uuidString).png"
            let url = root.appendingPathComponent(relativePath)
            try artwork.data.write(to: url, options: .atomic)
            let reference = ToolArtifactReference(
                id: artwork.id,
                relativePath: relativePath,
                mimeType: "image/png",
                byteCount: artwork.data.count,
                sha256: FloeDigest.sha256Hex(artwork.data)
            )
            let verified = try VerifiedToolImageArtifact.load(reference, root: root)
            guard verified.data == artwork.data else {
                throw FloeError.validationFailed("The multi-image fixture bytes did not verify.")
            }
            references.append(reference)
        }
        guard references.count == 2,
              Set(references.map(\.id)).count == references.count,
              Set(references.map(\.sha256)).count == references.count
        else {
            throw FloeError.validationFailed("The multi-image fixture is not two distinct artifacts.")
        }

        var storedReferences: [ToolArtifactReference]?
        if existing != nil {
            storedReferences = await storedArtifactReferences(runStore: runStore)
        }
        let rebuild = existing == nil || storedReferences != references

        if existing != nil, rebuild {
            // Only the fixture-owned conversation is removed. This keeps a
            // relaunch on a new OS/toolchain honest when PNG bytes (and thus
            // the receipt) change between runs.
            try await conversationStore.deleteConversation(id: conversationID)
        }
        if rebuild {
            try await conversationStore.saveConversation(ConversationRecord(
                id: conversationID,
                title: title,
                createdAt: Date(),
                updatedAt: Date()
            ))
            // messages.run_id references runs.id in the real SQLite schema.
            // Create the owned run before its first bound message.
            try await runStore.saveRun(RunRecord(
                id: runID,
                conversationID: conversationID,
                state: "completed",
                goal: "展示两张本地候选图片",
                startedAt: Date().addingTimeInterval(-30),
                endedAt: Date()
            ))
            try await conversationStore.appendMessage(PersistedMessage(
                id: userMessageID,
                conversationID: conversationID,
                role: "user",
                content: "请展示两张本地候选图片。",
                createdAt: Date(),
                runID: runID
            ))
            try await appendFixtureEvents(runStore: runStore, references: references)
        }

        _ = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: title)
        await environment.workspaceCenter.reload()
    }

    /// The current durable refs, decoded from the same nested payload the chat
    /// card consumes. Used only to decide whether the synthetic rows are stale.
    private static func storedArtifactReferences(
        runStore: SQLiteRunStore
    ) async -> [ToolArtifactReference]? {
        guard let events = try? await runStore.events(runID: runID) else { return nil }
        for event in events where event.kind == .toolResult {
            guard let payload = try? JSONDecoder().decode(
                    [String: String].self,
                    from: Data(event.payloadJSON.utf8)),
                  let encoded = payload["artifactRefsJSON"],
                  let data = encoded.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode([ToolArtifactReference].self, from: data)
        }
        return nil
    }

    private static func appendFixtureEvents(
        runStore: SQLiteRunStore,
        references: [ToolArtifactReference]
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let referencesData = try? encoder.encode(references),
              let referencesJSON = String(data: referencesData, encoding: .utf8)
        else {
            throw FloeError.validationFailed("The multi-image fixture references could not be encoded.")
        }

        // A short lead-in keeps the tool card (and therefore the gallery) at
        // the bottom of the completed thread.
        try await runStore.appendEvent(
            runID: runID,
            kind: .assistantText,
            payloadJSON: try json(["text": "两张本地候选图片如下。"])
        )
        try await runStore.appendEvent(
            runID: runID,
            kind: .toolRequest,
            payloadJSON: try json([
                "tool": "image.generate",
                "id": callID,
                "input": #"{"prompt":"synthetic local artwork","count":2}"#,
                "status": "pending"
            ])
        )
        try await runStore.appendEvent(
            runID: runID,
            kind: .toolResult,
            payloadJSON: try json([
                "tool": "image.generate",
                "id": callID,
                "status": "ok",
                "summary": "已保存 2 张本地候选图片",
                "durationMs": "1200",
                "artifactRefsJSON": referencesJSON
            ])
        )
        try await runStore.appendEvent(
            runID: runID,
            kind: .status,
            payloadJSON: #"{"state":"completed","reason":"fixture"}"#
        )
    }

    /// A small asymmetric local bitmap. Both variants are real PNG bytes from
    /// CoreGraphics; no network, provider or generated-AI image is involved.
    private static func artworkData(
        background: UIColor,
        accent: UIColor,
        variant: Int
    ) throws -> Data {
        let size = CGSize(width: 240, height: 72)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            background.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            accent.setFill()
            if variant == 0 {
                cg.saveGState()
                cg.translateBy(x: 120, y: -10)
                cg.rotate(by: .pi / 7)
                cg.fill(CGRect(x: 0, y: 0, width: 26, height: 120))
                cg.restoreGState()
                UIColor.black.withAlphaComponent(0.55).setFill()
                cg.fill(CGRect(x: 18, y: 14, width: 22, height: 22))
            } else {
                cg.fillEllipse(in: CGRect(x: 168, y: 12, width: 46, height: 46))
                UIColor.black.withAlphaComponent(0.55).setFill()
                cg.fill(CGRect(x: 26, y: 16, width: 12, height: 40))
            }
        }
        guard let data = image.pngData(), !data.isEmpty else {
            throw FloeError.validationFailed("The multi-image fixture artwork could not be encoded.")
        }
        return data
    }

    private static func json(_ values: [String: String]) throws -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: values,
                options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8)
        else {
            throw FloeError.validationFailed("The multi-image fixture payload could not be encoded.")
        }
        return encoded
    }
}
#endif

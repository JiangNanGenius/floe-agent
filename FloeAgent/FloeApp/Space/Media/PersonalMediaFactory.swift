// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeWorkbench

/// The library supplies one explicit original directory. Media content never
/// borrows a chat workspace or relies on a chat's lifetime.
enum PersonalMediaFactory {
    static func mediaRoot(directory: URL) -> URL { directory.appendingPathComponent("Media", isDirectory: true) }
    static func create(kind: PersonalContentKind, title: String, id: UUID, directory: URL) async throws {
        guard [.image, .drawing, .video].contains(kind) else { throw PersonalContentError.invalidProject }
        let root = mediaRoot(directory: directory)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        var project = MediaProject(id: id, kind: kind == .video ? .video : .image, name: title,
            canvas: kind == .video ? .init(width: 1920, height: 1080, frameRate: 30) : .init(width: 1600, height: 1200),
            ownerKind: "files", ownerID: id, taskWorkspacePath: root.path)
        if kind == .video { project.videoTimeline = VideoTimeline() }
        else {
            project.imageLayers = [ImageLayer(kind: .fill, name: WorkbenchText.t("背景", "Background"), fillColorHex: kind == .drawing ? "#FFFFFF" : "#FFFFFF00"),
                ImageLayer(kind: .freehand, name: WorkbenchText.t("绘图", "Drawing"), freehand: .init())]
        }
        project = try MediaPreparedUpgrade.upgrade(project)
        if kind == .video, var prepared = project.prepared {
            prepared.trackGraph.tracks = [
                .init(kind: .visual, name: WorkbenchText.t("视频 1", "Video 1")),
                .init(kind: .audio, name: WorkbenchText.t("声音 1", "Audio 1")),
                .init(kind: .caption, name: WorkbenchText.t("字幕", "Captions"))]
            project.prepared = prepared
        }
        try await store.save(project)
        try await verify(kind: kind, id: id, directory: directory)
    }
    static func verify(kind: PersonalContentKind, id: UUID, directory: URL) async throws {
        guard [.image, .drawing, .video].contains(kind) else { throw PersonalContentError.invalidProject }
        let root = mediaRoot(directory: directory)
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        guard let project = try await store.loadProject(id: id),
              project.kind == (kind == .video ? .video : .image), project.prepared != nil else { throw PersonalContentError.invalidProject }
        try MediaPreparedIntegrity.validateEnvelope(project)
    }
    @MainActor static func session(id: UUID, directory: URL) async throws -> MediaV2Session {
        let root = mediaRoot(directory: directory)
        return try await MediaV2Session.open(projectID: id, root: root,
            store: MediaProjectStore(directory: root.appendingPathComponent("Projects")))
    }
    @MainActor static func apply(id: UUID, directory: URL, operations: [MediaPreparedOperation], expectedRevision: Int64) async throws -> MediaPreparedCommit {
        try await session(id: id, directory: directory).apply(operations, expectedRevision: expectedRevision, actor: .model)
    }
    @MainActor static func tool(id: UUID, directory: URL, toolID: String, input: MediaV2ToolInput) async throws -> MediaV2ToolReceipt {
        try await session(id: id, directory: directory).performTool(toolID, input: input, actor: .model)
    }
}

struct PersonalMediaEditorView: View {
    let record: PersonalContentRecord
    let directory: URL
    var onAssistant: (() -> Void)? = nil
    @State private var session: MediaV2Session?
    @State private var diagnostic: String?
    var body: some View {
        Group {
            if let session { MediaV2Workspace(session: session, onAssistant: onAssistant) }
            else if let diagnostic {
                ContentUnavailableView { Label(WorkbenchText.t("无法打开", "Unable to open"), systemImage: "exclamationmark.triangle") }
                    description: { Text(diagnostic) } actions: { Button(WorkbenchText.t("重试", "Retry")) { Task { await load() } } }
            } else { ProgressView() }
        }.task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { note in
                if note.object as? UUID == record.id { Task { try? await session?.reload() } }
            }
    }
    private func load() async {
        do { session = try await PersonalMediaFactory.session(id: record.id, directory: directory); diagnostic = nil }
        catch { diagnostic = error.localizedDescription }
    }
}
#endif

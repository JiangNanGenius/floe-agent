// FloeApp — Workspace coordinator (UI-facing seam for workspaces).
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§4: the single UI entry point
// for workspace CRUD, security-scoped bookmark resolution (resolve + stale
// refresh + touchLastOpened, same pattern as FilesCenter), the per-root
// WorkspaceFileService, recent files, inspector state persistence, and the
// optional FLOE.md agent instruction file (read through the guard, ≤16 KiB,
// never persisted). The agent tool root provider registered in T04 is
// rebound to the currently opened workspace root.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeWorkspace

/// Coordinates workspaces for the UI layer. Views bind only to this center,
/// never to WorkspaceStore or WorkspaceFileService directly.
@MainActor
final class WorkspaceCenter: ObservableObject {

    /// All persisted workspaces in deterministic name order.
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    /// The currently opened workspace, if any.
    @Published private(set) var currentWorkspace: WorkspaceRecord?
    /// Recent files of the current workspace (most recent first).
    @Published private(set) var recentFiles: [RecentFile] = []
    /// Body of the current workspace's FLOE.md, when present and readable.
    @Published private(set) var instructionsBody: String?
    /// Honest error surface for the last failed workspace action.
    @Published var actionError: String?
    /// A save conflict surfaced by the text editor (file changed on disk).
    @Published var conflict: WorkspaceFileConflict?

    /// A write conflict on a workspace file: the editor's base snapshot no
    /// longer matches the on-disk mtime/sha256. Identifiable so it can drive
    /// `.alert(item:)`.
    struct WorkspaceFileConflict: Identifiable, Sendable {
        let id = UUID()
        let relativePath: String
        let detail: String
    }

    let environment: AppEnvironment
    private let store: any WorkspaceStore

    /// File service for the current workspace root, built on open.
    private(set) var fileService: WorkspaceFileService?
    /// Resolved root URL of the current workspace (security-scoped access
    /// stays started while the workspace is open).
    private(set) var currentRootURL: URL?

    /// Maximum size of the agent instruction file body (16 KiB).
    static let instructionsMaxBytes = 16 * 1024
    /// Conventional agent instruction file name (see ARCHITECTURE §7.3).
    static let instructionsFileName = "FLOE.md"

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = SQLiteWorkspaceStore(database: environment.database)
    }

    // MARK: - Listing & creation

    /// Reloads the workspace list from the store.
    func reload() async {
        do {
            workspaces = try await store.workspaces()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Creates a workspace from a picked directory URL (security-scoped).
    /// The URL is bookmarked immediately; only the bookmark enters the
    /// database — never file contents or secrets.
    @discardableResult
    func addWorkspace(fromDirectory url: URL, name: String?) async throws -> WorkspaceRecord {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let record = WorkspaceRecord(
            name: (name?.isEmpty == false ? name : nil) ?? url.lastPathComponent,
            rootBookmark: bookmark
        )
        try await store.saveWorkspace(record)
        await reload()
        return record
    }

    /// Deletes a workspace record (the on-disk directory is never touched).
    func deleteWorkspace(id: UUID) async throws {
        if currentWorkspace?.id == id {
            closeCurrentWorkspace()
        }
        try await store.deleteWorkspace(id: id)
        await reload()
    }

    // MARK: - Opening

    /// Opens a workspace: resolves its security-scoped bookmark (refreshing
    /// it when stale), touches last-opened, loads recent files and FLOE.md,
    /// and points the T04 agent tool root provider at the resolved root.
    func openWorkspace(id: UUID) async throws {
        guard let record = try await store.workspace(id: id) else {
            throw FloeError.notFound("workspace \(id.uuidString)")
        }
        let url = try await resolveRoot(record)
        guard url.startAccessingSecurityScopedResource() else {
            throw FloeError.validationFailed("Workspace folder is not accessible")
        }

        // Stop accessing the previously opened root before switching.
        closeCurrentWorkspace()

        currentRootURL = url
        fileService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: url))
        var opened = record
        opened.lastOpenedAt = Date()
        currentWorkspace = opened
        Self.sharedRootOverride = url

        try await store.touchLastOpened(id: id)
        await reloadRecentFiles()
        await loadInstructions()
    }

    /// Closes the current workspace and releases its security scope.
    func closeCurrentWorkspace() {
        if let url = currentRootURL {
            url.stopAccessingSecurityScopedResource()
        }
        currentRootURL = nil
        fileService = nil
        currentWorkspace = nil
        recentFiles = []
        instructionsBody = nil
        Self.sharedRootOverride = nil
    }

    /// Resolves a workspace root bookmark, refreshing it in the store when
    /// stale (same pattern as FilesCenter.resolveURL).
    private func resolveRoot(_ record: WorkspaceRecord) async throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                var updated = record
                updated.rootBookmark = refreshed
                updated.updatedAt = Date()
                try await store.saveWorkspace(updated)
            }
        }
        return url
    }

    // MARK: - Inspector state

    /// Persists inspector expansion / selection for the current workspace.
    func updateInspectorState(_ state: InspectorState) async {
        guard var record = currentWorkspace else { return }
        record.inspectorState = state
        record.updatedAt = Date()
        currentWorkspace = record
        do {
            try await store.saveWorkspace(record)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Recent files

    /// Records a file open in the current workspace (metadata only).
    func recordRecentFile(relativePath: String, displayName: String) async {
        guard let workspaceID = currentWorkspace?.id else { return }
        do {
            try await store.recordRecentFile(RecentFile(
                workspaceID: workspaceID,
                relativePath: relativePath,
                displayName: displayName,
                lastOpenedAt: Date()
            ))
            await reloadRecentFiles()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reloadRecentFiles() async {
        guard let workspaceID = currentWorkspace?.id else {
            recentFiles = []
            return
        }
        recentFiles = (try? await store.recentFiles(workspaceID: workspaceID)) ?? []
    }

    // MARK: - FLOE.md instructions

    /// Reads the agent instruction file through the guard (≤16 KiB). The
    /// body never enters the database.
    func loadInstructions() async {
        instructionsBody = nil
        guard let record = currentWorkspace, let service = fileService else { return }
        let relative = record.instructionsRelativePath ?? Self.instructionsFileName
        guard let content = try? service.readFile(relative, byteOffset: 0) else { return }
        let bytes = Data(content.text.utf8)
        guard bytes.count <= Self.instructionsMaxBytes else { return }
        instructionsBody = content.text
    }

    // MARK: - Saving (editor conflict surface)

    /// Saves editor text with mtime+sha256 conflict detection. On conflict
    /// nothing is overwritten; `conflict` is set for the UI to resolve
    /// explicitly (same UX contract as FilesCenter).
    func saveFile(
        relativePath: String,
        content: String,
        expectedMtime: Double?,
        expectedSHA256: String?
    ) async throws -> WriteOutcome {
        guard let service = fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        do {
            return try service.writeFile(
                relativePath,
                content: content,
                expectedMtime: expectedMtime,
                expectedSHA256: expectedSHA256
            )
        } catch let error as WorkspaceToolError {
            if case .conflict(let expected, let actual) = error {
                conflict = WorkspaceFileConflict(
                    relativePath: relativePath,
                    detail: "\(expected) → \(actual)"
                )
            }
            throw error
        }
    }

    /// Generates a unified diff between two versions of a file (used to
    /// show agent edits before/after).
    func diff(original: String, modified: String, label: String) -> String {
        fileService?.diff(original: original, modified: modified, label: label) ?? ""
    }

    // MARK: - Conversation context

    /// Attaches a workspace file to a conversation's context: persists an
    /// attachment reference (workspace-relative path + metadata only, never
    /// the body) and a context message part, and links the conversation to
    /// the workspace so approval scopes can resolve it.
    func addFileToConversationContext(
        relativePath: String,
        conversationID: UUID?
    ) async {
        guard let service = fileService, let workspace = currentWorkspace else {
            actionError = String(localized: "inspector.no_workspace")
            return
        }
        guard let conversationID else {
            actionError = String(localized: "inspector.context.no_conversation")
            return
        }
        do {
            let metadata = try service.metadata(relativePath)
            let attachment = AttachmentRef(
                conversationID: conversationID,
                kind: .document,
                displayName: (relativePath as NSString).lastPathComponent,
                uti: metadata.uti,
                byteCount: Int(metadata.size),
                sha256: metadata.sha256,
                storage: .none,
                urlBookmark: nil,
                relativePath: relativePath
            )
            try await environment.conversationStore.saveAttachment(attachment)
            let message = PersistedMessage(
                id: UUID(),
                conversationID: conversationID,
                role: "user",
                content: String(
                    format: String(localized: "inspector.context.added_format"),
                    relativePath
                ),
                createdAt: Date()
            )
            try await environment.conversationStore.appendMessage(message)
            try await store.linkConversation(
                workspaceID: workspace.id,
                conversationID: conversationID
            )
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Agent tool root provider (T04 wiring)

    /// Process-wide override for the current workspace root. Read by the
    /// root provider registered via `registerWorkspaceTools` in
    /// AppEnvironment. Written only on the main actor; read from tool
    /// execution closures. NSLock-free: a class reference read is atomic,
    /// and a stale read degrades to a structured "no workspace" failure or
    /// the previous root — never a crash.
    nonisolated(unsafe) private static var sharedRootOverride: URL?

    /// The root provider handed to `registerWorkspaceTools`.
    static var toolRootProvider: @Sendable () -> URL? {
        { sharedRootOverride }
    }
}
#endif

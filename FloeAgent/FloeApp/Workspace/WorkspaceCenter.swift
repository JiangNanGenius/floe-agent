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
import FloeExecution

/// Coordinates workspaces for the UI layer. Views bind only to this center,
/// never to WorkspaceStore or WorkspaceFileService directly.
@MainActor
final class WorkspaceCenter: ObservableObject {

    struct WorkspaceMount: Codable, Hashable, Identifiable, Sendable {
        var id: String { name }
        var name: String
        var bookmark: Data
        var addedAt: Date
    }

    struct CloudWorkspaceLink: Codable, Hashable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var hostID: UUID
        var remotePath: String
        var daemonPort: Int
        var createdAt: Date
        /// Nil preserves old records and means "external, never delete".
        var cleanupOnConversationDelete: Bool?
    }

    struct TaskRootLease: Sendable {
        let url: URL
        let release: @Sendable () -> Void
    }

    /// All persisted workspaces in deterministic name order.
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    /// Canonical v8 ownership, used by the sidebar tree. One conversation
    /// appears under exactly one project or under Chats.
    @Published private(set) var conversationWorkspaceIDs: [UUID: UUID] = [:]
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
    /// Active virtual folders currently reachable as `Mounts/<name>`.
    @Published private(set) var activeMountNames: [String] = []
    /// Cloud workspace markers currently linked into the private workspace.
    @Published private(set) var cloudWorkspaceLinks: [CloudWorkspaceLink] = []

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
    private var currentRootUsesSecurityScope = false
    private var currentMountScopeURLs: [URL] = []
    /// Invalidates completions from older asynchronous open requests. SwiftUI
    /// pickers can change selection again while bookmark refresh is awaiting.
    private var openGeneration: UInt64 = 0

    /// Maximum size of the agent instruction file body (16 KiB).
    static let instructionsMaxBytes = 16 * 1024
    /// Conventional agent instruction file name (see ARCHITECTURE §7.3).
    static let instructionsFileName = "FLOE.md"
    private static let mountsDirectoryName = "WorkspaceMounts"
    private static let cloudLinksFileName = ".floe-cloud-workspaces.json"

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = SQLiteWorkspaceStore(database: environment.database)
    }

    // MARK: - Listing & creation

    /// Reloads the workspace list from the store.
    func reload() async {
        do {
            workspaces = try await store.workspaces()
            var ownership: [UUID: UUID] = [:]
            for workspace in workspaces {
                for conversationID in try await store.conversations(workspaceID: workspace.id) {
                    ownership[conversationID] = workspace.id
                }
            }
            conversationWorkspaceIDs = ownership
            actionError = nil
        } catch is CancellationError {
            // SwiftUI cancels view-bound reload tasks during navigation. That
            // is an expected lifecycle event, not a workspace failure modal.
        } catch {
            actionError = error.localizedDescription
        }
    }

    var projectWorkspaces: [WorkspaceRecord] {
        workspaces.filter { $0.kind == .project }
    }

    func workspaceID(for conversationID: UUID) -> UUID? {
        conversationWorkspaceIDs[conversationID]
    }

    /// Only external projects belong in the composer project picker. A task's
    /// app-owned private workspace has an intentionally empty bookmark and
    /// must never be opened through the security-scoped project path.
    func projectWorkspaceID(for conversationID: UUID) -> UUID? {
        guard let id = conversationWorkspaceIDs[conversationID],
              workspaces.first(where: { $0.id == id })?.kind == .project else {
            return nil
        }
        return id
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

    /// Deletes a workspace record. User-selected project directories are never
    /// touched; app-owned private task directories are removed with the record.
    func deleteWorkspace(id: UUID) async throws {
        let deleting = try await store.workspace(id: id)
        if currentWorkspace?.id == id {
            closeCurrentWorkspace()
        }
        try await store.deleteWorkspace(id: id)
        if let deleting, deleting.kind == .privateTask {
            try removePrivateWorkspaceDirectory(deleting)
        }
        if let mountsURL = try? mountsStoreURL(workspaceID: id),
           FileManager.default.fileExists(atPath: mountsURL.path) {
            try? FileManager.default.removeItem(at: mountsURL)
        }
        await environment.credentialVault.drainDeletionQueue()
        await reload()
    }

    private func removePrivateWorkspaceDirectory(_ record: WorkspaceRecord) throws {
        guard record.kind == .privateTask, let relative = record.internalRelativePath else { return }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let managedRoot = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .standardizedFileURL
        let target = managedRoot.appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
        guard target.path.hasPrefix(managedRoot.path + "/") else {
            throw FloeError.validationFailed("Invalid private workspace path")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - Opening

    /// Opens a workspace: resolves its security-scoped bookmark (refreshing
    /// it when stale), touches last-opened, loads recent files and FLOE.md,
    /// and points the T04 agent tool root provider at the resolved root.
    func openWorkspace(id: UUID) async throws {
        openGeneration &+= 1
        let generation = openGeneration
        guard let record = try await store.workspace(id: id) else {
            throw FloeError.notFound("workspace \(id.uuidString)")
        }
        guard generation == openGeneration else { return }
        let url = try await resolveRoot(record)
        guard generation == openGeneration else { return }
        guard url.startAccessingSecurityScopedResource() else {
            throw FloeError.validationFailed("Workspace folder is not accessible")
        }
        guard generation == openGeneration else {
            url.stopAccessingSecurityScopedResource()
            return
        }

        // Stop accessing the previously opened root before switching.
        closeCurrentWorkspace(invalidatePendingOpen: false)

        currentRootURL = url
        currentRootUsesSecurityScope = true
        let mounts = try activateMounts(for: record, rootURL: url)
        fileService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: url, mounts: mounts))
        var opened = record
        opened.lastOpenedAt = Date()
        currentWorkspace = opened
        Self.sharedRootOverride = url

        try await store.touchLastOpened(id: id)
        guard generation == openGeneration else { return }
        await reloadRecentFiles()
        guard generation == openGeneration else { return }
        await loadInstructions()
    }

    /// Closes the current workspace and releases its security scope.
    func closeCurrentWorkspace() {
        closeCurrentWorkspace(invalidatePendingOpen: true)
    }

    private func closeCurrentWorkspace(invalidatePendingOpen: Bool) {
        if invalidatePendingOpen { openGeneration &+= 1 }
        if currentRootUsesSecurityScope, let url = currentRootURL {
            url.stopAccessingSecurityScopedResource()
        }
        if let root = currentRootURL {
            WorkspaceMountRegistry.shared.unregister(rootURL: root)
        }
        currentMountScopeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        currentMountScopeURLs = []
        activeMountNames = []
        cloudWorkspaceLinks = []
        currentRootUsesSecurityScope = false
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

    /// Acquires the root belonging to a specific task. Private chats receive
    /// an app-owned directory; projects receive their security-scoped root.
    /// The caller must release the lease when the run becomes terminal.
    func acquireTaskRoot(_ record: WorkspaceRecord, conversationID: UUID) async throws -> TaskRootLease {
        if record.kind == .privateTask {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let relative = record.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
            let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let activation = try activateMountsForLease(for: record, rootURL: root)
            return TaskRootLease(url: root, release: {
                WorkspaceMountRegistry.shared.unregister(rootURL: root)
                activation.scopeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            })
        }

        let root = try await resolveRoot(record)
        guard root.startAccessingSecurityScopedResource() else {
            throw FloeError.validationFailed("Workspace folder is not accessible")
        }
        let activation = try activateMountsForLease(for: record, rootURL: root)
        return TaskRootLease(url: root, release: {
            WorkspaceMountRegistry.shared.unregister(rootURL: root)
            activation.scopeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            root.stopAccessingSecurityScopedResource()
        })
    }

    /// Rebinds the visible file inspector to the selected task's immutable
    /// owner. It closes the previous tree immediately so switching tasks can
    /// never flash or operate on stale files.
    func openTaskWorkspace(conversationID: UUID) async throws {
        if workspaces.isEmpty || conversationWorkspaceIDs[conversationID] == nil {
            await reload()
        }
        var workspaceID = conversationWorkspaceIDs[conversationID]
        var record = workspaceID.flatMap { id in workspaces.first(where: { $0.id == id }) }
        if record == nil {
            guard let conversation = try await environment.conversationStore
                .conversation(id: conversationID) else {
                throw FloeError.notFound("conversation \(conversationID.uuidString)")
            }
            // Repair legacy or partially-migrated tasks in one DB transaction.
            // This is idempotent and never replaces an existing project owner.
            record = try await store.ensureWorkspace(
                conversationID: conversationID,
                title: conversation.title
            )
            await reload()
            workspaceID = record?.id
        }
        guard let record, workspaceID != nil else {
            throw FloeError.notFound("workspace for task \(conversationID.uuidString)")
        }
        if currentWorkspace?.id == record.id,
           currentRootURL != nil,
           fileService != nil {
            return
        }
        if record.kind == .project {
            try await openWorkspace(id: record.id)
            return
        }
        closeCurrentWorkspace()
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let relative = record.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        currentRootURL = root
        currentRootUsesSecurityScope = false
        let mounts = try activateMounts(for: record, rootURL: root)
        fileService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root, mounts: mounts))
        currentWorkspace = record
        Self.sharedRootOverride = root
        await reloadRecentFiles()
        await loadInstructions()
        actionError = nil
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

    /// Creates a directory in the open workspace.
    func createDirectory(relativePath: String) throws {
        guard let service = fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        try service.createDirectory(relativePath)
    }

    /// Deletes a file or directory (recursive when requested).
    func delete(relativePath: String, recursive: Bool = false) throws {
        guard let service = fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        try service.delete(relativePath, recursive: recursive)
    }

    /// Moves (or renames) a file or directory.
    func move(from: String, to: String) throws {
        guard let service = fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        try service.move(from, to: to)
    }

    /// Copies a file or directory.
    func copy(from: String, to: String) throws {
        guard let service = fileService else {
            throw FloeError.validationFailed("No workspace is open")
        }
        try service.copy(from, to: to)
    }

    // MARK: - Imported, mounted, and cloud folders

    /// Live-links a Files/iCloud directory beneath `Mounts/<name>`. The
    /// directory stays in place and is never copied or deleted by Floe.
    func mountExternalFolder(_ url: URL) async throws {
        guard let workspace = currentWorkspace, workspace.kind == .privateTask,
              let root = currentRootURL else {
            throw FloeError.validationFailed("External folders can be mounted only inside a private task workspace")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var records = try loadPersistedMounts(workspaceID: workspace.id)
        let name = uniqueMountName(preferred: url.lastPathComponent, existing: records.map(\.name))
        records.append(WorkspaceMount(name: name, bookmark: bookmark, addedAt: Date()))
        try savePersistedMounts(records, workspaceID: workspace.id)

        // Rebuild the active map without invalidating the workspace itself.
        WorkspaceMountRegistry.shared.unregister(rootURL: root)
        currentMountScopeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        currentMountScopeURLs = []
        let mounts = try activateMounts(for: workspace, rootURL: root)
        fileService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root, mounts: mounts))
    }

    /// Copies an entire selected folder into app-owned storage. This is the
    /// durable/offline alternative to a live security-scoped mount.
    func importFolder(_ url: URL) async throws {
        guard let workspace = currentWorkspace, workspace.kind == .privateTask,
              let root = currentRootURL else {
            throw FloeError.validationFailed("Folders can be imported only into a private task workspace")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let importsRoot = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsRoot, withIntermediateDirectories: true)
        let destinationName = uniqueFilesystemName(preferred: url.lastPathComponent, parent: importsRoot)
        let destination = importsRoot.appendingPathComponent(destinationName, isDirectory: true)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    /// Creates a local, explicit marker for a remote daemon-backed workspace.
    /// Network access still happens through the verified SSH tunnel; this
    /// folder tells the model and UI that its contents are remote, not local.
    @discardableResult
    func linkCloudWorkspace(
        name: String,
        hostID: UUID,
        remotePath: String,
        daemonPort: Int = RemoteAgentPayload.defaultPort,
        cleanupOnConversationDelete: Bool = false
    ) throws -> CloudWorkspaceLink {
        guard currentWorkspace?.kind == .privateTask, let root = currentRootURL else {
            throw FloeError.validationFailed("Cloud workspaces can be linked only inside a private task workspace")
        }
        guard daemonPort > 0, daemonPort <= 65_535 else {
            throw FloeError.validationFailed("Invalid daemon port")
        }
        let safeName = sanitizedFolderName(name.isEmpty ? "Cloud Workspace" : name)
        let cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
        let markerRoot = cloudRoot.appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: markerRoot, withIntermediateDirectories: true)
        let link = CloudWorkspaceLink(
            id: UUID(), name: safeName, hostID: hostID,
            remotePath: remotePath, daemonPort: daemonPort, createdAt: Date(),
            cleanupOnConversationDelete: cleanupOnConversationDelete
        )
        var links = loadCloudWorkspaceLinks(rootURL: root)
        links.removeAll { $0.name == safeName }
        links.append(link)
        let data = try JSONEncoder().encode(links)
        try data.write(to: root.appendingPathComponent(Self.cloudLinksFileName), options: .atomic)
        let readme = """
        # Cloud workspace: \(safeName)

        This folder is linked to remote host \(hostID.uuidString), path `\(remotePath)`.
        Use the Floe remote workspace service through its verified SSH tunnel. Do not treat this marker as a local copy.
        """
        try Data(readme.utf8).write(to: markerRoot.appendingPathComponent("README.md"), options: .atomic)
        cloudWorkspaceLinks = links.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return link
    }

    /// Captures remote deletion intents before local workspace metadata is
    /// removed. Only explicitly app-owned, single-root daemon workspaces are
    /// eligible; arbitrary linked server paths are never recursively deleted.
    func cloudCleanupTombstones(workspaceID: UUID) async -> [CloudWorkspaceCleanupTombstone] {
        guard let record = try? await store.workspace(id: workspaceID),
              record.kind == .privateTask,
              let relative = record.internalRelativePath,
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return [] }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        return loadCloudWorkspaceLinks(rootURL: root).compactMap { link in
            guard link.cleanupOnConversationDelete == true,
                  link.remotePath.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
            else { return nil }
            return CloudWorkspaceCleanupTombstone(hostID: link.hostID, workspaceID: link.remotePath, daemonPort: link.daemonPort)
        }
    }

    /// Produces a disposable folder copy suitable for the system share sheet.
    /// Live mount targets are represented by their local placeholders and are
    /// never silently copied out of the user's selected external directory.
    func prepareWorkspaceExport() throws -> URL {
        guard let workspace = currentWorkspace, let root = currentRootURL else {
            throw FloeError.validationFailed("No workspace is open")
        }
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeWorkspaceExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let destination = exportRoot.appendingPathComponent(
            "\(sanitizedFolderName(workspace.name))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: root, to: destination)
        return destination
    }

    /// Builds bounded, non-secret prompt notes for the active run. The real
    /// security-scoped URLs and remote credentials never enter model context.
    func runtimeWorkspaceNotes(rootURL: URL?) -> [String] {
        guard let rootURL else { return [] }
        let mountedNames = WorkspaceMountRegistry.shared.mounts(for: rootURL).keys.sorted()
        var notes = mountedNames.map {
            "External folder is live-mounted at Mounts/\($0). Changes there affect the user-selected Files folder."
        }
        notes += loadCloudWorkspaceLinks(rootURL: rootURL).map {
            "Cloud workspace '\($0.name)' is linked at Cloud/\($0.name) to host \($0.hostID.uuidString), remote path \($0.remotePath), daemon port \($0.daemonPort). Use cloudWorkspace.* tools rather than reading the local marker."
        }
        return Array(notes.prefix(16))
    }

    private func mountsStoreURL(workspaceID: UUID) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(Self.mountsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func loadPersistedMounts(workspaceID: UUID) throws -> [WorkspaceMount] {
        let url = try mountsStoreURL(workspaceID: workspaceID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([WorkspaceMount].self, from: data)
    }

    private func savePersistedMounts(_ mounts: [WorkspaceMount], workspaceID: UUID) throws {
        let data = try JSONEncoder().encode(mounts)
        try data.write(to: mountsStoreURL(workspaceID: workspaceID), options: .atomic)
    }

    private func activateMounts(for record: WorkspaceRecord, rootURL: URL) throws -> [String: URL] {
        let activation = try activateMountsForLease(for: record, rootURL: rootURL)
        currentMountScopeURLs = activation.scopeURLs
        activeMountNames = activation.mounts.keys.sorted()
        cloudWorkspaceLinks = loadCloudWorkspaceLinks(rootURL: rootURL)
        return activation.mounts
    }

    private func activateMountsForLease(
        for record: WorkspaceRecord,
        rootURL: URL
    ) throws -> (mounts: [String: URL], scopeURLs: [URL]) {
        let records = try loadPersistedMounts(workspaceID: record.id)
        var mounts: [String: URL] = [:]
        var scopes: [URL] = []
        let placeholders = rootURL.appendingPathComponent("Mounts", isDirectory: true)
        if !records.isEmpty { try FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true) }
        for record in records {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark,
                options: [], relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { continue }
            mounts[record.name] = url
            scopes.append(url)
            try? FileManager.default.createDirectory(
                at: placeholders.appendingPathComponent(record.name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        WorkspaceMountRegistry.shared.register(rootURL: rootURL, mounts: mounts)
        return (mounts, scopes)
    }

    private func loadCloudWorkspaceLinks(rootURL: URL) -> [CloudWorkspaceLink] {
        let url = rootURL.appendingPathComponent(Self.cloudLinksFileName)
        guard let data = try? Data(contentsOf: url),
              let links = try? JSONDecoder().decode([CloudWorkspaceLink].self, from: data) else { return [] }
        return links.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func uniqueMountName(preferred: String, existing: [String]) -> String {
        let base = sanitizedFolderName(preferred.isEmpty ? "Folder" : preferred)
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func uniqueFilesystemName(preferred: String, parent: URL) -> String {
        let base = sanitizedFolderName(preferred.isEmpty ? "Imported Folder" : preferred)
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func sanitizedFolderName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let clean = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Workspace" : clean
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
            guard workspaceID(for: conversationID) == workspace.id else {
                throw FloeError.validationFailed("File is outside this task's fixed workspace")
            }
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

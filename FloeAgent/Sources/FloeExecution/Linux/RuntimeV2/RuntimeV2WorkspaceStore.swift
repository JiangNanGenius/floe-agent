// FloeExecution — Runtime v2 workspace store.
//
// Three namespaces with strict ownership rules:
//
//   workspaces/owned/<workspaceID>/   internal workspaces. Persistent (never
//                                   auto-deleted, included in backups).
//   workspaces/refs/<workspaceID>.json  external projects by REFERENCE only:
//                                   the sidecar stores a security-scoped
//                                   bookmark plus a display path. External
//                                   project content is never copied, moved or
//                                   deleted by the runtime.
//   workspaces/scratch/<scratchID>/   temporary workspaces; promoted
//                                   atomically into workspaces/owned only
//                                   when the user asks to persist.
//
// A shared workspace may be mounted by several environments at once; the
// registry row carries an advisory write-session owner and a monotonically
// increasing change generation so mount coordination is explicit without
// copying anything. Legacy PrivateTasks workspaces are adopted as owned
// records pointing at their current location with relocationPending=true —
// physically moving them is the workspace manager's job, recorded here
// honestly instead of faked.

import Foundation
import FloeCore

public actor RuntimeV2WorkspaceStore {
    public struct ExternalRef: Codable, Sendable, Equatable {
        public var workspaceID: String
        /// Security-scoped bookmark data (opaque); the only persisted handle
        /// to an external project. Never the project's content.
        public var bookmark: Data
        public var displayPath: String
        public var registeredAt: Date

        public init(workspaceID: String, bookmark: Data, displayPath: String, registeredAt: Date) {
            self.workspaceID = workspaceID
            self.bookmark = bookmark
            self.displayPath = displayPath
            self.registeredAt = registeredAt
        }
    }

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout, registry: RuntimeV2Registry) {
        self.layout = layout
        self.registry = registry
    }

    // MARK: owned

    /// Creates an internal workspace under workspaces/owned/<id>.
    @discardableResult
    public func createOwned(workspaceID: String) async throws -> URL {
        try RuntimeV2Identifier.validate(workspaceID, kind: .workspace)
        let url = layout.ownedWorkspacesDirectory.appendingPathComponent(workspaceID, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try await registry.upsertWorkspace(
            RuntimeV2Registry.WorkspaceRow(
                id: workspaceID, kind: "owned", path: "workspaces/owned/\(workspaceID)",
                bookmark: nil, displayPath: nil, changeGeneration: 0,
                writeSessionOwner: nil, relocationPending: false,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
        return url
    }

    /// Adopts an existing internal workspace (e.g. a PrivateTasks directory)
    /// as an owned record WITHOUT moving it: the row records the current
    /// absolute path and relocationPending=true. Content is never copied.
    public func adoptLegacyOwned(workspaceID: String, currentPath: URL) async throws {
        try RuntimeV2Identifier.validate(workspaceID, kind: .workspace)
        try await registry.upsertWorkspace(
            RuntimeV2Registry.WorkspaceRow(
                id: workspaceID, kind: "owned", path: currentPath.path,
                bookmark: nil, displayPath: currentPath.lastPathComponent,
                changeGeneration: 0, writeSessionOwner: nil, relocationPending: true,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
    }

    // MARK: external references (reference only, never a copy)

    /// Records an external project as a security-scoped reference. This is
    /// the ONLY write the runtime performs for external workspaces: a JSON
    /// sidecar under workspaces/refs. The project itself is untouched.
    public func registerExternalRef(workspaceID: String, bookmark: Data, displayPath: String) async throws {
        try RuntimeV2Identifier.validate(workspaceID, kind: .workspace)
        let ref = ExternalRef(
            workspaceID: workspaceID, bookmark: bookmark,
            displayPath: displayPath, registeredAt: Date()
        )
        let url = layout.workspaceRefsDirectory.appendingPathComponent("\(workspaceID).json")
        try Self.encoder.encode(ref).write(to: url, options: .atomic)
        try await registry.upsertWorkspace(
            RuntimeV2Registry.WorkspaceRow(
                id: workspaceID, kind: "external-ref", path: nil,
                bookmark: bookmark, displayPath: displayPath, changeGeneration: 0,
                writeSessionOwner: nil, relocationPending: false,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
    }

    public func externalRef(workspaceID: String) throws -> ExternalRef? {
        try RuntimeV2Identifier.validate(workspaceID, kind: .workspace)
        let url = layout.workspaceRefsDirectory.appendingPathComponent("\(workspaceID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try Self.decoder.decode(ExternalRef.self, from: data)
    }

    // MARK: scratch + atomic promotion

    @discardableResult
    public func createScratch(scratchID: String = UUID().uuidString.lowercased()) async throws -> (id: String, url: URL) {
        try RuntimeV2Identifier.validate(scratchID, kind: .scratch)
        let url = layout.scratchWorkspacesDirectory.appendingPathComponent(scratchID, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try await registry.upsertWorkspace(
            RuntimeV2Registry.WorkspaceRow(
                id: scratchID, kind: "scratch", path: "workspaces/scratch/\(scratchID)",
                bookmark: nil, displayPath: nil, changeGeneration: 0,
                writeSessionOwner: nil, relocationPending: false,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
        return (scratchID, url)
    }

    /// Promotes a scratch workspace into workspaces/owned with one atomic
    /// rename (same volume): the only moment scratch content becomes
    /// persistent. The scratch record is replaced by the owned record.
    @discardableResult
    public func promoteScratchToOwned(scratchID: String, workspaceID: String) async throws -> URL {
        try RuntimeV2Identifier.validate(scratchID, kind: .scratch)
        try RuntimeV2Identifier.validate(workspaceID, kind: .workspace)
        let source = layout.scratchWorkspacesDirectory.appendingPathComponent(scratchID, isDirectory: true)
        let destination = layout.ownedWorkspacesDirectory.appendingPathComponent(workspaceID, isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-\(scratchID)", phase: "switched",
                reason: "scratch workspace is missing; nothing was promoted"
            )
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-\(scratchID)", phase: "switched",
                reason: "an owned workspace already exists at \(workspaceID); promotion refused"
            )
        }
        guard rename(source.path, destination.path) == 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: "scratch-\(scratchID)", phase: "switched",
                reason: "atomic promotion rename failed (errno \(errno))"
            )
        }
        try await registry.upsertWorkspace(
            RuntimeV2Registry.WorkspaceRow(
                id: workspaceID, kind: "owned", path: "workspaces/owned/\(workspaceID)",
                bookmark: nil, displayPath: nil, changeGeneration: 0,
                writeSessionOwner: nil, relocationPending: false,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
        return destination
    }

    // MARK: shared-workspace coordination

    /// Advisory write-session claim: bumps the change generation and records
    /// the holding environment. Coordination metadata only — never a copy.
    @discardableResult
    public func claimWriteSession(workspaceID: String, environmentID: String?) async throws -> Int64 {
        try await registry.claimWorkspaceWriteSession(id: workspaceID, environmentID: environmentID)
    }

    public func workspace(id: String) async throws -> RuntimeV2Registry.WorkspaceRow? {
        try await registry.workspace(id: id)
    }

    /// Resolves the on-disk URL for owned/scratch records, contained under
    /// the runtime root. External refs resolve to nil (host-side bookmark
    /// resolution belongs to the workspace manager).
    public func workspaceURL(row: RuntimeV2Registry.WorkspaceRow) throws -> URL? {
        switch row.kind {
        case "owned", "scratch":
            guard let path = row.path else { return nil }
            if path.hasPrefix("/") {
                // Adopted legacy location: outside the runtime root by
                // definition; returned as-is, never followed through a
                // symlink by any runtime file operation.
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return try layout.contain(layout.root.appendingPathComponent(path, isDirectory: true))
        default:
            return nil
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

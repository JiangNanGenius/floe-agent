// SPDX-License-Identifier: MPL-2.0
//
// G07.3B scheduled-task environment ownership proof.
//
// The app-process run domain owns task admission; the ORIGINAL
// `EnvironmentRegistry`/`FloeLinuxAuthority` live in the distinct-UID
// runtime component and are only reachable through the signed runtime IPC
// `environment.list` operation. This file therefore binds the host's FRESH
// metadata snapshot (the exact authority rows the host just read) into a
// narrow ownership gate:
//
//   * a PROJECT container authorizes a scheduled task only when its
//     `ownerID` is exactly the selected workspace UUID;
//   * a SESSION container authorizes an EXISTING conversation only when its
//     `ownerID` is that conversation; a new scheduled task (create intent)
//     can never borrow a session environment owned by an older conversation;
//   * the record must be active, not marked for rebuild and explicitly
//     selected for the settled `.linuxPRoot` backend;
//   * templates/shared layers, a missing record, an expired snapshot or any
//     unknown kind/state fail closed. There is no first-project, temporary
//     directory or host fallback anywhere in this path.
//
// Snapshots are short-lived host registrations, never a second registry:
// `registerHostMetadata` is called from the trusted host immediately before
// a scheduled dispatch or an explicit environment-aware launch, and the
// admission re-validates the exact row it is given. No model output, tool
// argument or imported document can reach this type (the schedule tool
// binding resolver supplies trusted values only).
import Foundation
import FloeCore

/// One authority row as exposed by `FloeLinuxAuthority.list()` /
/// `LinuxAuthorityEnvironmentMetadata`. Metadata ONLY: no layer paths, no
/// variables, no process data.
public struct G073EnvironmentMetadata: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case project
        case session
        case template
        case shared
    }

    public var id: String
    public var kind: Kind
    public var ownerID: String?
    public var name: String?
    public var state: String
    public var requiresRebuild: Bool
    public var executionBackend: String?
    public var parentID: String?
    public var templateID: String?

    public init(id: String, kind: Kind, ownerID: String?, name: String? = nil,
                state: String, requiresRebuild: Bool,
                executionBackend: String?, parentID: String? = nil,
                templateID: String? = nil) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.name = name
        self.state = state
        self.requiresRebuild = requiresRebuild
        self.executionBackend = executionBackend
        self.parentID = parentID
        self.templateID = templateID
    }

    /// The settled Android execution backend. A record without this exact
    /// value is never treated as executable (iOS `.native`/`.linuxVM` are
    /// not Android selections).
    public static let requiredExecutionBackend = "linuxPRoot"

    /// Shared closed validity gate. `expectedProjectOwner` is the workspace
    /// UUID string for project containers; `expectedSessionOwner` is the
    /// conversation UUID string for session containers.
    public func authorizes(projectOwner expectedProjectOwner: String?,
                           sessionOwner expectedSessionOwner: String?) -> Bool {
        guard state == "active", !requiresRebuild,
              executionBackend == Self.requiredExecutionBackend else { return false }
        switch kind {
        case .project:
            guard let expectedProjectOwner, !expectedProjectOwner.isEmpty else { return false }
            // The authority and workspace store may format the same UUID
            // differently; identity is case-insensitive, never fuzzy.
            return ownerID?.lowercased() == expectedProjectOwner.lowercased()
        case .session:
            guard let expectedSessionOwner, !expectedSessionOwner.isEmpty else { return false }
            return ownerID?.lowercased() == expectedSessionOwner.lowercased()
        case .template, .shared:
            return false
        }
    }
}

/// The host's fresh authority listing. Production binds the runtime IPC
/// `environment.list` result; tests bind synthetic rows.
public protocol G073EnvironmentMetadataSource: Sendable {
    func environmentMetadata(id: String) async -> G073EnvironmentMetadata?
    func allEnvironmentMetadata() async -> [G073EnvironmentMetadata]
}

/// A scheduled (create-intent) launch can only prove a PROJECT environment
/// owned by its frozen workspace; it never resolves or accepts a session
/// container owned by a previous conversation. Implemented by the real
/// metadata gate below.
public protocol RunScheduledEnvironmentOwnershipProving: Sendable {
    func proveScheduledEnvironment(
        _ environmentID: String,
        workspaceID: UUID,
        metadata: G073EnvironmentMetadata?,
        epoch: UInt64
    ) async -> Bool
}

/// Host-registered authority rows with a bounded freshness window. This is
/// NOT a registry: it only caches the exact snapshot the trusted host read
/// moments ago so the synchronous launch admission can validate it.
public final class G073ScheduleEnvironmentOwnership: RunEnvironmentOwnershipProving,
    RunScheduledEnvironmentOwnershipProving, @unchecked Sendable {

    /// Snapshot freshness. A stale row is never used for admission; the host
    /// registers a new snapshot immediately before each dispatch/launch.
    public static let maximumSnapshotAge: TimeInterval = 120

    public typealias WorkspaceLookup = @Sendable (UUID) async -> UUID?

    private struct Snapshot {
        var records: [String: G073EnvironmentMetadata]
        var capturedAt: Date
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private let workspaceLookup: WorkspaceLookup

    public init(workspaceLookup: @escaping WorkspaceLookup) {
        self.workspaceLookup = workspaceLookup
    }

    // MARK: Host registration

    /// Registers the exact host-read authority listing. Bounded: at most
    /// 200 rows; blank/oversized identifiers are dropped (never coerced).
    public func registerHostMetadata(_ records: [G073EnvironmentMetadata],
                                     at date: Date = Date()) {
        var map: [String: G073EnvironmentMetadata] = [:]
        for record in records.prefix(200) {
            let id = record.id
            guard !id.isEmpty, id.utf8.count <= 128,
                  !id.contains("\0") else { continue }
            map[id] = record
        }
        lock.lock()
        snapshot = Snapshot(records: map, capturedAt: date)
        lock.unlock()
    }

    public func clearHostMetadata() {
        lock.lock(); snapshot = nil; lock.unlock()
    }

    /// Fresh metadata for one identifier, or nil when the snapshot is
    /// absent/expired. The direct launch request can also carry the exact
    /// row it was dispatched with; callers prefer that one.
    public func metadata(id: String, now: Date = Date()) -> G073EnvironmentMetadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot,
              abs(now.timeIntervalSince(snapshot.capturedAt)) <= Self.maximumSnapshotAge
        else { return nil }
        return snapshot.records[id]
    }

    public func allMetadata(now: Date = Date()) -> [G073EnvironmentMetadata] {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot,
              abs(now.timeIntervalSince(snapshot.capturedAt)) <= Self.maximumSnapshotAge
        else { return [] }
        return snapshot.records.values.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    // MARK: RunEnvironmentOwnershipProving

    /// Existing-conversation role proof. A project container must belong to
    /// the conversation's canonical workspace; a session container must be
    /// owned by THIS conversation and hang under that same project. The
    /// metadata is the host's fresh authority snapshot; without it the
    /// proof fails closed exactly like the previous no-environment build.
    public func proveEnvironment(_ id: String, conversationID: UUID,
                                 epoch: UInt64) async -> Bool {
        guard let metadata = metadata(id: id) else { return false }
        switch metadata.kind {
        case .project:
            guard let workspaceID = await workspaceLookup(conversationID) else {
                return false
            }
            return metadata.authorizes(projectOwner: workspaceID.uuidString,
                                       sessionOwner: nil)
        case .session:
            guard metadata.authorizes(projectOwner: nil,
                                      sessionOwner: conversationID.uuidString) else {
                return false
            }
            // The session's parent must be the SAME conversation's project
            // container. A parentless or foreign-parent session is refused.
            guard let parentID = metadata.parentID,
                  let parent = self.metadata(id: parentID),
                  let workspaceID = await workspaceLookup(conversationID) else {
                return false
            }
            return parent.authorizes(projectOwner: workspaceID.uuidString,
                                     sessionOwner: nil)
        case .template, .shared:
            return false
        }
    }

    public func proveJob(_ id: String, runID: UUID, epoch: UInt64) async -> Bool {
        // Scheduling never grants a job role. Preserve the prior fail-closed
        // answer instead of inventing job ownership.
        false
    }

    // MARK: RunScheduledEnvironmentOwnershipProving

    /// New-task proof. The exact row supplied with the scheduled launch (or
    /// the freshest host snapshot for this id) must be a PROJECT container
    /// owned by the frozen workspace. Session/template/shared rows, a
    /// different owner, stopped/deleting/rebuild rows and an unproven backend
    /// all refuse. No other environment is substituted.
    public func proveScheduledEnvironment(
        _ environmentID: String,
        workspaceID: UUID,
        metadata supplied: G073EnvironmentMetadata?,
        epoch: UInt64
    ) async -> Bool {
        guard let metadata = supplied ?? self.metadata(id: environmentID),
              metadata.id == environmentID else { return false }
        return metadata.kind == .project
            && metadata.authorizes(projectOwner: workspaceID.uuidString,
                                   sessionOwner: nil)
    }
}

/// Convenience wrapper: a source that serves one immutable host snapshot.
/// Useful for the command that registers the runtime `environment.list`
/// result and for deterministic tests.
public struct G073StaticEnvironmentMetadataSource: G073EnvironmentMetadataSource {
    private let records: [String: G073EnvironmentMetadata]

    public init(_ records: [G073EnvironmentMetadata]) {
        var map: [String: G073EnvironmentMetadata] = [:]
        for record in records.prefix(200) { map[record.id] = record }
        self.records = map
    }

    public func environmentMetadata(id: String) async -> G073EnvironmentMetadata? {
        records[id]
    }

    public func allEnvironmentMetadata() async -> [G073EnvironmentMetadata] {
        records.values.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }
}

// FloeExecution — Runtime v2 durable repair exclusion.
//
// A repair hold is the non-expiring sibling of the TTL lease. The lease is a
// cross-process single-writer lock with a TTL so a dead owner can be reclaimed
// after proof; a repair hold is the durable statement "this environment's
// preserved bytes are not yet accounted for — no fresh VM may boot over them
// and no recovery may move them until a human/tool explicitly acknowledges
// repair". It exists for exactly the window the lease cannot cover: after the
// holder dies AND its TTL expires, and after a full-disk / IO / DB fault made
// the registry's repairRequired state unwritable.
//
// Durability rules:
//   - The sidecar (environments/<id>/repair-hold.json) is written BEFORE the
//     lease of a failed capture is released, so the exclusion outlives the
//     process that created it. Checked BEFORE stale-lease reclamation and
//     BEFORE working-disk preparation.
//   - It has no TTL and no pid: it is cleared only by acknowledgeRepair,
//     which first verifies the recoverable state (or verifies there is
//     nothing left to recover) and only then removes the marker and returns
//     the environment to the ordinary stopped flow.
//   - A corrupt hold sidecar is never half-trusted and never silently
//     dropped: it quarantines the unreadable file and answers as an
//     UNREADABLE hold that still excludes until acknowledged.
//   - The quarantined working disk is itself durable evidence: startup
//     recovery re-derives the hold from an orphaned runtime-vm quarantine
//     entry, so a fault that prevented the marker write at stop time can
//     never make the preserved state undiscoverable.

import Foundation
import FloeCore

public actor RuntimeV2RepairHoldStore {
    public struct Hold: Codable, Sendable, Equatable {
        public var version: Int
        public var environmentID: String
        /// The runtime whose preserved bytes motivated the hold ("" when
        /// unknown, e.g. an unreadable sidecar).
        public var runtimeID: String
        /// Human-readable truthful reason the environment is excluded.
        public var reason: String
        /// Layout-relative path of the preserved bytes (quarantine or runtime
        /// directory), nil when unknown or nothing remains.
        public var preservedPath: String?
        public var createdAt: Date

        public static let currentVersion = 1

        public init(
            environmentID: String, runtimeID: String, reason: String,
            preservedPath: String? = nil, createdAt: Date = Date()
        ) {
            self.version = Hold.currentVersion
            self.environmentID = environmentID
            self.runtimeID = runtimeID
            self.reason = reason
            self.preservedPath = preservedPath
            self.createdAt = createdAt
        }
    }

    /// Outcome of verifying the recoverable state before acknowledgement.
    public enum RecoverableState: Sendable, Equatable {
        /// Preserved bytes exist at the layout-relative path.
        case recoverable(preservedPath: String)
        /// No preserved bytes remain (already restored or discarded): the
        /// hold can be cleared without destroying anything.
        case nothingToRecover
    }

    private let layout: RuntimeV2Layout
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.layout = layout
    }

    /// The current hold, or nil when the environment is not excluded. A
    /// corrupt sidecar answers a synthesized unreadable hold: the exclusion
    /// survives until explicitly acknowledged, never fail-open.
    public func hold(environmentID: String) -> Hold? {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
              fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let hold = try? Self.decoder.decode(Hold.self, from: data),
              hold.version == Hold.currentVersion,
              hold.environmentID == environmentID else {
            // Repairable sidecar, same contract as the lease store: the
            // unreadable file is quarantined (never parsed partially, never
            // deleted outright) and the environment STAYS excluded.
            let quarantine = layout.quarantineDirectory
                .appendingPathComponent("repair-hold-\(environmentID)-\(UUID().uuidString).json")
            try? fileManager.moveItem(at: url, to: quarantine)
            return Hold(
                environmentID: environmentID, runtimeID: "",
                reason: "the repair hold sidecar was unreadable; the environment stays excluded until repair is acknowledged",
                preservedPath: nil, createdAt: .distantPast
            )
        }
        return hold
    }

    public func hasHold(environmentID: String) -> Bool {
        hold(environmentID: environmentID) != nil
    }

    /// Places (or refreshes) the durable exclusion. Throws when the marker
    /// itself cannot be persisted (full disk / IO fault): callers must then
    /// keep every other surviving exclusion (the lease) and rely on the
    /// quarantined bytes as the durable evidence.
    public func place(
        environmentID: String, runtimeID: String, reason: String, preservedPath: String? = nil
    ) throws {
        try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        let url = try layout.environmentRepairHoldURL(environmentID: environmentID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hold = Hold(
            environmentID: environmentID, runtimeID: runtimeID,
            reason: reason, preservedPath: preservedPath
        )
        try Self.encoder.encode(hold).write(to: url, options: .atomic)
    }

    /// Verifies the recoverable state an acknowledgement would release.
    public func verifyRecoverable(environmentID: String) -> RecoverableState {
        guard let hold = hold(environmentID: environmentID) else { return .nothingToRecover }
        guard let preservedPath = hold.preservedPath else { return .nothingToRecover }
        let url = layout.root.appendingPathComponent(preservedPath)
        let disk = url.appendingPathComponent("disk.img")
        if fileManager.fileExists(atPath: disk.path) { return .recoverable(preservedPath: preservedPath) }
        return .nothingToRecover
    }

    /// Clears the exclusion after verification. The cleared sidecar is
    /// archived to the recovery evidence directory, never deleted outright.
    public func acknowledge(environmentID: String) {
        guard let url = try? layout.environmentRepairHoldURL(environmentID: environmentID),
              fileManager.fileExists(atPath: url.path) else { return }
        let archive = layout.recoveryMigrationsDirectory
            .appendingPathComponent("repair-holds", isDirectory: true)
        try? fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let destination = archive.appendingPathComponent(
            "repair-hold-\(environmentID)-\(Int(Date().timeIntervalSince1970)).json"
        )
        if (try? fileManager.moveItem(at: url, to: destination)) == nil {
            // The archive move is evidence, not safety: the exclusion itself
            // must clear. Fall back to a plain removal.
            try? fileManager.removeItem(at: url)
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

import Foundation

// FloeCore — Durable design decision outbox.
//
// Adoption/rejection notices must survive a crash in the gap between the
// Canvas CAS commit and the delivery to the originating task. Awaiting the
// sink is NOT enough: the delivery itself can be interrupted. This outbox
// mirrors the CAD/Notes decision-intent pattern:
//
// 1. `prepare` atomically persists a durable `.committing` intent BEFORE the
//    adopting CAS, bound to (canvas, node, candidate, conversation,
//    operationID, decision). If persistence is unavailable the adoption is
//    aborted before the CAS — a decision must never be at risk of loss.
// 2. After the CAS succeeds, the caller delivers the notice through the
//    shared durable ingress and `ack`s the intent.
// 3. `reconcile` (run at launch) repairs crashes using the EXACT operation
//    fingerprint (operationID applied AND candidate in the matching terminal
//    state); lookups that fail stay pending for a later reconcile.
//
// Durability contracts (critical review):
// - ENOENT is the ONLY fresh-start case. A corrupt or newer-schema file, or
//   any read failure on an existing file, makes the outbox READ-ONLY
//   UNAVAILABLE: the original bytes are quarantined (never replaced by an
//   older build), every mutation throws an observable error, and the app can
//   surface the state instead of silently dropping decisions.
// - Pending (`.committing`) intents are NEVER pruned, on disk or in memory.
//   Acknowledged/cancelled records compact to a bounded tail. New work is
//   rejected (before the CAS) when the pending hard cap is reached.
// - Disk and memory are always identical: writes persist first, memory
//   follows, and load applies the same compaction rule.

public struct DesignDecisionIntent: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        /// Durable intent written; the adopting CAS has not been confirmed.
        case committing
        /// Delivered to the originating task and acknowledged.
        case recorded
        /// The exact operation never reached a terminal state; the CAS did
        /// not commit. Durable, so a later reconcile does not re-deliver.
        case cancelled
    }

    public let id: String
    public let canvasID: String
    public let nodeID: String
    public let candidateID: String
    /// The ORIGINATING task the notice belongs to.
    public let conversationID: String
    public let decision: String
    public let operationID: String
    public var phase: Phase
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        canvasID: String,
        nodeID: String,
        candidateID: String,
        conversationID: String,
        decision: String,
        operationID: String,
        phase: Phase = .committing,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.canvasID = canvasID
        self.nodeID = nodeID
        self.candidateID = candidateID
        self.conversationID = conversationID
        self.decision = decision
        self.operationID = operationID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum DesignDecisionOutboxError: Error, Equatable {
    case invalidState(String)
    case persistenceUnavailable(String)
    /// The on-disk state is corrupt, from a newer schema, or unreadable; the
    /// original is quarantined and the outbox refuses writes until resolved.
    case stateUnavailable(String)
    /// Too many undelivered decisions; the caller must abort before the CAS.
    case pendingCapReached(Int)
}

public actor DesignDecisionOutbox {
    public static let shared = DesignDecisionOutbox()

    static let schemaVersion = 1
    /// Pending intents are never pruned; new work is rejected past this cap.
    static let pendingHardCap = 512
    /// Acknowledged/cancelled records compact to the newest tail.
    static let acknowledgedRetention = 128

    struct Envelope: Codable {
        let schemaVersion: Int
        var intents: [DesignDecisionIntent]
    }

    enum StorageState: Sendable {
        /// No file yet (ENOENT): fresh, writable.
        case empty
        /// Readable and writable.
        case loaded(Envelope)
        /// Read-only: the original is quarantined; mutations throw.
        case unavailable(reason: String)
    }

    private let fileURL: URL
    private var state: StorageState
    /// In-flight delivery dedupe within this process.
    private var delivering: Set<String> = []

    /// The default store lives under Application Support — never a tmp
    /// fallback: decision durability must survive tmp cleaning.
    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.init(fileURL: support?
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("DesignDecisions", isDirectory: true)
            .appendingPathComponent("outbox.json")
            ?? URL(fileURLWithPath: "/dev/null/design-decisions-unavailable"))
    }

    /// Test-capable initializer with explicit file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let manager = FileManager.default
        guard fileURL.path != "/dev/null/design-decisions-unavailable" else {
            state = .unavailable(reason: "Application Support is unavailable")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(Envelope.self, from: data) else {
                throw DesignDecisionOutboxError.stateUnavailable("corrupt state")
            }
            guard decoded.schemaVersion <= Self.schemaVersion else {
                throw DesignDecisionOutboxError.stateUnavailable("newer schema v\(decoded.schemaVersion)")
            }
            state = .loaded(Self.compacted(decoded))
        } catch let error as DesignDecisionOutboxError {
            // Corrupt/newer-schema: the canonical bytes stay untouched (this
            // build never writes while unavailable, and the next launch
            // re-detects the same condition, so the read-only guard is
            // durable). A diagnostic COPY is kept alongside; nothing is
            // moved or replaced — an older build must never destroy or
            // substitute newer data.
            let copy = fileURL.appendingPathExtension("unavailable-copy.\(UUID().uuidString.lowercased())")
            try? manager.copyItem(at: fileURL, to: copy)
            state = .unavailable(reason: "\(error) preserved=\(fileURL.lastPathComponent)")
        } catch {
            let nsError = error as NSError
            let isMissing = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            if isMissing {
                // True ENOENT: fresh, writable start.
                state = .empty
            } else {
                // Permission/I/O failure on an existing path: read-only, the
                // original is left untouched; the next launch re-tests.
                state = .unavailable(reason: "read failure: \(error.localizedDescription)")
            }
        }
    }

    /// Why the outbox is unavailable, when it is (for app surfacing).
    public var unavailableReason: String? {
        guard case .unavailable(let reason) = state else { return nil }
        return reason
    }

    public func pendingIntents() -> [DesignDecisionIntent] {
        guard case .loaded(let envelope) = state else { return [] }
        return envelope.intents.filter { $0.phase == .committing }
    }

    /// Atomically persists the intent, THEN records it in memory. Any write
    /// failure throws and leaves both disk and memory unchanged.
    @discardableResult
    public func prepare(_ intent: DesignDecisionIntent) throws -> DesignDecisionIntent {
        try requireWritable()
        let current = envelope()
        // Hard cap: reject new work BEFORE the caller's CAS.
        let pending = current.intents.filter { $0.phase == .committing }.count
        guard pending < Self.pendingHardCap else {
            throw DesignDecisionOutboxError.pendingCapReached(pending)
        }
        var next = current
        next.intents.append(intent)
        try persist(next)
        state = .loaded(Self.compacted(next))
        return intent
    }

    /// Marks the intent delivered. A delivery failure throws and leaves the
    /// intent `.committing` so a later reconcile re-delivers.
    public func markDelivered(id: String) throws {
        try requireWritable()
        var next = envelope()
        guard let index = next.intents.firstIndex(where: { $0.id == id }) else {
            throw DesignDecisionOutboxError.invalidState(id)
        }
        next.intents[index].phase = .recorded
        next.intents[index].updatedAt = Date()
        try persist(next)
        state = .loaded(Self.compacted(next))
    }

    public func cancel(id: String) throws {
        try requireWritable()
        var next = envelope()
        guard let index = next.intents.firstIndex(where: { $0.id == id }) else { return }
        next.intents[index].phase = .cancelled
        next.intents[index].updatedAt = Date()
        try persist(next)
        state = .loaded(Self.compacted(next))
    }

    public enum ReconcileVerdict: Sendable {
        case committed(String)
        case notCommitted
        case unavailable
    }

    public func reconcile(
        terminalDecision: @escaping @Sendable (DesignDecisionIntent) async -> ReconcileVerdict,
        deliver: @escaping @Sendable (DesignDecisionIntent, String) async throws -> Void
    ) async {
        guard case .loaded(let envelope) = state else { return }
        for intent in envelope.intents where intent.phase == .committing && !delivering.contains(intent.id) {
            delivering.insert(intent.id)
            switch await terminalDecision(intent) {
            case .committed(let decision):
                do {
                    try await deliver(intent, decision)
                    try? markDelivered(id: intent.id)
                } catch {
                    // Remains .committing for the next reconcile.
                }
            case .notCommitted:
                try? cancel(id: intent.id)
            case .unavailable:
                break
            }
            delivering.remove(intent.id)
        }
    }

    // MARK: - Internals

    private func envelope() -> Envelope {
        switch state {
        case .empty: return Envelope(schemaVersion: Self.schemaVersion, intents: [])
        case .loaded(let envelope): return envelope
        case .unavailable: return Envelope(schemaVersion: Self.schemaVersion, intents: [])
        }
    }

    private func requireWritable() throws {
        switch state {
        case .empty, .loaded: return
        case .unavailable(let reason):
            throw DesignDecisionOutboxError.stateUnavailable(reason)
        }
    }

    /// Retention rule, applied identically on load and after every write:
    /// ALL pending intents are kept; acknowledged/cancelled compact to the
    /// newest tail. Disk and memory therefore always agree.
    static func compacted(_ envelope: Envelope) -> Envelope {
        var pending: [DesignDecisionIntent] = []
        var settled: [DesignDecisionIntent] = []
        for intent in envelope.intents {
            if intent.phase == .committing { pending.append(intent) } else { settled.append(intent) }
        }
        settled.sort { $0.updatedAt > $1.updatedAt }
        return Envelope(
            schemaVersion: envelope.schemaVersion,
            intents: pending + settled.prefix(acknowledgedRetention)
        )
    }

    private func persist(_ value: Envelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let staging = directory.appendingPathComponent(".outbox-\(UUID().uuidString.lowercased()).staging")
        try data.write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: fileURL)
        }
    }
}

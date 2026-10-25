// FloeAgentRuntime — bounded retention of captured tool results, for paging
// after provider-context compaction.
//
// The runtime already sends each tool result to the provider and, at
// settlement, stores only a compact projection (`ToolReplayPlanner`) in the
// checkpoint; semantic compaction then replaces old messages with a summary.
// Nothing retained the full text the tool actually captured. This store
// closes exactly that gap, under strict rules:
//
//  * it retains only the string the tool layer already produced AFTER its own
//    secret redaction and output sanitisation — it never re-reads raw logs,
//    argv, environment or files;
//  * ownership is the conversation (task) AND the run that produced the
//    capture. A read is resolved from the runtime's trusted configuration and
//    `ToolContext`, never from a model argument, and a capture for another
//    task or another run of the same task is never returned. Within one run
//    the newest settled capture for a call id is the explicit convenience
//    contract; an older occurrence is not archived;
//  * retention is bounded in RAM and on disk by the SAME caps (per result,
//    per task across every run, and in count). A result that exceeds the
//    per-result cap keeps its leading bytes and is explicitly labelled
//    truncated-by-retention (never silently dropped); eviction is recorded
//    and reported honestly at read time, and the exact evicted durable record
//    is removed rather than left behind;
//  * a temporary (ephemeral) conversation is RAM-only: its configuration
//    supplies no durable root, nothing is opened or written for it, and
//    discarding the runtime discards the captures;
//  * one shared app-process store actor exists per canonical durable root
//    (synchronized weak factory), so every runtime and the app's deletion
//    lifecycle observe the same bounded index and the same fence. A
//    temporary conversation gets its own nil-root store;
//  * the durable index is loaded once per task on first access, from
//    generated, validated regular files only, under a bounded scan and
//    bounded per-record reads. A restart therefore reports the same retained
//    set (and applies the same caps/eviction) as the writing process;
//  * a disk write failure is reported as an actual RAM-only provenance state;
//    the store never claims durability it could not achieve;
//  * task cleanup fences the conversation first, then removes RAM and the
//    exact owned directory. A removal failure keeps the directory, persists a
//    retry tombstone (when the root is writable) and is returned to the
//    caller for reporting — never an ignored `try?`;
//  * the store is an internal retention aid, NOT a promise of raw backfill:
//    when nothing was retained (capture disabled at the time, evicted, or a
//    restart without a durable root) reads say so and the caller must not
//    invent content.

import Foundation
import FloeCore

/// One captured tool result. `text` is the post-redaction tool output that
/// entered provider context; `providerCopyCompacted` is informational only
/// (the copy a checkpoint/wire replay later sends may be the compacted
/// excerpt produced by `ToolReplayPlanner`, which is a different thing from
/// execution-capture truncation).
public struct ToolResultCapture: Sendable, Equatable {
    /// Where the bytes backing a read actually live. Only `.durable` survives
    /// a process restart; the other states are reported at read time instead
    /// of being presented as persistence.
    public enum Durability: String, Sendable, Equatable {
        /// Temporary conversation: intentionally RAM-only.
        case memoryOnlyTemporary
        /// Ordinary conversation, but this runtime had no durable root.
        case memoryOnlyNoRoot
        /// Written atomically under the app-owned per-task directory.
        case durable
        /// A durable write was attempted and failed; this RAM copy is the
        /// only one and will not survive a restart.
        case durableWriteFailed
    }

    public var conversationID: UUID
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var status: String
    public var text: String
    /// The tool itself reported that it truncated the captured output
    /// (`stdoutTruncated` / `[output truncated]` style evidence), so this is
    /// an execution-capture limit, not a context-compaction effect.
    public var executionReportedTruncation: Bool
    /// This store kept only the leading bytes of the captured text.
    public var retentionTruncated: Bool
    public var capturedAt: Date
    public var durability: Durability
}

public enum ToolResultCaptureRead: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public var capture: ToolResultCapture
        public var offset: Int
        public var text: String
        public var totalBytes: Int
        public var nextOffset: Int?
        /// The bytes came from the durable per-task directory (for example
        /// after a restart) rather than this process's RAM.
        public var restoredFromDisk: Bool
        /// How many captures with the same call id were evicted from RAM
        /// before this read (informational only).
        public var evictedCopies: Int
    }
    case page(Page)
    case outOfRange(totalBytes: Int, callID: String)
    /// Nothing retained for this call id in this run. `reason` is user-safe
    /// and states whether the value is unknown, never captured, evicted or
    /// belongs to a different run — the caller must not fabricate output.
    case missing(callID: String, reason: String)
    public struct Summary: Sendable, Equatable {
        public var callID: String
        public var toolName: String
        public var totalBytes: Int
        public var executionReportedTruncation: Bool
        public var retentionTruncated: Bool
        public var capturedAt: Date
        public var durability: ToolResultCapture.Durability
    }
    case index([Summary], evicted: Int)
}

/// Honest result of removing one task's captured results. Deliberately not a
/// bare Bool: a caller must be able to report whether the durable directory
/// is gone and whether a launch retry was persisted.
public struct ToolResultCapturePurgeResult: Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable {
        /// The task directory exists but could not be removed.
        case removalFailed
    }
    public var removedDurableDirectory: Bool
    public var failure: Failure?
    /// A retry tombstone was persisted under the store root, so the existing
    /// launch reconciliation pass can reattempt the removal.
    public var retryScheduled: Bool
    public var succeeded: Bool { failure == nil }
}

public actor ToolResultCaptureStore {
    public struct Caps: Sendable, Equatable {
        public var perResultBytes: Int
        public var perTaskBytes: Int
        public var perTaskResults: Int
        public init(perResultBytes: Int = 2 * 1024 * 1024,
                    perTaskBytes: Int = 16 * 1024 * 1024,
                    perTaskResults: Int = 64) {
            self.perResultBytes = max(1, perResultBytes)
            self.perTaskBytes = max(self.perResultBytes, perTaskBytes)
            self.perTaskResults = max(1, perTaskResults)
        }
        public static let standard = Caps()
    }

    private struct Retained {
        var capture: ToolResultCapture
        var sequence: Int
        /// This entry was reconstructed from the durable index rather than
        /// written by this process. Reported to the model as provenance.
        var restoredFromDisk: Bool = false
    }

    private let caps: Caps
    private let durableRoot: URL?
    private var retained: [UUID: [Retained]] = [:]
    private var sequence = 0
    /// Evicted/expired counts per task, so a read can say the copy it wanted
    /// used to exist instead of pretending it never did.
    private var evicted: [UUID: Int] = [:]
    /// Tasks whose durable directory was already loaded into the bounded index
    /// (including empty/failed loads, which are attempted once).
    private var loadedTasks: Set<UUID> = []
    /// Tasks whose deletion lifecycle already fenced late settlements.
    private var fencedConversations: Set<UUID> = []
    /// Scan/read ceilings for restart reload. The cap budget is per task, so a
    /// directory planted with extra files can never turn into an unbounded
    /// startup read.
    private let maximumScannedRecords = 512
    private let maximumReloadReads = 80

    /// - Parameter durableRoot: optional app-provided directory for durable
    ///   per-task capture files. nil keeps this process's captures in RAM
    ///   only; a temporary conversation is always RAM-only regardless.
    public init(durableRoot: URL?, caps: Caps = .standard) {
        self.durableRoot = durableRoot
        self.caps = caps
    }

    /// The one app-process store for a canonical durable root. Runtimes and
    /// the app's conversation-deletion lifecycle must resolve the same actor
    /// so RAM entries, the fence and the durable index cannot diverge. A nil
    /// root is a temporary/unpersisted store and is intentionally not shared.
    public static func shared(durableRoot: URL?, caps: Caps = .standard) -> ToolResultCaptureStore {
        guard let durableRoot else {
            return ToolResultCaptureStore(durableRoot: nil, caps: caps)
        }
        return sharedStoreRegistry.store(for: durableRoot, caps: caps)
    }

    private static let sharedStoreRegistry = ToolResultCaptureStoreRegistry()

    // MARK: - Capture

    /// Retains one already-redacted tool output. Never throws: retention is a
    /// best-effort aid and its absence is reported at read time. The caps are
    /// enforced before any durable write, so an already-evicted result is
    /// never written.
    public func capture(
        conversationID: UUID?,
        runID: UUID,
        callID: String,
        toolName: String,
        status: String,
        text: String,
        temporary: Bool,
        executionReportedTruncation: Bool = false
    ) async {
        guard let conversationID else { return }
        guard !fencedConversations.contains(conversationID) else { return }
        let trimmedCall = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        // The paging tool refuses a call id beyond these bounds, so retaining
        // a longer one would only create an unreachable, larger record. Keep
        // the disk metadata envelope finite without changing any paged
        // identity (a callable id is stored exactly).
        guard !trimmedCall.isEmpty,
              trimmedCall.count <= Self.maximumCallIDCharacters,
              trimmedCall.utf8.count <= Self.maximumCallIDBytes else { return }
        loadDurableTaskIfNeeded(conversationID)
        var stored = text
        var retentionTruncated = false
        if stored.utf8.count > caps.perResultBytes {
            stored = Self.utf8Prefix(stored, maxBytes: caps.perResultBytes)
            retentionTruncated = true
        }
        let intendedDurability: ToolResultCapture.Durability = temporary
            ? .memoryOnlyTemporary
            : (durableRoot == nil ? .memoryOnlyNoRoot : .durable)
        let capture = ToolResultCapture(
            conversationID: conversationID,
            runID: runID,
            callID: trimmedCall,
            toolName: Self.boundedMetadata(toolName, characters: 512, bytes: 2048),
            status: Self.boundedMetadata(status, characters: 64, bytes: 256),
            text: stored,
            executionReportedTruncation: executionReportedTruncation,
            retentionTruncated: retentionTruncated,
            capturedAt: Date(),
            durability: intendedDurability
        )
        sequence += 1
        var entries = retained[conversationID, default: []]
        if let existing = entries.firstIndex(where: {
            $0.capture.callID == trimmedCall && $0.capture.runID == runID
        }) {
            // A replayed call id in the same run replaces its own capture;
            // repeated settlement must not duplicate evidence. The newest
            // occurrence is the explicit convenience contract for this run.
            entries[existing] = Retained(capture: capture, sequence: sequence)
        } else {
            entries.append(Retained(capture: capture, sequence: sequence))
        }
        var (kept, dropped) = enforceCaps(entries)
        for entry in dropped {
            removeOwnedDurableRecord(
                conversationID: conversationID,
                runID: entry.capture.runID,
                callID: entry.capture.callID
            )
        }
        if !dropped.isEmpty { evicted[conversationID, default: 0] += dropped.count }
        // Only persist a capture that actually survived the bounded index.
        if !temporary, durableRoot != nil, !fencedConversations.contains(conversationID),
           let index = kept.firstIndex(where: {
               $0.capture.callID == trimmedCall && $0.capture.runID == runID && $0.sequence == sequence
           }) {
            var final = kept[index]
            if writeDurably(final.capture) {
                final.capture.durability = .durable
            } else {
                final.capture.durability = .durableWriteFailed
            }
            kept[index] = final
        }
        retained[conversationID] = kept
    }

    // MARK: - Read

    /// Bounded read of one captured result. `conversationID` and `runID` must
    /// be the runtime's trusted identities; a capture belonging to another
    /// task or another run is indistinguishable from a missing one.
    public func page(
        conversationID: UUID,
        runID: UUID,
        callID: String,
        offset: Int,
        maxBytes: Int
    ) -> ToolResultCaptureRead {
        let trimmedCall = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCall.isEmpty else {
            return .missing(callID: callID, reason: "no tool-call id was supplied")
        }
        loadDurableTaskIfNeeded(conversationID)
        let matches = (retained[conversationID] ?? []).filter {
            $0.capture.callID == trimmedCall && $0.capture.runID == runID
        }
        var capture: ToolResultCapture?
        var fromDisk = false
        if let newest = matches.max(by: { $0.sequence < $1.sequence }) {
            capture = newest.capture
            fromDisk = newest.restoredFromDisk
        } else if !fencedConversations.contains(conversationID) {
            capture = readDurably(conversationID: conversationID, runID: runID, callID: trimmedCall)
            fromDisk = capture != nil
        }
        guard let capture else {
            let reason: String
            let hasOtherRunCopy = (retained[conversationID] ?? []).contains {
                $0.capture.callID == trimmedCall && $0.capture.runID != runID
            }
            if hasOtherRunCopy {
                reason = "no retained copy exists for this call id in the current run; captures from another run of this task are never paged"
            } else if (evicted[conversationID] ?? 0) > 0 {
                reason = "no retained copy exists in this run (older captures for this task were evicted under the retention bound); re-run only if repeating side effects is safe"
            } else if durableRoot == nil {
                reason = "no retained copy exists (this process does not persist tool results, so captures do not survive a restart); re-run only if repeating side effects is safe"
            } else {
                reason = "no retained copy exists for this call id in this run (it may not have been captured); re-run only if repeating side effects is safe"
            }
            return .missing(callID: trimmedCall, reason: reason)
        }
        let totalBytes = capture.text.utf8.count
        guard maxBytes > 0 else {
            return .outOfRange(totalBytes: totalBytes, callID: trimmedCall)
        }
        let start = max(0, offset)
        guard start < totalBytes || (start == 0 && totalBytes == 0) else {
            return .outOfRange(totalBytes: totalBytes, callID: trimmedCall)
        }
        let page = Self.utf8Window(capture.text, offset: start, maxBytes: maxBytes)
        // An arbitrary offset inside a scalar (or a window smaller than its
        // next scalar) cannot deliver bytes. Never return a non-advancing cursor.
        guard !page.isEmpty || totalBytes == 0 else {
            return .outOfRange(totalBytes: totalBytes, callID: trimmedCall)
        }
        let end = start + page.utf8.count
        return .page(.init(
            capture: capture,
            offset: start,
            text: page,
            totalBytes: totalBytes,
            nextOffset: end < totalBytes ? end : nil,
            restoredFromDisk: fromDisk,
            evictedCopies: evicted[conversationID] ?? 0
        ))
    }

    /// Bounded index of what this run still retains, newest first. The same
    /// conversation + run filter as `page` applies to reloaded records too.
    public func index(
        conversationID: UUID,
        runID: UUID,
        limit: Int = 20
    ) -> ToolResultCaptureRead {
        loadDurableTaskIfNeeded(conversationID)
        let entries = (retained[conversationID] ?? [])
            .filter { $0.capture.runID == runID }
            .sorted { $0.sequence > $1.sequence }
            .prefix(max(1, min(50, limit)))
        return .index(entries.map {
            .init(callID: $0.capture.callID,
                  toolName: $0.capture.toolName,
                  totalBytes: $0.capture.text.utf8.count,
                  executionReportedTruncation: $0.capture.executionReportedTruncation,
                  retentionTruncated: $0.capture.retentionTruncated,
                  capturedAt: $0.capture.capturedAt,
                  durability: $0.capture.durability)
        }, evicted: evicted[conversationID] ?? 0)
    }

    // MARK: - Task cleanup

    /// Removes every retained capture for one task (RAM and the durable
    /// per-task directory). The conversation is fenced FIRST, so a late
    /// settlement that raced the deletion cannot recreate an owned directory.
    /// A removal failure keeps the directory, writes a retry tombstone when
    /// possible and is returned to the caller; it is never silently ignored.
    @discardableResult
    public func purge(conversationID: UUID) -> ToolResultCapturePurgeResult {
        fence(conversationID)
        guard durableRoot != nil else {
            // Nothing durable was ever written for this store (temporary or
            // unpersisted conversation); RAM is already gone.
            return .init(removedDurableDirectory: false, failure: nil, retryScheduled: false)
        }
        if removeDurableDirectory(conversationID: conversationID) {
            removeTombstone(conversationID: conversationID)
            return .init(removedDurableDirectory: true, failure: nil, retryScheduled: false)
        }
        let scheduled = writeTombstone(conversationID: conversationID)
        return .init(
            removedDurableDirectory: false,
            failure: .removalFailed,
            retryScheduled: scheduled
        )
    }

    /// Tasks whose durable removal previously failed and whose retry
    /// tombstone is still present. Bounded and generated-name-only.
    public func pendingPurgeConversationIDs() -> [UUID] {
        guard let root = durableRoot else { return [] }
        let directory = Self.pendingDirectory(root)
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.prefix(maximumScannedRecords).compactMap { name in
            guard name.hasSuffix(".json"), name.count == 36 + 5 else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    /// Reattempts one persisted cleanup tombstone. Idempotent; succeeds when
    /// the owned directory is absent.
    @discardableResult
    public func retryPendingPurge(conversationID: UUID) -> ToolResultCapturePurgeResult {
        fence(conversationID)
        guard durableRoot != nil else {
            return .init(removedDurableDirectory: false, failure: nil, retryScheduled: false)
        }
        if removeDurableDirectory(conversationID: conversationID) {
            removeTombstone(conversationID: conversationID)
            return .init(removedDurableDirectory: true, failure: nil, retryScheduled: false)
        }
        let scheduled = writeTombstone(conversationID: conversationID)
        return .init(removedDurableDirectory: false, failure: .removalFailed, retryScheduled: scheduled)
    }

    /// Drops a stale tombstone for a conversation that still exists: its
    /// captures belong to a live task, so the deletion intent was rolled back.
    @discardableResult
    public func cancelPendingPurge(conversationID: UUID) -> Bool {
        removeTombstone(conversationID: conversationID)
    }

    public func purgeAll() {
        for conversationID in retained.keys { fencedConversations.insert(conversationID) }
        retained.removeAll()
        evicted.removeAll()
    }

    // MARK: - Bounds

    private func fence(_ conversationID: UUID) {
        fencedConversations.insert(conversationID)
        retained.removeValue(forKey: conversationID)
        evicted.removeValue(forKey: conversationID)
        // A fenced task never needs a durable reload; its directory is being
        // removed and any remaining record must not become readable again.
        loadedTasks.insert(conversationID)
    }

    /// FIFO across every run of the task. Returns the retained set and the
    /// exact entries that were dropped, so the caller can delete their owned
    /// durable records and count them.
    private func enforceCaps(_ entries: [Retained]) -> ([Retained], [Retained]) {
        var ordered = entries.sorted { $0.sequence < $1.sequence }
        var dropped: [Retained] = []
        while ordered.count > caps.perTaskResults {
            dropped.append(ordered.removeFirst())
        }
        var totalBytes = ordered.reduce(0) { $0 + $1.capture.text.utf8.count }
        while totalBytes > caps.perTaskBytes, ordered.count > 1 {
            totalBytes -= ordered[0].capture.text.utf8.count
            dropped.append(ordered.removeFirst())
        }
        return (ordered, dropped)
    }

    // MARK: - Durable per-task files

    static let maximumCallIDCharacters = 200
    static let maximumCallIDBytes = 800
    /// Bounded metadata headroom for the JSON header (escaped call id,
    /// tool name and status). Large enough for the worst JSON escape of the
    /// bounded values, so a written record is always readable under the same
    /// envelope.
    static let durableRecordMetadataEnvelopeBytes = 32 * 1024

    /// Finite read/write envelope for one durable record. The payload text is
    /// stored as base64 `Data`, so its encoded size is a fixed 4/3 expansion
    /// of the RAM text cap instead of an unbounded JSON escape of arbitrary
    /// control characters. RAM caps remain the retention authority: both
    /// sides keep the same records, and a record that cannot fit this
    /// envelope is reported as a persistence failure rather than written and
    /// later silently unreadable.
    nonisolated var maximumEncodedRecordBytes: Int {
        let base64 = (caps.perResultBytes / 3 + 1) * 4
        return base64 + Self.durableRecordMetadataEnvelopeBytes
    }

    private static func boundedMetadata(_ value: String, characters: Int, bytes: Int) -> String {
        var clipped = String(value.prefix(max(0, characters)))
        if clipped.utf8.count > bytes {
            clipped = utf8Prefix(clipped, maxBytes: bytes)
        }
        return clipped
    }

    private func durableDirectory(_ root: URL, conversationID: UUID) -> URL {
        root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    /// Run-qualified generated file identity. Two runs of the same task that
    /// reuse a provider call id can never overwrite or read each other.
    static func durableFileName(runID: UUID, callID: String) -> String {
        FloeDigest.sha256Hex(Data("\(runID.uuidString)\u{0}\(callID)".utf8)) + ".json"
    }

    private static func isGeneratedRecordName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), name.count == 64 + 5 else { return false }
        let hashed = name.dropLast(5)
        guard hashed.count == 64 else { return false }
        return hashed.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }

    private static func pendingDirectory(_ root: URL) -> URL {
        root.appendingPathComponent(".pending", isDirectory: true)
    }

    private struct DurableRecord: Codable {
        var conversationID: UUID
        var runID: UUID
        var callID: String
        var toolName: String
        var status: String
        /// Raw UTF-8 payload. JSONEncoder stores `Data` as base64, giving a
        /// predictable encoded size instead of an escape-dependent one.
        var text: Data
        var executionReportedTruncation: Bool
        var retentionTruncated: Bool
        var capturedAt: Date
    }

    /// Loads the task's durable records once, under the same caps as this
    /// process. Only generated file names are considered; each accepted record
    /// is opened with O_NOFOLLOW after an lstat regular-file check and its size
    /// cap is enforced before and during the read.
    private func loadDurableTaskIfNeeded(_ conversationID: UUID) {
        guard !loadedTasks.contains(conversationID) else { return }
        loadedTasks.insert(conversationID)
        guard let root = durableRoot, !fencedConversations.contains(conversationID) else { return }
        let directory = durableDirectory(root, conversationID: conversationID)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let generated = names.filter(Self.isGeneratedRecordName).prefix(maximumScannedRecords)
        var candidates: [(name: String, modified: TimeInterval)] = []
        candidates.reserveCapacity(generated.count)
        for name in generated {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  Int(info.st_size) <= maximumEncodedRecordBytes else { continue }
            #if canImport(Darwin)
            let modified = Double(info.st_mtimespec.tv_sec)
            #else
            let modified = 0.0
            #endif
            candidates.append((name, modified))
        }
        let selected = candidates
            .sorted { left, right in
                left.modified == right.modified ? left.name < right.name : left.modified > right.modified
            }
            .prefix(maximumReloadReads)
        var loaded: [ToolResultCapture] = []
        loaded.reserveCapacity(selected.count)
        for candidate in selected {
            let url = directory.appendingPathComponent(candidate.name)
            if let capture = readDurableRecord(
                at: url,
                conversationID: conversationID,
                expectedName: candidate.name
            ) {
                loaded.append(capture)
            }
        }
        guard !loaded.isEmpty else { return }
        // Newest occurrence wins if a crash left two files for one identity.
        var byIdentity: [String: ToolResultCapture] = [:]
        for capture in loaded {
            let key = "\(capture.runID.uuidString)\u{0}\(capture.callID)"
            if let existing = byIdentity[key], existing.capturedAt >= capture.capturedAt {
                continue
            }
            byIdentity[key] = capture
        }
        var entries = retained[conversationID, default: []]
        for capture in byIdentity.values.sorted(by: { left, right in
            left.capturedAt == right.capturedAt
                ? left.callID < right.callID
                : left.capturedAt < right.capturedAt
        }) {
            sequence += 1
            entries.append(Retained(capture: capture, sequence: sequence, restoredFromDisk: true))
        }
        let (kept, dropped) = enforceCaps(entries)
        for entry in dropped {
            removeOwnedDurableRecord(
                conversationID: conversationID,
                runID: entry.capture.runID,
                callID: entry.capture.callID
            )
        }
        if !dropped.isEmpty { evicted[conversationID, default: 0] += dropped.count }
        retained[conversationID] = kept
    }

    /// Best-effort durable write. Path ownership: the root and the per-task
    /// directory must be (or become) plain directories; the file name is
    /// generated and the write is atomic, so a partial record is never
    /// readable. Returns false on ANY failure so the caller can expose an
    /// honest RAM-only provenance instead of a durability promise.
    private func writeDurably(_ capture: ToolResultCapture) -> Bool {
        guard let root = durableRoot,
              let directory = ensureDurableDirectory(root: root, conversationID: capture.conversationID) else {
            return false
        }
        let record = DurableRecord(
            conversationID: capture.conversationID,
            runID: capture.runID,
            callID: capture.callID,
            toolName: capture.toolName,
            status: capture.status,
            text: Data(capture.text.utf8),
            executionReportedTruncation: capture.executionReportedTruncation,
            retentionTruncated: capture.retentionTruncated,
            capturedAt: capture.capturedAt
        )
        guard let data = try? JSONEncoder().encode(record),
              data.count <= maximumEncodedRecordBytes else { return false }
        let url = directory.appendingPathComponent(
            Self.durableFileName(runID: capture.runID, callID: capture.callID)
        )
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func ensureDurableDirectory(root: URL, conversationID: UUID) -> URL? {
        let fileManager = FileManager.default
        var info = stat()
        // An existing root must itself be a real directory; never follow a
        // planted link at the store root.
        if lstat(root.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        } else {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            guard lstat(root.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        }
        let directory = durableDirectory(root, conversationID: conversationID)
        if lstat(directory.path, &info) == 0 {
            return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) ? directory : nil
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            return nil
        }
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        return directory
    }

    /// Reads one durable record for this task and run only. The file must
    /// still be the exact generated name and a plain regular file within the
    /// size bound; it is opened with O_NOFOLLOW so a symlink planted in the
    /// app-private root cannot redirect the read.
    private func readDurably(conversationID: UUID, runID: UUID, callID: String) -> ToolResultCapture? {
        guard let root = durableRoot else { return nil }
        let directory = durableDirectory(root, conversationID: conversationID)
        let name = Self.durableFileName(runID: runID, callID: callID)
        guard let capture = readDurableRecord(
            at: directory.appendingPathComponent(name),
            conversationID: conversationID,
            expectedName: name
        ), capture.runID == runID, capture.callID == callID else {
            return nil
        }
        return capture
    }

    private func readDurableRecord(
        at url: URL,
        conversationID: UUID,
        expectedName: String
    ) -> ToolResultCapture? {
        #if canImport(Darwin)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        let limit = maximumEncodedRecordBytes
        guard Int(info.st_size) <= limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return nil }
        }
        #else
        return nil
        #endif
        guard let record = try? JSONDecoder().decode(DurableRecord.self, from: data),
              record.conversationID == conversationID,
              !record.callID.isEmpty,
              let decodedText = String(data: record.text, encoding: .utf8),
              Self.durableFileName(runID: record.runID, callID: record.callID) == expectedName else {
            return nil
        }
        var text = decodedText
        var retentionTruncated = record.retentionTruncated
        if text.utf8.count > caps.perResultBytes {
            text = Self.utf8Prefix(text, maxBytes: caps.perResultBytes)
            retentionTruncated = true
        }
        return ToolResultCapture(
            conversationID: record.conversationID,
            runID: record.runID,
            callID: record.callID,
            toolName: record.toolName,
            status: record.status,
            text: text,
            executionReportedTruncation: record.executionReportedTruncation,
            retentionTruncated: retentionTruncated,
            capturedAt: record.capturedAt,
            durability: .durable
        )
    }

    /// Deletes exactly the generated record for this run/call. Only the final
    /// component is unlinked; directories are never recursively removed here.
    private func removeOwnedDurableRecord(conversationID: UUID, runID: UUID, callID: String) {
        guard let root = durableRoot else { return }
        let url = durableDirectory(root, conversationID: conversationID)
            .appendingPathComponent(Self.durableFileName(runID: runID, callID: callID))
        _ = unlink(url.path)
    }

    /// Removes the task directory owned by this store. Absent is success; a
    /// symlink/file at the exact owned name is unlinked without following it;
    /// only a real directory is removed recursively.
    private func removeDurableDirectory(conversationID: UUID) -> Bool {
        guard let root = durableRoot else { return true }
        let directory = durableDirectory(root, conversationID: conversationID)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return true }
        if (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) {
            return unlink(directory.path) == 0 || errno == ENOENT
        }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            return false
        }
    }

    private func tombstoneURL(root: URL, conversationID: UUID) -> URL {
        Self.pendingDirectory(root).appendingPathComponent(conversationID.uuidString + ".json")
    }

    private func writeTombstone(conversationID: UUID) -> Bool {
        guard let root = durableRoot else { return false }
        let directory = Self.pendingDirectory(root)
        let fileManager = FileManager.default
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        } else {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        }
        let url = tombstoneURL(root: root, conversationID: conversationID)
        do {
            try Data().write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func removeTombstone(conversationID: UUID) -> Bool {
        guard let root = durableRoot else { return false }
        return unlink(tombstoneURL(root: root, conversationID: conversationID).path) == 0
            || errno == ENOENT
    }

    // MARK: - UTF-8 safe windows

    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    /// The longest whole-scalar window starting at a UTF-8 byte offset.
    static func utf8Window(_ text: String, offset: Int, maxBytes: Int) -> String {
        let view = text.utf8
        guard offset < view.count, maxBytes > 0 else { return "" }
        let start = view.index(view.startIndex, offsetBy: offset)
        let end = view.index(start, offsetBy: maxBytes, limitedBy: view.endIndex) ?? view.endIndex
        var bytes = Array(view[start..<end])
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}

/// Synchronized weak factory for the one app-process store per canonical
/// durable root. The lock only guards identity resolution; all retention and
/// cleanup state remains actor-isolated.
private final class ToolResultCaptureStoreRegistry: @unchecked Sendable {
    private final class WeakEntry {
        weak var store: ToolResultCaptureStore?
        init(_ store: ToolResultCaptureStore) { self.store = store }
    }

    private let lock = NSLock()
    private var entries: [String: WeakEntry] = [:]

    func store(for root: URL, caps: ToolResultCaptureStore.Caps) -> ToolResultCaptureStore {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key]?.store { return existing }
        let store = ToolResultCaptureStore(durableRoot: root, caps: caps)
        entries = entries.filter { $0.value.store != nil }
        entries[key] = WeakEntry(store)
        return store
    }
}

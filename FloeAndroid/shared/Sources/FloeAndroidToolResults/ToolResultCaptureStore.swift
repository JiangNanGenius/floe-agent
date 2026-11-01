// SPDX-License-Identifier: MPL-2.0
//
// C02 — bounded retention of already-redacted tool results, for paging after
// provider-context compaction or an ordinary task restart.
//
// Ownership is the conversation (task). A read is resolved from the runtime's
// trusted configuration and `ToolContext`, never from a model argument; a
// capture for another task is never returned. Within one task every capture
// has a deterministic `ref` derived from its run/call id, so an ordinary run,
// a delegated child and a later resumed run of the SAME task can all page
// evidence produced earlier.
//
// Retention is bounded in RAM and on disk by the SAME caps (per result, per
// task across every run, and in count). A result that exceeds the per-result
// cap keeps its leading bytes and is explicitly labelled truncated-by-
// retention (never silently dropped); eviction is recorded and reported
// honestly at read time. A temporary conversation is RAM-only. A durable
// write failure is reported as an actual RAM-only provenance state.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
// Bionic exports unlink(2), but the Swift Android overlay does not vend the
// declaration. Declare only the stable ABI fact this store needs.
@_silgen_name("unlink")
private func floeAndroidUnlink(_ path: UnsafePointer<CChar>) -> Int32
#endif

public actor ToolResultCaptureStore {
    public struct Caps: Sendable, Equatable {
        public var perResultBytes: Int
        public var perTaskBytes: Int
        public var perTaskResults: Int

        public init(
            perResultBytes: Int = 2 * 1024 * 1024,
            perTaskBytes: Int = 16 * 1024 * 1024,
            perTaskResults: Int = 64
        ) {
            self.perResultBytes = max(1, perResultBytes)
            self.perTaskBytes = max(self.perResultBytes, perTaskBytes)
            self.perTaskResults = max(1, perTaskResults)
        }

        /// Ordinary durable conversations may capture a much larger full
        /// result than a temporary/RAM-only one. The per-task quota is a hard
        /// bound; a result exceeding the per-result cap is explicitly
        /// truncated-by-retention, never silently claimed complete.
        public static let durableStandard = Caps(
            perResultBytes: 8 * 1024 * 1024,
            perTaskBytes: 64 * 1024 * 1024,
            perTaskResults: 64
        )
        /// Temporary conversations are RAM-only; keeping the smaller quota
        /// makes the absence of a durable copy explicit.
        public static let memoryStandard = Caps(
            perResultBytes: 2 * 1024 * 1024,
            perTaskBytes: 16 * 1024 * 1024,
            perTaskResults: 64
        )
        public static let standard = memoryStandard
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
    /// Restart reload is bounded by the SAME per-task quota as live retention.
    private var maximumReloadBytes: Int { caps.perTaskBytes }

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
    public static func shared(
        durableRoot: URL?,
        caps: Caps? = nil
    ) -> ToolResultCaptureStore {
        let resolvedCaps = caps ?? (durableRoot == nil ? .memoryStandard : .durableStandard)
        guard let durableRoot else {
            return ToolResultCaptureStore(durableRoot: nil, caps: resolvedCaps)
        }
        return sharedStoreRegistry.store(for: durableRoot, caps: resolvedCaps)
    }

    private static let sharedStoreRegistry = ToolResultCaptureStoreRegistry()

    // MARK: - Capture

    /// Retains one already-redacted tool output. Never throws: retention is a
    /// best-effort aid and its absence is reported through the returned
    /// receipt. The caps are enforced before any durable write, so an
    /// already-evicted result is never written.
    @discardableResult
    public func capture(
        conversationID: UUID?,
        runID: UUID,
        callID: String,
        toolName: String,
        status: String,
        text: String,
        temporary: Bool,
        executionReportedTruncation: Bool = false,
        originalDigest: String? = nil
    ) -> ToolResultCaptureReceipt {
        let trimmedCall = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalBytes = text.utf8.count
        let ref = Self.reference(runID: runID, callID: trimmedCall)
        func rejected(_ outcome: ToolResultCaptureReceipt.Outcome) -> ToolResultCaptureReceipt {
            .init(
                outcome: outcome,
                ref: ref,
                runID: runID,
                callID: trimmedCall,
                totalBytes: totalBytes,
                retainedBytes: 0,
                retentionTruncated: false,
                executionReportedTruncation: executionReportedTruncation,
                durability: nil,
                originalDigest: originalDigest
            )
        }
        guard let conversationID else { return rejected(.noTaskBinding) }
        guard !fencedConversations.contains(conversationID) else { return rejected(.taskFenced) }
        // The paging tool refuses a call id beyond these bounds, so retaining
        // a longer one would only create an unreachable, larger record.
        guard !trimmedCall.isEmpty,
              trimmedCall.count <= Self.maximumCallIDCharacters,
              trimmedCall.utf8.count <= Self.maximumCallIDBytes else {
            return rejected(.invalidCallID)
        }
        loadDurableTaskIfNeeded(conversationID)
        var stored = text
        var retentionTruncated = false
        if stored.utf8.count > caps.perResultBytes {
            stored = ToolResultUTF8.prefix(stored, maxBytes: caps.perResultBytes)
            retentionTruncated = true
        }
        let retainedSHA = FloeDigest.sha256Hex(Data(stored.utf8))
        let digest = Self.boundedDigest(originalDigest)
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
            durability: intendedDurability,
            sha256: retainedSHA,
            originalDigest: digest
        )
        sequence += 1
        var entries = retained[conversationID, default: []]
        if let existing = entries.firstIndex(where: {
            $0.capture.callID == trimmedCall && $0.capture.runID == runID
        }) {
            // A replayed call id in the same run replaces its own capture;
            // repeated settlement must not duplicate evidence.
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
        guard kept.contains(where: {
            $0.capture.callID == trimmedCall && $0.capture.runID == runID && $0.sequence == sequence
        }) else {
            retained[conversationID] = kept
            return rejected(.evictedImmediately)
        }
        // Only persist a capture that actually survived the bounded index.
        var finalDurability = intendedDurability
        if !temporary, durableRoot != nil, !fencedConversations.contains(conversationID),
           let index = kept.firstIndex(where: {
               $0.capture.callID == trimmedCall && $0.capture.runID == runID && $0.sequence == sequence
           }) {
            var final = kept[index]
            final.capture.durability = writeDurably(final.capture) ? .durable : .durableWriteFailed
            finalDurability = final.capture.durability
            kept[index] = final
        }
        retained[conversationID] = kept
        return .init(
            outcome: .retained,
            ref: ref,
            runID: runID,
            callID: trimmedCall,
            totalBytes: totalBytes,
            retainedBytes: stored.utf8.count,
            retentionTruncated: retentionTruncated,
            executionReportedTruncation: executionReportedTruncation,
            durability: finalDurability,
            sha256: retainedSHA,
            originalDigest: digest
        )
    }

    // MARK: - Read

    /// Bounded read by the deterministic capture ref. The ref is resolved
    /// inside this trusted task only; a ref belonging to another task is
    /// indistinguishable from a missing one.
    public func page(
        conversationID: UUID,
        ref: String,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String? = nil
    ) -> ToolResultCaptureRead {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .missing(callID: ref, reason: "no capture ref was supplied")
        }
        loadDurableTaskIfNeeded(conversationID)
        let matches = (retained[conversationID] ?? []).filter { $0.capture.ref == trimmed }
        if let newest = matches.max(by: { $0.sequence < $1.sequence }) {
            return makePage(
                capture: newest.capture,
                fromDisk: newest.restoredFromDisk,
                evicted: evicted[conversationID] ?? 0,
                offset: offset,
                maxBytes: maxBytes,
                expectedSHA256: expectedSHA256
            )
        }
        guard !fencedConversations.contains(conversationID) else {
            return .missing(callID: trimmed, reason: "this task was deleted; no captured result can be read")
        }
        if let restored = readDurablyByReference(conversationID: conversationID, ref: trimmed) {
            return makePage(
                capture: restored,
                fromDisk: true,
                evicted: evicted[conversationID] ?? 0,
                offset: offset,
                maxBytes: maxBytes,
                expectedSHA256: expectedSHA256
            )
        }
        return .missing(callID: trimmed, reason: missingReason(
            conversationID: conversationID,
            exactRef: true
        ))
    }

    /// Convenience lookup by call id within this task. The current run's
    /// newest settlement wins; otherwise the task's newest remaining capture
    /// for that call id is returned, with its run identity in the page.
    public func page(
        conversationID: UUID,
        runID: UUID,
        callID: String,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String? = nil,
        fallbackToTask: Bool = true
    ) -> ToolResultCaptureRead {
        let trimmedCall = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCall.isEmpty else {
            return .missing(callID: callID, reason: "no tool-call id was supplied")
        }
        loadDurableTaskIfNeeded(conversationID)
        let matches = (retained[conversationID] ?? []).filter { $0.capture.callID == trimmedCall }
        let currentRun = matches.filter { $0.capture.runID == runID }
        if let newest = currentRun.max(by: { $0.sequence < $1.sequence }) {
            return makePage(
                capture: newest.capture,
                fromDisk: newest.restoredFromDisk,
                evicted: evicted[conversationID] ?? 0,
                offset: offset,
                maxBytes: maxBytes,
                expectedSHA256: expectedSHA256
            )
        }
        if fallbackToTask, let newestTaskCopy = matches.max(by: { $0.sequence < $1.sequence }) {
            return makePage(
                capture: newestTaskCopy.capture,
                fromDisk: newestTaskCopy.restoredFromDisk,
                evicted: evicted[conversationID] ?? 0,
                offset: offset,
                maxBytes: maxBytes,
                expectedSHA256: expectedSHA256
            )
        }
        guard !fencedConversations.contains(conversationID) else {
            return .missing(callID: trimmedCall, reason: "this task was deleted; no captured result can be read")
        }
        if let restored = readDurablyForCall(
            conversationID: conversationID,
            runID: runID,
            callID: trimmedCall
        ) {
            return makePage(
                capture: restored,
                fromDisk: true,
                evicted: evicted[conversationID] ?? 0,
                offset: offset,
                maxBytes: maxBytes,
                expectedSHA256: expectedSHA256
            )
        }
        return .missing(callID: trimmedCall, reason: missingReason(
            conversationID: conversationID,
            exactRef: false
        ))
    }

    /// Bounded literal search over this task's retained captures (newest
    /// first). Searches the post-redaction retained text only, never a live
    /// tool, and reports when a bound stopped the scan early.
    public func search(
        conversationID: UUID,
        query: String,
        limit: Int = 10,
        maximumCaptures: Int = 32,
        maximumBytes: Int = 8 * 1024 * 1024
    ) -> ToolResultCaptureRead {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return .search(.init(hits: [], searchedCaptures: 0, searchedBytes: 0, truncated: false))
        }
        loadDurableTaskIfNeeded(conversationID)
        let ordered = (retained[conversationID] ?? []).sorted { $0.sequence > $1.sequence }
        var hits: [ToolResultCaptureRead.SearchHit] = []
        var scannedBytes = 0
        var scannedCaptures = 0
        var truncated = false
        for entry in ordered {
            if hits.count >= max(1, min(50, limit)) {
                truncated = true
                break
            }
            if scannedCaptures >= max(1, maximumCaptures) {
                truncated = true
                break
            }
            let text = entry.capture.text
            let size = text.utf8.count
            if scannedBytes + size > max(1, maximumBytes) {
                truncated = true
                break
            }
            scannedBytes += size
            scannedCaptures += 1
            guard let match = Self.firstMatch(of: needle, in: text) else { continue }
            hits.append(.init(
                ref: entry.capture.ref,
                runID: entry.capture.runID,
                callID: entry.capture.callID,
                toolName: entry.capture.toolName,
                totalBytes: size,
                matchOffset: match.offset,
                excerpt: Self.excerpt(around: match.offset, in: text),
                hasAdditionalMatches: Self.firstMatch(
                    of: needle,
                    in: ToolResultUTF8.window(text, offset: match.offset + max(1, match.length), maxBytes: size)
                ) != nil,
                sha256: entry.capture.sha256
            ))
        }
        return .search(.init(
            hits: hits,
            searchedCaptures: scannedCaptures,
            searchedBytes: scannedBytes,
            truncated: truncated
        ))
    }

    /// Full retained text for request selection (never a re-execution).
    public func retainedText(conversationID: UUID, ref: String) -> String? {
        retainedCapture(conversationID: conversationID, ref: ref)?.text
    }

    /// Full retained capture metadata for request selection and markers.
    public func retainedCapture(conversationID: UUID, ref: String) -> ToolResultCapture? {
        guard Self.isGeneratedReference(ref) else { return nil }
        loadDurableTaskIfNeeded(conversationID)
        if let newest = (retained[conversationID] ?? [])
            .filter({ $0.capture.ref == ref })
            .max(by: { $0.sequence < $1.sequence }) {
            return newest.capture
        }
        guard !fencedConversations.contains(conversationID) else { return nil }
        return readDurablyByReference(conversationID: conversationID, ref: ref)
    }

    /// Bounded index of what this run still retains, newest first.
    public func index(
        conversationID: UUID,
        runID: UUID,
        limit: Int = 20
    ) -> ToolResultCaptureRead {
        taskIndex(conversationID: conversationID, runID: runID, limit: limit)
    }

    /// Bounded index across every run of this task (newest first).
    public func taskIndex(
        conversationID: UUID,
        runID: UUID? = nil,
        limit: Int = 20
    ) -> ToolResultCaptureRead {
        loadDurableTaskIfNeeded(conversationID)
        let entries = (retained[conversationID] ?? [])
            .filter { runID == nil || $0.capture.runID == runID }
            .sorted { $0.sequence > $1.sequence }
            .prefix(max(1, min(50, limit)))
        return .index(entries.map {
            ToolResultCaptureSummary(
                ref: $0.capture.ref,
                runID: $0.capture.runID,
                callID: $0.capture.callID,
                toolName: $0.capture.toolName,
                totalBytes: $0.capture.text.utf8.count,
                executionReportedTruncation: $0.capture.executionReportedTruncation,
                retentionTruncated: $0.capture.retentionTruncated,
                capturedAt: $0.capture.capturedAt,
                durability: $0.capture.durability,
                sha256: $0.capture.sha256,
                originalDigest: $0.capture.originalDigest
            )
        }, evicted: evicted[conversationID] ?? 0)
    }

    /// Deterministic reference derivation. Full SHA-256 over the trusted
    /// run/call pair is also the durable file name; the ref keeps 24 hex
    /// characters (96 bits) so a summary stays readable while collisions
    /// remain negligible and are still resolved against the full identity.
    public static func reference(runID: UUID, callID: String) -> String {
        let digest = FloeDigest.sha256Hex(Data("\(runID.uuidString)\u{0}\(callID)".utf8))
        return "tr_" + digest.prefix(24)
    }

    /// Validates that a ref has the exact generated shape.
    public static func isGeneratedReference(_ ref: String) -> Bool {
        guard ref.count == 27, ref.hasPrefix("tr_") else { return false }
        let hex = ref.dropFirst(3)
        return hex.count == 24 && hex.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }

    static func firstMatch(of needle: String, in text: String) -> (offset: Int, length: Int)? {
        guard !needle.isEmpty else { return nil }
        let haystack = text.utf8
        let needleBytes = Array(needle.utf8)
        guard needleBytes.count <= haystack.count else { return nil }
        let bytes = Array(haystack)
        var index = 0
        let last = bytes.count - needleBytes.count
        while index <= last {
            if bytes[index] == needleBytes[0] {
                var matched = true
                for offset in 1..<needleBytes.count where bytes[index + offset] != needleBytes[offset] {
                    matched = false
                    break
                }
                if matched { return (index, needleBytes.count) }
            }
            index += 1
        }
        return nil
    }

    /// Deterministic, bounded excerpt around one byte offset. Whole-scalar
    /// boundaries only; never returns a head/tail summary of the whole body.
    static func excerpt(around offset: Int, in text: String, radius: Int = 240) -> String {
        var start = max(0, offset - radius)
        // A search hit is at a scalar boundary, but `offset - radius` need
        // not be. Advance to the next whole-scalar boundary instead of
        // returning an empty excerpt for a multibyte body.
        let bytes = Array(text.utf8)
        while start < bytes.count && (bytes[start] & 0xC0) == 0x80 {
            start += 1
        }
        let prefix = start > 0 ? "…" : ""
        let window = ToolResultUTF8.window(text, offset: start, maxBytes: radius * 2)
        let suffix = start + window.utf8.count < text.utf8.count ? "…" : ""
        return prefix + window + suffix
    }

    // MARK: - Task cleanup

    /// Removes every retained capture for one task (RAM and the durable
    /// per-task directory). The conversation is fenced FIRST, so a late
    /// settlement that raced the deletion cannot recreate an owned directory.
    @discardableResult
    public func purge(conversationID: UUID) -> ToolResultCapturePurgeResult {
        fence(conversationID)
        guard durableRoot != nil else {
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
        guard isPlainDirectory(directory.path),
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

    /// Drops a stale tombstone for a conversation that still exists.
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
        loadedTasks.insert(conversationID)
    }

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

    private func makePage(
        capture: ToolResultCapture,
        fromDisk: Bool,
        evicted: Int,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String?
    ) -> ToolResultCaptureRead {
        let totalBytes = capture.text.utf8.count
        if let expected = expectedSHA256, expected != capture.sha256 {
            return .changed(
                callID: capture.ref,
                expectedSHA256: expected,
                actualSHA256: capture.sha256
            )
        }
        guard maxBytes > 0 else {
            return .outOfRange(totalBytes: totalBytes, callID: capture.ref)
        }
        let start = max(0, offset)
        guard start < totalBytes || (start == 0 && totalBytes == 0) else {
            return .outOfRange(totalBytes: totalBytes, callID: capture.ref)
        }
        let page = ToolResultUTF8.window(capture.text, offset: start, maxBytes: maxBytes)
        guard !page.isEmpty || totalBytes == 0 else {
            return .outOfRange(totalBytes: totalBytes, callID: capture.ref)
        }
        let end = start + page.utf8.count
        return .page(.init(
            capture: capture,
            ref: capture.ref,
            runID: capture.runID,
            offset: start,
            endOffset: end,
            text: page,
            totalBytes: totalBytes,
            nextOffset: end < totalBytes ? end : nil,
            restoredFromDisk: fromDisk,
            evictedCopies: evicted
        ))
    }

    private func missingReason(conversationID: UUID, exactRef: Bool) -> String {
        if let evicted = evicted[conversationID], evicted > 0 {
            return "no retained copy exists for this task (older captures were evicted under the retention bound); re-run only if repeating side effects is safe"
        }
        if durableRoot == nil {
            return "no retained copy exists (this process does not persist tool results, so captures do not survive a restart); re-run only if repeating side effects is safe"
        }
        return exactRef
            ? "no retained capture exists for this ref in this task (it may have been evicted or never captured); re-run only if repeating side effects is safe"
            : "no retained copy exists for this call id in this task (it may not have been captured); re-run only if repeating side effects is safe"
    }

    // MARK: - Durable per-task files

    public static let maximumCallIDCharacters = 200
    public static let maximumCallIDBytes = 800
    /// Bounded metadata headroom for the JSON header (escaped call id, tool
    /// name and status).
    static let durableRecordMetadataEnvelopeBytes = 40 * 1024

    private var maximumEncodedRecordBytes: Int {
        let base64 = (caps.perResultBytes / 3 + 1) * 4
        return base64 + Self.durableRecordMetadataEnvelopeBytes
    }

    private static func boundedDigest(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64,
              trimmed.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
        else { return nil }
        return trimmed
    }

    private static func boundedMetadata(_ value: String, characters: Int, bytes: Int) -> String {
        var clipped = String(value.prefix(max(0, characters)))
        if clipped.utf8.count > bytes {
            clipped = ToolResultUTF8.prefix(clipped, maxBytes: bytes)
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
        var sha256: String?
        var originalDigest: String?
    }

    /// Loads the task's durable records once, under the same caps as this
    /// process. Only generated file names are considered; each accepted record
    /// is opened with O_NOFOLLOW and its size cap is enforced before and during
    /// the read.
    private func loadDurableTaskIfNeeded(_ conversationID: UUID) {
        guard !loadedTasks.contains(conversationID) else { return }
        loadedTasks.insert(conversationID)
        guard let root = durableRoot, !fencedConversations.contains(conversationID) else { return }
        let directory = durableDirectory(root, conversationID: conversationID)
        guard isPlainDirectory(directory.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let generated = names.filter(Self.isGeneratedRecordName).prefix(maximumScannedRecords)
        var candidates: [(name: String, modified: TimeInterval, bytes: Int)] = []
        candidates.reserveCapacity(generated.count)
        for name in generated {
            let url = directory.appendingPathComponent(name)
            guard let metadata = Self.plainRegularFileMetadata(url.path),
                  metadata.bytes <= maximumEncodedRecordBytes else { continue }
            candidates.append((name, metadata.modified, metadata.bytes))
        }
        let orderedCandidates = candidates.sorted { left, right in
            left.modified == right.modified ? left.name < right.name : left.modified > right.modified
        }
        var selected: [(name: String, modified: TimeInterval, bytes: Int)] = []
        var reloadBytes = 0
        for candidate in orderedCandidates {
            guard selected.count < maximumReloadReads else { break }
            guard reloadBytes + candidate.bytes <= maximumReloadBytes || selected.isEmpty else { break }
            selected.append(candidate)
            reloadBytes += candidate.bytes
        }
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
    /// generated and the write is atomic. Returns false on ANY failure so the
    /// caller can expose an honest RAM-only provenance instead of a durability
    /// promise.
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
            capturedAt: capture.capturedAt,
            sha256: capture.sha256,
            originalDigest: capture.originalDigest
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
        switch pathKind(root.path) {
        case .directory:
            break
        case .missing:
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            guard pathKind(root.path) == .directory else { return nil }
        case .other, .error:
            return nil
        }
        let directory = durableDirectory(root, conversationID: conversationID)
        switch pathKind(directory.path) {
        case .directory:
            return directory
        case .missing:
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                return nil
            }
            return pathKind(directory.path) == .directory ? directory : nil
        case .other, .error:
            return nil
        }
    }

    private func readDurablyForCall(
        conversationID: UUID,
        runID: UUID,
        callID: String
    ) -> ToolResultCapture? {
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

    private func readDurablyByReference(conversationID: UUID, ref: String) -> ToolResultCapture? {
        guard Self.isGeneratedReference(ref), let root = durableRoot else { return nil }
        let directory = durableDirectory(root, conversationID: conversationID)
        guard isPlainDirectory(directory.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for name in names.filter(Self.isGeneratedRecordName).prefix(maximumScannedRecords) {
            guard let capture = readDurableRecord(
                at: directory.appendingPathComponent(name),
                conversationID: conversationID,
                expectedName: name
            ), capture.ref == ref else { continue }
            return capture
        }
        return nil
    }

    private func readDurableRecord(
        at url: URL,
        conversationID: UUID,
        expectedName: String
    ) -> ToolResultCapture? {
        let limit = maximumEncodedRecordBytes
        let data: Data
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        #elseif canImport(Glibc)
        let fd = Glibc.open(url.path, O_RDONLY | O_NOFOLLOW)
        #elseif canImport(Android)
        let fd = Android.open(url.path, O_RDONLY | O_NOFOLLOW)
        #else
        return nil
        #endif
        guard fd >= 0 else { return nil }
        #if canImport(Darwin)
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = Self.closeFileDescriptor(fd)
            return nil
        }
        #else
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = Self.closeFileDescriptor(fd)
            return nil
        }
        #endif
        guard Int(info.st_size) <= limit else {
            _ = Self.closeFileDescriptor(fd)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var collected = Data()
            while collected.count <= limit {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                collected.append(chunk)
                if collected.count > limit { return nil }
            }
            data = collected
        } catch {
            return nil
        }
        #else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= limit,
              let contents = try? Data(contentsOf: url),
              contents.count <= limit else {
            return nil
        }
        data = contents
        #endif
        guard let record = try? JSONDecoder().decode(DurableRecord.self, from: data),
              record.conversationID == conversationID,
              !record.callID.isEmpty,
              let decodedText = String(data: record.text, encoding: .utf8),
              Self.durableFileName(runID: record.runID, callID: record.callID) == expectedName else {
            return nil
        }
        // Verify the stored digest over the WHOLE decoded payload before
        // applying this process's smaller cap; otherwise a record written by a
        // build with a larger per-result cap would look corrupt merely because
        // it is truncated on read.
        let fullSHA = FloeDigest.sha256Hex(Data(decodedText.utf8))
        if let stored = record.sha256, !stored.isEmpty, stored != fullSHA {
            return nil
        }
        var text = decodedText
        var retentionTruncated = record.retentionTruncated
        if text.utf8.count > caps.perResultBytes {
            text = ToolResultUTF8.prefix(text, maxBytes: caps.perResultBytes)
            retentionTruncated = true
        }
        let computedSHA = FloeDigest.sha256Hex(Data(text.utf8))
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
            durability: .durable,
            sha256: computedSHA,
            originalDigest: Self.boundedDigest(record.originalDigest)
        )
    }

    /// Deletes exactly the generated record for this run/call. Only the final
    /// component is unlinked; directories are never recursively removed here.
    private func removeOwnedDurableRecord(conversationID: UUID, runID: UUID, callID: String) {
        guard let root = durableRoot else { return }
        let url = durableDirectory(root, conversationID: conversationID)
            .appendingPathComponent(Self.durableFileName(runID: runID, callID: callID))
        _ = Self.unlinkPath(url.path)
    }

    /// Removes the task directory owned by this store. Absent is success; a
    /// symlink/file at the exact owned name is unlinked without following it;
    /// only a real directory is removed recursively.
    private func removeDurableDirectory(conversationID: UUID) -> Bool {
        guard let root = durableRoot else { return true }
        let directory = durableDirectory(root, conversationID: conversationID)
        switch pathKind(directory.path) {
        case .missing:
            return true
        case .directory:
            do {
                try FileManager.default.removeItem(at: directory)
                return true
            } catch {
                return false
            }
        case .other:
            return Self.unlinkPath(directory.path) == 0 || errno == ENOENT
        case .error:
            // A failed lstat is not proof of absence; never claim a removal
            // that could not be observed.
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
        switch pathKind(directory.path) {
        case .directory:
            break
        case .missing:
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
            guard pathKind(directory.path) == .directory else { return false }
        case .other, .error:
            return false
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
        return Self.unlinkPath(tombstoneURL(root: root, conversationID: conversationID).path) == 0
            || errno == ENOENT
    }

    // MARK: - Portable file identity

    private enum PathKind: Equatable {
        case missing
        case directory
        case other
        case error
    }

    private func pathKind(_ path: String) -> PathKind {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .missing : .error
        }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) ? .directory : .other
        #else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .other
        #endif
    }

    private func isPlainDirectory(_ path: String) -> Bool {
        pathKind(path) == .directory
    }

    private static func plainRegularFileMetadata(
        _ path: String
    ) -> (bytes: Int, modified: TimeInterval)? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        #if canImport(Darwin)
        let modified = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        #else
        let modified = Double(info.st_mtim.tv_sec)
            + Double(info.st_mtim.tv_nsec) / 1_000_000_000
        #endif
        return (Int(info.st_size), modified)
        #else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modified)
        #endif
    }

    private static func closeFileDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #elseif canImport(Glibc)
        return Glibc.close(fd)
        #elseif canImport(Android)
        return Android.close(fd)
        #else
        return 0
        #endif
    }

    private static func unlinkPath(_ path: String) -> Int32 {
        #if canImport(Darwin)
        return Darwin.unlink(path)
        #elseif canImport(Glibc)
        return Glibc.unlink(path)
        #elseif canImport(Android)
        return path.withCString { floeAndroidUnlink($0) }
        #else
        return -1
        #endif
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

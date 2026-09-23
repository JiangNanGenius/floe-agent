// FloeApp — Per-conversation composer draft store.
//
// SPDX-License-Identifier: MPL-2.0
//
// The shared composer's draft lives in the view model while a page is open,
// but switching tasks, backgrounding or quitting the app must not lose an
// unsent prompt. This store is the app-owned persistence seam behind that
// guarantee:
//
// - One entry per conversation (plus one stable entry for the Home
//   launchpad draft), holding the full text, staged attachments, the last
//   selection and a monotonically increasing revision.
// - Every mutation runs on the main actor and stamps the next revision;
//   callers that captured an older revision (voice-merge, editor commit)
//   pass it back as `expectedRevision` and a stale write is rejected
//   instead of overwriting newer text. `clear` keeps a revision floor per
//   conversation so a stale writer can never match a restarted sequence.
// - Disk writes are debounced per keystroke. Serialization and the atomic
//   write run on a serial background queue against a snapshot captured on
//   the main actor (a 100k-character, many-conversation store must not
//   block a keystroke); snapshots carry a monotonic revision and a
//   superseded snapshot is skipped. Lifecycle transitions flush the newest
//   snapshot with a bounded wait, and a failed or corrupt write is
//   reported (`lastWriteState`) instead of being swallowed.
//
// Storage is a single JSON document in Application Support. An unreadable
// document is preserved beside the live file, never deleted. A future
// consolidation into FloePersistence would move the file, not the contract.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit
import FloeCore
import FloeModels

@MainActor
final class ComposerDraftStore: ObservableObject {

    struct Entry: Codable, Equatable {
        var text: String
        var attachments: [AttachmentRef]
        var revision: Int
        var updatedAt: Date
        var selectionLocation: Int?
        var selectionLength: Int?

        /// Stored caret/selection, nil when nothing was captured yet.
        var selection: NSRange? {
            guard let selectionLocation else { return nil }
            return NSRange(location: selectionLocation, length: selectionLength ?? 0)
        }
    }

    /// Identity of the draft text at the moment a send consumed it.
    ///
    /// String equality is not identity: while a send is awaiting its run the
    /// user can edit A → B → A, and the stored text compares equal to the
    /// sent one again even though it is a brand-new draft. A token captured
    /// with `sendCommitToken(for:)` pins the exact text generation, and a
    /// commit may clear the stored text only while that generation is
    /// unchanged. Attachment-only and selection-only updates never advance
    /// the text generation, so staging a file during a send never keeps the
    /// sent prompt alive.
    struct SendCommitToken: Equatable, Sendable {
        fileprivate let conversationID: UUID
        fileprivate let textGeneration: Int
    }

    /// Outcome of the durable write pipeline. The composer surfaces
    /// `.failed` so a save problem is visible; nothing is silently dropped.
    enum WriteState: Equatable {
        case idle
        case pending
        case failed(message: String)

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Stable identity for the Home launchpad draft. Independent of the
    /// per-launch draft conversation UUID that Home rotates after each send.
    static let homeDraftID = UUID(uuidString: "8F4D0A6E-3B1C-4E2A-9D55-2C8F1A77E010")!

    static let shared = ComposerDraftStore()

    /// Debounce window for persisting typing bursts.
    static let writeDebounce: DispatchTimeInterval = .milliseconds(300)

    /// Visible result of the most recent save attempt.
    @Published private(set) var lastWriteState: WriteState = .idle

    private var entries: [UUID: Entry]
    /// A load failure stays visible until one healthy snapshot is written, so
    /// the notice cannot disappear on the first flush before anything new was
    /// actually persisted.
    private var pendingLoadFailure: String?
    /// Highest revision ever issued per conversation. `clear` removes the
    /// entry but keeps this floor, so a stale async writer holding an older
    /// revision is still rejected after the sequence would have restarted.
    private var revisionFloor: [UUID: Int] = [:]
    /// Monotonic identity of each conversation's *text* alone: every real
    /// text change advances it (even one that returns to an earlier string),
    /// while attachment-only and selection-only updates do not. Send commits
    /// compare it instead of string equality. Deliberately in-memory: a token
    /// only has to outlive one in-flight send, and a relaunch starts a new
    /// draft epoch anyway.
    private var textGenerations: [UUID: Int] = [:]
    private let fileURL: URL
    private let writeQueue: DispatchQueue
    /// Monotonic revision of the in-memory snapshot, bumped by every
    /// mutation. Snapshots are submitted with it; an older snapshot that is
    /// still queued when a newer one arrives is skipped.
    private var snapshotVersion: UInt64 = 0
    private var submittedVersion: UInt64 = 0
    private let writer = DraftWriteTracker()
    private var pendingWrite: DispatchWorkItem?
    private var cancellables: [NSObjectProtocol] = []

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ComposerDrafts", isDirectory: true)
        self.init(fileURL: base.appendingPathComponent("drafts.json"))
    }

    init(fileURL: URL, writeQueue: DispatchQueue? = nil) {
        self.fileURL = fileURL
        self.writeQueue = writeQueue ?? DispatchQueue(
            label: "app.floe.composer-drafts.write", qos: .utility
        )
        var loaded: [UUID: Entry] = [:]
        var loadFailure: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                loaded = try Self.decode(Self.readData(from: fileURL))
            } catch {
                // Never discard the user's unreadable input: keep a copy for
                // recovery, start from an empty map and report the failure.
                let preserved = Self.preserveCorruptFile(at: fileURL)
                let preservedName = preserved?.lastPathComponent ?? "未保留"
                loadFailure = "草稿文件无法读取（已保留副本 \(preservedName)）：\(error.localizedDescription)"
                FloeLogger(category: .app).error(
                    "composerDraftStoreDecodeFailed preserved=\(preservedName) error=\(error.localizedDescription)"
                )
            }
        }
        self.entries = loaded
        if let loadFailure {
            self.pendingLoadFailure = loadFailure
            self.lastWriteState = .failed(message: loadFailure)
        }
        // Flushing on lifecycle transitions keeps "switch task / background
        // / quit" lossless even when the debounce window has not elapsed.
        // Backgrounding and termination wait (bounded) for the newest
        // snapshot; resigning active is a quick non-blocking flush.
        let center = NotificationCenter.default
        cancellables = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.flushForLifecycle(timeout: 2) }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.flush() } },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.flushForLifecycle(timeout: 2) }
            },
        ]
    }

    // MARK: - Reads

    func entry(for conversationID: UUID) -> Entry? {
        entries[conversationID]
    }

    func text(for conversationID: UUID) -> String {
        entries[conversationID]?.text ?? ""
    }

    func attachments(for conversationID: UUID) -> [AttachmentRef] {
        entries[conversationID]?.attachments ?? []
    }

    /// Captures the identity of a conversation's text right now; pass the
    /// token to `clearAfterSend` so only that exact text can be committed
    /// away. A send that starts before any edit and commits after the user
    /// retyped the same string gets a mismatched token and keeps the draft.
    func sendCommitToken(for conversationID: UUID) -> SendCommitToken {
        SendCommitToken(
            conversationID: conversationID,
            textGeneration: textGenerations[conversationID] ?? 0
        )
    }

    // MARK: - Writes

    /// Stores the draft and returns the new revision. When `expectedRevision`
    /// is supplied it must match the stored one, otherwise the write is
    /// rejected as stale (returns nil) and newer text survives.
    @discardableResult
    func save(
        text: String,
        attachments: [AttachmentRef] = [],
        conversationID: UUID,
        selection: NSRange? = nil,
        expectedRevision: Int? = nil
    ) -> Int? {
        let current = entries[conversationID]
        if let expectedRevision, current?.revision != expectedRevision {
            return nil
        }
        let base = max(current?.revision ?? 0, revisionFloor[conversationID] ?? 0)
        let next = base + 1
        var entry = current ?? Entry(
            text: "", attachments: [], revision: 0,
            updatedAt: Date(), selectionLocation: nil, selectionLength: nil
        )
        // The text generation tracks the *text*: a real change always
        // advances it (A → B → A is two changes, never zero), while an
        // attachment-only update leaves it where it was.
        if text != entry.text {
            textGenerations[conversationID, default: 0] += 1
        }
        entry.text = text
        entry.attachments = attachments
        entry.revision = next
        entry.updatedAt = Date()
        if let selection {
            entry.selectionLocation = selection.location
            entry.selectionLength = selection.length
        }
        entries[conversationID] = entry
        markDirty()
        return next
    }

    /// Selection-only updates never bump the revision: caret moves are not
    /// draft edits and must not invalidate in-flight merge revisions.
    func updateSelection(_ selection: NSRange?, conversationID: UUID) {
        guard var entry = entries[conversationID] else { return }
        entry.selectionLocation = selection?.location
        entry.selectionLength = selection?.length
        entry.updatedAt = Date()
        entries[conversationID] = entry
        markDirty()
    }

    /// Removes the draft after a successful send (or a deleted conversation).
    /// The revision floor stays behind, so a stale async writer holding an
    /// older revision is rejected instead of matching a fresh entry. The
    /// text generation advances too: text saved after a clear is a new draft,
    /// never the one a pre-clear send token captured.
    func clear(conversationID: UUID) {
        guard let removed = entries.removeValue(forKey: conversationID) else { return }
        revisionFloor[conversationID] = max(
            revisionFloor[conversationID] ?? 0, removed.revision
        )
        textGenerations[conversationID, default: 0] += 1
        markDirty()
    }

    /// Commits a successful send without erasing work started while the send
    /// was in flight:
    /// - the sent text is dropped only while the store still holds the exact
    ///   text generation the send started from (`sendToken`) and that text is
    ///   still the sent one (or the field was emptied as part of the send);
    ///   newer text — including a retyped A → B → A — survives,
    /// - only the attachment refs that were part of the send are dropped;
    ///   attachments staged during the send keep their own identity.
    /// A nil `sendToken` keeps the pre-identity text comparison for callers
    /// that do not capture a generation.
    /// Returns true when the entry existed and was reconciled.
    @discardableResult
    func clearAfterSend(
        conversationID: UUID,
        sentText: String,
        sentAttachments: [AttachmentRef] = [],
        sendToken: SendCommitToken? = nil
    ) -> Bool {
        guard let current = entries[conversationID] else { return false }
        let sentIDs = Set(sentAttachments.map(\.id))
        let remaining = current.attachments.filter { !sentIDs.contains($0.id) }
        let identityMatches = sendToken.map {
            $0.conversationID == conversationID
                && $0.textGeneration == (textGenerations[conversationID] ?? 0)
        } ?? true
        let consumedText = identityMatches
            && (current.text == sentText || current.text.isEmpty)
        if consumedText, remaining.isEmpty {
            clear(conversationID: conversationID)
            return true
        }
        var entry = current
        if consumedText { entry.text = "" }
        entry.attachments = remaining
        entry.revision = max(current.revision, revisionFloor[conversationID] ?? 0) + 1
        entry.updatedAt = Date()
        entries[conversationID] = entry
        markDirty()
        return true
    }

    // MARK: - Persistence

    /// Writes the latest in-memory state immediately, cancelling any
    /// debounced write. The snapshot is captured on the main actor; encoding
    /// and the atomic write happen on the serial background queue.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        submitSnapshot()
        syncWriteState()
    }

    /// Bounded flush for lifecycle transitions: waits up to `timeout` for the
    /// newest snapshot to reach disk and returns whether it did. The main
    /// thread is only parked during a background/terminate transition.
    @discardableResult
    func flushAndWait(timeout: TimeInterval = 2) -> Bool {
        pendingWrite?.cancel()
        pendingWrite = nil
        let version = snapshotVersion
        submitSnapshot()
        let semaphore = DispatchSemaphore(value: 0)
        writeQueue.async { semaphore.signal() }
        let finished = semaphore.wait(timeout: .now() + timeout) == .success
        syncWriteState()
        return finished && writer.persistedVersion >= version && writer.lastFailure == nil
    }

    private func flushForLifecycle(timeout: TimeInterval) {
        if !flushAndWait(timeout: timeout) {
            FloeLogger(category: .app).error(
                "composerDraftFlushIncomplete timeout=\(timeout) failure=\(writer.lastFailure ?? "none")"
            )
        }
    }

    private func markDirty() {
        snapshotVersion += 1
        scheduleWrite()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    /// Submits the current snapshot for background serialization. A snapshot
    /// older than one already submitted is skipped; a pending debounce for
    /// the same version is not resubmitted.
    private func submitSnapshot() {
        let version = snapshotVersion
        if version == submittedVersion,
           writer.persistedVersion >= version,
           writer.lastFailure == nil {
            return
        }
        submittedVersion = version
        let snapshot = entries
        let url = fileURL
        let writer = self.writer
        writer.begin(version: version)
        lastWriteState = .pending
        writeQueue.async { [weak self] in
            // A newer snapshot was requested while this one waited. Writing
            // this older state would only be overwritten — skip it.
            guard writer.latestRequested <= version else {
                Task { @MainActor [weak self] in self?.syncWriteState() }
                return
            }
            var wrote = false
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try Self.encode(snapshot)
                try data.write(to: url, options: .atomic)
                writer.complete(version: version)
                wrote = true
            } catch {
                writer.fail(error.localizedDescription)
            }
            let succeeded = wrote
            Task { @MainActor [weak self] in
                guard let self else { return }
                // One healthy snapshot clears a stale load failure.
                if succeeded, writer.persistedVersion >= version {
                    self.pendingLoadFailure = nil
                }
                self.syncWriteState()
                if let failure = writer.lastFailure {
                    FloeLogger(category: .app).error("composerDraftPersistFailed error=\(failure)")
                }
            }
        }
    }

    private func syncWriteState() {
        if let failure = writer.lastFailure ?? pendingLoadFailure {
            if lastWriteState != .failed(message: failure) {
                lastWriteState = .failed(message: failure)
            }
        } else if writer.persistedVersion >= submittedVersion {
            // Nothing to flush (or the newest snapshot is on disk): idle.
            if lastWriteState != .idle { lastWriteState = .idle }
        } else if lastWriteState != .pending {
            lastWriteState = .pending
        }
    }

    private nonisolated static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private nonisolated static func decode(_ data: Data) throws -> [UUID: Entry] {
        let raw = try JSONDecoder().decode([String: Entry].self, from: data)
        var decoded: [UUID: Entry] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "草稿键不是会话 UUID：\(key)"
                    )
                )
            }
            decoded[id] = value
        }
        return decoded
    }

    private nonisolated static func encode(_ entries: [UUID: Entry]) throws -> Data {
        var raw: [String: Entry] = [:]
        for (key, value) in entries {
            raw[key.uuidString] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(raw)
    }

    /// Moves an unreadable draft document aside (copy as a fallback) so the
    /// corrupt input survives the next healthy write.
    private nonisolated static func preserveCorruptFile(at url: URL) -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let preserved = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("json")
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: url, to: preserved)
            return preserved
        } catch {
            do {
                try fileManager.copyItem(at: url, to: preserved)
                return preserved
            } catch {
                FloeLogger(category: .app).error(
                    "composerDraftCorruptPreserveFailed error=\(error.localizedDescription)"
                )
                return nil
            }
        }
    }

    /// Lock-protected write bookkeeping shared between the main actor and the
    /// serial write queue.
    private final class DraftWriteTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var requested: UInt64 = 0
        private var persisted: UInt64 = 0
        private var failure: String?

        func begin(version: UInt64) {
            lock.lock()
            requested = max(requested, version)
            lock.unlock()
        }

        var latestRequested: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        var persistedVersion: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return persisted
        }

        var lastFailure: String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func complete(version: UInt64) {
            lock.lock()
            persisted = max(persisted, version)
            failure = nil
            lock.unlock()
        }

        func fail(_ message: String) {
            lock.lock()
            failure = message
            lock.unlock()
        }
    }
}
#endif

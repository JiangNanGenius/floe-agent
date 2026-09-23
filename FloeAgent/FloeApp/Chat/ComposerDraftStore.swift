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
//   instead of overwriting newer text.
// - Disk writes are debounced per keystroke and flushed on scene
//   background/resign/terminate, so rapid typing never hammers the file
//   system and a killed app still keeps the latest draft.
//
// Storage is a single JSON document in Application Support. A future
// consolidation into FloePersistence would move the file, not the contract.

#if canImport(UIKit)
import Foundation
import UIKit
import FloeModels

@MainActor
final class ComposerDraftStore {

    struct Entry: Codable, Equatable {
        var text: String
        var attachments: [AttachmentRef]
        var revision: Int
        var updatedAt: Date
        var selectionLocation: Int?
        var selectionLength: Int?
    }

    /// Stable identity for the Home launchpad draft. Independent of the
    /// per-launch draft conversation UUID that Home rotates after each send.
    static let homeDraftID = UUID(uuidString: "8F4D0A6E-3B1C-4E2A-9D55-2C8F1A77E010")!

    static let shared = ComposerDraftStore()

    private var entries: [UUID: Entry]
    private let fileURL: URL
    private var pendingWrite: DispatchWorkItem?
    private var cancellables: [NSObjectProtocol] = []

    /// Debounce window for persisting typing bursts.
    static let writeDebounce: DispatchTimeInterval = .milliseconds(300)

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ComposerDrafts", isDirectory: true)
        self.init(fileURL: base.appendingPathComponent("drafts.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.entries = (try? Self.decode(Self.readData(from: fileURL))) ?? [:]
        // Flushing on lifecycle transitions keeps "switch task / background
        // / quit" lossless even when the debounce window has not elapsed.
        let center = NotificationCenter.default
        cancellables = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.flush() } },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.flush() } },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil, queue: nil
            ) { [weak self] _ in Task { @MainActor in self?.flush() } },
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
        let next = (current?.revision ?? 0) + 1
        var entry = current ?? Entry(
            text: "", attachments: [], revision: 0,
            updatedAt: Date(), selectionLocation: nil, selectionLength: nil
        )
        entry.text = text
        entry.attachments = attachments
        entry.revision = next
        entry.updatedAt = Date()
        if let selection {
            entry.selectionLocation = selection.location
            entry.selectionLength = selection.length
        }
        entries[conversationID] = entry
        scheduleWrite()
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
        scheduleWrite()
    }

    /// Removes the draft after a successful send (or a deleted conversation).
    func clear(conversationID: UUID) {
        guard entries.removeValue(forKey: conversationID) != nil else { return }
        scheduleWrite()
    }

    // MARK: - Persistence

    /// Writes the latest in-memory state immediately, cancelling any
    /// debounced write. Always serializes the freshest snapshot — never a
    /// captured stale copy.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let snapshot = entries
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? Self.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    private static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private static func decode(_ data: Data) throws -> [UUID: Entry] {
        let raw = try JSONDecoder().decode([String: Entry].self, from: data)
        var decoded: [UUID: Entry] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else { continue }
            decoded[id] = value
        }
        return decoded
    }

    private static func encode(_ entries: [UUID: Entry]) throws -> Data {
        var raw: [String: Entry] = [:]
        for (key, value) in entries {
            raw[key.uuidString] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(raw)
    }
}
#endif

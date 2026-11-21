// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import FloeCore
import FloeModels
import Foundation

@MainActor
final class MacWorkspaceDraftStore: ObservableObject {
    private typealias Document = ComposerDraftDocument<DesignJSONValue, DesignJSONValue>
    nonisolated private static let textByteLimit = 1_048_576
    nonisolated private static let documentByteLimit = 32 * 1_048_576
    private let directory: URL?
    private let fileQueue = DispatchQueue(label: "org.floeagent.mac.drafts", qos: .utility)
    @Published private var document = Document(drafts: [:], handoffs: [:])
    private var textRevisions = ComposerDraftTextRevisions()
    private var dirty = false
    private var readFailed = false
    private var deferredWrite: Task<Void, Never>?
    private var scheduledWrite: UUID?
    @Published private(set) var saveFailed = false

    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        do {
            guard try Self.checkDirectory(directory) else { return }
            let archive = directory.appendingPathComponent("drafts.json")
            if let bytes = try Self.readFile(archive, limit: Self.documentByteLimit) {
                let decoder = JSONDecoder()
                if let stored = try? decoder.decode(Document.self, from: bytes) {
                    document = stored
                } else {
                    document.drafts = try decoder.decode([String: ComposerDraftEntry].self, from: bytes)
                    dirty = true
                }
            } else {
                let legacy = try Self.readLegacyDrafts(in: directory)
                document.drafts = legacy
                dirty = !legacy.isEmpty
            }
        } catch {
            // An unreadable archive or legacy draft stays in place for recovery.
            readFailed = true
            saveFailed = true
        }
    }

    func text(for conversation: UUID?) -> String {
        document.drafts[Self.key(for: conversation)]?.text ?? ""
    }

    func attachments(for conversation: UUID?) -> [AttachmentRef] {
        document.drafts[Self.key(for: conversation)]?.attachments ?? []
    }

    func adoptLegacyHomeDraft(for id: UUID) {
        let home = Self.key(for: nil)
        let target = Self.key(for: id)
        guard let prior = document.drafts[home], document.drafts[target] == nil else { return }
        document.drafts.removeValue(forKey: home)
        document.drafts[target] = prior
        textRevisions.advance(for: Document.homeDraftID)
        textRevisions.advance(for: id)
        dirty = true
        flush()
    }

    func uncommittedDrafts(excluding known: Set<UUID>) -> [(id: UUID, date: Date)] {
        document.drafts.compactMap { key, draft in
            guard let id = UUID(uuidString: key), id != Document.homeDraftID, !known.contains(id),
                  !draft.text.isEmpty || !draft.attachments.isEmpty else { return nil }
            return (id, draft.updatedAt)
        }.sorted { $0.date > $1.date }
    }

    var attachmentURLs: Set<URL> {
        Set(document.drafts.values.flatMap(\.attachments).compactMap { attachment in
            guard attachment.storage == .securityScopedBookmark, let bookmark = attachment.urlBookmark else { return nil }
            var stale = false
            return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL
        })
    }

    func setText(_ text: String, for conversation: UUID?) {
        update(conversation) { $0.text = text }
    }

    func setAttachments(_ attachments: [AttachmentRef], for conversation: UUID?) {
        update(conversation) { $0.attachments = attachments }
    }

    func clear(for conversation: UUID) {
        update(conversation) {
            $0.text = ""
            $0.attachments = []
        }
    }

    func captureSendCommit(for conversation: UUID) -> () -> Void {
        let token = textRevisions.token(for: conversation)
        return { [weak self] in
            guard let self, textRevisions.matches(token, for: conversation) else { return }
            setText("", for: conversation)
        }
    }

    private func update(_ conversation: UUID?, edit: (inout ComposerDraftEntry) -> Void) {
        let key = Self.key(for: conversation)
        let previous = document.drafts[key] ?? ComposerDraftEntry(text: "", attachments: [], revision: 0, updatedAt: Date())
        var updated = previous
        edit(&updated)
        guard updated != previous else { return }
        if updated.text != previous.text {
            textRevisions.advance(for: conversation ?? Document.homeDraftID)
        }
        updated.revision = min(max(previous.revision, 0), Int.max - 1) + 1
        updated.updatedAt = Date()
        document.drafts[key] = updated
        guard directory != nil, !readFailed else { return }
        dirty = true
        deferredWrite?.cancel()
        deferredWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        deferredWrite?.cancel()
        deferredWrite = nil
        guard let directory, dirty, !readFailed, scheduledWrite == nil else { return }
        let snapshot = document
        let writeID = UUID()
        scheduledWrite = writeID
        dirty = false
        fileQueue.async { [weak self] in
            let saved = Self.write(snapshot, to: directory)
            Task { @MainActor [weak self] in
                guard let self, scheduledWrite == writeID else { return }
                scheduledWrite = nil
                if !saved { dirty = true }
                saveFailed = !saved
                if saved && dirty { flush() }
            }
        }
    }

    func flushBeforeClosing() {
        deferredWrite?.cancel()
        deferredWrite = nil
        guard let directory, !readFailed, dirty || scheduledWrite != nil else { return }
        let snapshot = document
        // Join earlier saves before the last snapshot so an old queued write
        // cannot replace the document we just committed during app teardown.
        let saved = fileQueue.sync { Self.write(snapshot, to: directory) }
        scheduledWrite = nil
        dirty = !saved
        saveFailed = !saved
    }

    nonisolated private static func write(_ document: Document, to directory: URL) -> Bool {
        do {
            if try !Self.checkDirectory(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard try Self.checkDirectory(directory), document.drafts.values.allSatisfy({ $0.text.utf8.count <= Self.textByteLimit }) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let bytes = try JSONEncoder().encode(document)
            guard bytes.count <= Self.documentByteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            let archive = directory.appendingPathComponent("drafts.json")
            try bytes.write(to: archive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            return true
        } catch {
            return false
        }
    }

    private static func key(for conversation: UUID?) -> String {
        (conversation ?? Document.homeDraftID).uuidString
    }

    private static func readLegacyDrafts(in directory: URL) throws -> [String: ComposerDraftEntry] {
        var drafts: [String: ComposerDraftEntry] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            let id = name == "new-task" ? Document.homeDraftID : UUID(uuidString: name)
            guard let id, let bytes = try readFile(file, limit: textByteLimit) else { continue }
            guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            drafts[id.uuidString] = ComposerDraftEntry(text: text, attachments: [], revision: 1, updatedAt: modified ?? .distantPast)
        }
        return drafts
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    nonisolated private static func checkDirectory(_ directory: URL) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadNoPermission)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return true
    }
}

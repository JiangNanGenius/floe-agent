// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

/// One private record per item trashed by Floe. Separate atomic files let
/// windows update unrelated entries without rewriting a shared index.
struct MacWorkspaceTrashRecord: Codable, Identifiable, Sendable {
    typealias Operations = MacWorkspaceFileOperations
    enum Availability { case available(Operations.TrashReceipt), removed, unavailable }
    enum HistoryError: Error { case unavailable, removed }

    private struct FileID: Codable, Sendable {
        let statID: Operations.Identity
        let volume: String?

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            statID = .init(info)
            volume = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }

        func matches(_ other: Self) -> Bool {
            let sameVolume = volume.map { $0 == other.volume } ?? (statID.device == other.statID.device)
            return sameVolume && statID.inode == other.statID.inode && statID.type == other.statID.type
                && statID.birthSeconds == other.statID.birthSeconds && statID.birth == other.statID.birth
        }
    }

    let id: UUID
    let name: String
    let removedAt: Date
    let subdirectory: String
    private let workspace: FileID
    private let parent: FileID
    private let originalItem: FileID
    private var trashDirectory: URL?
    private var trashID: FileID?
    private var trashDirectoryBookmark: Data?
    private var itemBookmark: Data?
    private var trashName: String?
    // Optional for compatibility with records written before this field
    // existed. A successful system move remains successful even when macOS
    // does not permit the app to inspect the resulting Trash location.
    private var systemMoved: Bool?
    var confirmedBySystem: Bool { systemMoved == true || trashName != nil }

    var finderTrashItemURL: URL? {
        guard let directory = trashDirectory, directory.isFileURL else { return nil }
        guard let trashName else { return directory }
        return directory.appendingPathComponent(trashName)
    }

    init(id: UUID, original: Operations, item: Operations.Item) throws {
        guard let root = original.rootURL else { throw HistoryError.unavailable }
        let url = original.directory.appendingPathComponent(item.name)
        self.id = id
        name = item.name
        removedAt = Date()
        workspace = try FileID(root)
        parent = try FileID(original.directory)
        originalItem = try FileID(url)
        guard parent.statID == original.directoryIdentity, originalItem.statID == item.identity else {
            throw HistoryError.unavailable
        }
        subdirectory = original.directory.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        // On a fresh external volume only trashItem can initialize the real
        // per-user Trash. An absent bin must not block that first system move.
        let bin = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                               appropriateFor: url, create: false)
        trashDirectory = bin
        trashID = bin.flatMap { try? FileID($0) }
        trashDirectoryBookmark = bin.flatMap(Self.bookmark)
        itemBookmark = Self.bookmark(url)
        // A pre-move bookmark is essential to recover a move interrupted before
        // the system reports the item's final name.
        guard itemBookmark != nil else { throw HistoryError.unavailable }
    }

    mutating func didTrash(to url: URL?) {
        systemMoved = true
        guard let url, url.isFileURL else { return }
        let bin = url.deletingLastPathComponent()
        trashDirectory = bin
        trashName = url.lastPathComponent
        // Store the system's reported location even if privacy permissions
        // prevent verification. It is only a Finder hint until availability
        // independently verifies the item's and directory's identities.
        guard let item = try? FileID(url), originalItem.matches(item),
              let verifiedBin = try? FileID(bin) else { return }
        trashID = verifiedBin
        trashDirectoryBookmark = Self.bookmark(bin)
        itemBookmark = Self.bookmark(url) ?? itemBookmark
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func save(in history: URL) throws {
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file(id, history), options: .atomic)
    }

    private static func file(_ id: UUID, _ history: URL) -> URL {
        history.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    static func forget(_ id: UUID, in history: URL) {
        try? FileManager.default.removeItem(at: file(id, history))
    }

    static func entries(for root: URL, in history: URL) throws -> [Self] {
        let rootID = try FileID(root)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil,
                                                                options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return files.compactMap { url -> Self? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Self.self, from: data),
                  id == entry.id, entry.workspace.matches(rootID) else { return nil }
            return entry
        }.sorted { $0.removedAt > $1.removedAt }
    }

    /// Verify only the bookmarked item and its recorded Trash slot. A missing
    /// volume or inaccessible directory retains the receipt. Finder moving an
    /// item out of Trash never authorizes Floe to move it from its new home.
    func availability(root: URL, history: URL, managed: URL?) -> Availability {
        do {
            guard Operations.validName(name), workspace.matches(try FileID(root)) else { return .unavailable }
            let directory = subdirectory.isEmpty ? root : root.appendingPathComponent(subdirectory, isDirectory: true)
            let original = try Operations(root: root, directory: directory, managedConversationsRoot: managed)
            guard parent.matches(try FileID(original.directory)) else { return .unavailable }
            let systemBin = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                         appropriateFor: original.directory, create: false)
            // Confirm the current system location as well as the original
            // identity: a directory bookmark alone could follow an entire
            // Trash directory that was moved elsewhere in Finder.
            let volume = try original.directory.resourceValues(forKeys: [.volumeURLKey]).volume
            let externalBin = volume?.appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(String(geteuid()), isDirectory: true)
            let systemIDs = [systemBin, externalBin].compactMap { url in url.flatMap { try? FileID($0) } }
            let candidates = [trashDirectory, Self.resolve(trashDirectoryBookmark), systemBin, externalBin]
            let trash = candidates.compactMap { $0 }.first {
                guard let identity = try? FileID($0), systemIDs.contains(where: { $0.matches(identity) }) else { return false }
                return trashID?.matches(identity) ?? true
            }
            guard let trash, let verifiedBin = try? FileID(trash),
                  Operations.readableTrashDirectory(trash) == verifiedBin.statID else { return .unavailable }
            let slot = trashName.map { trash.appendingPathComponent($0) }
            func inspect(_ url: URL?) -> Availability? {
                guard let candidate = url, let current = try? FileID(candidate), originalItem.matches(current) else { return nil }
                guard let container = try? FileID(candidate.deletingLastPathComponent()) else { return .unavailable }
                guard verifiedBin.matches(container) else {
                    // Another window may be between journaling and Trash.
                    // Never prune its pending receipt while the move is live.
                    return trashName == nil ? .unavailable : .removed
                }
                let item = Operations.Item(name: name, identity: current.statID)
                return .available(.init(id: id, original: original, item: item, trashed: candidate, history: history,
                                        trashDirectoryIdentity: container.statID))
            }
            if let status = inspect(slot) ?? inspect(Self.resolve(itemBookmark)) { return status }
            // A missing/unreadable original parent or volume never gets here.
            // Only a proven missing/replaced slot on the original, mounted
            // Trash volume retires a completed receipt.
            if let slot {
                var info = stat()
                if lstat(slot.path, &info) == 0 {
                    if let identity = try? FileID(slot), !originalItem.matches(identity) { return .removed }
                } else if errno == ENOENT { return .removed }
            }
        } catch {}
        return .unavailable
    }

    func restore(root: URL, history: URL, managed: URL?) throws {
        switch availability(root: root, history: history, managed: managed) {
        case .available(let receipt):
            try Operations.restore(receipt)
        case .removed:
            Self.forget(id, in: history)
            throw HistoryError.removed
        case .unavailable: throw HistoryError.unavailable
        }
    }
}

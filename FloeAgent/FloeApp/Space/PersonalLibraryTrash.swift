// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

struct PersonalLibraryFolder: Hashable, Identifiable, Sendable {
    let components: [String]
    let resourceIdentity: String
    var name: String { components.last ?? "" }
    var relativePath: String { components.joined(separator: "/") }
    var id: String { relativePath + ":" + resourceIdentity }
}

struct PersonalLibraryTrashEntry: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case work, folder }
    var id = UUID()
    var kind: Kind
    var title: String
    var relativePath: String
    var deletedAt = Date()
    var projectID: UUID?
    var contentKind: PersonalContentKind?
    var folderID: UUID?
    /// Future tombstones bind the directory, not just its reused pathname.
    var resourceIdentity: String?
}

/// Positive, same-index commit proof for companion assistant cleanup after a
/// crash. Missing files alone never authorize deleting a saved conversation.
struct PersonalLibraryAssistantPurgeReceipt: Codable, Hashable, Sendable {
    let entryID: UUID
    let relativePath: String
    let projectIDs: [UUID]
}

/// One atomic metadata file hides originals in place. It grants no filesystem
/// authority, and cannot move, unlink or rewrite any document/asset/history.
enum PersonalLibraryTrashStore {
    struct State: Codable {
        var version = 1
        var entries: [PersonalLibraryTrashEntry] = []
        var assistantPurgeReceipts: [PersonalLibraryAssistantPurgeReceipt]?
        func deletionDate(projectID: UUID?, path: String) -> Date? {
            let components = path.split(separator: "/").map(String.init)
            return entries.filter { entry in
                if entry.kind == .work { return projectID != nil && entry.projectID == projectID }
                let parent = entry.relativePath.split(separator: "/").map(String.init)
                return components.starts(with: parent)
            }.map(\.deletedAt).min()
        }
    }
    static let fileName = ".FloeLibraryTrash.json"
    static let folderMarker = ".FloeFolderIdentity.json"
    static func components(_ path: String) throws -> [String] {
        let values = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !values.isEmpty, values.count <= 64,
              values.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") &&
                  $0.utf8.count <= 255 && !$0.contains("\\") && !$0.contains(":") &&
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw PersonalContentError.outsideLibrary
        }
        return values
    }
    static func read(root: URL) throws -> State {
        let file = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return State() }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 4 * 1_024 * 1_024 else {
            throw PersonalContentError.invalidProject
        }
        return try decode(Data(contentsOf: file))
    }
    static func decode(_ bytes: Data) throws -> State {
        guard bytes.count <= 4 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        let value = try JSONDecoder().decode(State.self, from: bytes)
        guard value.version == 1, value.entries.count <= 10_000,
              (value.assistantPurgeReceipts?.count ?? 0) <= 10_000,
              Set(value.entries.map(\.id)).count == value.entries.count else { throw PersonalContentError.invalidProject }
        let receiptIDs = (value.assistantPurgeReceipts ?? []).map(\.entryID)
        guard Set(receiptIDs).count == receiptIDs.count,
              Set(receiptIDs).isDisjoint(with: value.entries.map(\.id)) else { throw PersonalContentError.invalidProject }
        for receipt in value.assistantPurgeReceipts ?? [] {
            _ = try components(receipt.relativePath)
            guard Set(receipt.projectIDs).count == receipt.projectIDs.count else { throw PersonalContentError.invalidProject }
        }
        for entry in value.entries {
            let path = try components(entry.relativePath)
            guard entry.title.utf8.count <= 1_024, entry.deletedAt.timeIntervalSince1970.isFinite else { throw PersonalContentError.invalidProject }
            if entry.kind == .work {
                guard entry.projectID != nil, entry.contentKind != nil, entry.folderID == nil,
                      (path.last! as NSString).pathExtension == "floeproject" else { throw PersonalContentError.invalidProject }
            } else {
                guard entry.projectID == nil, entry.contentKind == nil, entry.folderID != nil,
                      !path.contains(where: { ($0 as NSString).pathExtension.lowercased() == "floeproject" }) else { throw PersonalContentError.invalidProject }
            }
        }
        guard Set(value.entries.compactMap(\.projectID)).count == value.entries.filter({ $0.kind == .work }).count,
              Set(value.entries.filter({ $0.kind == .folder }).map(\.relativePath)).count == value.entries.filter({ $0.kind == .folder }).count else {
            throw PersonalContentError.invalidProject
        }
        return value
    }
    static func write(_ state: State, root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        guard bytes.count <= 4 * 1_024 * 1_024, state.entries.count <= 10_000,
              (state.assistantPurgeReceipts?.count ?? 0) <= 10_000 else { throw PersonalContentError.storageUnavailable }
        try bytes.write(to: root.appendingPathComponent(fileName), options: .atomic)
    }
    static func locked<T>(root: URL, _ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = Darwin.open(root.appendingPathComponent(".FloeLibraryMutation.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PersonalContentError.storageUnavailable }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 { if errno != EINTR { throw PersonalContentError.storageUnavailable } }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation() // Never crosses await or calls an external service.
    }
    static func requireActive(root: URL, directory: URL, id: UUID) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let location = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard location.path.hasPrefix(base.path + "/") else { throw PersonalContentError.outsideLibrary }
        let path = String(location.path.dropFirst(base.path.count + 1))
        if try read(root: base).deletionDate(projectID: id, path: path) != nil { throw PersonalContentError.deleted }
    }
    static func folder(root: URL, components: [String]) throws -> (url: URL, identity: String) {
        _ = try self.components(components.joined(separator: "/"))
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var value = base
        for component in components {
            guard (component as NSString).pathExtension.lowercased() != "floeproject" else { throw PersonalContentError.invalidName }
            value.appendPathComponent(component, isDirectory: true)
            let info = try value.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw PersonalContentError.outsideLibrary }
        }
        guard value.path.hasPrefix(base.path + "/") else { throw PersonalContentError.outsideLibrary }
        let info = try value.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let identity = info.fileResourceIdentifier else { throw PersonalContentError.changedDocument }
        let digest = SHA256.hash(data: Data(String(describing: identity).utf8)).map { String(format: "%02x", $0) }.joined()
        return (value, digest)
    }
    static func marker(at folder: URL, create: Bool) throws -> UUID {
        let file = folder.appendingPathComponent(folderMarker)
        if FileManager.default.fileExists(atPath: file.path) {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 128 else { throw PersonalContentError.changedDocument }
            return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: file))
        }
        guard create else { throw PersonalContentError.changedDocument }
        let id = UUID(); try JSONEncoder().encode(id).write(to: file, options: .atomic); return id
    }
}

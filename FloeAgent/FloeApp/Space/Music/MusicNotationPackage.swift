// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Darwin
import Foundation
import FloeHeavyEditorSupport
import FloeMusicCore

nonisolated struct MusicNotationBinding: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let musicProjectID: UUID
    let scoreDocumentID: UUID
}
nonisolated struct MusicNotationOriginal: Sendable {
    let binding: MusicNotationBinding
    let bindingData: Data
    let document: HeavyEditorDocument
    let documentData: Data
}
nonisolated struct MusicNotationSnapshot: Codable, Equatable, Sendable {
    let parentID: UUID
    let musicRevision: Int64
    let musicSHA256: String
    let scoreRevision: UInt64?
    let scoreSHA256: String?
    let djSHA256: String?
    let device: UInt64
    let inode: UInt64
}
nonisolated struct MusicNotationBackupManifest: Codable, Sendable {
    var schemaVersion = 1
    let parentID: UUID
    let musicRevision: Int64
    let musicSHA256: String
    let scoreRevision: UInt64?
    let scoreSHA256: String?
    let bindingSHA256: String?
    let djSHA256: String?
}
nonisolated struct MusicNotationRestoreJournal: Codable, Sendable {
    var schemaVersion = 1
    let parentID: UUID
    let before: MusicNotationSnapshot
    let target: MusicNotationSnapshot
    let stagingName: String
    let backupName: String
    var committed = false
}

private nonisolated final class MusicNotationXMLShape: NSObject, XMLParserDelegate {
    var depth = 0
    var isPartwise = false
    var definitions = Set<String>()
    var parts: [String: Int] = [:]
    var currentPart: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if depth == 0 { isPartwise = elementName == "score-partwise" }
        if elementName == "score-part", depth == 2, let id = attributes["id"] { definitions.insert(id) }
        if elementName == "part", depth == 1, let id = attributes["id"] { currentPart = id; parts[id] = 0 }
        if elementName == "measure", depth == 2, let currentPart { parts[currentPart, default: 0] += 1 }
        depth += 1
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        if elementName == "part", depth == 1 { currentPart = nil }
    }
    var isEditable: Bool { isPartwise && !parts.isEmpty && parts.allSatisfy { definitions.contains($0.key) && $0.value > 0 } }
}

/// Fixed music-project companion storage. No imported field selects an owner or path.
/// Whole-project restoration exchanges the two owned directories in one filesystem
/// operation; a durable journal makes interruption recover to a complete old pair.
nonisolated enum MusicNotationPackage {
    static let manifestName = "FloeMusicBackup.json"
    static let journalName = ".music-notation-restore.json"
    static let maximumDocumentBytes = 128 * 1024 * 1024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func notationRoot(_ musicRoot: URL) -> URL { musicRoot.appendingPathComponent("Notation", isDirectory: true) }
    static func musicFile(_ root: URL, id: UUID) -> URL {
        root.appendingPathComponent("documents/" + digest(Data(id.uuidString.lowercased().utf8)) + ".json")
    }
    static func regularData(_ url: URL, maximum: Int = maximumDocumentBytes) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PersonalContentError.invalidProject }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw PersonalContentError.invalidProject }
        let data = try file.readToEnd() ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_ino == info.st_ino, after.st_dev == info.st_dev,
              after.st_size == info.st_size, data.count == info.st_size else { throw PersonalContentError.changedDocument }
        return data
    }
    static func directoryIdentity(_ root: URL) throws -> (UInt64, UInt64) {
        var value = stat()
        guard lstat(root.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR,
              root.standardizedFileURL == root.standardizedFileURL.resolvingSymlinksInPath() else { throw PersonalContentError.changedDocument }
        return (UInt64(UInt32(bitPattern: value.st_dev)), UInt64(value.st_ino))
    }
    static func validateScore(_ document: HeavyEditorDocument, parentID: UUID) throws {
        guard document.schemaVersion == 1, document.id == parentID, document.kind == .score else { throw PersonalContentError.invalidProject }
        let content = document.content["data"] == .null ? document.content : document.content["data"]
        guard let xml = content["xml"].string, !xml.isEmpty, xml.utf8.count <= maximumDocumentBytes,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw PersonalContentError.invalidProject }
        let shape = MusicNotationXMLShape(), parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = shape
        guard parser.parse(), shape.isEditable else { throw PersonalContentError.invalidProject }
        for key in ["layout", "playback", "archive"] where content[key] != .null {
            guard case .object = content[key] else { throw PersonalContentError.invalidProject }
        }
        if document.content["history"] != .null {
            guard case .object = document.content["history"],
                  case .array = document.content["history"]["past"], case .array = document.content["history"]["future"] else { throw PersonalContentError.invalidProject }
        }
    }
    static func readOriginal(root: URL, parentID: UUID) throws -> MusicNotationOriginal? {
        let directory = notationRoot(root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        _ = try directoryIdentity(directory)
        let bindingData = try regularData(directory.appendingPathComponent("Binding.json"), maximum: 4096)
        let binding = try JSONDecoder().decode(MusicNotationBinding.self, from: bindingData)
        guard binding.schemaVersion == 1, binding.musicProjectID == parentID, binding.scoreDocumentID == parentID else { throw PersonalContentError.invalidProject }
        let bytes = try regularData(directory.appendingPathComponent("Document.json"))
        let document = try JSONDecoder().decode(HeavyEditorDocument.self, from: bytes)
        try validateScore(document, parentID: parentID)
        return .init(binding: binding, bindingData: bindingData, document: document, documentData: bytes)
    }
    static func capture(root: URL, parentID: UUID) throws -> MusicNotationSnapshot {
        let identity = try directoryIdentity(root), bytes = try regularData(musicFile(root, id: parentID))
        let music = try JSONDecoder().decode(MusicDocument.self, from: bytes)
        guard music.id.rawValue == parentID.uuidString.lowercased() else { throw PersonalContentError.invalidProject }
        let score = try readOriginal(root: root, parentID: parentID)
        let djURL = root.appendingPathComponent("dj-session.json")
        let djHash = FileManager.default.fileExists(atPath: djURL.path) ? try digest(regularData(djURL)) : nil
        return .init(parentID: parentID, musicRevision: music.revision, musicSHA256: digest(bytes),
                     scoreRevision: score?.document.revision, scoreSHA256: score.map { digest($0.documentData) }, djSHA256: djHash, device: identity.0, inode: identity.1)
    }
    static func sameOriginals(_ a: MusicNotationSnapshot, _ b: MusicNotationSnapshot) -> Bool {
        a.parentID == b.parentID && a.musicRevision == b.musicRevision && a.musicSHA256 == b.musicSHA256
            && a.scoreRevision == b.scoreRevision && a.scoreSHA256 == b.scoreSHA256 && a.djSHA256 == b.djSHA256
    }
    static func requireUnchanged(_ expected: MusicNotationSnapshot, root: URL) throws {
        let actual = try capture(root: root, parentID: expected.parentID)
        guard actual == expected else { throw PersonalContentError.changedDocument }
    }
    static func stageCompanion(source: URL, destination: URL, parentID: UUID, music: MusicDocument) throws -> MusicNotationBackupManifest {
        let sourceMusic = try regularData(musicFile(source, id: parentID))
        let savedMusic = try JSONDecoder().decode(MusicDocument.self, from: sourceMusic)
        guard savedMusic == music else { throw PersonalContentError.changedDocument }
        let original = try readOriginal(root: source, parentID: parentID)
        if let original {
            let output = notationRoot(destination)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try original.bindingData.write(to: output.appendingPathComponent("Binding.json"), options: .withoutOverwriting)
            try original.documentData.write(to: output.appendingPathComponent("Document.json"), options: .withoutOverwriting)
        }
        let djURL = source.appendingPathComponent("dj-session.json")
        let djBytes = FileManager.default.fileExists(atPath: djURL.path) ? try regularData(djURL) : nil
        if let djBytes { try djBytes.write(to: destination.appendingPathComponent("dj-session.json"), options: .atomic) }
        let djHash = djBytes.map(digest)
        let manifest = MusicNotationBackupManifest(parentID: parentID, musicRevision: music.revision,
            musicSHA256: digest(try regularData(musicFile(destination, id: parentID))), scoreRevision: original?.document.revision,
            scoreSHA256: original.map { digest($0.documentData) }, bindingSHA256: original.map { digest($0.bindingData) }, djSHA256: djHash)
        try encoded(manifest).write(to: destination.appendingPathComponent(manifestName), options: .withoutOverwriting)
        return manifest
    }
    static func validateExport(_ manifest: MusicNotationBackupManifest, source: URL) throws {
        let actual = try capture(root: source, parentID: manifest.parentID)
        guard actual.musicRevision == manifest.musicRevision, actual.musicSHA256 == manifest.musicSHA256,
              actual.scoreRevision == manifest.scoreRevision, actual.scoreSHA256 == manifest.scoreSHA256, actual.djSHA256 == manifest.djSHA256 else { throw PersonalContentError.changedDocument }
    }
    static func validateBackup(root: URL, parentID: UUID) throws -> MusicNotationBackupManifest {
        let manifest = try JSONDecoder().decode(MusicNotationBackupManifest.self, from: regularData(root.appendingPathComponent(manifestName), maximum: 16384))
        guard manifest.schemaVersion == 1, manifest.parentID == parentID else { throw PersonalContentError.invalidProject }
        let pair = try capture(root: root, parentID: parentID), original = try readOriginal(root: root, parentID: parentID)
        guard pair.musicRevision == manifest.musicRevision, pair.musicSHA256 == manifest.musicSHA256,
              pair.scoreRevision == manifest.scoreRevision, pair.scoreSHA256 == manifest.scoreSHA256,
              original.map({ digest($0.bindingData) }) == manifest.bindingSHA256 else { throw PersonalContentError.invalidProject }
        let dj = root.appendingPathComponent("dj-session.json")
        let djHash = FileManager.default.fileExists(atPath: dj.path) ? try digest(regularData(dj)) : nil
        guard djHash == manifest.djSHA256 else { throw PersonalContentError.invalidProject }
        return manifest
    }
    static func prepareRestoredScore(source: URL, destination: URL, expected: MusicNotationSnapshot) throws {
        guard let original = try readOriginal(root: source, parentID: expected.parentID) else { return }
        guard (expected.scoreRevision ?? 0) < UInt64.max else { throw PersonalContentError.changedDocument }
        var next = original.document
        next.revision = (expected.scoreRevision ?? 0) + 1; next.modifiedAt = Date()
        let directory = notationRoot(destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try original.bindingData.write(to: directory.appendingPathComponent("Binding.json"), options: .withoutOverwriting)
        try encoded(next).write(to: directory.appendingPathComponent("Document.json"), options: .withoutOverwriting)
        _ = try readOriginal(root: destination, parentID: expected.parentID)
    }
    static func validOwnedName(_ name: String, prefix: String) -> Bool { name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil }
    static func swap(_ a: URL, _ b: URL) throws {
        guard a.deletingLastPathComponent() == b.deletingLastPathComponent() else { throw PersonalContentError.changedDocument }
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func withRestoreLock<T>(root: URL, _ action: () throws -> T) throws -> T {
        let file = root.deletingLastPathComponent().appendingPathComponent(".music-notation-restore.lock")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw PersonalContentError.changedDocument }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PersonalContentError.changedDocument }
        return try action()
    }
    static func writeJournal(_ journal: MusicNotationRestoreJournal, root: URL) throws {
        try encoded(journal).write(to: root.deletingLastPathComponent().appendingPathComponent(journalName), options: .atomic)
        // Persist before a directory exchange. Recovery never trusts just a success string.
        let file = try FileHandle(forWritingTo: root.deletingLastPathComponent().appendingPathComponent(journalName))
        try file.synchronize(); try file.close()
    }
    static func recoverPending(root: URL, parentID: UUID) throws {
        let file = root.deletingLastPathComponent().appendingPathComponent(journalName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try withRestoreLock(root: root) {
            let journal = try JSONDecoder().decode(MusicNotationRestoreJournal.self, from: regularData(file, maximum: 32768))
            guard journal.schemaVersion == 1, journal.parentID == parentID,
                  validOwnedName(journal.stagingName, prefix: ".music-restore-stage-"), validOwnedName(journal.backupName, prefix: ".music-restore-backup-") else { throw PersonalContentError.invalidProject }
            let stage = root.deletingLastPathComponent().appendingPathComponent(journal.stagingName)
            let backup = root.deletingLastPathComponent().appendingPathComponent(journal.backupName)
            let current = try capture(root: root, parentID: parentID)
            if sameOriginals(current, journal.before) {
                if FileManager.default.fileExists(atPath: stage.path) {
                    guard sameOriginals(try capture(root: stage, parentID: parentID), journal.target) else { throw PersonalContentError.changedDocument }
                    try FileManager.default.removeItem(at: stage)
                }
            } else if sameOriginals(current, journal.target) ||
                (journal.committed && current.device == journal.target.device && current.inode == journal.target.inode
                 && current.musicRevision >= journal.target.musicRevision
                 && (journal.target.scoreRevision == nil || (current.scoreRevision ?? 0) >= journal.target.scoreRevision!)) {
                if journal.committed {
                    if FileManager.default.fileExists(atPath: stage.path) {
                        guard sameOriginals(try capture(root: stage, parentID: parentID), journal.before), !FileManager.default.fileExists(atPath: backup.path) else { throw PersonalContentError.changedDocument }
                        try FileManager.default.moveItem(at: stage, to: backup)
                    } else {
                        guard sameOriginals(try capture(root: backup, parentID: parentID), journal.before) else { throw PersonalContentError.changedDocument }
                    }
                } else {
                    guard sameOriginals(try capture(root: stage, parentID: parentID), journal.before) else { throw PersonalContentError.changedDocument }
                    try swap(root, stage)
                    guard sameOriginals(try capture(root: root, parentID: parentID), journal.before) else { throw PersonalContentError.changedDocument }
                    try FileManager.default.removeItem(at: stage)
                }
            } else { throw PersonalContentError.changedDocument }
            try FileManager.default.removeItem(at: file)
        }
    }
}

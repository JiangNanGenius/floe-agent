// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// The personal library organizes durable originals. It never changes a task's
/// workspace, execution environment, or the native editor's commit authority.
enum PersonalContentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case canvas, diagram, image, drawing, video, music, meeting, chemistry
    case cad2D, cad3D, printing, manufacturing, document
}

struct PersonalContentRecord: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var kind: PersonalContentKind
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var lastOpenedAt: Date?
    var isPinned = false
    /// Organizational location only; execution ownership is never inferred here.
    var folders: [String]
    var relativePath: String
    var needsRecovery = false
}

enum PersonalContentError: Error, LocalizedError {
    case invalidName, outsideLibrary, missingDocument, changedDocument
    case invalidProject, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidName: IDELanguageRunText.t("请输入有效名称。", "Enter a valid name.")
        case .outsideLibrary: IDELanguageRunText.t("这个位置不属于当前文件库。", "This location is outside this library.")
        case .missingDocument: IDELanguageRunText.t("找不到这份作品，请刷新文件列表。", "This work is unavailable. Refresh the file list.")
        case .changedDocument: IDELanguageRunText.t("作品位置已改变，请重新打开。", "This work has moved. Open it again.")
        case .invalidProject: IDELanguageRunText.t("工程资料不完整，原文件仍然保留。", "The project is incomplete. Its original files have been preserved.")
        case .storageUnavailable: IDELanguageRunText.t("暂时无法保存，请检查设备可用空间。", "Unable to save. Check available device storage.")
        }
    }
}

actor PersonalContentLibrary {
    let root: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let manifestName = "FloeProject.json"

    init(root: URL) {
        self.root = root.standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    static func applicationRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/PersonalContent", isDirectory: true)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func validComponent(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PersonalContentError.invalidName
        }
        return name
    }

    private func confined(_ url: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let value = url.resolvingSymlinksInPath().standardizedFileURL
        guard value.path == base || value.path.hasPrefix(base + "/") else {
            throw PersonalContentError.outsideLibrary
        }
        return value
    }

    func folderURL(_ components: [String]) throws -> URL {
        try ensureRoot()
        var url = root
        for component in components {
            let name = try validComponent(component)
            guard !(name as NSString).pathExtension.lowercased().elementsEqual("floeproject") else { throw PersonalContentError.invalidName }
            url.appendPathComponent(name, isDirectory: true)
        }
        return try confined(url)
    }

    func createFolder(_ name: String, in folders: [String]) throws {
        let parent = try folderURL(folders)
        let target = try confined(parent.appendingPathComponent(try validComponent(name), isDirectory: true))
        guard !fileManager.fileExists(atPath: target.path) else { throw PersonalContentError.changedDocument }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
    }

    func folders(in path: [String]) throws -> [String] {
        let directory = try folderURL(path)
        return try fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).filter { url in
                let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return info.isDirectory == true && info.isSymbolicLink != true && url.pathExtension != "floeproject"
            }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// New editor state is committed before its library record is published.
    /// Incomplete generated state stays in Recovery instead of being discarded.
    func create(kind: PersonalContentKind, title: String, in folders: [String] = [], id: UUID = UUID(),
                prepare: @Sendable (URL, UUID) async throws -> Void) async throws -> PersonalContentRecord {
        try ensureRoot()
        let title = try validComponent(title)
        let directory = try folderURL(folders)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try records().first(where: { $0.id == id }) {
            guard existing.kind == kind, !existing.needsRecovery else {
                throw PersonalContentError.changedDocument
            }
            return existing
        }
        var target = directory.appendingPathComponent(title + ".floeproject", isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent(title + " " + id.uuidString.prefix(8) + ".floeproject", isDirectory: true)
        }
        target = try confined(target)
        let staging = root.appendingPathComponent(".creating-" + id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var record = PersonalContentRecord(id: id, kind: kind, title: title,
            createdAt: Date(), modifiedAt: Date(), folders: folders,
            relativePath: String(target.path.dropFirst(root.path.count + 1)))
        do {
            try await prepare(staging, id)
            try Task.checkCancellation()
            try encoder.encode(record).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
            guard !fileManager.fileExists(atPath: target.path) else { throw PersonalContentError.changedDocument }
            try fileManager.moveItem(at: staging, to: target)
            return record
        } catch {
            let recovery = root.appendingPathComponent("Recovery", isDirectory: true)
            try? fileManager.createDirectory(at: recovery, withIntermediateDirectories: true)
            let saved = recovery.appendingPathComponent(id.uuidString + ".floeproject", isDirectory: true)
            record.needsRecovery = true
            record.folders = ["Recovery"]
            record.relativePath = "Recovery/" + saved.lastPathComponent
            if fileManager.fileExists(atPath: staging.path) {
                try? encoder.encode(record).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
                try? fileManager.moveItem(at: staging, to: saved)
            }
            throw error
        }
    }

    func records() throws -> [PersonalContentRecord] {
        try ensureRoot()
        var pending = [root]
        var result: [PersonalContentRecord] = []
        while let directory = pending.popLast() {
            for entry in try fileManager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) {
                let info = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
                let checked = try confined(entry)
                if checked.pathExtension == "floeproject" {
                    let manifest = checked.appendingPathComponent(manifestName)
                    guard let bytes = try? Data(contentsOf: manifest),
                          var record = try? decoder.decode(PersonalContentRecord.self, from: bytes),
                          record.schemaVersion == 1 else { continue }
                    let relative = String(checked.path.dropFirst(root.path.count + 1))
                    record.relativePath = relative
                    record.folders = Array(relative.split(separator: "/").dropLast()).map(String.init)
                    result.append(record)
                } else {
                    pending.append(checked)
                }
            }
        }
        guard Set(result.map(\.id)).count == result.count else { throw PersonalContentError.invalidProject }
        return result.sorted { ($0.lastOpenedAt ?? $0.modifiedAt) > ($1.lastOpenedAt ?? $1.modifiedAt) }
    }

    func resolve(_ id: UUID) throws -> (record: PersonalContentRecord, url: URL) {
        guard let record = try records().first(where: { $0.id == id }) else {
            throw PersonalContentError.missingDocument
        }
        return (record, try confined(root.appendingPathComponent(record.relativePath, isDirectory: true)))
    }

    func markOpened(_ id: UUID) throws {
        let value = try resolve(id)
        var record = value.record
        record.lastOpenedAt = Date()
        try encoder.encode(record).write(to: value.url.appendingPathComponent(manifestName), options: .atomic)
    }
    func markChanged(_ id: UUID, title: String? = nil) throws {
        let value = try resolve(id)
        var record = value.record
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { record.title = title }
        record.modifiedAt = Date()
        try encoder.encode(record).write(to: value.url.appendingPathComponent(manifestName), options: .atomic)
    }

    func pin(_ id: UUID, pinned: Bool) throws {
        let value = try resolve(id)
        var record = value.record
        record.isPinned = pinned
        try encoder.encode(record).write(to: value.url.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Organization happens only after the caller drains editor writes and
    /// retains any adopted versions used by another canvas.
    func move(_ id: UUID, to folders: [String], expectedRelativePath: String) throws -> PersonalContentRecord {
        let value = try resolve(id)
        guard value.record.relativePath == expectedRelativePath else { throw PersonalContentError.changedDocument }
        let directory = try folderURL(folders)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = try confined(directory.appendingPathComponent(value.url.lastPathComponent, isDirectory: true))
        guard target != value.url else { return value.record }
        guard !fileManager.fileExists(atPath: target.path) else { throw PersonalContentError.changedDocument }
        try fileManager.moveItem(at: value.url, to: target)
        var record = value.record
        record.folders = folders
        record.relativePath = String(target.path.dropFirst(root.path.count + 1))
        record.modifiedAt = Date()
        do {
            try encoder.encode(record).write(to: target.appendingPathComponent(manifestName), options: .atomic)
        } catch {
            let writeError = error
            do {
                guard !fileManager.fileExists(atPath: value.url.path) else { throw PersonalContentError.changedDocument }
                try fileManager.moveItem(at: target, to: value.url)
            } catch {
                // Never remove either location to make rollback succeed.
                throw PersonalFileActionError.moveRecovery((folders + [target.lastPathComponent]).joined(separator: "/"))
            }
            throw writeError
        }
        return record
    }
}

import Foundation
import CryptoKit
import Darwin

public struct ChemistryRevision: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let revision: UInt64
    public let digest: String
    public var filename: String { "\(revision)-\(digest).json" }
}

/// Immutable snapshots plus an atomically replaced head. flock provides CAS across store instances.
public actor ChemistryProjectStore {
    public nonisolated let root: URL
    private let maxBytes = 128 * 1024 * 1024
    public init(root: URL) throws {
        guard root.isFileURL else { throw ChemistryError.invalid("A project storage directory is required.") }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    public nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func directory(_ id: UUID) throws -> URL {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try refuseLink(url)
        return url
    }
    private func refuseLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ChemistryError.corrupt("Symbolic links are not permitted in project storage.")
        }
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        try refuseLink(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ChemistryError.corrupt("Project file exceeds its size limit.") }
        return data
    }
    private func withLock<T>(_ action: () throws -> T) throws -> T {
        let lock = root.appendingPathComponent(".store.lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ChemistryError.unavailable("Cannot lock project storage.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ChemistryError.unavailable("Cannot lock project storage.") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func head(_ id: UUID) throws -> ChemistryRevision? {
        let path = try directory(id).appendingPathComponent("HEAD.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(ChemistryRevision.self, from: read(path, limit: 4096))
        try validate(value, id: id)
        return value
    }
    private func validate(_ revision: ChemistryRevision, id: UUID) throws {
        guard revision.projectID == id, revision.revision > 0, revision.digest.count == 64,
              revision.digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ChemistryError.corrupt("Invalid project head.")
        }
    }
    private func snapshot(_ value: ChemistryRevision) throws -> ChemistryProject {
        let folder = try directory(value.projectID).appendingPathComponent("revisions", isDirectory: true)
        try refuseLink(folder)
        let bytes = try read(folder.appendingPathComponent(value.filename), limit: maxBytes)
        guard Self.digest(bytes) == value.digest else { throw ChemistryError.corrupt("Project checksum does not match.") }
        let project = try JSONDecoder().decode(ChemistryProject.self, from: bytes)
        guard project.id == value.projectID, project.revision == value.revision else { throw ChemistryError.corrupt("Project identity does not match.") }
        try project.validate()
        return project
    }
    public func load(_ id: UUID) throws -> ChemistryProject {
        guard let value = try head(id) else { throw ChemistryError.unavailable("Project not found.") }
        return try snapshot(value)
    }
    public func save(_ project: ChemistryProject, expectedRevision: UInt64) throws -> ChemistryProject {
        try withLock {
            let current = try head(project.id)
            let actual = current?.revision ?? 0
            guard actual == expectedRevision else { throw ChemistryError.conflict(expected: expectedRevision, actual: actual) }
            // Validate the previous head before publishing a new one; preserve corrupt evidence.
            if let current { _ = try snapshot(current) }
            guard actual < UInt64.max else { throw ChemistryError.invalid("Revision overflow.") }
            var saved = project
            saved.revision = actual + 1; saved.modifiedAt = Date()
            try saved.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(saved)
            guard bytes.count <= maxBytes else { throw ChemistryError.invalid("Project exceeds its size limit.") }
            let revision = ChemistryRevision(projectID: saved.id, revision: saved.revision, digest: Self.digest(bytes))
            let folder = try directory(saved.id).appendingPathComponent("revisions", isDirectory: true)
            try refuseLink(folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appendingPathComponent(revision.filename), options: [.atomic])
            try encoder.encode(revision).write(to: directory(saved.id).appendingPathComponent("HEAD.json"), options: [.atomic])
            return saved
        }
    }
    public func list() throws -> [ChemistryProject] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }.map { try load($0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
    public func history(_ id: UUID) throws -> [ChemistryRevision] {
        let folder = try directory(id).appendingPathComponent("revisions", isDirectory: true)
        try refuseLink(folder)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { url in
            let name = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
            guard url.pathExtension == "json", name.count == 2, let n = UInt64(name[0]) else { throw ChemistryError.corrupt("Invalid revision filename.") }
            let item = ChemistryRevision(projectID: id, revision: n, digest: String(name[1]))
            try validate(item, id: id)
            return item
        }.sorted { $0.revision > $1.revision }
    }
    public func restore(_ revision: ChemistryRevision, expectedRevision: UInt64) throws -> ChemistryProject {
        try validate(revision, id: revision.projectID)
        var old = try snapshot(revision)
        // Restoring document history never resumes a past execution attempt.
        // Fence it in the same saved snapshot, before any late callback can observe HEAD.
        for i in old.runs.indices where [.queued, .running].contains(old.runs[i].status) {
            old.runs[i].status = .interrupted; old.runs[i].finishedAt = Date()
            old.runs[i].result = nil
            old.runs[i].error = "This historical calculation was interrupted by revision restoration. Start a new calculation to run it again."
        }
        return try save(old, expectedRevision: expectedRevision)
    }
    private func recoveryFolder(_ id: UUID) throws -> URL {
        let path = try directory(id).appendingPathComponent("drawing-recovery", isDirectory: true)
        try refuseLink(path)
        return path
    }
    public func saveDrawingRecovery(_ draft: ChemistryDrawingRecovery) throws {
        try withLock {
            _ = try load(draft.projectID)
            let folder = try recoveryFolder(draft.projectID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(draft)
            guard data.count <= 40 * 1024 * 1024 else { throw ChemistryError.invalid("Drawing recovery exceeds its size limit.") }
            let target = folder.appendingPathComponent(draft.id.uuidString + ".json")
            try refuseLink(target); try data.write(to: target, options: .atomic)
        }
    }
    public func drawingRecoveries(_ id: UUID) throws -> [ChemistryDrawingRecovery] {
        let folder = try recoveryFolder(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { path in
            guard path.pathExtension == "json", let draftID = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else { throw ChemistryError.corrupt("Invalid drawing recovery file.") }
            let value = try JSONDecoder().decode(ChemistryDrawingRecovery.self, from: read(path, limit: 40 * 1024 * 1024))
            guard value.projectID == id, value.id == draftID else { throw ChemistryError.corrupt("Drawing recovery identity does not match.") }
            return value
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func removeDrawingRecovery(_ id: UUID, recoveryID: UUID) throws {
        try withLock {
            let target = try recoveryFolder(id).appendingPathComponent(recoveryID.uuidString + ".json")
            try refuseLink(target)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }
}

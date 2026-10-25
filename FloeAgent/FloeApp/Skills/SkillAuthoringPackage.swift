#if canImport(UIKit)
import Foundation
import FloeCore
import FloeSkills

struct SkillAuthoringPackageDescriptor: Codable, Sendable, Equatable {
    enum Origin: String, Codable, Sendable { case imported, generated, adapted }
    let ownerID: UUID
    let snapshotID: UUID
    let origin: Origin
    let createdAt: Date
    let parentSnapshotID: UUID?
    let sourceURL: URL?
    let gitHubBinding: SkillGitHubBinding?
    let digest: String
    let manifest: SkillManifest
    let title: String
    let summary: String
    let fileNames: [String]

    var preparedSkill: SkillAuthoringPreparedSkillValue {
        .init(id: manifest.id, version: manifest.version, digest: digest)
    }
}

/// Small UI/backend value; the durable store owns the installation receipt.
struct SkillAuthoringPreparedSkillValue: Sendable, Equatable {
    let id: String
    let version: String
    let digest: String
}

struct SkillAuthoringPackageStorage: Sendable {
    let root: URL

    enum PackageError: Error, Equatable {
        case invalidResponse, invalidPath, duplicatePath, unsafeSnapshot, missingSnapshot
    }

    private struct Envelope: Decodable {
        struct File: Decodable {
            let path: String
            let text: String?
            let base64: String?
        }
        let files: [File]
        let question: String?
    }

    func importFolder(_ source: URL, ownerID: UUID) throws -> SkillAuthoringPackageDescriptor {
        let package = try SkillPackageValidator().validate(packageAt: source, requireManifest: false)
        let snapshot = try SkillContentSnapshot(root: source, expectedDigest: package.canonicalSHA256,
                                                manifestOverride: package.manifest)
        return try persist(files: snapshot.files, ownerID: ownerID, origin: .imported,
                           parentSnapshotID: nil, manifestOverride: package.manifest)
    }

    /// The preparer owns network/redirect validation. This step owns a fresh,
    /// immutable copy before any picker/download lease may disappear.
    func importPrepared(_ prepared: SkillsCenter.PreparedImport, ownerID: UUID) throws -> SkillAuthoringPackageDescriptor {
        try persist(files: prepared.snapshot.files, ownerID: ownerID, origin: .imported,
                    parentSnapshotID: nil, manifestOverride: prepared.snapshot.package.manifest,
                    sourceURL: prepared.sourceURL, gitHubBinding: prepared.gitHubBinding)
    }

    /// A strict data-only final response. No model output is executed, and no
    /// capability is granted. Adaptation overlays explicitly returned files on
    /// the immutable original so unmentioned assets/licenses cannot disappear.
    func generatedPackage(from response: String, ownerID: UUID,
                          adapting originalID: UUID? = nil) throws -> SkillAuthoringPackageDescriptor {
        let limits = SkillValidationLimits()
        guard response.utf8.count <= limits.maximumPackageBytes * 6 + 262_144 else {
            throw PackageError.invalidResponse
        }
        var payload = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```json\n"), payload.hasSuffix("```") {
            payload.removeFirst(8); payload.removeLast(3)
        } else if payload.hasPrefix("```\n"), payload.hasSuffix("```") {
            payload.removeFirst(4); payload.removeLast(3)
        }
        let envelope: Envelope
        do {
            let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            guard let object, Set(object.keys) == ["files"], let rows = object["files"] as? [[String: Any]],
                  rows.allSatisfy({ Set($0.keys).isSubset(of: ["path", "text", "base64"]) }) else {
                throw PackageError.invalidResponse
            }
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(payload.utf8))
        }
        catch { throw PackageError.invalidResponse }
        guard envelope.question == nil, !envelope.files.isEmpty, envelope.files.count <= limits.maximumFileCount else {
            throw PackageError.invalidResponse
        }
        var files: [String: Data] = [:]
        if let originalID { files = try snapshot(ownerID: ownerID, id: originalID).files }
        var seen = Set<String>()
        for file in envelope.files {
            try Task.checkCancellation()
            let path = try Self.validatedPath(file.path)
            guard seen.insert(path.lowercased()).inserted else { throw PackageError.duplicatePath }
            let data: Data
            switch (file.text, file.base64) {
            case (.some(let text), nil): data = Data(text.utf8)
            case (nil, .some(let encoded)):
                guard let decoded = Data(base64Encoded: encoded) else { throw PackageError.invalidResponse }
                data = decoded
            default: throw PackageError.invalidResponse
            }
            guard data.count <= limits.maximumFileBytes else { throw PackageError.invalidResponse }
            // Case-insensitive destinations must not overwrite a different
            // resource that happened to differ only in case upstream.
            if let other = files.keys.first(where: { $0.lowercased() == path.lowercased() }), other != path {
                throw PackageError.duplicatePath
            }
            files[path] = data
        }
        return try persist(files: files, ownerID: ownerID,
                           origin: originalID == nil ? .generated : .adapted,
                           parentSnapshotID: originalID, manifestOverride: nil)
    }

    static func question(from response: String) throws -> String? {
        guard response.utf8.count <= 8 * 1024 * 1024 * 6 + 262_144 else { throw PackageError.invalidResponse }
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json\n"), value.hasSuffix("```") { value.removeFirst(8); value.removeLast(3) }
        else if value.hasPrefix("```\n"), value.hasSuffix("```") { value.removeFirst(4); value.removeLast(3) }
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw PackageError.invalidResponse
        }
        guard object["question"] != nil else { return nil }
        guard Set(object.keys) == ["question"], let question = object["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 4096 else { throw PackageError.invalidResponse }
        return question
    }

    func removeOwnedSnapshots(ownerID: UUID) throws {
        let owner = root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: owner.path) { try FileManager.default.removeItem(at: owner) }
    }

    func descriptor(ownerID: UUID, id: UUID) throws -> SkillAuthoringPackageDescriptor {
        let url = directory(ownerID: ownerID, id: id).appendingPathComponent("snapshot.json")
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, let size = attributes.fileSize, (1...131_072).contains(size) else {
            throw PackageError.unsafeSnapshot
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 131_072 else { throw PackageError.unsafeSnapshot }
        let value = try JSONDecoder().decode(SkillAuthoringPackageDescriptor.self, from: data)
        guard value.ownerID == ownerID, value.snapshotID == id else { throw PackageError.unsafeSnapshot }
        return value
    }

    func snapshot(ownerID: UUID, id: UUID) throws -> SkillContentSnapshot {
        let value = try descriptor(ownerID: ownerID, id: id)
        return try SkillContentSnapshot(root: packageURL(ownerID: ownerID, id: id),
                                        expectedDigest: value.digest, manifestOverride: value.manifest)
    }

    func packageURL(ownerID: UUID, id: UUID) -> URL {
        directory(ownerID: ownerID, id: id).appendingPathComponent("package", isDirectory: true)
    }

    private func directory(ownerID: UUID, id: UUID) -> URL {
        root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func persist(files: [String: Data], ownerID: UUID,
                         origin: SkillAuthoringPackageDescriptor.Origin, parentSnapshotID: UUID?,
                         manifestOverride: SkillManifest?, sourceURL: URL? = nil,
                         gitHubBinding: SkillGitHubBinding? = nil) throws -> SkillAuthoringPackageDescriptor {
        let limits = SkillValidationLimits()
        guard !files.isEmpty, files.count <= limits.maximumFileCount,
              files.values.reduce(0, { $0 + $1.count }) <= limits.maximumPackageBytes else {
            throw PackageError.invalidResponse
        }
        let snapshotID = UUID()
        let owner = root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        let pending = owner.appendingPathComponent(snapshotID.uuidString + ".pending", isDirectory: true)
        let destination = directory(ownerID: ownerID, id: snapshotID)
        guard !FileManager.default.fileExists(atPath: pending.path),
              !FileManager.default.fileExists(atPath: destination.path) else { throw PackageError.unsafeSnapshot }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: pending) } }
        let packageRoot = pending.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
        var paths = Set<String>()
        for (rawPath, data) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let path = try Self.validatedPath(rawPath)
            guard paths.insert(path.lowercased()).inserted else { throw PackageError.duplicatePath }
            guard data.count <= limits.maximumFileBytes else { throw PackageError.invalidResponse }
            let target = packageRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .withoutOverwriting)
        }
        let package = try SkillPackageValidator().validate(packageAt: packageRoot,
            requireManifest: false, manifestOverride: manifestOverride)
        let value = SkillAuthoringPackageDescriptor(ownerID: ownerID, snapshotID: snapshotID,
            origin: origin, createdAt: Date(), parentSnapshotID: parentSnapshotID,
            sourceURL: sourceURL, gitHubBinding: gitHubBinding, digest: package.canonicalSHA256,
            manifest: package.manifest, title: package.metadata.name,
            summary: package.metadata.description, fileNames: package.files.map(\.relativePath).sorted())
        try JSONEncoder().encode(value).write(to: pending.appendingPathComponent("snapshot.json"), options: .atomic)
        try FileManager.default.moveItem(at: pending, to: destination)
        committed = true
        return value
    }

    static func validatedPath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains("\0"),
              parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              let top = parts.first, SkillPackageValidator.packageTopLevelEntries.contains(String(top)) else {
            throw PackageError.invalidPath
        }
        return path
    }
}
#endif

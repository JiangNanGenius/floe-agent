// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeBuildingRecords
import FloeBuildingProject

/// Independent outputs created from a building project. Every case writes a
/// new package under `<project parent>/Copies`; the source project is only
/// read after its current state has been checkpointed.
public enum BuildingProjectCopyKind: String, Codable, Sendable, CaseIterable, Hashable {
    case building
    case cad2D
    case cad3D

    public var fileExtension: String {
        switch self {
        case .building: return BuildingProjectDocumentType.filenameExtension
        case .cad2D, .cad3D: return "floecad"
        }
    }
}

/// Stable receipt for one independent copy. `id` is the new copy identity the
/// Space layer must use when it reserves a record/assistant binding. The
/// internal Records project identity is retained only as provenance.
public struct BuildingProjectCopyReceipt: Codable, Sendable, Hashable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let kind: BuildingProjectCopyKind
    public let title: String
    public let fileName: String
    public let projectID: ProjectID
    public let sourceGenerationID: String?
    public let contentSHA256: String?
    public let cadRevision: Int?
    public let byteCount: Int
    public let createdAt: Date
    public let losses: [String]

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        kind: BuildingProjectCopyKind,
        title: String,
        fileName: String,
        projectID: ProjectID,
        sourceGenerationID: String?,
        contentSHA256: String?,
        cadRevision: Int?,
        byteCount: Int,
        createdAt: Date,
        losses: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.title = title
        self.fileName = fileName
        self.projectID = projectID
        self.sourceGenerationID = sourceGenerationID
        self.contentSHA256 = contentSHA256
        self.cadRevision = cadRevision
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.losses = losses
    }

    public var relativePath: String {
        kind == .building ? "Copies/\(fileName)" : "Copies/CAD/\(fileName)"
    }

    /// Resolve the copy under its owning Space record directory. Receipts never
    /// store absolute paths, so moving or sharing the record is safe.
    public func url(in recordDirectory: URL) -> URL {
        let root = recordDirectory.appendingPathComponent("Copies", isDirectory: true)
        let directory = kind == .building
            ? root
            : root.appendingPathComponent("CAD", isDirectory: true)
        return directory.appendingPathComponent(fileName, isDirectory: kind == .building)
    }
}

public enum BuildingProjectCopyError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case invalidTitle
    case destinationExists(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message): return message
        case .invalidTitle: return "Use a non-empty copy name without path separators."
        case let .destinationExists(name): return "A copy named \(name) already exists; nothing was overwritten."
        case let .verifyFailed(message): return "The copy could not be verified: \(message)"
        }
    }
}

struct BuildingProjectCopyIndex: Codable, Sendable {
    var schemaVersion = 1
    var copies: [BuildingProjectCopyReceipt] = []
}

enum BuildingProjectCopyStore {
    static func copiesRoot(projectDirectory: URL) -> URL {
        if projectDirectory.lastPathComponent == "Project.floebuilding" {
            return projectDirectory.deletingLastPathComponent().appendingPathComponent("Copies", isDirectory: true)
        }
        // Workspace CAD originals can have several sibling building projects; each owns its copies.
        return projectDirectory.appendingPathComponent("Copies", isDirectory: true)
    }

    static func cadRoot(projectDirectory: URL) -> URL {
        copiesRoot(projectDirectory: projectDirectory).appendingPathComponent("CAD", isDirectory: true)
    }

    static func indexURL(projectDirectory: URL) -> URL {
        copiesRoot(projectDirectory: projectDirectory).appendingPathComponent("Index.json", isDirectory: false)
    }

    static func sanitizedStem(_ value: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = ""
        for character in cleaned {
            if name.utf8.count + String(character).utf8.count > 180 { break }
            name.append(character)
        }
        return name.isEmpty ? "Building copy" : name
    }

    static func uniqueURL(directory: URL, stem: String, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 1
        while index <= 9999 {
            let suffix = index == 1 ? "" : "-\(index)"
            let name = "\(stem)\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        throw BuildingProjectCopyError.destinationExists(stem)
    }

    static func loadIndex(projectDirectory: URL) throws -> BuildingProjectCopyIndex {
        let url = indexURL(projectDirectory: projectDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return BuildingProjectCopyIndex() }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 4 * 1024 * 1024 else {
            throw BuildingProjectCopyError.verifyFailed("The copy index is not a readable regular file.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(BuildingProjectCopyIndex.self, from: Data(contentsOf: url))
        guard index.schemaVersion == 1, Set(index.copies.map(\.id)).count == index.copies.count,
              index.copies.allSatisfy({ item in
                  let name = item.fileName
                  return !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
                      && (name as NSString).pathExtension.lowercased() == item.kind.fileExtension
              }) else { throw BuildingProjectCopyError.verifyFailed("The project copy index is invalid.") }
        return index
    }

    static func append(_ receipt: BuildingProjectCopyReceipt, projectDirectory: URL) throws {
        var index = try loadIndex(projectDirectory: projectDirectory)
        index.copies.removeAll { $0.id == receipt.id }
        index.copies.insert(receipt, at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        guard data.count <= 4 * 1024 * 1024 else {
            throw BuildingProjectCopyError.verifyFailed("The copy index exceeded its budget.")
        }
        let url = indexURL(projectDirectory: projectDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func url(for receipt: BuildingProjectCopyReceipt, projectDirectory: URL) -> URL {
        let root = receipt.kind == .building
            ? copiesRoot(projectDirectory: projectDirectory)
            : cadRoot(projectDirectory: projectDirectory)
        return root.appendingPathComponent(receipt.fileName, isDirectory: receipt.kind == .building)
    }

    static func directoryByteCount(_ url: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BuildingProjectCopyError.verifyFailed("The copied package is missing.")
        }
        var total = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BuildingProjectCopyError.verifyFailed("The copied package could not be enumerated.")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw BuildingProjectCopyError.verifyFailed("The copied package contains a symbolic link.")
            }
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
                guard total <= 8 * 1024 * 1024 * 1024 else {
                    throw BuildingProjectCopyError.verifyFailed("The copied package exceeded its size budget.")
                }
            }
        }
        return total
    }
}

public extension BuildingEditorProjectSession {
    func projectCopyURL(_ receipt: BuildingProjectCopyReceipt) -> URL {
        BuildingProjectCopyStore.url(for: receipt, projectDirectory: projectDirectory)
    }

    func publishSavedCopy(_ receipt: BuildingProjectCopyReceipt) async throws {
        try requireOpenForCopy()
        let url = projectCopyURL(receipt)
        let parent = BuildingProjectCopyStore.copiesRoot(projectDirectory: projectDirectory).standardizedFileURL
        guard receipt.projectID == projectID,
              url.standardizedFileURL.pathComponents.starts(with: parent.pathComponents),
              url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: parent.resolvingSymlinksInPath().pathComponents),
              try listProjectCopies().contains(where: { $0.id == receipt.id && $0.fileName == receipt.fileName && $0.contentSHA256 == receipt.contentSHA256 }) else {
            throw BuildingProjectCopyError.verifyFailed("This copy does not belong to the current project.")
        }
        try await publishIndependentCopy?(receipt, url)
    }

    func listProjectCopies() throws -> [BuildingProjectCopyReceipt] {
        let index = try BuildingProjectCopyStore.loadIndex(projectDirectory: projectDirectory)
        return index.copies.filter {
            FileManager.default.fileExists(atPath: projectCopyURL($0).path)
        }
    }

    /// Save-as with an independent portable `.floebuilding` package. Any
    /// unpublished edit is checkpointed first, so the copy reflects the state
    /// the user sees rather than an older generation.
    @discardableResult
    func saveBuildingCopy(title: String? = nil) async throws -> BuildingProjectCopyReceipt {
        try requireOpenForCopy()
        if hasUnpublishedChanges { try await checkpoint() }
        guard !busy else { throw BuildingEditorProjectError.busy }
        busy = true
        defer { busy = false }
        let stem = BuildingProjectCopyStore.sanitizedStem(
            title ?? (cad.document.name.isEmpty ? "Building" : cad.document.name) + " copy"
        )
        let directory = BuildingProjectCopyStore.copiesRoot(projectDirectory: projectDirectory)
        let destination = try BuildingProjectCopyStore.uniqueURL(
            directory: directory,
            stem: stem,
            extension: BuildingProjectDocumentType.filenameExtension
        )
        let portable = try repository.exportPortableCopy(to: destination)
        let receipt = BuildingProjectCopyReceipt(
            id: UUID(),
            kind: .building,
            title: destination.deletingPathExtension().lastPathComponent,
            fileName: destination.lastPathComponent,
            projectID: projectID,
            sourceGenerationID: portable.generationID,
            contentSHA256: portable.contentDigest,
            cadRevision: nil,
            byteCount: portable.totalByteCount,
            createdAt: Date(),
            losses: [
                "The copy keeps the source Records project identity as provenance; its path and Space/assistant identity are new.",
                "Working copies, journals and staging directories are not included.",
            ]
        )
        do { try BuildingProjectCopyStore.append(receipt, projectDirectory: projectDirectory) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return receipt
    }

    /// A 2D copy can use an existing drawing page or a plan projected from the selected building elements.
    @discardableResult
    func exportCADCopy(kind: BuildingProjectCopyKind,
                       pageID: UUID? = nil,
                       title: String? = nil,
                       scope: CADBuildingExportScope = .wholeProject) async throws -> BuildingProjectCopyReceipt {
        guard kind != .building else { throw BuildingProjectCopyError.unavailable("Choose a CAD copy type.") }
        guard pageID == nil || (kind == .cad2D && scope == .wholeProject) else {
            throw BuildingProjectCopyError.unavailable("A drawing page belongs to a whole-project 2D copy.")
        }
        try requireOpenForCopy()
        if hasUnpublishedChanges { try await checkpoint() }
        try requireOpenForCopy()
        let temporary: URL
        let source: URL
        var losses: [String] = []
        if pageID != nil {
            let (directory, receipt) = try await exportProject(pageID: pageID)
            guard let file = receipt.files.first(where: {
                $0.role == "whole-project-native-2d" && $0.format == "floecad-package" && $0.verified
            }) else {
                try? FileManager.default.removeItem(at: directory)
                throw BuildingProjectCopyError.unavailable("The selected page produced no verified native 2D package.")
            }
            temporary = directory
            source = directory.appendingPathComponent(file.relativePath)
            losses = file.unsupportedLosses + receipt.unsupported
            guard await FloeCADDocument.storedIdentity(at: source)?.contentSHA256 == file.sha256 else {
                try? FileManager.default.removeItem(at: directory)
                throw BuildingProjectCopyError.verifyFailed("The drawing page changed during export.")
            }
        } else {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            source = temporary.appendingPathComponent("Copy.floecad", isDirectory: true)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try requireOpenForCopy()
        busy = true
        defer { busy = false }
        if pageID == nil {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let document: FloeCADDocument
            if kind == .cad2D {
                document = try await cad.document.createScopedBuildingPlan(scope, at: source)
            } else {
                document = try await cad.document.createScopedBuildingExportDocument(scope, at: source)
            }
            document.close()
        }
        guard let stored = await FloeCADDocument.storedIdentity(at: source),
              let modelSHA = stored.modelSHA256, !modelSHA.isEmpty else {
            throw BuildingProjectCopyError.verifyFailed("The native copy has no verified model identity.")
        }
        let stem = BuildingProjectCopyStore.sanitizedStem(
            title ?? (cad.document.name.isEmpty ? "Building" : cad.document.name) + (kind == .cad2D ? " 2D" : " 3D")
        )
        let directory = BuildingProjectCopyStore.cadRoot(projectDirectory: projectDirectory)
        let destination = try BuildingProjectCopyStore.uniqueURL(directory: directory, stem: stem, extension: "floecad")
        try await Self.importNativeDocumentPackage(
            from: source,
            expected: (stored.revision, stored.contentSHA256, modelSHA),
            to: destination
        )
        let copied = try await FloeCADDocument.storedIdentity(at: destination)
        guard copied?.contentSHA256 == stored.contentSHA256,
              copied?.revision == stored.revision,
              copied?.modelSHA256 == stored.modelSHA256 else {
            try? FileManager.default.removeItem(at: destination)
            throw BuildingProjectCopyError.verifyFailed("The copied CAD package did not reopen with the same identity.")
        }
        let receipt = BuildingProjectCopyReceipt(
            id: UUID(),
            kind: kind,
            title: destination.deletingPathExtension().lastPathComponent,
            fileName: destination.lastPathComponent,
            projectID: projectID,
            sourceGenerationID: published?.generationID,
            contentSHA256: stored.contentSHA256,
            cadRevision: stored.revision,
            byteCount: try BuildingProjectCopyStore.directoryByteCount(destination),
            createdAt: Date(),
            losses: Array(Set(losses)).sorted()
        )
        do { try BuildingProjectCopyStore.append(receipt, projectDirectory: projectDirectory) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return receipt
    }

    func exchangeFiles() throws -> [URL] {
        let root = BuildingProjectCopyStore.copiesRoot(projectDirectory: projectDirectory)
            .appendingPathComponent("Exports", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw BuildingProjectCopyError.verifyFailed("The export folder has moved.")
        }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).filter { file in
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
                    && BuildingInterchangeFormat(rawValue: file.pathExtension.lowercased()) != nil
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func exportExchangeFile(format: BuildingInterchangeFormat, scope: CADBuildingExportScope, pageID: UUID? = nil,
                            title: String? = nil) async throws -> BuildingInterchangeReceipt {
        try requireOpenForCopy()
        if hasUnpublishedChanges { try await checkpoint() }
        try requireOpenForCopy()
        busy = true
        defer { busy = false }
        let directory = BuildingProjectCopyStore.copiesRoot(projectDirectory: projectDirectory)
            .appendingPathComponent("Exports", isDirectory: true)
        let stem = BuildingProjectCopyStore.sanitizedStem(title ?? cad.document.name)
        let name = try BuildingProjectCopyStore.uniqueURL(directory: directory, stem: stem, extension: format.rawValue).lastPathComponent
        return try await BuildingInterchangeExport.write(document: cad.document, scope: scope, pageID: pageID,
            format: format, to: directory.appendingPathComponent(name, isDirectory: false), encodeDWG: encodeDWG, encodeIFC: encodeIFC)
    }

    /// A portable package suitable for sharing. Verification runs again so a
    /// stale receipt or a partially copied folder is never shared as valid.
    func verifiedPortableCopyURL(_ receipt: BuildingProjectCopyReceipt) throws -> URL {
        guard receipt.kind == .building else {
            throw BuildingProjectCopyError.unavailable("Only a building copy is portable as .floebuilding.")
        }
        let url = projectCopyURL(receipt)
        let verified = try BuildingProjectRepository.verifyPortableCopy(at: url)
        guard verified.generationID == receipt.sourceGenerationID,
              verified.contentDigest == receipt.contentSHA256 else {
            throw BuildingProjectCopyError.verifyFailed("The portable copy no longer matches its receipt.")
        }
        return url
    }

    private func requireOpenForCopy() throws {
        guard !closed else { throw BuildingEditorProjectError.closed }
        guard !busy, furniture?.busy != true else { throw BuildingEditorProjectError.busy }
    }
}
#endif

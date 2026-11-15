import CryptoKit
import Foundation
import UniformTypeIdentifiers
import FloeBuildingRecords

/// The user-exchangeable building project document.
///
/// The on-disk project is already a directory with an immutable published
/// generation and a manifest that is written last. A portable copy contains
/// only that published state plus its manifest, so it can be copied, shared
/// and reopened without the working copies, journals or staging directories
/// of the editor that produced it. The extension and UTType are stable App
/// metadata; they are not inferred from a folder name.
public enum BuildingProjectDocumentType {
    public static let filenameExtension = "floebuilding"
    public static let contentTypeIdentifier = "org.floeagent.building-project"
    public static let contentTypeDescription = "Floe Building Project"
    public static let mimeType = "application/vnd.floe.building-project"
    public static let conformsToPackage = "com.apple.package"

    @available(iOS 14.0, macOS 11.0, *)
    public static var contentType: UTType {
        UTType(contentTypeIdentifier)
            ?? UTType(filenameExtension: filenameExtension)
            ?? .package
    }

    /// A directory is only offered as a building project after its own
    /// manifest and generation verify. The extension is a hint, never the
    /// authority for opening arbitrary folders.
    public static func recognizes(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == filenameExtension
    }
}

/// A verified copy receipt. Paths are deliberately absent: the host owns the
/// copy location, and a receipt survives moving the project or the copy.
public struct BuildingProjectPortableCopyReceipt: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let projectID: ProjectID
    public let generationID: String
    public let sequence: Int
    public let fileCount: Int
    public let totalByteCount: Int
    public let manifestSHA256: String
    public let contentDigest: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1,
        projectID: ProjectID,
        generationID: String,
        sequence: Int,
        fileCount: Int,
        totalByteCount: Int,
        manifestSHA256: String,
        contentDigest: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.generationID = generationID
        self.sequence = sequence
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.manifestSHA256 = manifestSHA256
        self.contentDigest = contentDigest
        self.createdAt = createdAt
    }
}

private struct InspectedPortableCopy {
    let root: URL
    let manifestData: Data
    let manifest: BuildingProjectManifest
    let generationJSONData: Data
    let record: BuildingGenerationRecord
    let receipt: BuildingProjectPortableCopyReceipt
}

public extension BuildingProjectRepository {
    /// Write a self-contained, verified copy of the current published
    /// generation. Nothing is overwritten and the source repository is only
    /// read. The destination is a `*.floebuilding` directory package.
    func exportPortableCopy(
        to destination: URL,
        cancellation: BuildingProjectCancellation? = nil
    ) throws -> BuildingProjectPortableCopyReceipt {
        try configuration.validate()
        if let cancellation { try cancellation.check() }
        guard destination.isFileURL else {
            throw BuildingProjectError.ioFailure("the portable copy destination is not a file URL")
        }
        let target = destination.standardizedFileURL
        guard !BuildingProjectPaths.isSameOrAncestor(rootURL, of: target),
              !BuildingProjectPaths.isSameOrAncestor(target, of: rootURL) else {
            throw BuildingProjectError.pathEscapesRoot("the portable copy must be outside the project")
        }
        guard BuildingProjectFileSystem.kind(of: target) == .missing else {
            throw BuildingProjectError.outputExists(target.lastPathComponent)
        }
        let snapshot = try withLock(exclusive: false) {
            guard let manifestData = try readManifestDataUnderLock(),
                  let manifest = try readManifestUnderLock() else {
                throw BuildingProjectError.noPublishedGeneration
            }
            let generation = try loadGeneration(
                manifest.generationID,
                manifest: manifest,
                verify: true
            )
            let generationJSON = generation.directoryURL.appendingPathComponent(
                BuildingProjectPaths.generationFileName,
                isDirectory: false
            )
            let generationData = try BuildingProjectFileSystem.readBounded(
                generationJSON,
                maxBytes: limits.maxManifestBytes
            )
            return (manifestData, manifest, generation.record, generationData)
        }
        let (manifestData, manifest, record, generationData) = snapshot
        if let cancellation { try cancellation.check() }

        let parent = target.deletingLastPathComponent()
        try BuildingProjectFileSystem.ensureDirectory(parent)
        let staging = parent.appendingPathComponent(
            ".\(target.lastPathComponent).staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var completed = false
        defer {
            if !completed { try? BuildingProjectFileSystem.removeTree(staging) }
        }
        try BuildingProjectFileSystem.ensureDirectory(staging)
        let isCancelled: @Sendable () -> Bool = { cancellation?.isCancelled ?? false }

        let destinationManifest = staging.appendingPathComponent(BuildingProjectPaths.manifestName)
        _ = try BuildingProjectFileSystem.copyFile(
            from: rootURL.appendingPathComponent(BuildingProjectPaths.manifestName, isDirectory: false),
            to: destinationManifest,
            expectedByteCount: manifestData.count,
            expectedSHA256: BuildingProjectFileSystem.sha256Hex(manifestData),
            relativePath: BuildingProjectPaths.manifestName,
            chunkBytes: limits.copyChunkBytes,
            isCancelled: isCancelled
        )

        let generationDirectory = BuildingProjectPaths.generationDirectoryURL(
            root: staging,
            generationID: record.generationID
        )
        try BuildingProjectFileSystem.ensureDirectory(generationDirectory)
        let sourceGeneration = BuildingProjectPaths.generationDirectoryURL(
            root: rootURL,
            generationID: record.generationID
        )
        for section in BuildingFileSection.allCases {
            if isCancelled() { throw BuildingProjectError.cancelled }
            let expected = record.files.filter { $0.section == section }
            let destinationSection = BuildingProjectPaths.sectionRootURL(
                generationURL: generationDirectory,
                section: section
            )
            try BuildingProjectFileSystem.ensureDirectory(destinationSection)
            let sourceSection = BuildingProjectPaths.sectionRootURL(
                generationURL: sourceGeneration,
                section: section
            )
            if expected.isEmpty {
                let actual = try BuildingProjectFileSystem.hashTree(
                    root: sourceSection,
                    section: section,
                    limits: limits,
                    isCancelled: isCancelled
                )
                guard actual.isEmpty else {
                    throw BuildingProjectError.generationCorrupted(
                        generationID: record.generationID,
                        reason: "the \(section.rawValue) section contains files outside Generation.json"
                    )
                }
                continue
            }
            for file in expected.sorted(by: { $0.relativePath < $1.relativePath }) {
                if isCancelled() { throw BuildingProjectError.cancelled }
                _ = try BuildingProjectFileSystem.copyFile(
                    from: sourceSection.appendingPathComponent(file.relativePath, isDirectory: false),
                    to: destinationSection.appendingPathComponent(file.relativePath, isDirectory: false),
                    expectedByteCount: file.byteCount,
                    expectedSHA256: file.sha256,
                    relativePath: file.relativePath,
                    chunkBytes: limits.copyChunkBytes,
                    isCancelled: isCancelled
                )
            }
            let copied = try BuildingProjectFileSystem.hashTree(
                root: destinationSection,
                section: section,
                limits: limits,
                isCancelled: isCancelled
            )
            guard copied == expected.sorted(by: { $0.relativePath < $1.relativePath }) else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: record.generationID,
                    reason: "the \(section.rawValue) files did not copy with the published hashes"
                )
            }
        }
        _ = try BuildingProjectFileSystem.copyFile(
            from: sourceGeneration.appendingPathComponent(BuildingProjectPaths.generationFileName),
            to: generationDirectory.appendingPathComponent(BuildingProjectPaths.generationFileName),
            expectedByteCount: generationData.count,
            expectedSHA256: BuildingProjectFileSystem.sha256Hex(generationData),
            relativePath: BuildingProjectPaths.generationFileName,
            chunkBytes: limits.copyChunkBytes,
            isCancelled: isCancelled
        )
        if let cancellation { try cancellation.check() }
        let verified = try Self.verifyPortableCopy(at: staging, configuration: configuration)
        guard verified.generationID == record.generationID,
              verified.projectID == record.projectID,
              verified.manifestSHA256 == BuildingProjectFileSystem.sha256Hex(manifestData) else {
            throw BuildingProjectError.ioFailure("the portable copy did not verify with the same identity")
        }
        _ = manifest
        try FileManager.default.moveItem(at: staging, to: target)
        completed = true
        return verified
    }

    /// Read-only verification of a portable copy. No lock, working directory
    /// or journal is created inside the copy. The package must contain exactly
    /// Manifest.json and one Generations/<manifest.generationID> directory;
    /// every section file is hashed against Generation.json.
    static func verifyPortableCopy(
        at url: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectPortableCopyReceipt {
        try inspectProjectRoot(url, configuration: configuration, allowRuntimeDirectories: false).receipt
    }

    /// Verify a live project directory that may contain recovery/working
    /// directories. Only Manifest.json and the named generation are trusted;
    /// runtime directories are ignored rather than mistaken for published data.
    /// Older immutable generation directories are allowed but never trusted for
    /// this read.
    static func verifyProjectDirectory(
        at url: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectPortableCopyReceipt {
        try inspectProjectRoot(url, configuration: configuration, allowRuntimeDirectories: true).receipt
    }

    /// Pure read-only, size/count-limited portable-to-portable copy. It uses
    /// only the verified record's file list, never creates a lock in the source,
    /// and fails rather than copying any unlisted root, generation or section
    /// entry. Space import, system open staging and share export share this.
    static func copyPortableCopy(
        from source: URL,
        to destination: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectPortableCopyReceipt {
        try configuration.validate()
        let inspection = try inspectProjectRoot(
            source,
            configuration: configuration,
            allowRuntimeDirectories: false
        )
        let sourceRoot = inspection.root
        guard destination.isFileURL else {
            throw BuildingProjectError.ioFailure("the destination is not a file URL")
        }
        let target = destination.standardizedFileURL
        guard !BuildingProjectPaths.isSameOrAncestor(sourceRoot, of: target),
              !BuildingProjectPaths.isSameOrAncestor(target, of: sourceRoot) else {
            throw BuildingProjectError.pathEscapesRoot("the copied package must be outside its source")
        }
        guard BuildingProjectFileSystem.kind(of: target) == .missing else {
            throw BuildingProjectError.outputExists(target.lastPathComponent)
        }
        let parent = target.deletingLastPathComponent()
        try BuildingProjectFileSystem.ensureDirectory(parent)
        let staging = parent.appendingPathComponent(
            ".\(target.lastPathComponent).copy-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var completed = false
        defer {
            if !completed { try? BuildingProjectFileSystem.removeTree(staging) }
        }
        try BuildingProjectFileSystem.ensureDirectory(staging)
        let isCancelled: @Sendable () -> Bool = { false }

        _ = try BuildingProjectFileSystem.copyFile(
            from: sourceRoot.appendingPathComponent(BuildingProjectPaths.manifestName, isDirectory: false),
            to: staging.appendingPathComponent(BuildingProjectPaths.manifestName, isDirectory: false),
            expectedByteCount: inspection.manifestData.count,
            expectedSHA256: inspection.receipt.manifestSHA256,
            relativePath: BuildingProjectPaths.manifestName,
            chunkBytes: configuration.limits.copyChunkBytes,
            isCancelled: isCancelled
        )
        let destinationGeneration = BuildingProjectPaths.generationDirectoryURL(
            root: staging,
            generationID: inspection.record.generationID
        )
        try BuildingProjectFileSystem.ensureDirectory(destinationGeneration)
        for section in BuildingFileSection.allCases {
            let expected = inspection.record.files
                .filter { $0.section == section }
                .sorted { $0.relativePath < $1.relativePath }
            let destinationSection = BuildingProjectPaths.sectionRootURL(
                generationURL: destinationGeneration,
                section: section
            )
            try BuildingProjectFileSystem.ensureDirectory(destinationSection)
            for file in expected {
                let sourceSection = BuildingProjectPaths.sectionRootURL(
                    generationURL: BuildingProjectPaths.generationDirectoryURL(
                        root: sourceRoot,
                        generationID: inspection.record.generationID
                    ),
                    section: section
                )
                _ = try BuildingProjectFileSystem.copyFile(
                    from: sourceSection.appendingPathComponent(file.relativePath, isDirectory: false),
                    to: destinationSection.appendingPathComponent(file.relativePath, isDirectory: false),
                    expectedByteCount: file.byteCount,
                    expectedSHA256: file.sha256,
                    relativePath: file.relativePath,
                    chunkBytes: configuration.limits.copyChunkBytes,
                    isCancelled: isCancelled
                )
            }
            let copied = try BuildingProjectFileSystem.hashTree(
                root: destinationSection,
                section: section,
                limits: configuration.limits,
                isCancelled: isCancelled
            )
            guard copied == expected else {
                throw BuildingProjectError.ioFailure("the \(section.rawValue) section did not copy exactly")
            }
        }
        _ = try BuildingProjectFileSystem.copyFile(
            from: BuildingProjectPaths.generationDirectoryURL(
                root: sourceRoot,
                generationID: inspection.record.generationID
            ).appendingPathComponent(BuildingProjectPaths.generationFileName),
            to: destinationGeneration.appendingPathComponent(BuildingProjectPaths.generationFileName),
            expectedByteCount: inspection.generationJSONData.count,
            expectedSHA256: BuildingProjectFileSystem.sha256Hex(inspection.generationJSONData),
            relativePath: BuildingProjectPaths.generationFileName,
            chunkBytes: configuration.limits.copyChunkBytes,
            isCancelled: isCancelled
        )
        let verified = try verifyPortableCopy(at: staging, configuration: configuration)
        guard verified.generationID == inspection.receipt.generationID,
              verified.contentDigest == inspection.receipt.contentDigest,
              verified.manifestSHA256 == inspection.receipt.manifestSHA256 else {
            throw BuildingProjectError.sourceChangedDuringCommit("the portable copy changed while it was copied")
        }
        try FileManager.default.moveItem(at: staging, to: target)
        completed = true
        return verified
    }

    /// Create a new project repository from a verified portable copy. The
    /// source is never modified, and the destination is never an existing
    /// directory. The copy itself is written by `copyPortableCopy`; opening the
    /// destination creates its own working directories and lock.
    static func importPortableCopy(
        from source: URL,
        to destination: URL,
        configuration: BuildingProjectConfiguration = .default
    ) throws -> BuildingProjectRepository {
        _ = try copyPortableCopy(from: source, to: destination, configuration: configuration)
        let repository = try BuildingProjectRepository.open(at: destination, configuration: configuration)
        _ = try repository.currentGeneration()
        return repository
    }

    private static func inspectProjectRoot(
        _ url: URL,
        configuration: BuildingProjectConfiguration,
        allowRuntimeDirectories: Bool
    ) throws -> InspectedPortableCopy {
        try configuration.validate()
        guard url.isFileURL else {
            throw BuildingProjectError.invalidRoot("the portable copy is not a file URL")
        }
        // Do not resolve the input first: a symlink at the selected package
        // URL must be rejected rather than silently opened at its target.
        let root = url.standardizedFileURL
        switch BuildingProjectFileSystem.kind(of: root) {
        case .directory:
            break
        case .missing:
            throw BuildingProjectError.projectNotFound
        case .symbolicLink:
            throw BuildingProjectError.invalidRoot("the portable copy must not be a symbolic link")
        case .regular, .other:
            throw BuildingProjectError.invalidRoot("the portable copy is not a directory")
        }
        let names = try BuildingProjectFileSystem.listDirectoryNames(root)
        var allowed: Set<String> = [
            BuildingProjectPaths.manifestName,
            BuildingProjectPaths.generationsDirectoryName
        ]
        if allowRuntimeDirectories {
            allowed.formUnion([
                BuildingProjectPaths.stagingDirectoryName,
                BuildingProjectPaths.journalDirectoryName,
                BuildingProjectPaths.workDirectoryName,
                BuildingProjectPaths.abandonedDirectoryName,
                BuildingProjectPaths.lockName
            ])
        }
        guard Set(names).isSubset(of: allowed),
              names.contains(BuildingProjectPaths.manifestName),
              names.contains(BuildingProjectPaths.generationsDirectoryName) else {
            throw BuildingProjectError.manifestCorrupted(
                allowRuntimeDirectories
                    ? "the project root contains an unexpected entry"
                    : "a portable copy contains only Manifest.json and Generations"
            )
        }
        let manifestURL = root.appendingPathComponent(BuildingProjectPaths.manifestName)
        guard BuildingProjectFileSystem.kind(of: manifestURL) == .regular else {
            throw BuildingProjectError.manifestCorrupted("Manifest.json is missing, a symlink or not a regular file")
        }
        let manifestData = try BuildingProjectFileSystem.readBounded(
            manifestURL,
            maxBytes: configuration.limits.maxManifestBytes
        )
        let manifest: BuildingProjectManifest
        do {
            manifest = try BuildingProjectJSON.decode(BuildingProjectManifest.self, from: manifestData)
        } catch {
            throw BuildingProjectError.manifestCorrupted(String(describing: error))
        }
        try manifest.validate(limits: configuration.limits)

        let generationsRoot = root.appendingPathComponent(BuildingProjectPaths.generationsDirectoryName, isDirectory: true)
        guard BuildingProjectFileSystem.kind(of: generationsRoot) == .directory else {
            throw BuildingProjectError.manifestCorrupted("Generations is missing, a symlink or not a directory")
        }
        let generationNames = try BuildingProjectFileSystem.listDirectoryNames(generationsRoot)
        if allowRuntimeDirectories {
            for name in generationNames {
                guard BuildingStoredIdentity.isSHA256Hex(name),
                      BuildingProjectFileSystem.kind(
                        of: generationsRoot.appendingPathComponent(name, isDirectory: true)
                      ) == .directory else {
                    throw BuildingProjectError.generationCorrupted(
                        generationID: name,
                        reason: "Generations contains a symlink or an unexpected entry"
                    )
                }
            }
            guard generationNames.contains(manifest.generationID) else {
                throw BuildingProjectError.generationNotFound(manifest.generationID)
            }
        } else {
            guard generationNames == [manifest.generationID] else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: manifest.generationID,
                    reason: "a portable copy contains exactly the manifest generation"
                )
            }
        }

        let generationDirectory = BuildingProjectPaths.generationDirectoryURL(
            root: root,
            generationID: manifest.generationID
        )
        guard BuildingProjectFileSystem.kind(of: generationDirectory) == .directory else {
            throw BuildingProjectError.generationNotFound(manifest.generationID)
        }
        try BuildingProjectFileSystem.requireNoSymlinkComponents(root: root, url: generationDirectory)
        let generationJSON = generationDirectory.appendingPathComponent(BuildingProjectPaths.generationFileName)
        guard BuildingProjectFileSystem.kind(of: generationJSON) == .regular else {
            throw BuildingProjectError.generationCorrupted(
                generationID: manifest.generationID,
                reason: "Generation.json is missing, a symlink or not a regular file"
            )
        }
        let generationData = try BuildingProjectFileSystem.readBounded(
            generationJSON,
            maxBytes: configuration.limits.maxManifestBytes
        )
        let record: BuildingGenerationRecord
        do {
            record = try BuildingProjectJSON.decode(BuildingGenerationRecord.self, from: generationData)
        } catch {
            throw BuildingProjectError.generationCorrupted(
                generationID: manifest.generationID,
                reason: "Generation.json is unreadable"
            )
        }
        try record.validate(limits: configuration.limits)
        guard record.generationID == manifest.generationID,
              record.projectID == manifest.projectID,
              record.identity == manifest.identity,
              record.recordsTreeDigest == manifest.recordsTreeDigest,
              record.cadTreeDigest == manifest.cadTreeDigest,
              record.editorStateSHA256 == manifest.editorStateSHA256,
              record.editorStateByteCount == manifest.editorStateByteCount,
              record.assetResourcesTreeDigest == manifest.assetResourcesTreeDigest else {
            throw BuildingProjectError.manifestCorrupted(
                "Manifest.json does not match the copied generation"
            )
        }
        let expectedNames: Set<String> = [
            BuildingProjectPaths.generationFileName,
            BuildingProjectPaths.recordsDirectoryName,
            BuildingProjectPaths.cadDirectoryName,
            BuildingProjectPaths.editorStateDirectoryName,
            BuildingProjectPaths.assetResourcesDirectoryName
        ]
        guard Set(try BuildingProjectFileSystem.listDirectoryNames(generationDirectory)) == expectedNames else {
            throw BuildingProjectError.generationCorrupted(
                generationID: record.generationID,
                reason: "the copied generation contains unexpected entries"
            )
        }
        let isCancelled: @Sendable () -> Bool = { false }
        for section in BuildingFileSection.allCases {
            let sectionRoot = BuildingProjectPaths.sectionRootURL(
                generationURL: generationDirectory,
                section: section
            )
            try BuildingProjectFileSystem.requireNoSymlinkComponents(root: root, url: sectionRoot)
            let actual = try BuildingProjectFileSystem.hashTree(
                root: sectionRoot,
                section: section,
                limits: configuration.limits,
                isCancelled: isCancelled
            )
            let expected = record.files
                .filter { $0.section == section }
                .sorted { $0.relativePath < $1.relativePath }
            guard actual == expected else {
                throw BuildingProjectError.generationCorrupted(
                    generationID: record.generationID,
                    reason: "the \(section.rawValue) files do not match Generation.json"
                )
            }
        }
        let manifestSHA = BuildingProjectFileSystem.sha256Hex(manifestData)
        let receipt = BuildingProjectPortableCopyReceipt(
            projectID: record.projectID,
            generationID: record.generationID,
            sequence: manifest.sequence,
            fileCount: record.fileCount,
            totalByteCount: record.totalByteCount,
            manifestSHA256: manifestSHA,
            contentDigest: contentDigest(manifestSHA256: manifestSHA, files: record.files),
            createdAt: record.createdAt
        )
        return InspectedPortableCopy(
            root: root,
            manifestData: manifestData,
            manifest: manifest,
            generationJSONData: generationData,
            record: record,
            receipt: receipt
        )
    }

    private static func contentDigest(manifestSHA256: String, files: [BuildingFileRecord]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(manifestSHA256.utf8))
        for file in files.sorted(by: {
            "\($0.section.rawValue)\u{0}\($0.relativePath)" < "\($1.section.rawValue)\u{0}\($1.relativePath)"
        }) {
            hasher.update(data: Data("\u{0}\(file.section.rawValue)\u{0}\(file.relativePath)\u{0}\(file.byteCount)\u{0}\(file.sha256)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension BuildingProjectRepository {
    func readManifestDataUnderLock() throws -> Data? {
        switch BuildingProjectFileSystem.kind(of: manifestURL) {
        case .missing:
            return nil
        case .regular:
            return try BuildingProjectFileSystem.readBounded(
                manifestURL,
                maxBytes: limits.maxManifestBytes
            )
        case .symbolicLink:
            throw BuildingProjectError.manifestCorrupted("Manifest.json is a symbolic link")
        case .directory, .other:
            throw BuildingProjectError.manifestCorrupted("Manifest.json is not a regular file")
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeBuildingEditor
import FloeBuildingProject
import FloeBuildingRecords

/// Owns the contents of one Space building record. The central Space service
/// resolves the record directory and calls these functions; they never accept
/// a model-provided path or grant a permission.
enum BuildingProjectSpaceOriginal {
    static let projectFolderName = "Project.floebuilding"
    static let assetLibraryName = "Asset Library"
    static let copiesFolderName = "Copies"

    static func projectURL(directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent(projectFolderName, isDirectory: true)
    }

    static func assetLibraryURL(directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent(assetLibraryName, isDirectory: true)
    }

    /// Create a new independent project inside a freshly reserved Space record
    /// directory. The internal Records identity is aligned to the Space record,
    /// so its editor and assistant never share an identity with a copy.
    static func create(spaceRecordID: UUID, title: String, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = projectURL(directory: directory)
        guard !FileManager.default.fileExists(atPath: project.path) else {
            throw BuildingProjectCopyError.destinationExists(project.lastPathComponent)
        }
        do {
            let session = try await BuildingEditorProjectSession.create(
                at: project,
                name: title,
                assetLibraryDirectory: assetLibraryURL(directory: directory),
                projectID: ProjectID(spaceRecordID),
                spaceRecordID: spaceRecordID
            )
            try await session.close(discardWorkingCopy: true)
        } catch {
            // A failed first publication may leave a recoverable working tree.
            // Keep it if a manifest exists; remove only the empty new root.
            let manifest = project.appendingPathComponent("Manifest.json")
            if !FileManager.default.fileExists(atPath: manifest.path) {
                try? FileManager.default.removeItem(at: project)
            }
            throw error
        }
    }

    /// Verify the actual published package. This is read-only with respect to
    /// the project: it does not acquire a lock or create a working directory.
    @discardableResult
    static func verify(spaceRecordID: UUID, title: String, directory: URL) throws
        -> BuildingProjectPortableCopyReceipt {
        let project = projectURL(directory: directory)
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw PersonalContentError.missingDocument
        }
        let receipt = try BuildingProjectRepository.verifyProjectDirectory(at: project)
        let database = project
            .appendingPathComponent("Generations", isDirectory: true)
            .appendingPathComponent(receipt.generationID, isDirectory: true)
            .appendingPathComponent("Records/Building/Records.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw PersonalContentError.invalidProject
        }
        return receipt
    }

    /// Import a portable package into a new record directory. `spaceRecordID`
    /// must be the newly reserved record ID; the source package is only read.
    /// The source's internal Records identity stays as provenance.
    @discardableResult
    static func importPortable(spaceRecordID: UUID, title: String,
                               from source: URL, directory: URL) throws
        -> BuildingProjectPortableCopyReceipt {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = projectURL(directory: directory)
        guard !FileManager.default.fileExists(atPath: project.path) else {
            throw BuildingProjectCopyError.destinationExists(project.lastPathComponent)
        }
        _ = try BuildingProjectRepository.copyPortableCopy(from: source, to: project)
        // Read-only local verification only. The caller performs the async
        // editor mount/open after the file-coordinated accessor returns.
        return try BuildingProjectRepository.verifyPortableCopy(at: project)
    }

    /// Save-as a portable package into `<record>/Copies`, using the same live
    /// session as the editor. The returned receipt's `id` is the new copy
    /// identity the Space service should reserve.
    @discardableResult
    static func exportCopy(spaceRecordID: UUID, title: String, directory: URL) async throws
        -> BuildingProjectCopyReceipt {
        let project = projectURL(directory: directory)
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw PersonalContentError.missingDocument
        }
        let session = try await BuildingEditorProjectSession.open(
            at: project,
            assetLibraryDirectory: assetLibraryURL(directory: directory),
            spaceRecordID: spaceRecordID
        )
        do {
            let receipt = try await session.saveBuildingCopy(title: title)
            try await session.close(discardWorkingCopy: true)
            return receipt
        } catch {
            try? await session.close(discardWorkingCopy: false)
            throw error
        }
    }

    /// A verified published transaction copy for a temporary/share package.
    /// The caller supplies a dedicated destination; this never creates a
    /// persistent copy and never touches the project's working directory.
    static func exportPublishedPortable(directory: URL, to destination: URL) throws
        -> BuildingProjectPortableCopyReceipt {
        let project = projectURL(directory: directory)
        let repository = try BuildingProjectRepository.open(at: project)
        return try repository.exportPortableCopy(to: destination)
    }
}
#endif

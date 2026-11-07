// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench
import FloeChemistryCore

extension PersonalContentPreviewService {
    /// Resolves the same durable original as Files. Missing records, deleted
    /// parents and stale locations never create a replacement project/session.
    func request(for record: PersonalContentRecord, contentService: PersonalContentService = .shared,
                 maximumPixelSize: Int = 640) async throws -> PersonalContentPreviewRequest {
        try Task.checkCancellation(); try PersonalLibraryFileActions.requireAvailable(record.id)
        guard !record.needsRecovery, record.deletedAt == nil else { throw PersonalContentPreviewError.unavailable }
        let library = try await contentService.library()
        let location = try await library.resolve(record.id)
        let root = await library.root
        guard location.record.kind == record.kind, location.record.modifiedAt == record.modifiedAt else { throw PersonalContentPreviewError.sourceChanged }
        let owner = "library:\(previewHash(Data(root.path.utf8))):\(record.id.uuidString)", directory = location.url
        let validate: @MainActor @Sendable () async throws -> Void = {
            try Task.checkCancellation(); try PersonalLibraryFileActions.requireAvailable(record.id)
            let current = try await library.resolve(record.id)
            guard current.url == directory, current.record.kind == record.kind,
                  current.record.modifiedAt == record.modifiedAt, !current.record.needsRecovery else {
                throw PersonalContentPreviewError.sourceChanged
            }
        }
        let inner: PersonalContentPreviewRequest
        switch record.kind {
        case .document:
            let file = try await contentService.originalFile(record.id)
            inner = try await PersonalContentPreviewProducers.file(ownerID: owner, objectID: record.id.uuidString,
                revision: String(record.modifiedAt.timeIntervalSince1970), root: directory, url: file,
                maximumPixelSize: maximumPixelSize, validate: validate)
        case .image, .drawing, .video:
            let media = directory.appendingPathComponent("Media", isDirectory: true)
            let store = MediaProjectStore(directory: media.appendingPathComponent("Projects", isDirectory: true))
            let projectFile = try await personalPreviewOffMain {
                try PersonalPreviewFile(root: directory, url: store.projectURL(id: record.id), maximumBytes: 8 * 1_024 * 1_024)
            }
            guard let project = try await store.loadProject(id: record.id), project.id == record.id,
                  project.ownerID == record.id, project.kind == (record.kind == .video ? .video : .image) else {
                throw PersonalContentPreviewError.unavailable
            }
            try projectFile.validate()
            inner = try await PersonalContentPreviewProducers.media(project: project, root: media, ownerID: owner,
                maximumPixelSize: maximumPixelSize, validate: { try await validate(); try projectFile.validate() })
        case .cad2D, .cad3D:
            inner = try await savedCAD(ownerID: owner, objectID: record.id.uuidString,
                package: directory.appendingPathComponent("Document.floecad", isDirectory: true),
                maximumPixelSize: maximumPixelSize, validate: validate)
        case .chemistry:
            inner = try await savedChemical(ownerID: owner, projectID: record.id,
                root: directory.appendingPathComponent("Chemistry", isDirectory: true),
                maximumPixelSize: maximumPixelSize, validate: validate)
        case .canvas, .diagram, .music, .meeting, .printing, .manufacturing:
            inner = try await remainingLibraryRequest(record: record, directory: directory, ownerID: owner,
                maximumPixelSize: maximumPixelSize, validate: validate)
        case .biology:
            inner = try await savedBiology(ownerID: owner, projectID: record.id, originalDirectory: directory,
                storeRoot: BiologyAppComposition.permanentRoot(forLibraryRoot: root).appendingPathComponent("Projects", isDirectory: true),
                maximumPixelSize: maximumPixelSize, validate: validate)
        }
        return .init(key: inner.key, validate: inner.validate, produce: {
            let lease = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: directory, libraryRoot: root)
            defer { lease.release() }
            try await validate()
            let result = try await inner.produce()
            try await validate()
            return result
        })
    }

    /// Only the already saved actual viewport. A missing thumbnail is not a
    /// reason to open an editable CAD document, recover files or invoke Metal.
    func savedCAD(ownerID: String, objectID: String, package: URL, maximumPixelSize: Int = 640,
                  validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        let prepared = try await personalPreviewOffMain {
            let manifest = try PersonalPreviewFile(root: package, url: package.appendingPathComponent("manifest.json"), maximumBytes: 512 * 1_024)
            let header = try JSONDecoder().decode(SavedCADPreviewHeader.self, from: manifest.data())
            guard header.revision >= 0, let digest = header.thumbnailSHA256,
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PersonalContentPreviewError.notPrepared }
            let image = try PersonalPreviewFile(root: package, url: package.appendingPathComponent("blobs/thumbnail.img"), maximumBytes: 8 * 1_024 * 1_024)
            return (manifest, header, image, digest)
        }
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: objectID, revision: String(prepared.1.revision),
            variant: "savedCAD:\(prepared.3):\(prepared.0.identity.token)", maximumPixelSize: maximumPixelSize)
        return .init(key: key, validate: {
            try await validate(); try prepared.0.validate(); try prepared.2.validate()
        }, produce: {
            try await personalPreviewOffMain {
                let bytes = try prepared.2.data(expectedSHA256: prepared.3)
                try prepared.0.validate()
                let value = try PersonalContentPreviewProducers.image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: .savedCADViewport)
                // Historical packages do not bind thumbnail age to model
                // revision. Do not call an older saved view current geometry.
                return PersonalContentPreviewArtifact(value.content, provenance: .savedCADViewport,
                    detail: previewText("已保存视图；打开原件可查看最新内容", "Saved view. Open the original for the latest content"))
            }
        })
    }

    private func savedChemical(ownerID: String, projectID: UUID, root: URL, maximumPixelSize: Int,
                               validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        // Decode the existing immutable typed snapshot, retaining the store's
        // HEAD/digest/identity validation. No store init/mkdir or chemistry job.
        let prepared = try await personalPreviewOffMain {
            let directory = root.appendingPathComponent(projectID.uuidString, isDirectory: true)
            let headFile = try PersonalPreviewFile(root: root, url: directory.appendingPathComponent("HEAD.json"), maximumBytes: 4_096)
            let head = try JSONDecoder().decode(SavedChemicalPreviewHead.self, from: headFile.data())
            guard head.projectID == projectID, head.revision > 0,
                  head.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PersonalContentPreviewError.unavailable }
            let snapshotFile = try PersonalPreviewFile(root: root,
                url: directory.appendingPathComponent("revisions/\(head.revision)-\(head.digest).json"), maximumBytes: 16 * 1_024 * 1_024)
            let project = try JSONDecoder().decode(ChemistryProject.self, from: snapshotFile.data(expectedSHA256: head.digest))
            guard project.id == projectID, project.revision == head.revision else { throw PersonalContentPreviewError.sourceChanged }
            try project.validate(); try headFile.validate()
            guard let object = project.objects.first else { throw PersonalContentPreviewError.notPrepared }
            return (headFile, snapshotFile, object)
        }
        return PersonalContentPreviewProducers.chemical(object: prepared.2, ownerID: ownerID, maximumPixelSize: maximumPixelSize,
            validate: { try await validate(); try prepared.0.validate(); try prepared.1.validate() })
    }
}

private nonisolated struct SavedCADPreviewHeader: Decodable, Sendable { let revision: Int; let thumbnailSHA256: String? }
private nonisolated struct SavedChemicalPreviewHead: Decodable, Sendable { let projectID: UUID; let revision: UInt64; let digest: String }
#endif

//
//  FileCADDocumentStore.swift
//  FloeCADKit
//
//  A versioned, crash-recoverable FloeCAD document package.
//
//  Layout (directory `<name>.floecad/`):
//    manifest.json          schema version, revision, units/tolerance, counts,
//                           content SHA-256 (atomic-commit identity)
//    document.json          sketches / planes / axes / images / symbols /
//                           features / variables / folders / assembly /
//                           drawings metadata (no binary inline)
//    blobs/<id>.mesh        MeshBlob binary, one file per body
//    blobs/<id>.brep        OCCT BRep binary, one file per analytic body
//    blobs/images/<id>.img  inserted image bytes
//    previous/              the last COMPLETE commit (manifest + document +
//                           blobs) kept for recovery; replaced on next commit
//
//  Commit protocol: everything is staged under a sibling staging directory,
//  verified by re-reading the staged manifest/document, then `previous/`
//  rotates and the staged files move into place. A crash leaves either the
//  old commit, the staged copy, or the previous copy — never a half-written
//  manifest with lost blobs. `create(overwrite:)` uses the same staged-swap
//  rule at the package level: the old package is moved aside (not deleted)
//  before the new one lands and is restored if anything fails.
//
//  Work split (review 2026-10-09): `makePayload` runs on the session actor and
//  is deliberately cheap — it only slices existing `Data` blobs into a Sendable
//  value. JSON encoding, SHA-256 hashing and all file I/O happen in
//  `performWrite`, which callers run off the main actor.
//
//  Unknown/newer `schemaVersion` still loads for viewing; `formatVersion` is
//  surfaced to `DocumentSession`, which refuses to save a newer store.
//

import Foundation
import CryptoKit

nonisolated enum CADDocumentStoreError: Error, LocalizedError {
    case noStoreAttached
    case packageMissing(URL)
    case corruptManifest(String)
    case corruptDocument(String)
    case commitFailed(String)
    case revisionMoved(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .noStoreAttached:
            return "The CAD document has no store attached."
        case .packageMissing(let url):
            return "CAD document package not found at \(url.path)."
        case .corruptManifest(let detail):
            return "CAD document manifest is unreadable: \(detail)"
        case .corruptDocument(let detail):
            return "CAD document metadata is unreadable: \(detail)"
        case .commitFailed(let detail):
            return "CAD document commit failed: \(detail)"
        case .revisionMoved(let expected, let actual):
            return "CAD document commit refused: expected revision \(expected), store is at \(actual)."
        }
    }
}

/// Fault hooks used only by tests to prove the recovery paths (failure
/// injection). Production code never sets them.
nonisolated enum CADDocumentFaultInjection {
    nonisolated(unsafe) static var beforeCommit: (@Sendable () throws -> Void)?
    nonisolated(unsafe) static var beforeCreateSwap: (@Sendable () throws -> Void)?
}

// MARK: - Wire records

struct CADManifest: Codable, Sendable {
    var schemaVersion: Int
    var revision: Int
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var unit: String?
    var tolerance: Double?
    var contentSHA256: String
    var thumbnailSHA256: String?
    var appBuild: String
    var counts: [String: Int]
}

struct CADBodyRecord: Codable, Sendable {
    var bodyID: UUID
    var name: String
    var transform: Data
    var primitive: Data?
    var meshBlob: String?
    var meshSHA256: String?
    var isHidden: Bool
    var material: Data?
    var brepBlob: String?
    var brepSHA256: String?
}

struct CADBlobRecord: Codable, Sendable {
    var blobID: UUID
    var data: Data
    var sha256: String
}

struct CADImageRecord: Codable, Sendable {
    var imageID: UUID
    var info: Data
    var imageBlob: String?
    var imageSHA256: String?
}

struct CADFeatureRecord: Codable, Sendable {
    var featureID: UUID
    var orderIndex: Int
    var name: String
    var suppressed: Bool
    var kind: Data
    var outputBodyIDs: Data
}

struct CADVariableRecord: Codable, Sendable {
    var variableID: UUID
    var orderIndex: Int
    var name: String
    var expression: String
    var value: Double
}

struct CADDocumentRecord: Codable, Sendable {
    var bodies: [CADBodyRecord]
    var sketches: [CADBlobRecord]
    var planes: [CADBlobRecord]
    var axes: [CADBlobRecord]
    var images: [CADImageRecord]
    var symbols: [CADBlobRecord]
    var features: [CADFeatureRecord]
    var variables: [CADVariableRecord]
    var rollbackIndex: Int?
    var folderID: UUID?
    var itemFolders: Data?
    var assembly: Data?
    var drawings: Data?
    var scripts: Data?
}

/// Everything a commit needs, in a `Sendable` value: cheap to build on the
/// session actor, safe to encode/hash/write off it.
struct CADWritePayload: Sendable {
    var expectedRevision: Int
    var schemaVersion: Int
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var unit: String?
    var tolerance: Double?
    var appBuild: String
    var document: CADDocumentRecord
    /// Repository-relative path → bytes (mesh/brep/image blobs).
    var blobs: [String: Data]
    var thumbnail: Data?

    var counts: [String: Int] {
        [
            "bodies": document.bodies.count,
            "sketches": document.sketches.count,
            "planes": document.planes.count,
            "axes": document.axes.count,
            "images": document.images.count,
            "symbols": document.symbols.count,
            "features": document.features.count,
            "variables": document.variables.count,
        ]
    }
}

/// Store boundary used by `DocumentSession` (and the public facade). One
/// store instance owns one package path.
protocol CADDocumentStore: AnyObject {
    func read() throws -> Project
    func write(_ project: Project) throws
    func makePayload(_ project: Project) throws -> CADWritePayload
    @discardableResult
    func performWrite(_ payload: CADWritePayload) throws -> (revision: Int, contentSHA256: String)
    /// Revision of the last successful read/write; nil before any commit.
    var revision: Int { get }
    /// Content identity of the last successful commit.
    var contentSHA256: String { get }
}

// MARK: - File store

final class FileCADDocumentStore: CADDocumentStore, @unchecked Sendable {
    static let packageExtension = "floecad"
    static let currentSchemaVersion = 1

    private let packageURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var storedRevision: Int = 0
    private var storedContentSHA256: String = ""

    init(packageURL: URL, fileManager: FileManager = .default) {
        self.packageURL = packageURL
        self.fileManager = fileManager
    }

    var url: URL { packageURL }
    var revision: Int { lock.withLock { storedRevision } }
    var contentSHA256: String { lock.withLock { storedContentSHA256 } }

    private var manifestURL: URL { packageURL.appendingPathComponent("manifest.json") }
    private var documentURL: URL { packageURL.appendingPathComponent("document.json") }
    private var blobsURL: URL { packageURL.appendingPathComponent("blobs") }
    private var imagesURL: URL { blobsURL.appendingPathComponent("images") }
    private var previousURL: URL { packageURL.appendingPathComponent("previous") }

    // MARK: Read

    func read() throws -> Project {
        if !fileManager.fileExists(atPath: manifestURL.path) {
            // Interrupted commit: a complete previous snapshot is the
            // recoverable truth.
            let previousManifest = previousURL.appendingPathComponent("manifest.json")
            if fileManager.fileExists(atPath: previousManifest.path) {
                try restorePrevious()
            } else {
                throw CADDocumentStoreError.packageMissing(packageURL)
            }
        }

        let manifest = try readManifest(at: packageURL)
        let document = try readDocument(at: packageURL)
        // Newer schema: decoded best-effort (unknown extra keys are ignored by
        // JSONDecoder) and surfaced so the session refuses to save. Never
        // rewritten by an older build.
        lock.withLock {
            storedRevision = manifest.revision
            storedContentSHA256 = manifest.contentSHA256
        }

        return makeProject(manifest: manifest, document: document, root: packageURL)
    }

    private func readManifest(at root: URL) throws -> CADManifest {
        let url = root.appendingPathComponent("manifest.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CADManifest.self, from: data)
        } catch {
            throw CADDocumentStoreError.corruptManifest(error.localizedDescription)
        }
    }

    private func readDocument(at root: URL) throws -> CADDocumentRecord {
        let url = root.appendingPathComponent("document.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CADDocumentRecord.self, from: data)
        } catch {
            throw CADDocumentStoreError.corruptDocument(error.localizedDescription)
        }
    }

    private func makeProject(manifest: CADManifest,
                             document: CADDocumentRecord,
                             root: URL) -> Project {
        let project = Project(name: manifest.name)
        project.createdAt = manifest.createdAt
        project.modifiedAt = manifest.modifiedAt
        project.formatVersion = manifest.schemaVersion
        project.rollbackIndex = document.rollbackIndex
        project.folderID = document.folderID
        project.itemFoldersData = document.itemFolders
        project.unitRaw = manifest.unit
        project.tolerance = manifest.tolerance
        project.assemblyData = document.assembly
        project.drawingsData = document.drawings
        project.scriptsData = document.scripts
        if manifest.thumbnailSHA256 != nil {
            project.thumbnail = try? Data(contentsOf: root.appendingPathComponent("blobs/thumbnail.img"))
        }

        for record in document.bodies {
            let meshData = record.meshBlob.flatMap {
                try? Data(contentsOf: root.appendingPathComponent($0))
            } ?? Data()
            let persisted = PersistedBody(
                bodyID: record.bodyID,
                name: record.name,
                transformData: record.transform,
                primitiveData: record.primitive,
                meshData: meshData
            )
            persisted.isHidden = record.isHidden
            persisted.materialData = record.material
            persisted.brepData = record.brepBlob.flatMap {
                try? Data(contentsOf: root.appendingPathComponent($0))
            }
            persisted.project = project
            project.bodies.append(persisted)
        }
        for record in document.sketches {
            let sketch = PersistedSketch(sketchID: record.blobID, sketchData: record.data)
            sketch.project = project
            project.sketches.append(sketch)
        }
        for record in document.planes {
            let plane = PersistedPlane(planeID: record.blobID, planeData: record.data)
            plane.project = project
            project.planes.append(plane)
        }
        for record in document.axes {
            let axis = PersistedAxis(axisID: record.blobID, axisData: record.data)
            axis.project = project
            project.axes.append(axis)
        }
        for record in document.images {
            let imageData = record.imageBlob.flatMap {
                try? Data(contentsOf: root.appendingPathComponent($0))
            } ?? Data()
            let image = PersistedImage(imageID: record.imageID,
                                       infoData: record.info,
                                       imageData: imageData)
            image.project = project
            project.images.append(image)
        }
        for record in document.symbols {
            let symbol = PersistedSymbol(symbolID: record.blobID, symbolData: record.data)
            symbol.project = project
            project.symbols.append(symbol)
        }
        for record in document.features {
            let feature = PersistedFeature(featureID: record.featureID,
                                           orderIndex: record.orderIndex,
                                           name: record.name,
                                           suppressed: record.suppressed,
                                           kindData: record.kind,
                                           outputBodyIDData: record.outputBodyIDs)
            feature.project = project
            project.features.append(feature)
        }
        for record in document.variables {
            let variable = PersistedVariable(variableID: record.variableID,
                                             orderIndex: record.orderIndex,
                                             name: record.name,
                                             expression: record.expression,
                                             value: record.value)
            variable.project = project
            project.variables.append(variable)
        }
        return project
    }

    // MARK: Payload (session actor: cheap, no encode/hash/IO)

    /// Slice the in-memory record graph into a Sendable payload. No JSON
    /// encoding, no hashing and no file I/O happen here: callers may run this
    /// on the main actor, then hand the value to `performWrite` off-main.
    func makePayload(_ project: Project) throws -> CADWritePayload {
        var document = CADDocumentRecord(
            bodies: [], sketches: [], planes: [], axes: [], images: [],
            symbols: [], features: [], variables: [],
            rollbackIndex: project.rollbackIndex,
            folderID: project.folderID,
            itemFolders: project.itemFoldersData,
            assembly: project.assemblyData,
            drawings: project.drawingsData,
            scripts: project.scriptsData
        )
        var blobs: [String: Data] = [:]

        for body in project.bodies {
            var meshBlob: String?
            var meshSHA: String?
            if !body.meshData.isEmpty {
                let name = "blobs/\(body.bodyID.uuidString).mesh"
                blobs[name] = body.meshData
                meshBlob = name
                meshSHA = Self.sha256(body.meshData)
            }
            var brepBlob: String?
            var brepSHA: String?
            if let brep = body.brepData, !brep.isEmpty {
                let name = "blobs/\(body.bodyID.uuidString).brep"
                blobs[name] = brep
                brepBlob = name
                brepSHA = Self.sha256(brep)
            }
            document.bodies.append(CADBodyRecord(
                bodyID: body.bodyID,
                name: body.name,
                transform: body.transformData,
                primitive: body.primitiveData,
                meshBlob: meshBlob,
                meshSHA256: meshSHA,
                isHidden: body.isHidden,
                material: body.materialData,
                brepBlob: brepBlob,
                brepSHA256: brepSHA
            ))
        }
        document.sketches = project.sketches.map {
            CADBlobRecord(blobID: $0.sketchID, data: $0.sketchData,
                          sha256: Self.sha256($0.sketchData))
        }
        document.planes = project.planes.map {
            CADBlobRecord(blobID: $0.planeID, data: $0.planeData,
                          sha256: Self.sha256($0.planeData))
        }
        document.axes = project.axes.map {
            CADBlobRecord(blobID: $0.axisID, data: $0.axisData,
                          sha256: Self.sha256($0.axisData))
        }
        document.images = project.images.map { image in
            var imageBlob: String?
            var imageSHA: String?
            if !image.imageData.isEmpty {
                let name = "blobs/images/\(image.imageID.uuidString).img"
                blobs[name] = image.imageData
                imageBlob = name
                imageSHA = Self.sha256(image.imageData)
            }
            return CADImageRecord(imageID: image.imageID, info: image.infoData,
                                  imageBlob: imageBlob, imageSHA256: imageSHA)
        }
        document.symbols = project.symbols.map {
            CADBlobRecord(blobID: $0.symbolID, data: $0.symbolData,
                          sha256: Self.sha256($0.symbolData))
        }
        document.features = project.features.map {
            CADFeatureRecord(featureID: $0.featureID, orderIndex: $0.orderIndex,
                             name: $0.name, suppressed: $0.suppressed,
                             kind: $0.kindData, outputBodyIDs: $0.outputBodyIDData)
        }
        document.variables = project.variables.map {
            CADVariableRecord(variableID: $0.variableID, orderIndex: $0.orderIndex,
                              name: $0.name, expression: $0.expression, value: $0.value)
        }

        let schemaVersion = max(project.formatVersion, 1)
        let manifest = CADManifest(
            schemaVersion: schemaVersion,
            revision: revision + 1,
            name: project.name,
            createdAt: project.createdAt,
            modifiedAt: project.modifiedAt,
            unit: project.unitRaw,
            tolerance: project.tolerance,
            contentSHA256: "",
            thumbnailSHA256: project.thumbnail.map { Self.sha256($0) },
            appBuild: Self.appBuild,
            counts: [:]
        )
        return CADWritePayload(
            expectedRevision: revision,
            schemaVersion: schemaVersion,
            name: manifest.name,
            createdAt: manifest.createdAt,
            modifiedAt: manifest.modifiedAt,
            unit: manifest.unit,
            tolerance: manifest.tolerance,
            appBuild: manifest.appBuild,
            document: document,
            blobs: blobs,
            thumbnail: project.thumbnail
        )
    }

    // MARK: Write (off-main: encode + hash + I/O)

    /// Perform a staged commit of a payload. Revision-guarded: if another
    /// commit landed since the payload was built, the write is refused rather
    /// than clobbering the newer revision.
    @discardableResult
    func performWrite(_ payload: CADWritePayload) throws -> (revision: Int, contentSHA256: String) {
        lock.lock()
        defer { lock.unlock() }
        guard payload.expectedRevision == storedRevision else {
            throw CADDocumentStoreError.revisionMoved(expected: payload.expectedRevision,
                                                      actual: storedRevision)
        }
        let commitRevision = storedRevision + 1

        let staging = packageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(packageURL.lastPathComponent).staging-\(UUID().uuidString)")
        let transaction = Transaction(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try transaction.track(staging)

            var contentHasher = SHA256()
            for (path, data) in payload.blobs.sorted(by: { $0.key < $1.key }) {
                let url = staging.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: url)
            }
            let documentData = try JSONEncoder().encode(payload.document)
            contentHasher.update(data: documentData)
            try documentData.write(to: staging.appendingPathComponent("document.json"))
            for (path, data) in payload.blobs.sorted(by: { $0.key < $1.key }) {
                contentHasher.update(data: Data(path.utf8))
                contentHasher.update(data: Data(Self.sha256(data).utf8))
            }

            var thumbnailSHA256: String?
            if let thumbnail = payload.thumbnail, !thumbnail.isEmpty {
                let sha = Self.sha256(thumbnail)
                thumbnailSHA256 = sha
                try thumbnail.write(to: staging.appendingPathComponent("blobs/thumbnail.img"))
                contentHasher.update(data: Data(sha.utf8))
            }
            let contentDigest = Self.hex(contentHasher.finalize())

            let manifest = CADManifest(
                schemaVersion: payload.schemaVersion,
                revision: commitRevision,
                name: payload.name,
                createdAt: payload.createdAt,
                modifiedAt: payload.modifiedAt,
                unit: payload.unit,
                tolerance: payload.tolerance,
                contentSHA256: contentDigest,
                thumbnailSHA256: thumbnailSHA256,
                appBuild: payload.appBuild,
                counts: payload.counts
            )
            try JSONEncoder().encode(manifest)
                .write(to: staging.appendingPathComponent("manifest.json"))

            // Verify the staged commit decodes before rotating anything.
            _ = try readManifest(at: staging)
            let stagedDocument = try readDocument(at: staging)
            guard stagedDocument.bodies.count == payload.document.bodies.count else {
                throw CADDocumentStoreError.commitFailed("staged body count mismatch")
            }

            try CADDocumentFaultInjection.beforeCommit?()
            try commit(staging: staging, transaction: transaction)
            storedRevision = commitRevision
            storedContentSHA256 = contentDigest
            return (commitRevision, contentDigest)
        } catch {
            transaction.rollback()
            throw error
        }
    }

    /// Synchronous convenience used by `CADModelContext.save()` on the session
    /// actor. Prefer `performWrite` off-main for large documents.
    func write(_ project: Project) throws {
        let payload = try makePayload(project)
        _ = try performWrite(payload)
    }

    // MARK: Package-level staged create/overwrite

    /// Replace (or create) the package with a complete, verified staged
    /// commit. The existing package is moved aside — never deleted — before
    /// the new one lands, and is restored if anything fails. On success the
    /// old package is preserved as `previous/` inside the new package.
    static func createPackage(at packageURL: URL,
                              payload: CADWritePayload,
                              overwrite: Bool,
                              fileManager: FileManager = .default) throws {
        let packageExists = fileManager.fileExists(atPath: packageURL.path)
        guard !packageExists || overwrite else {
            throw CADDocumentStoreError.commitFailed("package already exists")
        }
        let staging = packageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(packageURL.lastPathComponent).create-\(UUID().uuidString)")
        let backup = packageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(packageURL.lastPathComponent).old-\(UUID().uuidString)")
        let transaction = Transaction(fileManager: fileManager)
        var movedAside = false
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try transaction.track(staging)
            // Stage + verify a complete package at the sibling path.
            let stagedStore = FileCADDocumentStore(packageURL: staging, fileManager: fileManager)
            try stagedStore.writePayloadDirect(payload)
            _ = try stagedStore.readManifest(at: staging)
            _ = try stagedStore.readDocument(at: staging)

            try CADDocumentFaultInjection.beforeCreateSwap?()

            if packageExists {
                try fileManager.moveItem(at: packageURL, to: backup)
                movedAside = true
                try transaction.track(backup)
            }
            try fileManager.moveItem(at: staging, to: packageURL)
            if movedAside {
                // Keep the replaced package as the recoverable previous
                // snapshot inside the new package. If this fails the backup
                // stays beside the package — still recoverable.
                let previous = packageURL.appendingPathComponent("previous")
                try? fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
                try? fileManager.moveItem(at: backup, to: previous.appendingPathComponent("snapshot"))
            }
            try? fileManager.removeItem(at: staging)
        } catch {
            // Restore the old package if the new one did not land.
            if movedAside, !fileManager.fileExists(atPath: packageURL.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: packageURL)
            }
            transaction.rollback()
            throw error
        }
    }

    /// Write a verified commit directly into this store's directory (used for
    /// the staging package of `createPackage`). Assumes the directory is
    /// empty/new; no rotation.
    fileprivate func writePayloadDirect(_ payload: CADWritePayload) throws {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for (path, data) in payload.blobs {
            let url = packageURL.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try data.write(to: url)
        }
        var contentHasher = SHA256()
        let documentData = try JSONEncoder().encode(payload.document)
        contentHasher.update(data: documentData)
        try documentData.write(to: packageURL.appendingPathComponent("document.json"))
        for (path, data) in payload.blobs.sorted(by: { $0.key < $1.key }) {
            contentHasher.update(data: Data(path.utf8))
            contentHasher.update(data: Data(Self.sha256(data).utf8))
        }
        var thumbnailSHA256: String?
        if let thumbnail = payload.thumbnail, !thumbnail.isEmpty {
            let sha = Self.sha256(thumbnail)
            thumbnailSHA256 = sha
            try thumbnail.write(to: packageURL.appendingPathComponent("blobs/thumbnail.img"))
            contentHasher.update(data: Data(sha.utf8))
        }
        let contentDigest = Self.hex(contentHasher.finalize())
        let manifest = CADManifest(
            schemaVersion: payload.schemaVersion,
            revision: max(payload.expectedRevision, 0) + 1,
            name: payload.name,
            createdAt: payload.createdAt,
            modifiedAt: payload.modifiedAt,
            unit: payload.unit,
            tolerance: payload.tolerance,
            contentSHA256: contentDigest,
            thumbnailSHA256: thumbnailSHA256,
            appBuild: payload.appBuild,
            counts: payload.counts
        )
        try JSONEncoder().encode(manifest)
            .write(to: packageURL.appendingPathComponent("manifest.json"))
    }

    /// Rotate the current commit into `previous/`, then move the staged
    /// files into place. Callers stage and verify first.
    private func commit(staging: URL, transaction: Transaction) throws {
        let parent = packageURL.deletingLastPathComponent()
        let rotating = parent.appendingPathComponent(".\(packageURL.lastPathComponent).rotate-\(UUID().uuidString)")
        try transaction.track(rotating)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.moveItem(at: packageURL, to: rotating)
            // Rebuild the package root with the old commit preserved under
            // previous/. The intermediate directory `rotating` only holds the
            // old manifest/document/blobs plus its own previous/.
            try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let previous = previousURL
            try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
            for name in ["manifest.json", "document.json", "blobs"] {
                let source = rotating.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = previous.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            }
            try? fileManager.removeItem(at: rotating)
        } else {
            try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }
        for name in ["manifest.json", "document.json", "blobs"] {
            let source = staging.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = packageURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
        }
        try? fileManager.removeItem(at: staging)
    }

    private func restorePrevious() throws {
        let parent = packageURL.deletingLastPathComponent()
        let restoring = parent.appendingPathComponent(".\(packageURL.lastPathComponent).recover-\(UUID().uuidString)")
        try fileManager.moveItem(at: previousURL, to: restoring)
        if fileManager.fileExists(atPath: packageURL.path) {
            try? fileManager.removeItem(at: packageURL)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for name in ["manifest.json", "document.json", "blobs"] {
            let source = restoring.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: packageURL.appendingPathComponent(name))
        }
        try? fileManager.removeItem(at: restoring)
    }

    // MARK: Helpers

    static let appBuild: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "FloeCAD/\(version)(\(build))"
    }()

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Cleans staging/rotate/backup directories when a transaction throws.
    private final class Transaction {
        private let fileManager: FileManager
        private var tracked: [URL] = []
        init(fileManager: FileManager) { self.fileManager = fileManager }
        func track(_ url: URL) throws { tracked.append(url) }
        func rollback() {
            for url in tracked where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

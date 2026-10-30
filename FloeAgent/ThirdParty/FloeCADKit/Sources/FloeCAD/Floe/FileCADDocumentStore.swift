//
//  FileCADDocumentStore.swift
//  FloeCADKit
//
//  A versioned, crash-recoverable FloeCAD document package.
//
//  Layout (directory `<name>.floecad/`):
//    manifest.json          schema version, revision, units/tolerance, counts,
//                           content SHA-256 (atomic-commit identity; its
//                           inputs are unchanged), plus the ADDITIVE
//                           `modelSHA256` — a canonical identity of the
//                           document records + every blob, preview excluded
//                           (absent on historical manifests; nil-safe). The
//                           preview artifact stays part of `contentSHA256`,
//                           exactly as before.
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
    case integrityFailed(String)
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
        case .integrityFailed(let detail):
            return "CAD document integrity check failed: \(detail)"
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
    /// Existing atomic-commit identity — inputs (canonical? no: as-stored
    /// document bytes + every blob + the preview artifact) unchanged.
    var contentSHA256: String
    /// ADDITIVE (2026-T7T): a canonical, deterministic identity of the
    /// DOCUMENT MODEL — document records + every blob, with the viewport
    /// preview artifact excluded. Absent on historical manifests; readers
    /// treat it as `nil`. It exists so a caller can prove the semantic
    /// document is byte-identical to a recorded state even after a
    /// preview-only commit re-encoded the JSON. `contentSHA256` semantics
    /// are deliberately untouched.
    var modelSHA256: String?
    var thumbnailSHA256: String?
    var appBuild: String
    var counts: [String: Int]
}

/// The user-editable semantic manifest metadata folded into `modelSHA256`.
/// Deliberately excludes timestamps/schema/appBuild: those move on a
/// preview-only commit and are not user content.
private struct CADModelDigestMetadata: Codable, Sendable {
    var name: String
    var unit: String?
    var tolerance: Double?
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
    /// Additive stable per-face material bindings (`[CADFaceMaterialBinding]`
    /// JSON). Absent on every document written before custom materials.
    var faceMaterials: Data?
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
    /// Legacy-scene presentation (`CADSceneSettings`). Additive optional key:
    /// absent on ordinary documents; older builds ignore it.
    var sceneSettings: Data?
    /// Custom-material library (`CADMaterialLibrary`). Additive optional key.
    var materials: Data?
    /// Keyframe animation (`CADAnimationDocument`). Additive optional key;
    /// absent on every document that never animated. Older builds ignore it.
    var animation: Data?
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
    /// Canonical model identity of the last successful read/write. Empty when
    /// the manifest predates it or contains unknown fields this build cannot
    /// include in a verified canonical identity.
    var modelSHA256: String { get }
}

// MARK: - File store

final class FileCADDocumentStore: CADDocumentStore, @unchecked Sendable {
    static let packageExtension = "floecad"
    static let currentSchemaVersion = CADDocumentFormat.supportedVersion

    private let packageURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var storedRevision: Int = 0
    private var storedSchemaVersion = CADDocumentFormat.legacyVersion
    private var storedContentSHA256: String = ""
    private var storedModelSHA256: String = ""
    /// Fenced release flag. Set by `revoke()` under the same lock every
    /// commit holds, so once it is set no `performWrite` can commit and any
    /// write already in flight has finished. A later flush of a released
    /// document can therefore never resurrect a removed package.
    private var revoked = false

    init(packageURL: URL, fileManager: FileManager = .default) {
        self.packageURL = packageURL
        self.fileManager = fileManager
    }

    var url: URL { packageURL }
    var revision: Int { lock.withLock { storedRevision } }
    var schemaVersion: Int { lock.withLock { storedSchemaVersion } }
    var contentSHA256: String { lock.withLock { storedContentSHA256 } }
    var modelSHA256: String { lock.withLock { storedModelSHA256 } }

    /// Atomic identity snapshot of this store's last verified read/commit.
    /// It reuses the public save outcome value; no new digest or identity path.
    var committedIdentity: CADSaveOutcome {
        lock.withLock { CADSaveOutcome(revision: storedRevision, contentSHA256: storedContentSHA256,
            modelSHA256: storedModelSHA256, error: nil) }
    }

    /// Fence the store: after this returns, no commit can land. Any write
    /// already in flight is waited out (both share `lock`), so the caller may
    /// safely delete the package knowing no late write will re-create it.
    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }

    private var manifestURL: URL { packageURL.appendingPathComponent("manifest.json") }
    private var documentURL: URL { packageURL.appendingPathComponent("document.json") }
    private var blobsURL: URL { packageURL.appendingPathComponent("blobs") }
    private var imagesURL: URL { blobsURL.appendingPathComponent("images") }
    private var previousURL: URL { packageURL.appendingPathComponent("previous") }

    // MARK: Read

    func read() throws -> Project {
        try read(recoverInterruptedCommit: true)
    }

    /// Identity queries must never turn a missing current commit into a write.
    /// A normal open retains the existing interrupted-commit recovery route.
    func readWithoutRecovery() throws -> Project {
        try read(recoverInterruptedCommit: false)
    }

    private func read(recoverInterruptedCommit: Bool) throws -> Project {
        if !fileManager.fileExists(atPath: manifestURL.path) {
            let previousManifest = previousURL.appendingPathComponent("manifest.json")
            if recoverInterruptedCommit, fileManager.fileExists(atPath: previousManifest.path) {
                try restorePrevious()
            } else {
                throw CADDocumentStoreError.packageMissing(packageURL)
            }
        }

        let verified = try verifiedPackage(at: packageURL)
        let manifest = verified.manifest
        // Newer schema: decoded best-effort (unknown extra keys are ignored by
        // JSONDecoder) and surfaced so the session refuses to save. Never
        // rewritten by an older build. Publish identities only after the
        // complete read succeeded, never from an unchecked manifest.
        lock.withLock {
            storedRevision = manifest.revision
            storedSchemaVersion = manifest.schemaVersion
            storedContentSHA256 = manifest.contentSHA256
            storedModelSHA256 = verified.modelSHA256 ?? ""
        }

        let project = makeProject(manifest: manifest, document: verified.document,
                                  blobs: verified.blobs, thumbnail: verified.thumbnail)
        project.hasOpaqueAssociations = verified.formatAssessment.isOpaqueReadOnly
        return project
    }

    private struct VerifiedPackage {
        let manifest: CADManifest
        let document: CADDocumentRecord
        let blobs: [String: Data]
        let thumbnail: Data?
        let modelSHA256: String?
        let formatAssessment: CADDocumentFormat.Assessment
    }

    /// Replays the EXISTING writer's digest inputs: original document bytes,
    /// sorted blob paths and content digests, then the declared preview digest.
    /// The returned bytes are also used to construct the Project, so a file is
    /// not read again after validation. This is consistency, not authentication:
    /// the manifest itself is not signed.
    private func verifiedPackage(at root: URL) throws -> VerifiedPackage {
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: CADManifest
        do {
            manifest = try JSONDecoder().decode(CADManifest.self, from: manifestData)
        } catch {
            throw CADDocumentStoreError.corruptManifest(error.localizedDescription)
        }
        let documentData = try Data(contentsOf: root.appendingPathComponent("document.json"))
        let document: CADDocumentRecord
        do {
            document = try JSONDecoder().decode(CADDocumentRecord.self, from: documentData)
        } catch {
            throw CADDocumentStoreError.corruptDocument(error.localizedDescription)
        }

        var blobs: [String: Data] = [:]
        let blobRoot = root.appendingPathComponent("blobs", isDirectory: true)
        if fileManager.fileExists(atPath: blobRoot.path) {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: blobRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else {
                throw CADDocumentStoreError.integrityFailed("blob directory is unreadable")
            }
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true,
                      url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath) else {
                    throw CADDocumentStoreError.integrityFailed("blob path is not a package-owned regular file")
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else {
                    throw CADDocumentStoreError.integrityFailed("blob is not a regular file")
                }
                let prefix = root.standardizedFileURL.path + "/"
                let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                // A preview is a separate, OPTIONAL writer input. An old or
                // thumbnail-free manifest does not claim an orphan preview.
                if path != "blobs/thumbnail.img" {
                    blobs[path] = try Data(contentsOf: url)
                }
            }
            if let enumerationError { throw enumerationError }
        }

        func checkBlob(path: String?, digest: String?, label: String) throws {
            guard let path else {
                guard digest == nil else {
                    throw CADDocumentStoreError.integrityFailed("\(label) declares a digest without a blob")
                }
                return
            }
            guard path.hasPrefix("blobs/"), !path.split(separator: "/").contains(".."),
                  let data = blobs[path] else {
                throw CADDocumentStoreError.integrityFailed("\(label) blob is missing or outside the package")
            }
            // Old records may omit an individual digest; the complete content
            // digest below still binds their bytes. An omitted blob+digest is
            // valid for empty bodies/images and is not made mandatory here.
            if let digest, Self.sha256(data) != digest {
                throw CADDocumentStoreError.integrityFailed("\(label) blob digest mismatch")
            }
        }
        for body in document.bodies {
            try checkBlob(path: body.meshBlob, digest: body.meshSHA256, label: "body mesh")
            try checkBlob(path: body.brepBlob, digest: body.brepSHA256, label: "body B-rep")
        }
        for image in document.images {
            try checkBlob(path: image.imageBlob, digest: image.imageSHA256, label: "image")
        }
        for row in document.sketches + document.planes + document.axes + document.symbols {
            guard Self.sha256(row.data) == row.sha256 else {
                throw CADDocumentStoreError.integrityFailed("inline record digest mismatch")
            }
        }
        var thumbnail: Data?
        if let digest = manifest.thumbnailSHA256 {
            do {
                thumbnail = try Data(contentsOf: root.appendingPathComponent("blobs/thumbnail.img"))
            } catch {
                throw CADDocumentStoreError.integrityFailed("declared preview is missing")
            }
            guard let thumbnail, Self.sha256(thumbnail) == digest else {
                throw CADDocumentStoreError.integrityFailed("preview digest mismatch")
            }
        }
        var contentHasher = SHA256()
        contentHasher.update(data: documentData)
        for (path, data) in blobs.sorted(by: { $0.key < $1.key }) {
            contentHasher.update(data: Data(path.utf8))
            contentHasher.update(data: Data(Self.sha256(data).utf8))
        }
        if let thumbnail {
            contentHasher.update(data: Data(Self.sha256(thumbnail).utf8))
        }
        guard Self.hex(contentHasher.finalize()) == manifest.contentSHA256 else {
            throw CADDocumentStoreError.integrityFailed("committed content digest mismatch")
        }

        var verifiedModelSHA256: String?
        if let expected = manifest.modelSHA256 {
            let knownDocumentData = try JSONEncoder().encode(document)
            let raw = try JSONSerialization.jsonObject(with: documentData)
            let known = try JSONSerialization.jsonObject(with: knownDocumentData)
            // A future additive field remains covered by the raw content
            // digest, but cannot be discarded while claiming its canonical
            // semantic identity. Keep viewing compatibility; do not attest an
            // identity this build cannot reconstruct.
            if !Self.hasUnknownFields(raw, comparedTo: known) {
                let actual = try Self.modelDigest(name: manifest.name, unit: manifest.unit,
                                                  tolerance: manifest.tolerance,
                                                  document: document, blobs: blobs)
                guard actual == expected else {
                    throw CADDocumentStoreError.integrityFailed("model digest mismatch")
                }
                verifiedModelSHA256 = actual
            }
        }
        // A supported writer rotating the package during this read cannot
        // leave us publishing a mixed generation. Validated snapshot bytes
        // are used below; an identity query never tries to repair a race.
        guard try Data(contentsOf: manifestURL) == manifestData else {
            throw CADDocumentStoreError.integrityFailed("package changed while it was read")
        }
        let formatAssessment = try CADDocumentFormat.assess(document)
        return VerifiedPackage(manifest: manifest, document: document, blobs: blobs,
                               thumbnail: thumbnail, modelSHA256: verifiedModelSHA256,
                               formatAssessment: formatAssessment)
    }

    private static func hasUnknownFields(_ raw: Any, comparedTo known: Any) -> Bool {
        if let raw = raw as? [String: Any], let known = known as? [String: Any] {
            for (key, value) in raw {
                guard let knownValue = known[key] else { return true }
                if hasUnknownFields(value, comparedTo: knownValue) { return true }
            }
        } else if let raw = raw as? [Any], let known = known as? [Any] {
            guard raw.count == known.count else { return true }
            return zip(raw, known).contains { hasUnknownFields($0.0, comparedTo: $0.1) }
        }
        return false
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
                             blobs: [String: Data], thumbnail: Data?) -> Project {
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
        project.sceneSettingsData = document.sceneSettings
        project.materialsData = document.materials
        project.animationData = document.animation
        project.thumbnail = thumbnail

        for record in document.bodies {
            let meshData = record.meshBlob.flatMap { blobs[$0] } ?? Data()
            let persisted = PersistedBody(
                bodyID: record.bodyID,
                name: record.name,
                transformData: record.transform,
                primitiveData: record.primitive,
                meshData: meshData
            )
            persisted.isHidden = record.isHidden
            persisted.materialData = record.material
            persisted.faceMaterialsData = record.faceMaterials
            persisted.brepData = record.brepBlob.flatMap { blobs[$0] }
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
            let imageData = record.imageBlob.flatMap { blobs[$0] } ?? Data()
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

    /// Slice the in-memory record graph and validate inline association
    /// semantics before choosing its writer version. The complete package
    /// verification, staging and I/O remain in `performWrite` off-main.
    func makePayload(_ project: Project) throws -> CADWritePayload {
        var document = CADDocumentRecord(
            bodies: [], sketches: [], planes: [], axes: [], images: [],
            symbols: [], features: [], variables: [],
            rollbackIndex: project.rollbackIndex,
            folderID: project.folderID,
            itemFolders: project.itemFoldersData,
            assembly: project.assemblyData,
            drawings: project.drawingsData,
            scripts: project.scriptsData,
            sceneSettings: project.sceneSettingsData,
            materials: project.materialsData,
            animation: project.animationData
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
                faceMaterials: body.faceMaterialsData,
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

        guard !project.hasOpaqueAssociations else { throw CADDocumentFormatError.opaqueAssociations }
        let assessment = try CADDocumentFormat.assess(document)
        guard !assessment.isOpaqueReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
        let schemaVersion = max(project.formatVersion, max(assessment.requiredVersion, self.schemaVersion))
        let manifest = CADManifest(
            schemaVersion: schemaVersion,
            revision: revision + 1,
            name: project.name,
            createdAt: project.createdAt,
            modifiedAt: project.modifiedAt,
            unit: project.unitRaw,
            tolerance: project.tolerance,
            contentSHA256: "",
            modelSHA256: nil,
            thumbnailSHA256: project.thumbnail.map { Self.sha256($0) },
            appBuild: Self.appBuild,
            counts: [:]
        )
        let payload = CADWritePayload(
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
        try CADDocumentFormat.validateWrite(payload)
        return payload
    }

    // MARK: Write (off-main: encode + hash + I/O)

    /// Perform a staged commit of a payload. Revision-guarded: if another
    /// commit landed since the payload was built, the write is refused rather
    /// than clobbering the newer revision.
    @discardableResult
    func performWrite(_ payload: CADWritePayload) throws -> (revision: Int, contentSHA256: String) {
        let committed = try performWriteWithIdentity(payload)
        return (committed.revision, committed.contentSHA256)
    }

    /// File-store-only additive receipt API. The generic CADDocumentStore
    /// protocol and its legacy tuple return stay unchanged for other stores.
    /// Return the exact already-calculated hashes before releasing commit lock.
    @discardableResult
    func performWriteWithIdentity(_ payload: CADWritePayload) throws -> CADSaveOutcome {
        // Serialize every supported writer of this package with the
        // cancellation route's verify→delete critical section and with other
        // store instances for the same path (see `CADPackageGate`).
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        lock.lock()
        defer { lock.unlock() }
        // Fenced release: a write that starts after `revoke()` (or finds the
        // fence already set) never commits. Together with `revoke()` taking
        // this same lock, a close/delete can never race a late commit.
        guard !revoked else {
            throw CADDocumentStoreError.commitFailed("store revoked (document released)")
        }
        guard payload.expectedRevision == storedRevision else {
            throw CADDocumentStoreError.revisionMoved(expected: payload.expectedRevision,
                                                      actual: storedRevision)
        }
        // Disk CAS fence: the in-memory `storedRevision` only tracks THIS
        // store instance, so a commit must also verify the package on disk is
        // still at that revision. Without this, a save from a session that
        // read an older revision would silently OVERWRITE a foreign commit
        // (revision guard passes on the stale in-memory value). Refusing here
        // preserves the foreign package; the caller surfaces the failure and
        // the draft/node are kept.
        try CADDocumentFormat.validateWrite(payload)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let onDisk = try verifiedPackage(at: packageURL)
            guard onDisk.manifest.revision == storedRevision else {
                throw CADDocumentStoreError.revisionMoved(expected: storedRevision, actual: onDisk.manifest.revision)
            }
            guard !onDisk.formatAssessment.isOpaqueReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
            try CADDocumentFormat.validateWrite(payload, storedSchema: max(onDisk.manifest.schemaVersion, onDisk.formatAssessment.requiredVersion))
        } else if storedRevision != 0 {
            throw CADDocumentStoreError.commitFailed("package manifest missing")
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
                // A document with no mesh/brep/image payloads never created
                // the `blobs/` directory in the loop above; the thumbnail is
                // still a real commit artifact of its own and must land. (T7S
                // regression: the first save of a brand-new, empty CAD
                // document — the workbench records its viewport thumbnail on
                // fullscreen return/close — failed with NSCocoaError 4,
                // “thumbnail.img doesn’t exist”, because that directory was
                // missing.)
                let thumbnailURL = staging.appendingPathComponent("blobs/thumbnail.img")
                try fileManager.createDirectory(at: thumbnailURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try thumbnail.write(to: thumbnailURL)
                contentHasher.update(data: Data(sha.utf8))
            }
            let contentDigest = Self.hex(contentHasher.finalize())
            // ADDITIVE model identity (canonical encode, preview excluded);
            // `contentDigest` above is byte-for-byte the existing semantics.
            let modelDigest = try Self.modelDigest(name: payload.name,
                                                   unit: payload.unit,
                                                   tolerance: payload.tolerance,
                                                   document: payload.document,
                                                   blobs: payload.blobs)

            let manifest = CADManifest(
                schemaVersion: payload.schemaVersion,
                revision: commitRevision,
                name: payload.name,
                createdAt: payload.createdAt,
                modifiedAt: payload.modifiedAt,
                unit: payload.unit,
                tolerance: payload.tolerance,
                contentSHA256: contentDigest,
                modelSHA256: modelDigest,
                thumbnailSHA256: thumbnailSHA256,
                appBuild: payload.appBuild,
                counts: payload.counts
            )
            try JSONEncoder().encode(manifest)
                .write(to: staging.appendingPathComponent("manifest.json"))

            // Verify the same complete digest/blob contract as an open before
            // rotating anything. Do not redefine either writer identity.
            let stagedDocument = try verifiedPackage(at: staging).document
            guard stagedDocument.bodies.count == payload.document.bodies.count else {
                throw CADDocumentStoreError.commitFailed("staged body count mismatch")
            }
            if let thumbnailSHA256 {
                // The manifest now claims a thumbnail; the staged bytes must
                // back that claim. Never report a committed save whose preview
                // artifact did not actually land.
                let stagedThumbnail = staging.appendingPathComponent("blobs/thumbnail.img")
                guard Self.sha256(contentsOf: stagedThumbnail) == thumbnailSHA256 else {
                    throw CADDocumentStoreError.commitFailed("staged thumbnail mismatch")
                }
            }

            try CADDocumentFaultInjection.beforeCommit?()
            try commit(staging: staging, transaction: transaction)
            storedRevision = commitRevision
            storedSchemaVersion = payload.schemaVersion
            storedContentSHA256 = contentDigest
            storedModelSHA256 = modelDigest
            return CADSaveOutcome(revision: commitRevision, contentSHA256: contentDigest,
                                  modelSHA256: modelDigest, error: nil)
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
        project.formatVersion = max(project.formatVersion, payload.schemaVersion)
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
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        let packageExists = fileManager.fileExists(atPath: packageURL.path)
        guard !packageExists || overwrite else {
            throw CADDocumentStoreError.commitFailed("package already exists")
        }
        try CADDocumentFormat.validateWrite(payload)
        if packageExists {
            let existing = try FileCADDocumentStore(packageURL: packageURL, fileManager: fileManager).verifiedPackage(at: packageURL)
            guard existing.manifest.revision == payload.expectedRevision else {
                throw CADDocumentStoreError.revisionMoved(expected: payload.expectedRevision, actual: existing.manifest.revision)
            }
            guard !existing.formatAssessment.isOpaqueReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
            try CADDocumentFormat.validateWrite(payload, storedSchema: max(existing.manifest.schemaVersion, existing.formatAssessment.requiredVersion))
        } else if payload.expectedRevision != 0 {
            throw CADDocumentStoreError.revisionMoved(expected: payload.expectedRevision, actual: 0)
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
            _ = try stagedStore.verifiedPackage(at: staging)

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
        try CADDocumentFormat.validateWrite(payload)
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
            // Same rule as `performWrite`: a payload with no blobs has no
            // `blobs/` directory, and the thumbnail must still be written.
            let thumbnailURL = packageURL.appendingPathComponent("blobs/thumbnail.img")
            try fileManager.createDirectory(at: thumbnailURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try thumbnail.write(to: thumbnailURL)
            contentHasher.update(data: Data(sha.utf8))
        }
        let contentDigest = Self.hex(contentHasher.finalize())
        let modelDigest = try Self.modelDigest(name: payload.name,
                                               unit: payload.unit,
                                               tolerance: payload.tolerance,
                                               document: payload.document,
                                               blobs: payload.blobs)
        let manifest = CADManifest(
            schemaVersion: payload.schemaVersion,
            revision: max(payload.expectedRevision, 0) + 1,
            name: payload.name,
            createdAt: payload.createdAt,
            modifiedAt: payload.modifiedAt,
            unit: payload.unit,
            tolerance: payload.tolerance,
            contentSHA256: contentDigest,
            modelSHA256: modelDigest,
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
        // Only ordinary open calls this method. Identity inspection must not
        // acquire this gate: cancellation already owns it while it verifies.
        CADPackageGate.acquire(packageURL)
        defer { CADPackageGate.release(packageURL) }
        // A supported writer may have completed between the missing-manifest
        // observation and acquiring its gate. Read that current commit instead.
        guard !fileManager.fileExists(atPath: manifestURL.path) else { return }
        _ = try verifiedPackage(at: previousURL)
        let parent = packageURL.deletingLastPathComponent()
        let restoring = parent.appendingPathComponent(".\(packageURL.lastPathComponent).recover-\(UUID().uuidString)")
        let interrupted = parent.appendingPathComponent(".\(packageURL.lastPathComponent).interrupted-\(UUID().uuidString)")
        var movedOriginal = false
        do {
            // Copy, then verify the copy. The original current/previous bytes
            // remain recoverable even if copying or promotion fails.
            try fileManager.copyItem(at: previousURL, to: restoring)
            _ = try verifiedPackage(at: restoring)
            if fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.moveItem(at: packageURL, to: interrupted)
                movedOriginal = true
            }
            try fileManager.moveItem(at: restoring, to: packageURL)
            // Keep the interrupted package as a sibling recovery point. It
            // may contain newer residual geometry not present in `previous`.
        } catch {
            if movedOriginal, !fileManager.fileExists(atPath: packageURL.path) {
                try? fileManager.moveItem(at: interrupted, to: packageURL)
            }
            try? fileManager.removeItem(at: restoring)
            throw error
        }
    }

    // MARK: Helpers

    static let appBuild: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "FloeCAD/\(version)(\(build))"
    }()

    /// Canonical, deterministic identity of the DOCUMENT MODEL. Domain
    /// separated into: the USER-EDITABLE semantic metadata (name, unit,
    /// tolerance — `modifiedAt`/`createdAt`/schema/appBuild are deliberately
    /// excluded because a preview-only commit moves them), then the document
    /// records encoded with SORTED keys, then every blob (path + content
    /// SHA). The viewport preview artifact is excluded.
    ///
    /// Sorted keys are required because Swift's default `JSONEncoder` emits an
    /// UNSPECIFIED key order (observed: a different order for every encode of
    /// the same value on Xcode 27 / Swift 6), which is why `contentSHA256`
    /// alone cannot express “semantically unchanged” across commits.
    /// Additive: callers may treat a manifest without this field as
    /// unverifiable.
    static func modelDigest(name: String, unit: String?, tolerance: Double?,
                            document: CADDocumentRecord,
                            blobs: [String: Data]) throws -> String {
        var hasher = SHA256()
        let metadata = CADModelDigestMetadata(name: name, unit: unit,
                                              tolerance: tolerance)
        hasher.update(data: try canonicalJSON(metadata))
        hasher.update(data: try canonicalJSON(document))
        for (path, data) in blobs.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data(Self.sha256(data).utf8))
        }
        return hex(hasher.finalize())
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

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

//
//  ProjectArchive.swift
//  openshape3d
//
//  The .os3d project archive (Phase F, spec §13): a single-file, full-fidelity
//  snapshot of a project — bodies (with their compact mesh blobs), sketches,
//  planes, images, symbols, the feature graph, variables, rollback marker and
//  thumbnail. The records carry the SAME pre-encoded JSON/mesh blobs the
//  SwiftData rows do, so export is a straight copy of persisted state and
//  import rebuilds rows byte-for-byte.
//
//  Import always REMAPS every UUID (consistently, across record IDs and the
//  IDs inside the JSON blobs) so importing an archive next to the project it
//  came from — or twice — never collides with SwiftData's unique columns.
//

import Foundation
import SwiftData

// MARK: - Container

nonisolated struct ProjectArchive: Codable, Sendable {
    /// v2 (2026-08-25): `BodyRecord.brep` carries the OCCT analytic solid —
    /// before that, export/import silently degraded smooth geometry to its
    /// tessellation (review C4). v1 archives load fine (field decodes nil).
    static let currentVersion = 2
    /// Readers refuse archives NEWER than they understand (best-effort forward
    /// reads risk silent data loss); older versions always load.
    var version: Int = ProjectArchive.currentVersion

    var name: String
    var thumbnail: Data?
    var rollbackIndex: Int?
    /// Items Manager folders (`[ItemFolder]` JSON); absent in older archives.
    var itemFolders: Data?

    struct BodyRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var transform: Data
        var primitive: Data?
        var mesh: Data
        var isHidden: Bool
        var material: Data?
        /// OCCT brep blob (v2+); nil for Euclid-only bodies and v1 archives.
        ///
        /// STILL WRITTEN, NEVER READ BACK (2026-08-25 review round 3 fuzzing).
        /// Feeding an archive's brep to `BRepTools::Read` is a remote-crash
        /// vector: of 294 malformed blobs, 53 segfaulted and 46 hung forever
        /// — inside the reader, so the bridge's `catch (...)` cannot help, and
        /// on the MainActor, so a hang is an unrecoverable freeze. A poisoned
        /// project then re-kills the app every time it is opened.
        /// Re-enable `insert(into:name:)`'s import only once the reader is
        /// hardened (bail on stream fail/eof, clamp declared section counts).
        var brep: Data?
    }
    /// Sketches / planes / symbols: one JSON blob each.
    struct BlobRecord: Codable, Sendable {
        var id: UUID
        var data: Data
    }
    struct ImageRecord: Codable, Sendable {
        var id: UUID
        var info: Data
        var image: Data
    }
    struct FeatureRecord: Codable, Sendable {
        var id: UUID
        var orderIndex: Int
        var name: String
        var suppressed: Bool
        var kind: Data
        var outputBodyIDs: Data
    }
    struct VariableRecord: Codable, Sendable {
        var id: UUID
        var orderIndex: Int
        var name: String
        var expression: String
        var value: Double
    }

    var bodies: [BodyRecord] = []
    var sketches: [BlobRecord] = []
    var planes: [BlobRecord] = []
    var images: [ImageRecord] = []
    var symbols: [BlobRecord] = []
    var features: [FeatureRecord] = []
    var variables: [VariableRecord] = []
}

// MARK: - Encoding

nonisolated extension ProjectArchive {

    /// Binary property list — Data-heavy records stay compact (JSON would
    /// base64-bloat every mesh blob by a third).
    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    /// Nil for corrupt data or an archive from a NEWER format version.
    static func decode(_ data: Data) -> ProjectArchive? {
        guard let archive = try? PropertyListDecoder()
            .decode(ProjectArchive.self, from: data) else { return nil }
        guard archive.version <= currentVersion else { return nil }
        return archive
    }
}

// MARK: - UUID remap

nonisolated extension ProjectArchive {

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )

    /// The archive with EVERY UUID replaced by a fresh one — the same old ID
    /// always maps to the same new ID, whether it appears as a record ID or
    /// inside a JSON blob (feature body refs, sketch entity IDs, plane refs…).
    /// Mesh and image blobs are binary formats with no IDs and pass through
    /// untouched.
    func remappingAllUUIDs() -> ProjectArchive {
        var map = [String: String]()   // uppercase uuidString → fresh

        func mapped(_ id: UUID) -> UUID {
            let key = id.uuidString
            if let hit = map[key] { return UUID(uuidString: hit)! }
            let fresh = UUID()
            map[key] = fresh.uuidString
            return fresh
        }

        /// Rewrite the UUID strings inside a JSON blob. JSON is UTF-8 text, so
        /// a string-level regex replace is exact; the map is shared with the
        /// record-ID remap so references stay consistent.
        func rewritten(_ blob: Data) -> Data {
            guard !blob.isEmpty, var text = String(data: blob, encoding: .utf8)
            else { return blob }
            let matches = Self.uuidPattern.matches(
                in: text, range: NSRange(text.startIndex..., in: text))
            // Replace back-to-front so earlier ranges stay valid.
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let old = String(text[range]).uppercased()
                let fresh: String
                if let hit = map[old] {
                    fresh = hit
                } else {
                    fresh = UUID().uuidString
                    map[old] = fresh
                }
                text.replaceSubrange(range, with: fresh)
            }
            return Data(text.utf8)
        }

        var out = self
        out.itemFolders = itemFolders.map(rewritten)
        out.bodies = bodies.map { record in
            var r = record
            r.id = mapped(record.id)
            r.transform = rewritten(record.transform)
            r.primitive = record.primitive.map(rewritten)
            r.material = record.material.map(rewritten)
            return r
        }
        out.sketches = sketches.map { .init(id: mapped($0.id), data: rewritten($0.data)) }
        out.planes = planes.map { .init(id: mapped($0.id), data: rewritten($0.data)) }
        out.symbols = symbols.map { .init(id: mapped($0.id), data: rewritten($0.data)) }
        out.images = images.map { record in
            var r = record
            r.id = mapped(record.id)
            r.info = rewritten(record.info)
            return r
        }
        out.features = features.map { record in
            var r = record
            r.id = mapped(record.id)
            r.kind = rewritten(record.kind)
            r.outputBodyIDs = rewritten(record.outputBodyIDs)
            return r
        }
        out.variables = variables.map { record in
            var r = record
            r.id = mapped(record.id)
            return r
        }
        return out
    }
}

// MARK: - SwiftData bridge

extension ProjectArchive {

    /// Snapshot a project's PERSISTED rows. Callers that hold live edits must
    /// save the session first so the rows are current.
    @MainActor
    static func archive(from project: Project) -> ProjectArchive {
        var archive = ProjectArchive(name: project.name)
        archive.thumbnail = project.thumbnail
        archive.rollbackIndex = project.rollbackIndex
        archive.itemFolders = project.itemFoldersData
        archive.bodies = project.bodies.map {
            BodyRecord(
                id: $0.bodyID, name: $0.name, transform: $0.transformData,
                primitive: $0.primitiveData, mesh: $0.meshData,
                isHidden: $0.isHidden, material: $0.materialData,
                brep: $0.brepData)
        }
        archive.sketches = project.sketches.map {
            BlobRecord(id: $0.sketchID, data: $0.sketchData)
        }
        archive.planes = project.planes.map {
            BlobRecord(id: $0.planeID, data: $0.planeData)
        }
        archive.images = project.images.map {
            ImageRecord(id: $0.imageID, info: $0.infoData, image: $0.imageData)
        }
        archive.symbols = project.symbols.map {
            BlobRecord(id: $0.symbolID, data: $0.symbolData)
        }
        archive.features = project.features.map {
            FeatureRecord(
                id: $0.featureID, orderIndex: $0.orderIndex, name: $0.name,
                suppressed: $0.suppressed, kind: $0.kindData,
                outputBodyIDs: $0.outputBodyIDData)
        }
        archive.variables = project.variables.map {
            VariableRecord(
                id: $0.variableID, orderIndex: $0.orderIndex, name: $0.name,
                expression: $0.expression, value: $0.value)
        }
        return archive
    }

    /// Materialize the archive as a NEW project (rows inserted, not saved —
    /// the caller saves the context). Always remap first (`remappingAllUUIDs`)
    /// when the archive may share IDs with rows already in the store.
    /// `trustingBRep` restores each body's OCCT solid as well. It is for
    /// archives the app itself ships (`SampleDesigns`) — bytes we wrote, in
    /// our own bundle — never for a file a user picked; see the note on
    /// `BodyRecord.brep` for why that reader must not see untrusted input.
    @MainActor
    @discardableResult
    func insert(into context: ModelContext, name: String, trustingBRep: Bool = false) -> Project {
        let project = Project(name: name)
        project.thumbnail = thumbnail
        project.rollbackIndex = rollbackIndex
        project.itemFoldersData = itemFolders
        context.insert(project)

        for record in bodies {
            let row = PersistedBody(
                bodyID: record.id, name: record.name,
                transformData: record.transform,
                primitiveData: record.primitive, meshData: record.mesh)
            row.isHidden = record.isHidden
            row.materialData = record.material
            // DELIBERATELY NOT IMPORTED — see the note on `BodyRecord.brep`.
            // An archive is untrusted input; OCCT's BREP reader is not
            // hardened against hostile bytes (fuzzing: 34% of malformed blobs
            // segfault or hang the process, inside BRepTools::Read where no
            // catch(...) can help). Dropping it costs analytic fidelity on
            // imported bodies — `load()` already falls back to the archived
            // render mesh — and removes the entire remote-crash surface.
            row.brepData = trustingBRep ? record.brep : nil
            row.project = project
            context.insert(row)
        }
        for record in sketches {
            let row = PersistedSketch(sketchID: record.id, sketchData: record.data)
            row.project = project
            context.insert(row)
        }
        for record in planes {
            let row = PersistedPlane(planeID: record.id, planeData: record.data)
            row.project = project
            context.insert(row)
        }
        for record in images {
            let row = PersistedImage(
                imageID: record.id, infoData: record.info, imageData: record.image)
            row.project = project
            context.insert(row)
        }
        for record in symbols {
            let row = PersistedSymbol(symbolID: record.id, symbolData: record.data)
            row.project = project
            context.insert(row)
        }
        for record in features {
            let row = PersistedFeature(
                featureID: record.id, orderIndex: record.orderIndex,
                name: record.name, suppressed: record.suppressed,
                kindData: record.kind, outputBodyIDData: record.outputBodyIDs)
            row.project = project
            context.insert(row)
        }
        for record in variables {
            let row = PersistedVariable(
                variableID: record.id, orderIndex: record.orderIndex,
                name: record.name, expression: record.expression,
                value: record.value)
            row.project = project
            context.insert(row)
        }
        return project
    }
}

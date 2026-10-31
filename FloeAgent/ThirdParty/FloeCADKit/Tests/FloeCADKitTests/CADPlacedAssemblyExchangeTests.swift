//
//  CADPlacedAssemblyExchangeTests.swift
//  FloeCADKitTests
//
//  E24/E25 acceptance over REAL documents and REAL kernel geometry:
//   * one source part placed three times (one under a two-level/nested
//     subassembly, distinct rotations/translations, hidden definition),
//   * one independent copy and one mesh-only body,
//   * part vs assembly selection, exact coverage counts/reasons,
//   * GLB object/node count + independently parsed world matrices,
//   * actual PBR texture / UV accessors on every placed source occurrence,
//   * STEP coverage before promotion, exact placed B-rep copies and mesh-only
//     exclusion, same-engine reparse as a SUPPLEMENTARY check only,
//   * no double transform after save/reopen.
//
//  The STEP same-engine reparse is NOT external CAD acceptance. An external
//  CAD runtime read-back is root-run (see the handoff sample).
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADPlacedAssemblyExchangeTests: XCTestCase {
    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloePlacedExchange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("placed.floecad"), name: "Placed")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixture

    private func execute(_ json: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private func makeBox(name: String, min: [Double], max: [Double],
                         height: Double = 10) throws -> String {
        let sketch = try execute(#"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try execute("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],
                      "max":[\(max[0]),\(max[1])]}]}}
        """)
        let extrude = try execute("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":\(height)}}
        """)
        return try XCTUnwrap((extrude["producedBodyIDs"] as? [String])?.first
            ?? (extrude["changedBodyIDs"] as? [String])?.first,
            "extrude returned no body: \(extrude)")
    }

    @discardableResult
    private func addMeshBody(name: String) -> String {
        let half: Float = 5
        let positions: [SIMD3<Float>] = [
            [-half, -half, -half], [half, -half, -half],
            [half, half, -half], [-half, half, -half],
            [-half, -half, half], [half, -half, half],
            [half, half, half], [-half, half, half],
        ]
        let normals = positions.map { simd_normalize($0) }
        let indices: [UInt32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
            1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3,
        ]
        let mesh = RenderMesh(positions: positions, normals: normals, indices: indices)
        let body = Body(id: BodyID(), name: name, transform: .identity,
                        primitive: nil, render: mesh, revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Add \(name)"))
        return body.id.raw.uuidString
    }

    @discardableResult
    private func addInvalidMeshBody(name: String) -> String {
        let mesh = RenderMesh(positions: [SIMD3(0, 0, 0)],
                              normals: [SIMD3(0, 0, 1)],
                              indices: [])
        let body = Body(id: BodyID(), name: name, transform: .identity,
                        primitive: nil, render: mesh, revision: 2)
        document.session.perform(AddBodyCommand(body: body, title: "Add \(name)"))
        return body.id.raw.uuidString
    }

    private func addSubassembly(_ service: CADAssemblyService, name: String,
                                transform: [String: Any]? = nil,
                                parentID: String? = nil) throws -> String {
        var args: [String: Any] = ["name": name]
        if let transform { args["transform"] = transform }
        if let parentID { args["parentID"] = parentID }
        let reply = service.handle(action: "addSubassembly", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func addInstance(_ service: CADAssemblyService, bodyID: String, name: String,
                             parentID: String? = nil,
                             transform: [String: Any]? = nil,
                             independentCopy: Bool = false) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID, "name": name]
        if let parentID { args["parentID"] = parentID }
        if let transform { args["transform"] = transform }
        if independentCopy { args["independentCopy"] = true }
        let reply = service.handle(action: "addInstance", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private struct Fixture {
        var sourceA: String
        var sourceB: String
        var meshBody: String
        var subassembly: String
        var a1: String
        var a2: String
        var a3: String
        var independent: String
        var meshInstance: String
    }

    private func makeFixture(includeInvalidMesh: Bool = false,
                             includeMissingTexture: Bool = false) throws -> Fixture {
        let sourceA = try makeBox(name: "Part A", min: [0, 0], max: [40, 20])
        let sourceB = try makeBox(name: "Part B", min: [60, 0], max: [70, 10])
        if includeMissingTexture {
            var spec = BodyMaterialSpec(baseColor: SIMD4(0.8, 0.2, 0.2, 1))
            spec.textureMetadata = [CADMaterialTextureMetadata(
                assetID: UUID(), slot: .baseColor, mimeType: "image/png",
                colorSpace: .srgb, orientation: .topLeft,
                sha256: String(repeating: "0", count: 64), byteCount: 0)]
            document.session.perform(SetMaterialCommand(
                bodyIDs: [BodyID(raw: try XCTUnwrap(UUID(uuidString: sourceB)))],
                material: spec,
                document: document.session.document))
        }
        let meshBody = addMeshBody(name: "Mesh Insert")
        let service = CADAssemblyService(document: document)
        let nested = try addSubassembly(service, name: "Nested",
                                        transform: ["position": [0.0, 50.0, 0.0],
                                                    "rotation": [0.0, 0.0, 1.0, 0.0]])
        let a1 = try addInstance(service, bodyID: sourceA, name: "Part A 1")
        let a2 = try addInstance(service, bodyID: sourceA, name: "Part A 2",
                                 transform: ["position": [40.0, 0.0, 0.0],
                                             "rotation": [0.0, 0.7071067811865476,
                                                          0.0, 0.7071067811865476]])
        let a3 = try addInstance(service, bodyID: sourceA, name: "Part A 3",
                                 parentID: nested,
                                 transform: ["position": [100.0, 0.0, 0.0]])
        let independent = try addInstance(service, bodyID: sourceB,
                                          name: "Independent B",
                                          transform: ["position": [0.0, 0.0, 100.0]],
                                          independentCopy: true)
        let meshInstance = try addInstance(service, bodyID: meshBody,
                                           name: "Mesh Insert 1",
                                           transform: ["position": [0.0, 0.0, 60.0]])

        // Hidden DEFINITION with visible instances. The export must still
        // write all three visible placements.
        document.session.perform(SetItemVisibilityCommand(
            item: .body(BodyID(raw: try XCTUnwrap(UUID(uuidString: sourceA)))),
            isHidden: true))

        if includeInvalidMesh {
            let bad = addInvalidMeshBody(name: "Bad Mesh")
            _ = try addInstance(service, bodyID: bad, name: "Bad Mesh 1",
                                transform: ["position": [0.0, 80.0, 0.0]])
        }
        return Fixture(sourceA: sourceA, sourceB: sourceB, meshBody: meshBody,
                       subassembly: nested, a1: a1, a2: a2, a3: a3,
                       independent: independent, meshInstance: meshInstance)
    }

    private func applyTexturedMaterial(to bodyID: String) throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        var spec = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.8, 0.3, 1),
                                    metallic: 0.25, roughness: 0.4)
        spec.baseColorTexture = png
        spec.textureMetadata = [CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: CADMaterialTexture.digest(png), byteCount: png.count)]
        spec.uvMapping = CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                              scaleMM: SIMD2(20, 20))
        document.session.perform(SetMaterialCommand(
            bodyIDs: [BodyID(raw: try XCTUnwrap(UUID(uuidString: bodyID)))],
            material: spec,
            document: document.session.document))
    }

    // MARK: - Coverage / selection

    func testAssemblyCoverageKeepsVisibleInstancesOfHiddenDefinitionAndIndependentCopy() throws {
        let fixture = try makeFixture()
        let part = try document.exchangeCoverage(
            format: "glb", selection: .init(scope: .part)).get()
        let assembly = try document.exchangeCoverage(
            format: "glb", selection: .init(scope: .assembly)).get()

        XCTAssertEqual(part.selectedCount, 4,
                       "part scope sees the four document bodies, not placements")
        XCTAssertEqual(assembly.selectedCount, 5,
                       "assembly scope sees three A placements + independent B + mesh")
        XCTAssertTrue(assembly.complete)
        XCTAssertFalse(assembly.requiresConfirmation)

        let sourceRows = assembly.items.filter { $0.bodyID.uuidString == fixture.sourceA }
        XCTAssertEqual(sourceRows.count, 3,
                       "the same source part must stay three distinct occurrences")
        XCTAssertEqual(Set(sourceRows.map(\.instanceID)).count, 3)
        XCTAssertTrue(sourceRows.allSatisfy(\.included))
        let nested = try XCTUnwrap(sourceRows.first { $0.instanceID?.uuidString == fixture.a3 })
        XCTAssertEqual(nested.path.count, 2, "the nested occurrence must retain its path")
        assertVector(nested.worldPositionMM, [-100, 50, 0], accuracy: 1e-6)
        assertVector(try XCTUnwrap(sourceRows.first {
            $0.instanceID?.uuidString == fixture.a2
        }).worldPositionMM, [40, 0, 0], accuracy: 1e-6)

        let independent = try XCTUnwrap(assembly.items.first {
            $0.instanceID?.uuidString == fixture.independent
        })
        XCTAssertTrue(independent.independentCopy)
        XCTAssertNotEqual(independent.bodyID.uuidString, fixture.sourceB,
                          "an independent copy must report its copied body")
        assertVector(independent.worldPositionMM, [0, 0, 100], accuracy: 1e-6)

        let mesh = try XCTUnwrap(assembly.items.first {
            $0.instanceID?.uuidString == fixture.meshInstance
        })
        XCTAssertFalse(mesh.analyticBRep)
        XCTAssertTrue(mesh.included)
        XCTAssertEqual(document.session.document.body(with: BodyID(
            raw: try XCTUnwrap(UUID(uuidString: fixture.sourceA))))?.isHidden, true,
            "fixture definition is hidden; instances must still export")
    }

    func testSTEPCoverageRequiresExplicitChoiceForMeshOnlyBody() throws {
        _ = try makeFixture()
        let coverage = try document.exchangeCoverage(
            format: "step", selection: .init(scope: .assembly)).get()
        XCTAssertEqual(coverage.selectedCount, 5)
        XCTAssertEqual(coverage.includedCount, 4)
        XCTAssertEqual(coverage.excludedCount, 1)
        XCTAssertEqual(coverage.excludedItems.first?.reason, "mesh_only_no_analytic_brep")
        XCTAssertFalse(coverage.complete)
        XCTAssertTrue(coverage.requiresConfirmation)

        switch document.nativeExchangeExport(
            format: "step", pageID: nil,
            selection: .init(scope: .assembly), dryRun: false) {
        case .coverageRequired(let receipt):
            XCTAssertEqual(receipt.excludedCount, 1)
        default:
            XCTFail("STEP with a mesh-only object must stop for an explicit choice")
        }

        switch document.nativeExchangeExport(
            format: "step", pageID: nil,
            selection: .init(scope: .assembly, acceptPartial: true), dryRun: false) {
        case let .success(data, _, receipt):
            XCTAssertFalse(receipt.complete)
            XCTAssertTrue(receipt.acceptedPartial)
            XCTAssertEqual(receipt.includedCount, 4)
            XCTAssertTrue(String(decoding: data.prefix(32), as: UTF8.self)
                .contains("ISO-10303-21"))
            let solids = STEPKit.solids(from: data)
            XCTAssertEqual(solids.count, 4,
                           "same-engine STEP reparse: four exact placed solids")
            for solid in solids { XCTAssertGreaterThan(OCCTKernel.volume(solid), 0) }
            // Supplementary same-engine placement check (NOT external CAD
            // acceptance): a reparsed box's world bounding-box centre must be
            // the freshly composed placement, not the source definition alone.
            let centers = solids.map(solidCentreMM)
            let expectedCenters: [[Double]] = [
                [20, 5, 10], [50, 5, -20], [-120, 45, 10], [65, 5, 105],
            ]
            for expected in expectedCenters {
                XCTAssertTrue(centers.contains { distance($0, expected) < 0.5 },
                              "missing STEP placed centre \(expected); got \(centers)")
            }
        default:
            XCTFail("the explicit partial STEP export must return bytes")
        }
    }

    // MARK: - GLB independent reader

    func testGLBPreservesThreeOccurrencesHierarchyWorldMatricesAndMaterials() throws {
        let fixture = try makeFixture()
        try applyTexturedMaterial(to: fixture.sourceA)

        let (data, coverage) = try exportGLB(selection: .init(scope: .assembly))
        XCTAssertTrue(coverage.complete)
        let parsed = try glbJSON(data)
        let nodes = try XCTUnwrap(parsed["nodes"] as? [[String: Any]])
        let scenes = try XCTUnwrap(parsed["scenes"] as? [[String: Any]])
        let roots = try XCTUnwrap(scenes.first?["nodes"] as? [Int])
        let world = worldMatrices(nodes: nodes, roots: roots)

        let meshNodes = nodes.enumerated().filter { $0.element["mesh"] != nil }
        XCTAssertEqual(meshNodes.count, 5,
                       "three A placements + independent B + mesh-only body")
        XCTAssertEqual(Set(meshNodes.compactMap {
            ($0.element["extras"] as? [String: Any])?["floe_occurrence_id"] as? String
        }).count, 5)

        let byName = Dictionary(uniqueKeysWithValues: meshNodes.compactMap { entry -> (String, [String: Any])? in
            guard let name = entry.element["name"] as? String else { return nil }
            return (name, entry.element)
        })
        let expected: [String: [Double]] = [
            "Part A 1": [0, 0, 0],
            "Part A 2": [40, 0, 0],
            "Part A 3": [-100, 50, 0],
            "Independent B": [0, 0, 100],
            "Mesh Insert 1": [0, 0, 60],
        ]
        for (name, expectedMM) in expected {
            let node = try XCTUnwrap(byName[name], "missing exported mesh node \(name)")
            let index = try XCTUnwrap(meshNodes.first { ($0.element["name"] as? String) == name }?.offset)
            let matrix = try XCTUnwrap(world[index])
            let metres = [matrix[12], matrix[13], matrix[14]]
            let expectedMetres = expectedMM.map { $0 / 1000 }
            assertVector(metres, expectedMetres, accuracy: 1e-6)
            let extras = try XCTUnwrap(node["extras"] as? [String: Any])
            assertVector(extras["floe_world_position_mm"] as? [Double] ?? [],
                         expectedMM, accuracy: 1e-6)
        }

        // Three nodes, one shared source definition, distinct occurrence
        // identities and paths; the nested one has a subassembly ancestor.
        let aNodes = meshNodes.filter {
            (($0.element["extras"] as? [String: Any])?["floe_source_body_id"] as? String)
                == fixture.sourceA
        }
        XCTAssertEqual(aNodes.count, 3)
        let nestedNode = try XCTUnwrap(aNodes.first {
            (($0.element["extras"] as? [String: Any])?["floe_occurrence_id"] as? String)
                == fixture.a3
        })
        let nestedExtras = try XCTUnwrap(nestedNode.element["extras"] as? [String: Any])
        XCTAssertEqual((nestedExtras["floe_occurrence_path"] as? [String])?.count ?? -1, 2)
        let subassemblyNodes = nodes.filter {
            ($0["extras"] as? [String: Any])?["floe_kind"] as? String == "subassembly"
        }
        XCTAssertEqual(subassemblyNodes.count, 1)
        XCTAssertEqual((subassemblyNodes.first?["children"] as? [Int])?.count ?? -1, 1)

        // Actual PBR/UV data: every A primitive samples the applied texture.
        let materials = try XCTUnwrap(parsed["materials"] as? [[String: Any]])
        let meshes = try XCTUnwrap(parsed["meshes"] as? [[String: Any]])
        let accessors = try XCTUnwrap(parsed["accessors"] as? [[String: Any]])
        for entry in aNodes {
            let meshIndex = try XCTUnwrap(entry.element["mesh"] as? Int)
            let mesh = try XCTUnwrap(meshes[safe: meshIndex])
            let primitive = try XCTUnwrap((mesh["primitives"] as? [[String: Any]])?.first)
            let attributes = try XCTUnwrap(primitive["attributes"] as? [String: Any])
            let uvIndex = try XCTUnwrap(attributes["TEXCOORD_0"] as? Int,
                                        "the placed part lost its UV set")
            let uvAccessor = try XCTUnwrap(accessors[safe: uvIndex])
            let positionIndex = try XCTUnwrap(attributes["POSITION"] as? Int)
            let positionAccessor = try XCTUnwrap(accessors[safe: positionIndex])
            XCTAssertEqual(uvAccessor["count"] as? Int, positionAccessor["count"] as? Int)
            let materialIndex = try XCTUnwrap(primitive["material"] as? Int)
            let material = try XCTUnwrap(materials[safe: materialIndex])
            let pbr = try XCTUnwrap(material["pbrMetallicRoughness"] as? [String: Any])
            XCTAssertNotNil(pbr["baseColorTexture"],
                            "the applied base-color texture must survive placement export")
        }
        let root = try XCTUnwrap(nodes.last)
        XCTAssertEqual(root["name"] as? String, "FloeRoot")
        XCTAssertEqual(root["scale"] as? [Double], [0.001, 0.001, 0.001])
        let rootExtras = try XCTUnwrap(root["extras"] as? [String: Any])
        XCTAssertEqual(rootExtras["floe_assembly_scope"] as? String, "assembly")
        XCTAssertEqual(rootExtras["floe_hierarchy"] as? String, "preserved")
        XCTAssertEqual(rootExtras["floe_occurrence_count"] as? Int, 5)
        XCTAssertEqual(rootExtras["floe_source_units"] as? String, "millimetres")
        XCTAssertEqual((rootExtras["floe_format_loss"] as? [String])?.contains("brep") ?? false, true)
        XCTAssertEqual((rootExtras["floe_format_loss"] as? [String])?
            .contains("assembly_hierarchy") ?? true, false)
    }

    func testNoDoubleTransformAfterSaveReopen() async throws {
        let fixture = try makeFixture()
        try applyTexturedMaterial(to: fixture.sourceA)
        let (before, _) = try exportGLB(selection: .init(scope: .assembly))
        let beforePositions = try occurrencePositions(before)
        XCTAssertEqual(beforePositions[fixture.a3] ?? [], [-100, 50, 0])

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = document.url
        document.close()
        document = try await FloeCADDocument.open(at: url)

        let (after, _) = try exportGLB(selection: .init(scope: .assembly))
        let afterPositions = try occurrencePositions(after)
        XCTAssertEqual(Set(beforePositions.keys), Set(afterPositions.keys))
        for (id, position) in beforePositions {
            assertVector(try XCTUnwrap(afterPositions[id]), position, accuracy: 1e-6)
        }
    }

    // MARK: - Truthful failure receipts

    func testInvalidMeshIsExcludedBeforePromotionAndNeverReportedComplete() throws {
        _ = try makeFixture(includeInvalidMesh: true)
        let coverage = try document.exchangeCoverage(
            format: "glb", selection: .init(scope: .assembly)).get()
        XCTAssertEqual(coverage.selectedCount, 6)
        XCTAssertEqual(coverage.includedCount, 5)
        XCTAssertEqual(coverage.excludedItems.first?.reason, "empty_mesh")
        XCTAssertFalse(coverage.complete)
        XCTAssertTrue(coverage.requiresConfirmation)

        switch document.nativeExchangeExport(
            format: "glb", pageID: nil,
            selection: .init(scope: .assembly), dryRun: false) {
        case .coverageRequired(let receipt):
            XCTAssertEqual(receipt.excludedCount, 1)
        default:
            XCTFail("an invalid mesh must stop before any bytes are promoted")
        }

        switch document.nativeExchangeExport(
            format: "glb", pageID: nil,
            selection: .init(scope: .assembly, acceptPartial: true), dryRun: false) {
        case let .success(data, _, receipt):
            XCTAssertFalse(receipt.complete, "partial bytes must never claim complete")
            XCTAssertTrue(receipt.acceptedPartial)
            XCTAssertGreaterThan(data.count, 20)
            let parsed = try glbJSON(data)
            let nodes = try XCTUnwrap(parsed["nodes"] as? [[String: Any]])
            XCTAssertEqual(nodes.filter { $0["mesh"] != nil }.count, 5,
                           "valid occurrences are exported; the invalid one is excluded")
        default:
            XCTFail("explicit partial GLB export must produce valid bytes")
        }
    }

    func testMissingTextureIsReportedAndRequiresConfirmation() throws {
        _ = try makeFixture(includeMissingTexture: true)
        let coverage = try document.exchangeCoverage(
            format: "glb", selection: .init(scope: .assembly)).get()
        XCTAssertFalse(coverage.complete)
        XCTAssertTrue(coverage.requiresConfirmation)
        let textured = try XCTUnwrap(coverage.items.first {
            $0.name == "Independent B"
        })
        XCTAssertTrue(textured.included)
        XCTAssertTrue(textured.materialWarnings.contains("texture_baseColor_missing"),
                      "\(textured.materialWarnings)")
    }

    func testStaleRevisionFenceWritesNothing() throws {
        _ = try makeFixture()
        let receipt = try document.exchangeCoverage(
            format: "glb", selection: .init(scope: .assembly)).get()
        let stale = document.nativeExchangeExport(
            format: "glb", pageID: nil,
            selection: .init(scope: .assembly,
                             expectedRevision: receipt.documentRevision + 1),
            dryRun: false)
        switch stale {
        case .failure(let error):
            XCTAssertEqual(error.code, "stale_export")
        default:
            XCTFail("a stale revision must be refused before producing bytes")
        }
    }

    // MARK: - Export / parser helpers

    private func exportGLB(selection: CADExchangeSelection) throws -> (Data, CADExchangeCoverage) {
        switch document.nativeExchangeExport(format: "glb", pageID: nil,
                                             selection: selection, dryRun: false) {
        case let .success(data, _, coverage):
            return (data, coverage)
        case .coverageRequired(let coverage):
            throw XCTSkip("coverage requires confirmation: \(coverage.excludedItems.map(\.name))")
        case .coverage(let coverage):
            throw XCTSkip("dry run only: \(coverage.selectedCount)")
        case .failure(let error):
            throw error
        }
    }

    private func glbJSON(_ data: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        let json = data.subdata(in: 20..<(20 + length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func occurrencePositions(_ glb: Data) throws -> [String: [Double]] {
        let json = try glbJSON(glb)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let scenes = try XCTUnwrap(json["scenes"] as? [[String: Any]])
        let roots = try XCTUnwrap(scenes.first?["nodes"] as? [Int])
        let world = worldMatrices(nodes: nodes, roots: roots)
        var result: [String: [Double]] = [:]
        for (index, node) in nodes.enumerated() {
            guard node["mesh"] != nil,
                  let extras = node["extras"] as? [String: Any],
                  let id = extras["floe_occurrence_id"] as? String,
                  let matrix = world[index] else { continue }
            result[id] = [matrix[12], matrix[13], matrix[14]]
        }
        return result
    }

    private func worldMatrices(nodes: [[String: Any]], roots: [Int]) -> [Int: [Double]] {
        var result: [Int: [Double]] = [:]
        func visit(_ index: Int, parent: [Double]) {
            guard nodes.indices.contains(index) else { return }
            let node = nodes[index]
            let local = localMatrix(node)
            let world = multiply(parent, local)
            result[index] = world
            if let children = node["children"] as? [Int] {
                for child in children { visit(child, parent: world) }
            }
        }
        let identity: [Double] = [
            1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
        ]
        for root in roots { visit(root, parent: identity) }
        return result
    }

    private func localMatrix(_ node: [String: Any]) -> [Double] {
        if let matrix = node["matrix"] as? [Double], matrix.count == 16 { return matrix }
        var matrix: [Double] = [
            1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
        ]
        if let scale = node["scale"] as? [Double], scale.count == 3 {
            matrix[0] = scale[0]; matrix[5] = scale[1]; matrix[10] = scale[2]
        }
        if let translation = node["translation"] as? [Double], translation.count == 3 {
            matrix[12] = translation[0]; matrix[13] = translation[1]
            matrix[14] = translation[2]
        }
        return matrix
    }

    /// Column-major 4x4 multiply.
    private func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var value = 0.0
                for k in 0..<4 {
                    value += a[k * 4 + row] * b[column * 4 + k]
                }
                result[column * 4 + row] = value
            }
        }
        return result
    }

    private func solidCentreMM(_ handle: BRepHandle) -> [Double] {
        let mesh = OCCTKernel.renderMesh(from: handle)
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for point in mesh.positions {
            let value = SIMD3(Double(point.x), Double(point.y), Double(point.z))
            lo = simd_min(lo, value)
            hi = simd_max(hi, value)
        }
        return [(lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2]
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return .infinity }
        var sum = 0.0
        for (left, right) in zip(a, b) {
            sum += (left - right) * (left - right)
        }
        return sqrt(sum)
    }

    private func assertVector(_ actual: [Double], _ expected: [Double],
                              accuracy: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for index in 0..<min(actual.count, expected.count) {
            XCTAssertEqual(actual[index], expected[index], accuracy: accuracy,
                           "component \(index): \(actual) vs \(expected)",
                           file: file, line: line)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

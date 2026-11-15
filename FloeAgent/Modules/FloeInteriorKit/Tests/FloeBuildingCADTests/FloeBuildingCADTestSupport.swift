// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

@MainActor
enum FloeBuildingCADTestSupport {
    static func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBuildingCAD-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeSession(_ name: String) async throws -> (FloeBuildingCADSession, URL) {
        let root = try makeRoot(name)
        let url = root.appendingPathComponent("Project.floecad", isDirectory: true)
        let session = try await FloeBuildingCADSession.create(at: url, name: name)
        return (session, root)
    }

    static func cabinetRecipe(width: Double = 2400, height: Double = 2100) -> CabinetRecipe {
        var recipe = InteriorResearchSamples.cabinet(bayCount: 3, shelvesPerBay: 3, includeFronts: true)
        recipe.widthMM = width
        recipe.heightMM = height
        return recipe
    }

    static func buildingSpec() -> FloeBuildingCADSpec {
        let buildingID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let groundID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let upperID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let roomA = UUID(uuidString: "10000000-0000-4000-8000-000000000011")!
        let roomB = UUID(uuidString: "10000000-0000-4000-8000-000000000012")!
        let roomC = UUID(uuidString: "10000000-0000-4000-8000-000000000013")!
        let door = UUID(uuidString: "10000000-0000-4000-8000-000000000021")!
        let window = UUID(uuidString: "10000000-0000-4000-8000-000000000022")!
        let ground = FloeBuildingCADStoreySpec(
            id: groundID, name: "Ground", elevationMM: 0, heightMM: 3000,
            rooms: [
                FloeBuildingCADRoomSpec(
                    id: roomA, name: "Living", minimum: [0, 0], maximum: [4000, 3000],
                    heightMM: 3000, wallThicknessMM: 200,
                    openings: [
                        FloeBuildingCADOpeningSpec(
                            id: door, kind: .door, name: "Entry", wallIndex: 0,
                            offsetMM: 500, widthMM: 900, heightMM: 2100, baseOffsetMM: 0),
                        FloeBuildingCADOpeningSpec(
                            id: window, kind: .window, name: "Shared window", wallIndex: 1,
                            offsetMM: 400, widthMM: 1200, heightMM: 1200, baseOffsetMM: 900),
                    ]),
                FloeBuildingCADRoomSpec(
                    id: roomB, name: "Dining", minimum: [4200, 0], maximum: [8200, 3000],
                    heightMM: 3000, wallThicknessMM: 200, openings: []),
            ])
        let upper = FloeBuildingCADStoreySpec(
            id: upperID, name: "Upper", elevationMM: 3000, heightMM: 2700,
            rooms: [
                FloeBuildingCADRoomSpec(
                    id: roomC, name: "Bedroom", minimum: [0, 0], maximum: [3000, 3000],
                    heightMM: 2700, wallThicknessMM: 200, openings: []),
            ])
        return FloeBuildingCADSpec(id: buildingID, name: "Shared wall house",
                                   storeys: [ground, upper])
    }

    static func sharedWallSpec() -> FloeBuildingCADSpec {
        let buildingID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let storeyID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let roomA = UUID(uuidString: "20000000-0000-4000-8000-000000000011")!
        let roomB = UUID(uuidString: "20000000-0000-4000-8000-000000000012")!
        return FloeBuildingCADSpec(
            id: buildingID, name: "Adjacent rooms",
            storeys: [FloeBuildingCADStoreySpec(
                id: storeyID, name: "Ground", elevationMM: 0, heightMM: 3000,
                rooms: [
                    FloeBuildingCADRoomSpec(
                        id: roomA, name: "Left", minimum: [0, 0], maximum: [4000, 3000],
                        heightMM: 3000, wallThicknessMM: 200, openings: []),
                    FloeBuildingCADRoomSpec(
                        id: roomB, name: "Right", minimum: [4200, 0], maximum: [8200, 3000],
                        heightMM: 3000, wallThicknessMM: 200, openings: []),
                ])])
    }

    static func partialWallSpec() -> FloeBuildingCADSpec {
        let buildingID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let storeyID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
        let roomA = UUID(uuidString: "30000000-0000-4000-8000-000000000011")!
        let roomB = UUID(uuidString: "30000000-0000-4000-8000-000000000012")!
        return FloeBuildingCADSpec(
            id: buildingID, name: "Partial overlap",
            storeys: [FloeBuildingCADStoreySpec(
                id: storeyID, name: "Ground", elevationMM: 0, heightMM: 3000,
                rooms: [
                    FloeBuildingCADRoomSpec(
                        id: roomA, name: "Left", minimum: [0, 0], maximum: [4000, 3000],
                        heightMM: 3000, wallThicknessMM: 200, openings: []),
                    FloeBuildingCADRoomSpec(
                        id: roomB, name: "Right", minimum: [4200, 1000], maximum: [8200, 4000],
                        heightMM: 3000, wallThicknessMM: 200, openings: []),
                ])])
    }

    static func invalidOpeningSpec() -> FloeBuildingCADSpec {
        var spec = sharedWallSpec()
        let opening = FloeBuildingCADOpeningSpec(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000099")!,
            kind: .door, name: "Too wide", wallIndex: 0,
            offsetMM: 3800, widthMM: 900, heightMM: 2100, baseOffsetMM: 0)
        spec.storeys[0].rooms[0].openings = [opening]
        return spec
    }

    static func syntheticCubeOBJ(origin: [Double] = [0, 0, 0],
                                 size: [Double] = [2, 4, 2]) -> String {
        let x0 = origin[0], y0 = origin[1], z0 = origin[2]
        let x1 = x0 + size[0], y1 = y0 + size[1], z1 = z0 + size[2]
        func v(_ x: Double, _ y: Double, _ z: Double) -> String { "v \(x) \(y) \(z)" }
        return """
        o SyntheticCube
        \(v(x0, y0, z0))
        \(v(x1, y0, z0))
        \(v(x1, y1, z0))
        \(v(x0, y1, z0))
        \(v(x0, y0, z1))
        \(v(x1, y0, z1))
        \(v(x1, y1, z1))
        \(v(x0, y1, z1))
        f 1 2 3
        f 1 3 4
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
    }

    static func syntheticCubeInput(instanceID: UUID = UUID()) -> FurniturePlacementInput {
        .init(instanceID: instanceID, roomID: nil,
              assetID: "synthetic-cube", assetVersion: "1",
              sourceSHA256: String(repeating: "a", count: 64),
              dependencySHA256: [:],
              sourceBounds: .init(minimum: .init(0, 0, 0), maximum: .init(2, 4, 2)),
              orientation: .cadYUp,
              sizing: .sourceUnits(millimetresPerUnit: 100),
              pose: .init(planXMM: 500, planYMM: 500, floorElevationMM: 0,
                          elevationAboveFloorMM: 0, yawDegrees: 30,
                          anchor: .bottomCenter))
    }

    /// A fixture with a nested primary, an MTL in a different directory and
    /// two textures that share the basename but live in different folders.
    static func texturedFurnitureFixture(root: URL) throws
        -> (primary: URL, resources: FloeBuildingCADFurnitureResources,
            input: FurniturePlacementInput) {
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        let aDir = root.appendingPathComponent("Textures/a", isDirectory: true)
        let bDir = root.appendingPathComponent("Textures/b", isDirectory: true)
        for url in [models, materials, aDir, bDir] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let primary = models.appendingPathComponent("chair.obj")
        let mtl = materials.appendingPathComponent("chair.mtl")
        let textureA = aDir.appendingPathComponent("wood.png")
        let textureB = bDir.appendingPathComponent("wood.png")
        let pngRed = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0ZkAAAAASUVORK5CYII="))
        let pngBlue = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try pngRed.write(to: textureA)
        try pngBlue.write(to: textureB)
        let obj = """
        mtllib ../Materials/chair.mtl
        o Body
        v 0 0 0
        v 2 0 0
        v 2 4 0
        v 0 4 0
        v 0 0 2
        v 2 0 2
        v 2 4 2
        v 0 4 2
        usemtl red
        f 1 2 3
        f 1 3 4
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        usemtl blue
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
        try obj.write(to: primary, atomically: true, encoding: .utf8)
        let mtlText = """
        newmtl red
        Kd 1 0 0
        map_Kd ../Textures/a/wood.png
        newmtl blue
        Kd 0 0 1
        map_Kd ../Textures/b/wood.png
        """
        try mtlText.write(to: mtl, atomically: true, encoding: .utf8)
        let mtlData = try Data(contentsOf: mtl)
        let hashes = [
            "Materials/chair.mtl": FloeBuildingCADGeometry.sha256(mtlData),
            "Textures/a/wood.png": FloeBuildingCADGeometry.sha256(pngRed),
            "Textures/b/wood.png": FloeBuildingCADGeometry.sha256(pngBlue),
        ]
        let primaryData = try Data(contentsOf: primary)
        let input = FurniturePlacementInput(
            instanceID: UUID(), roomID: nil,
            assetID: "textured-chair", assetVersion: "1",
            sourceSHA256: FloeBuildingCADGeometry.sha256(primaryData),
            dependencySHA256: hashes,
            sourceBounds: .init(minimum: .init(0, 0, 0), maximum: .init(2, 4, 2)),
            orientation: .cadYUp,
            sizing: .sourceUnits(millimetresPerUnit: 100),
            pose: .init(planXMM: 1000, planYMM: 700, floorElevationMM: 0,
                        elevationAboveFloorMM: 0, yawDegrees: 15,
                        anchor: .bottomCenter))
        let resources = FloeBuildingCADFurnitureResources(
            rootURL: root,
            dependencyFiles: [
                "Materials/chair.mtl": mtl,
                "Textures/a/wood.png": textureA,
                "Textures/b/wood.png": textureB,
            ])
        return (primary, resources, input)
    }

    static func assemblyInstanceIDs(_ document: FloeCADDocument) -> Set<UUID> {
        let reply = CADAssemblyService(document: document).handle(action: "instances", args: [:])
        let rows = reply["instances"] as? [[String: Any]] ?? []
        return Set(rows.compactMap { UUID(uuidString: $0["id"] as? String ?? "") })
    }

    static func pageGeometry(_ document: FloeCADDocument, pageID: UUID) -> [String: Any] {
        CADDrawingService(document: document).pageGeometry(pageID: pageID)
    }

    static func autoValues(_ payload: [String: Any]) -> [Double] {
        (payload["dimensions"] as? [[String: Any]] ?? []).compactMap {
            ($0["value"] as? NSNumber)?.doubleValue
        }
    }

    static func manualValues(_ payload: [String: Any],
                             sheet: FloeBuildingCADSheetBinding) -> [String: Double] {
        let rows = payload["manualDimensions"] as? [[String: Any]] ?? []
        var result: [String: Double] = [:]
        for binding in sheet.dimensionBindings {
            guard let row = rows.first(where: {
                ($0["id"] as? String) == binding.dimensionID.uuidString
            }), let value = (row["value"] as? NSNumber)?.doubleValue else { continue }
            result[binding.role] = value
        }
        return result
    }

    static func fingerprintInstanceIDs(_ payload: [String: Any]) -> Set<UUID> {
        guard let page = payload["page"] as? [String: Any],
              let fingerprint = page["sourceFingerprint"] as? [String: Any],
              let instances = fingerprint["instances"] as? [[String: Any]] else { return [] }
        return Set(instances.compactMap {
            UUID(uuidString: ($0["instanceID"] as? String) ?? "")
        })
    }

    static func hasValue(_ values: [Double], _ expected: Double,
                         tolerance: Double = 0.5) -> Bool {
        values.contains { abs($0 - expected) <= tolerance }
    }

    static func manifestRoundtrip(_ manifest: FloeBuildingCADManifest) throws
        -> FloeBuildingCADManifest {
        let data = try JSONEncoder().encode(manifest)
        return try JSONDecoder().decode(FloeBuildingCADManifest.self, from: data)
    }
}
#endif

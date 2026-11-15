import Foundation
import FloeBuildingProject
import FloeBuildingRecords

enum ProjectTestSupport {
    static func makeSpace(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBuildingProjectTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func hex(_ character: Character, count: Int = 64) -> String {
        String(repeating: String(character), count: count)
    }

    static func makeCADDirectory(at url: URL) throws {
        try write("{\"format\":\"floecad\",\"revision\":7}", to: url.appendingPathComponent("model.json"))
        try write(Data([0, 1, 2, 3, 4, 5, 6, 7]), to: url.appendingPathComponent("geometry/mesh.bin"))
        try write("native-cad-staging", to: url.appendingPathComponent("meta/native.txt"))
    }

    static func makeAssetResourceDirectory(at url: URL) throws {
        try write("""
        # synthetic armchair
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """, to: url.appendingPathComponent("armchair.obj"))
        try write("""
        newmtl fabric
        map_Kd textures/armchair.png
        """, to: url.appendingPathComponent("armchair.mtl"))
        try write(Data([137, 80, 78, 71, 1, 2, 3]), to: url.appendingPathComponent("textures/armchair.png"))
        try write("CC0 synthetic test resource", to: url.appendingPathComponent("LICENSE.txt"))
    }

    static func makeEditorState(projectID: ProjectID, roomID: RoomID) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "projectID": projectID.description,
            "rooms": [
                ["roomID": roomID.description, "nativeSpaceID": "space-1"]
            ],
            "cabinets": [
                [
                    "cabinetID": "cabinet-1",
                    "nativeBodyIDs": ["body-1"],
                    "recipeID": "between-sides-inset-back",
                    "recipeVersion": "1"
                ]
            ],
            "furniture": [
                [
                    "instanceID": "chair-1",
                    "assetID": "armchair",
                    "assetVersion": "1.0.0",
                    "assetSHA256": hex("a")
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func makeIdentity(snapshot: ProjectRecordsSnapshot) throws -> BuildingStoredIdentity {
        try BuildingStoredIdentity(
            cadRevision: 7,
            cadContentSHA256: hex("a"),
            cadModelSHA256: hex("b"),
            recordsProjectID: snapshot.projectID,
            recordsRevision: snapshot.revision
        )
    }

    static func captureSnapshot(
        from store: ProjectRecordsStore,
        to url: URL
    ) throws -> ProjectRecordsSnapshot {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let revision = try store.currentRevision()
        return try store.captureSnapshot(
            to: url,
            projectID: store.projectID,
            expectedRevision: revision
        )
    }

    static func populate(_ store: ProjectRecordsStore) throws -> ProjectFixture {
        let projectID = store.projectID
        let room = try store.createRoom(
            RoomDraft(name: "Kitchen", storey: "1F", kind: .kitchen, aliases: ["Cook room"]),
            expectedRevision: 0
        )
        let manual = try store.importSource(
            SourceImportRequest(
                kind: .note,
                title: "Measurements",
                originalName: "measurements.txt",
                mediaType: "text/plain",
                data: Data("kitchen 3.6 m".utf8),
                roomIDs: [room.value.id]
            ),
            expectedRevision: room.receipt.revision
        )
        let observation = try store.recordObservation(
            ObservationDraft(
                roomID: room.value.id,
                propertyKey: "room.length_m",
                rawValue: "kitchen 3.6 m",
                normalizedValue: try RecordedValue(number: 3.6, unit: "m"),
                sourceVersionID: manual.value.version.id
            ),
            expectedRevision: manual.receipt.revision
        )
        let component = try store.importSource(
            SourceImportRequest(
                kind: .other,
                title: "Cabinet binding component",
                originalName: "component.json",
                mediaType: "application/json",
                data: Data("{\"schemaVersion\":1,\"payload\":{}}".utf8)
            ),
            expectedRevision: observation.receipt.revision
        )
        let csv = """
        Brand,Model,Quantity,Unit,Room,Role,Product
        Example,SW-2G,2,台,Kitchen,design,Switch
        """
        let table = try store.importSource(
            SourceImportRequest(
                kind: .table,
                title: "BOM",
                originalName: "bom.csv",
                mediaType: "text/csv",
                data: Data(csv.utf8)
            ),
            expectedRevision: component.receipt.revision
        )
        let target = try store.createBOMTarget(
            name: "Smart Home",
            expectedRevision: table.receipt.revision
        )
        let draft = try store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: table.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        let applied = try store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        return ProjectFixture(
            projectID: projectID,
            roomID: room.value.id,
            sourceID: manual.value.source.id,
            sourceVersionID: manual.value.version.id,
            observationID: observation.value.id,
            targetID: target.value.id,
            adoptedItemCount: applied.value.adoptedItemIDs.count,
            revision: applied.receipt.revision
        )
    }
}

struct ProjectFixture {
    let projectID: ProjectID
    let roomID: RoomID
    let sourceID: SourceID
    let sourceVersionID: SourceVersionID
    let observationID: ObservationID
    let targetID: BOMTargetID
    let adoptedItemCount: Int
    let revision: Int
}

// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADBuildingTests: XCTestCase {
    @MainActor
    func testAdjacentRoomsShareOneExactWallAndReopen() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("shared-wall")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let binding = try await session.createBuilding(FloeBuildingCADTestSupport.sharedWallSpec())
        let model = try XCTUnwrap(try session.building())
        let walls = model.elements.filter { $0.kind == .wall }
        XCTAssertEqual(walls.count, 7, "Two adjacent rooms must share one exact wall instead of stacking eight.")
        XCTAssertEqual(Set(walls.map(\.id)).count, 7)
        let left = try XCTUnwrap(binding.rooms.first { $0.name == "Left" })
        let right = try XCTUnwrap(binding.rooms.first { $0.name == "Right" })
        XCTAssertEqual(left.wallIDs[1], right.wallIDs[3],
                       "The left east wall and right west wall must be the same native wall id.")
        XCTAssertEqual(walls.filter { $0.id == left.wallIDs[1] }.count, 1)
        XCTAssertEqual(model.elements.filter { $0.kind == .space }.count, 2)
        XCTAssertEqual(model.elements.count, 2 + 7)

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let saved = try XCTUnwrap(try reopened.building())
        XCTAssertEqual(saved.elements.map(\.id), model.elements.map(\.id))
        XCTAssertEqual(saved.elements.filter { $0.kind == .wall }.count, 7)
        XCTAssertEqual(Set(saved.elements.filter { $0.kind == .wall }.map(\.id)).count, 7)
    }

    @MainActor
    func testMultipleStoreysDoorWindowAndEditableWallKeepIdentity() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("building-edit")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let binding = try await session.createBuilding(FloeBuildingCADTestSupport.buildingSpec())
        var model = try XCTUnwrap(try session.building())
        XCTAssertEqual(model.storeys.count, 2)
        let spaces = model.elements.filter { $0.kind == .space }
        XCTAssertEqual(spaces.count, 3)
        let doors = model.elements.filter { $0.kind == .door }
        let windows = model.elements.filter { $0.kind == .window }
        XCTAssertEqual(doors.count, 1)
        XCTAssertEqual(windows.count, 1)
        let wallIDs = Set(model.elements.filter { $0.kind == .wall }.map(\.id))
        XCTAssertTrue(wallIDs.contains(try XCTUnwrap(doors.first?.hostID)))
        XCTAssertTrue(wallIDs.contains(try XCTUnwrap(windows.first?.hostID)))
        XCTAssertEqual(model.elements.filter { $0.kind == .wall }.count, 11)
        let originalIDs = model.elements.map(\.id)

        // Extend the shared ground wall; the authored element and host ids
        // must stay stable in the same Building transaction.
        let sharedID = try XCTUnwrap(binding.rooms.first { $0.name == "Living" }?.wallIDs[1])
        let index = try XCTUnwrap(model.elements.firstIndex(where: { $0.id == sharedID }))
        model.elements[index].b = [model.elements[index].b[0], 3500]
        let updated = try await session.applyBuilding(model)
        let edited = try XCTUnwrap(try session.building())
        XCTAssertEqual(edited.elements.map(\.id), originalIDs)
        XCTAssertEqual(edited.elements.filter { $0.kind == .wall }.count, 11)
        XCTAssertTrue(updated.rooms.contains { $0.wallIDs.contains(sharedID) })

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let persisted = try XCTUnwrap(try reopened.building())
        XCTAssertEqual(persisted.elements.map(\.id), originalIDs)
        XCTAssertEqual(persisted.storeys.count, 2)
        XCTAssertEqual(persisted.elements.filter { $0.kind == .door }.count, 1)
        XCTAssertEqual(persisted.elements.filter { $0.kind == .window }.count, 1)
    }


    @MainActor
    func testApplyBuildingReprojectsAddedRenamedMovedAndDeletedRooms() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("room-reproject")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let binding = try await session.createBuilding(FloeBuildingCADTestSupport.sharedWallSpec())
        var model = try XCTUnwrap(try session.building())
        let left = try XCTUnwrap(binding.rooms.first { $0.name == "Left" })
        let right = try XCTUnwrap(binding.rooms.first { $0.name == "Right" })
        let leftSpaceIndex = try XCTUnwrap(model.elements.firstIndex { $0.id == left.roomID })
        let rightSpaceID = right.roomID
        var upper = CADBuildingStorey(name: "Upper", elevationMM: 3000, heightMM: 3000)
        upper.id = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
        model.storeys.append(upper)
        model.elements[leftSpaceIndex].name = "Renamed living"
        model.elements[leftSpaceIndex].storeyID = upper.id
        let newRoomID = UUID(uuidString: "40000000-0000-4000-8000-000000000099")!
        var newRoom = CADBuildingElement(
            storeyID: model.storeys[0].id, kind: .space, name: "New room",
            a: [9000, 0], b: [12000, 3000], thicknessMM: 200, heightMM: 3000)
        newRoom.id = newRoomID
        model.elements.append(newRoom)
        model.elements.removeAll { $0.id == rightSpaceID }

        let updated = try await session.applyBuilding(model)
        XCTAssertEqual(updated.rooms.count, 2)
        let renamed = try XCTUnwrap(updated.rooms.first { $0.roomID == left.roomID })
        XCTAssertEqual(renamed.name, "Renamed living")
        XCTAssertEqual(renamed.storeyID, upper.id)
        XCTAssertEqual(renamed.wallIDs, left.wallIDs)
        let added = try XCTUnwrap(updated.rooms.first { $0.roomID == newRoomID })
        XCTAssertEqual(added.name, "New room")
        XCTAssertTrue(added.wallIDs.isEmpty)
        XCTAssertFalse(updated.rooms.contains { $0.roomID == rightSpaceID })

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let reopenedBinding = try XCTUnwrap(reopened.manifest.building)
        XCTAssertEqual(reopenedBinding.rooms.count, 2)
        XCTAssertEqual(reopenedBinding.rooms.first { $0.roomID == left.roomID }?.name,
                       "Renamed living")
        XCTAssertTrue(reopenedBinding.rooms.contains { $0.roomID == newRoomID })
        XCTAssertFalse(reopenedBinding.rooms.contains { $0.roomID == rightSpaceID })
        let saved = try XCTUnwrap(try reopened.building())
        XCTAssertEqual(saved.elements.filter { $0.kind == .space }.count, 2)
    }

    @MainActor
    func testPartialCollinearWallOverlapIsRejectedWithoutWrites() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("partial-wall")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let before = session.document.summary()
        do {
            _ = try await session.createBuilding(FloeBuildingCADTestSupport.partialWallSpec())
            XCTFail("A partial shared wall must be refused instead of stacked or silently split.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Partial or conflicting"), message)
        }
        let absent = try session.building()
        XCTAssertNil(absent)
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
        XCTAssertEqual(session.document.summary().featureCount, before.featureCount)
    }

    @MainActor
    func testInvalidOpeningIsRejectedBeforeBuildingTransaction() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("invalid-opening")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let before = session.document.summary()
        do {
            _ = try await session.createBuilding(FloeBuildingCADTestSupport.invalidOpeningSpec())
            XCTFail("An opening outside its host wall must fail validation.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let absent = try session.building()
        XCTAssertNil(absent)
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
    }
}
#endif

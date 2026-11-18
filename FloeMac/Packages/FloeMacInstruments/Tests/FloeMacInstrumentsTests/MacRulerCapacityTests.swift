// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeToolboxUtilities
@testable import FloeMacInstruments

@MainActor
final class MacRulerCapacityTests: XCTestCase {
    private func display(_ identity: String, topology: UUID, id: UInt32) -> MacDisplayIdentity {
        MacDisplayIdentity(displayID: id, nativeScale: 2,
            size: CGSize(width: 1200, height: 900), name: "Display", stableID: identity, topologyID: topology)
    }

    func testSeventeenTopologiesRequireExplicitReviewedCleanupThenRecover() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-capacity-17")
        defer { MacToolboxTestRoot.remove(root) }
        let url = root.appendingPathComponent("ruler.json")
        let store = MacRulerCalibrationStore(url: url), activity = MacInstrumentActivityCoordinator()
        let model = MacRulerModel(store: store, activity: activity)
        for id in 0..<16 {
            let topology = UUID()
            await model.load(display: display("unverified:\(topology):\(id)", topology: topology, id: UInt32(id)))
            await model.calibrate(separation: 428)
            XCTAssertNil(model.storageFailure)
        }
        let original = try Data(contentsOf: url)
        let topology = UUID()
        let current = display("unverified:\(topology):17", topology: topology, id: 17)
        await model.load(display: current)
        await model.calibrate(separation: 428)
        XCTAssertEqual(model.storageFailure, .capacity)
        XCTAssertEqual(try Data(contentsOf: url), original, "Capacity must not silently evict records")
        let reviewed = model.obsoleteUnverifiedIDs
        XCTAssertEqual(reviewed.count, 16)
        model.requestRemoveObsoleteUnverified(expected: reviewed)
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertNil(model.storageFailure)
        await model.calibrate(separation: 428)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.map(\.stableID), [current.stableID])
    }

    func testCleanupPreservesReliableCurrentAndUnverifiableRecords() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-capacity-mixed")
        defer { MacToolboxTestRoot.remove(root) }
        let url = root.appendingPathComponent("ruler.json")
        let store = MacRulerCalibrationStore(url: url), activity = MacInstrumentActivityCoordinator()
        let model = MacRulerModel(store: store, activity: activity)
        let currentTopology = UUID()
        let reliable = display("display:1:2:3", topology: currentTopology, id: 1)
        let current = display("unverified:\(currentTopology):2", topology: currentTopology, id: 2)
        let malformed = display("unverified:not-a-uuid:3", topology: currentTopology, id: 3)
        for value in [reliable, current, malformed] {
            await model.load(display: value); await model.calibrate(separation: 428)
        }
        for id in 4..<17 {
            let topology = UUID()
            await model.load(display: display("unverified:\(topology):\(id)", topology: topology, id: UInt32(id)))
            await model.calibrate(separation: 428)
        }
        let newDisplay = display("unverified:\(currentTopology):18", topology: currentTopology, id: 18)
        await model.load(display: newDisplay); await model.calibrate(separation: 428)
        XCTAssertEqual(model.storageFailure, .capacity)
        let reviewed = model.obsoleteUnverifiedIDs
        XCTAssertEqual(reviewed.count, 13)
        let before = try Data(contentsOf: url)
        do {
            _ = try await store.removeObsoleteUnverified(expected: ["unverified:wrong:4"], currentTopology: currentTopology)
            XCTFail("A changed reviewed set must not be deleted")
        } catch MacRulerStoreError.changed { }
        XCTAssertEqual(try Data(contentsOf: url), before)
        model.requestRemoveObsoleteUnverified(expected: reviewed)
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        let retained = try await store.load()
        XCTAssertEqual(Set(retained.compactMap(\.stableID)), Set([reliable.stableID, current.stableID, malformed.stableID]))
        await model.calibrate(separation: 428)
        let final = try await store.load()
        XCTAssertEqual(final.count, 4)
        XCTAssertTrue(final.contains { $0.stableID == reliable.stableID })
    }
}

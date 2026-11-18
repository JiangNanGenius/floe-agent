// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import FloeMacInstruments
import FloeToolboxUtilities

@MainActor
final class MacRulerTests: XCTestCase {
    private let displayA = MacDisplayIdentity(
        displayID: 1, nativeScale: 2,
        size: CGSize(width: 3024, height: 1964), name: "Built-in Retina Display")
    private let displayB = MacDisplayIdentity(
        displayID: 2, nativeScale: 1,
        size: CGSize(width: 2560, height: 1440), name: "External Display")

    func testCalibrationIsPhysicalAndScopedToItsDisplay() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-scope")
        defer { MacToolboxTestRoot.remove(directory) }
        let store = MacRulerCalibrationStore(url: directory.appendingPathComponent("ruler.json"))
        let model = MacRulerModel(store: store)
        model.referencePreset = .custom
        model.customReferenceMillimeters = "85.6"
        await model.load(display: displayA)
        await model.calibrate(separation: 428)

        let ppm = try XCTUnwrap(model.pointsPerMillimeter)
        XCTAssertEqual(ppm, 5.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(model.millimeters(points: 500)), 100, accuracy: 0.0001)
        XCTAssertEqual(model.calibrationDisplayName, displayA.name)

        await model.load(display: displayB)
        XCTAssertNil(model.pointsPerMillimeter, "A calibration from display A must not measure display B")
        await model.load(display: displayA)
        XCTAssertEqual(try XCTUnwrap(model.pointsPerMillimeter), 5.0, accuracy: 0.0001)
    }

    func testCalibrationInvalidatesOnScaleAndResolutionBandChanges() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-compat")
        defer { MacToolboxTestRoot.remove(directory) }
        let store = MacRulerCalibrationStore(url: directory.appendingPathComponent("ruler.json"))
        let model = MacRulerModel(store: store)
        model.referencePreset = .custom
        model.customReferenceMillimeters = "100"
        await model.load(display: displayA)
        await model.calibrate(separation: 500)
        XCTAssertNotNil(model.pointsPerMillimeter)

        let scaled = MacDisplayIdentity(displayID: 1, nativeScale: 1,
                                        size: displayA.frameSize, name: displayA.name)
        await model.load(display: scaled)
        XCTAssertNil(model.pointsPerMillimeter, "Changing backing scale must invalidate calibration")

        let resized = MacDisplayIdentity(displayID: 1, nativeScale: 2,
                                         size: CGSize(width: 2560, height: 1440), name: displayA.name)
        await model.load(display: resized)
        XCTAssertNil(model.pointsPerMillimeter, "Changing the resolution band must invalidate calibration")
    }

    func testCorruptStoreIsPreservedAndReported() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-corrupt")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("ruler.json")
        let corrupt = Data("{ definitely not json".utf8)
        try corrupt.write(to: url)
        let store = MacRulerCalibrationStore(url: url)

        do {
            _ = try await store.load()
            XCTFail("Corrupt calibration must not load as an empty success")
        } catch MacRulerStoreError.corrupt {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "Corrupt source bytes must be preserved")

        let model = MacRulerModel(store: store)
        await model.load(display: displayA)
        XCTAssertEqual(model.storageFailure, .corrupt)
        XCTAssertNil(model.pointsPerMillimeter)
        await model.calibrate(separation: 500)
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "Recalibration must not overwrite corrupt bytes")
        XCTAssertEqual(model.storageFailure, .corrupt)
        XCTAssertNotNil(model.pointsPerMillimeter, "The user can still calibrate for this session")
        model.beginRecalibration()
        XCTAssertEqual(model.storageFailure, .corrupt)
        await model.calibrate(separation: 500)
        XCTAssertEqual(model.storageFailure, .corrupt)
        await model.clearCalibration()
        XCTAssertNil(model.pointsPerMillimeter)
        XCTAssertEqual(model.storageFailure, .corrupt)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testStableIdentitySurvivesRestartAndUnverifiedIdentityDoesNot() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-restart")
        defer { MacToolboxTestRoot.remove(directory) }
        let store = MacRulerCalibrationStore(url: directory.appendingPathComponent("ruler.json"))
        let sessionA = UUID(), sessionB = UUID()
        func display(_ stable: String, _ topology: UUID, id: UInt32 = 1, mode: String = "native") -> MacDisplayIdentity {
            MacDisplayIdentity(displayID: id, nativeScale: 2, size: CGSize(width: 1440, height: 900), name: "Fake", modeKey: mode, stableID: stable, topologyID: topology)
        }
        let first = MacRulerModel(store: store)
        await first.load(display: display("display:1:2:3", sessionA))
        await first.calibrate(separation: 400)
        let restarted = MacRulerModel(store: store)
        await restarted.load(display: display("display:1:2:3", sessionB, id: 9))
        XCTAssertNotNil(restarted.pointsPerMillimeter)
        await restarted.load(display: display("display:1:2:3", sessionB, id: 9, mode: "different"))
        XCTAssertNil(restarted.pointsPerMillimeter)
        await restarted.load(display: display("display:1:2:4", sessionB))
        XCTAssertNil(restarted.pointsPerMillimeter)
        let volatile = MacRulerModel(store: store)
        await volatile.load(display: display("unverified:\(sessionA)", sessionA))
        await volatile.calibrate(separation: 400)
        let volatileRestart = MacRulerModel(store: store)
        await volatileRestart.load(display: display("unverified:\(sessionB)", sessionB))
        XCTAssertNil(volatileRestart.pointsPerMillimeter)
    }

    func testEvenSmallModeChangeAndUnknownDisplayInvalidateCalibration() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-mode")
        defer { MacToolboxTestRoot.remove(directory) }
        let model = MacRulerModel(store: MacRulerCalibrationStore(url: directory.appendingPathComponent("ruler.json")))
        let first = MacDisplayIdentity(displayID: 2, nativeScale: 2, size: CGSize(width: 1440, height: 900), name: "Fake", modeKey: "mode-a")
        let changed = MacDisplayIdentity(displayID: 2, nativeScale: 2, size: CGSize(width: 1441, height: 900), name: "Fake", modeKey: "mode-b")
        await model.load(display: first)
        await model.calibrate(separation: 400)
        XCTAssertNotNil(model.pointsPerMillimeter)
        model.invalidateDisplay()
        XCTAssertNil(model.pointsPerMillimeter)
        await model.load(display: changed)
        XCTAssertNil(model.pointsPerMillimeter)
        await model.load(display: nil)
        XCTAssertNil(model.pointsPerMillimeter)
    }

    func testSavedCalibrationIsOwnerReadableOnly() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("ruler-permissions")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("ruler.json")
        let store = MacRulerCalibrationStore(url: url)
        let calibration = try EverydayRulerGeometry.calibrate(
            knownMillimeters: 85.6, measuredPoints: 428, nativeScale: 2,
            viewportKey: displayA.viewportKey)
        let record = MacRulerCalibrationRecord(calibration: calibration, display: displayA)
        try await store.save([record])

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(permissions & 0o777, 0o600)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [record])
    }

    func testAngleUsesTheSameGeometryAsTheSharedToolbox() {
        let model = MacRulerModel(store: MacRulerCalibrationStore(url: URL(fileURLWithPath: "/nonexistent")))
        model.vertex = CGPoint(x: 0, y: 0)
        model.armEnd1 = CGPoint(x: 100, y: 0)
        model.armEnd2 = CGPoint(x: 0, y: 100)
        XCTAssertEqual(try XCTUnwrap(model.angleDegrees()), 90, accuracy: 0.0001)
    }
}

private extension MacDisplayIdentity {
    var frameSize: CGSize { CGSize(width: widthPoints, height: heightPoints) }
}

// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import FloeMacInstruments
import FloeToolboxUtilities

@MainActor
final class MacLocationTests: XCTestCase {
    func testPermissionResultAfterInactiveOrCloseNeedsExplicitRestart() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-permission-inactive")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        let model = makeModel(source: source, archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")))
        model.start()
        XCTAssertEqual(model.phase, .permission)
        model.stop() // Window close or app resignation fences permission completion.
        source.authorization = .authorized
        source.emit(.authorizationChanged(.authorized))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(source.startTokens.isEmpty)
        model.start() // Explicitly returning and starting is required.
        XCTAssertEqual(source.startTokens.count, 1)
        model.stop()
        source.emit(.authorizationChanged(.authorized))
        XCTAssertEqual(source.startTokens.count, 1)
        XCTAssertEqual(model.phase, .idle)
    }
    func testStreamGateRejectsOldManagerAndCachedOrFutureFixes() {
        let old = NSObject(), current = NSObject()
        let start = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 105)
        XCTAssertFalse(MacLocationCallbackGate.accepts(sender: old, active: current, startedAt: start, timestamp: now, now: now))
        XCTAssertFalse(MacLocationCallbackGate.accepts(sender: current, active: current, startedAt: start, timestamp: start.addingTimeInterval(-1), now: now))
        XCTAssertFalse(MacLocationCallbackGate.accepts(sender: current, active: current, startedAt: start, timestamp: now.addingTimeInterval(2), now: now))
        XCTAssertTrue(MacLocationCallbackGate.accepts(sender: current, active: current, startedAt: start, timestamp: now, now: now))
        XCTAssertFalse(MacLocationCallbackGate.accepts(sender: current, active: nil, startedAt: nil, timestamp: now, now: now))
    }
    private func makeModel(source: FakeLocationSource,
                           archive: ToolboxLocationArchive) -> MacLocationModel {
        MacLocationModel(source: source, archive: archive)
    }

    func testStartRequestsPermissionOnceThenBeginsAfterAuthorization() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-start")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        let model = makeModel(source: source,
                              archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")))

        model.start()
        XCTAssertEqual(model.phase, .permission)
        XCTAssertEqual(source.authorizationRequests, 1)
        model.start()
        XCTAssertEqual(source.authorizationRequests, 1, "The single system prompt must not be spent twice")

        source.authorization = .authorized
        source.emit(.authorizationChanged(.authorized))
        XCTAssertEqual(model.phase, .locating)
        XCTAssertEqual(source.startTokens.count, 1)

        source.emitFix(latitude: -33.8688, longitude: 151.2093, accuracy: 8)
        XCTAssertEqual(model.phase, .live)
        XCTAssertEqual(model.fix?.latitude ?? 0, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(model.fix?.horizontalAccuracy ?? 0, 8, accuracy: 1e-9)
    }

    func testPauseStopsUpdatesAndRejectsALateFix() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-pause")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        source.authorization = .authorized
        let model = makeModel(source: source,
                              archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")))
        model.start()
        XCTAssertEqual(model.phase, .locating)
        source.emitFix(accuracy: 5)
        XCTAssertEqual(model.phase, .live)
        let firstFix = try XCTUnwrap(model.fix)

        model.pause()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(source.stopCount, 1)
        source.emitFix(latitude: 0, longitude: 0, accuracy: 1)
        XCTAssertEqual(model.fix, firstFix, "A callback from the stopped stream must not replace the paused fix")
        XCTAssertEqual(model.phase, .paused)
    }

    func testDeniedRestrictedAndDisabledNeverStartSampling() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-denied")
        defer { MacToolboxTestRoot.remove(directory) }
        let archive = ToolboxLocationArchive(url: directory.appendingPathComponent("places.json"))

        let denied = FakeLocationSource()
        denied.authorization = .denied
        let deniedModel = makeModel(source: denied, archive: archive)
        deniedModel.start()
        XCTAssertEqual(deniedModel.phase, .denied)
        XCTAssertTrue(denied.startTokens.isEmpty)

        let restricted = FakeLocationSource()
        restricted.authorization = .restricted
        let restrictedModel = makeModel(source: restricted, archive: archive)
        restrictedModel.start()
        XCTAssertEqual(restrictedModel.phase, .restricted)
        XCTAssertTrue(restricted.startTokens.isEmpty)

        let disabled = FakeLocationSource()
        disabled.servicesEnabled = false
        let disabledModel = makeModel(source: disabled, archive: archive)
        disabledModel.start()
        XCTAssertEqual(disabledModel.phase, .disabled)
        XCTAssertTrue(disabled.startTokens.isEmpty)
    }

    func testSavedPlacesRoundTripAndRemoval() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-places")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        source.authorization = .authorized
        let archive = ToolboxLocationArchive(url: directory.appendingPathComponent("places.json"))
        let model = makeModel(source: source, archive: archive)
        model.start()
        source.emitFix(latitude: 51.5074, longitude: -0.1278, accuracy: 10)
        await model.savePlace("  London  ")
        XCTAssertEqual(model.places.count, 1)
        XCTAssertEqual(model.places.first?.name, "London")

        let second = makeModel(source: FakeLocationSource(), archive: archive)
        await second.loadPlaces()
        XCTAssertEqual(second.places.count, 1)
        let id = try XCTUnwrap(second.places.first?.id)
        await second.removePlace(id: id)
        XCTAssertTrue(second.places.isEmpty)
        await model.loadPlaces()
        XCTAssertTrue(model.places.isEmpty)
    }

    func testShutdownReleasesTheCallbackAndStopsSampling() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-shutdown")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        source.authorization = .authorized
        let model = makeModel(source: source,
                              archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")))
        model.start()
        XCTAssertNotNil(source.onEvent)
        model.shutdown()
        XCTAssertNil(source.onEvent)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertGreaterThanOrEqual(source.stopCount, 1)
    }

    func testPrecisionChangeIsReportedWithoutChangingTheFix() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-precision")
        defer { MacToolboxTestRoot.remove(directory) }
        let source = FakeLocationSource()
        source.authorization = .authorized
        let model = makeModel(source: source,
                              archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")))
        model.start()
        source.emitFix()
        let fix = model.fix
        source.emit(.precisionChanged(false))
        XCTAssertFalse(model.precise)
        XCTAssertEqual(model.fix, fix)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeMacInstruments
import FloeToolboxUtilities

@MainActor
final class MacInstrumentActivityTests: XCTestCase {
    func testTerminationCancelsButWaitsForActualCompletionAndCanResume() async throws {
        let activity = MacInstrumentActivityCoordinator()
        let token = try XCTUnwrap(activity.begin())
        var cancelCount = 0
        activity.onCancel(token) { cancelCount += 1 }
        activity.closeAdmissions()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertNil(activity.begin())
        let unfinished = await activity.drain(timeout: 0.05)
        XCTAssertFalse(unfinished)
        activity.finish(token)
        let drained = await activity.drain(timeout: 0.05)
        XCTAssertTrue(drained)
        activity.resumeAfterCancelledTermination()
        XCTAssertNotNil(activity.begin())
    }

    func testTerminationStopsLocationAndFencesLatePermission() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("location-termination")
        defer { MacToolboxTestRoot.remove(directory) }
        let activity = MacInstrumentActivityCoordinator()
        let source = FakeLocationSource()
        let model = MacLocationModel(source: source,
            archive: ToolboxLocationArchive(url: directory.appendingPathComponent("places.json")),
            activity: activity)
        model.activateLifecycle()
        model.start()
        XCTAssertEqual(source.authorizationRequests, 1)
        activity.closeAdmissions()
        source.authorization = .authorized
        source.emit(.authorizationChanged(.authorized))
        model.start()
        XCTAssertTrue(source.startTokens.isEmpty)
        activity.resumeAfterCancelledTermination()
        model.start()
        XCTAssertEqual(source.startTokens.count, 1)
    }

    func testModelsRejectNewWritesWhileTerminatingAndResumeAfterwards() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("instrument-admissions")
        defer { MacToolboxTestRoot.remove(directory) }
        let activity = MacInstrumentActivityCoordinator()
        let source = FakeLocationSource()
        source.authorization = .authorized
        let placesURL = directory.appendingPathComponent("places.json")
        let location = MacLocationModel(source: source, archive: ToolboxLocationArchive(url: placesURL), activity: activity)
        location.activateLifecycle()
        location.start()
        source.emitFix()
        let rulerURL = directory.appendingPathComponent("ruler.json")
        let ruler = MacRulerModel(store: MacRulerCalibrationStore(url: rulerURL), activity: activity)
        let display = MacDisplayIdentity(displayID: 1, nativeScale: 2,
                                         size: CGSize(width: 3024, height: 1964), name: "Fixture")
        await ruler.load(display: display)
        let photo = MacPhotoMeasureModel(unit: .millimeter, activity: activity)
        await photo.load(data: try SyntheticImage.png(width: 40, height: 40))
        photo.addReferencePoint(pixel: PhotoPoint(0, 0))
        photo.addReferencePoint(pixel: PhotoPoint(20, 0))
        photo.referenceValueText = "10"
        photo.applyCalibration()
        let imageURL = directory.appendingPathComponent("image.png")
        activity.closeAdmissions()
        await location.savePlace("Fixture")
        await ruler.calibrate(separation: 428)
        photo.exportAnnotatedPNG(to: imageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: placesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        activity.resumeAfterCancelledTermination()
        await location.savePlace("Fixture")
        await ruler.calibrate(separation: 428)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placesURL.path))
        XCTAssertNotNil(ruler.calibration)
    }

    func testTerminationDrainsPendingPhotoExport() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-termination")
        defer { MacToolboxTestRoot.remove(directory) }
        let activity = MacInstrumentActivityCoordinator()
        let photo = MacPhotoMeasureModel(unit: .millimeter, activity: activity)
        await photo.load(data: try SyntheticImage.png(width: 40, height: 40))
        photo.addReferencePoint(pixel: PhotoPoint(0, 0))
        photo.addReferencePoint(pixel: PhotoPoint(20, 0))
        photo.referenceValueText = "10"
        photo.applyCalibration()
        let target = directory.appendingPathComponent("export.png")
        photo.exportAnnotatedPNG(to: target)
        activity.closeAdmissions()
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testAcceptedButtonWritesAreReservedBeforeTheirTasksStart() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("instrument-queued-write")
        defer { MacToolboxTestRoot.remove(directory) }
        let activity = MacInstrumentActivityCoordinator()
        let source = FakeLocationSource()
        source.authorization = .authorized
        let placesURL = directory.appendingPathComponent("places.json")
        let location = MacLocationModel(source: source, archive: ToolboxLocationArchive(url: placesURL), activity: activity)
        location.activateLifecycle()
        location.start()
        source.emitFix()
        let rulerURL = directory.appendingPathComponent("ruler.json")
        let ruler = MacRulerModel(store: MacRulerCalibrationStore(url: rulerURL), activity: activity)
        await ruler.load(display: MacDisplayIdentity(displayID: 1, nativeScale: 2,
            size: CGSize(width: 3024, height: 1964), name: "Fixture"))
        XCTAssertTrue(location.requestSavePlace("Queued"))
        ruler.requestCalibration(separation: 428)
        activity.closeAdmissions()
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placesURL.path))
        // An unverified synthetic display retains calibration in memory only.
        XCTAssertNotNil(ruler.calibration)
        XCTAssertFalse(location.requestSavePlace("Too late"))
    }
}

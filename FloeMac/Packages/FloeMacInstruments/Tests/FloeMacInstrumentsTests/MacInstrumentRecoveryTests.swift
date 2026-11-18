// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeToolboxUtilities
@testable import FloeMacInstruments

private enum InjectedFailure: Error { case afterCommit }

private actor RulerLoadGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
final class MacInstrumentRecoveryTests: XCTestCase {
    private let displayA = MacDisplayIdentity(displayID: 11, nativeScale: 2,
        size: CGSize(width: 3024, height: 1964), name: "A")
    private let displayB = MacDisplayIdentity(displayID: 22, nativeScale: 1,
        size: CGSize(width: 2560, height: 1440), name: "B")

    func testSavedPlacePostCommitFailureSurvivesViewReconstructionAndBlocksQuit() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("location-uncertain")
        defer { MacToolboxTestRoot.remove(root) }
        let archive = ToolboxLocationArchive(url: root.appendingPathComponent("places.json"))
        let activity = MacInstrumentActivityCoordinator()
        let source = FakeLocationSource(); source.authorization = .authorized
        let model = MacLocationModel(source: source, archive: archive, activity: activity,
            saveOperation: { name, fix in
                _ = try await archive.save(name: name, fix: fix)
                throw InjectedFailure.afterCommit
            })
        model.activateLifecycle(); model.start(); source.emitFix()
        XCTAssertTrue(model.requestSavePlace("Home"))
        XCTAssertTrue(model.saving)
        XCTAssertFalse(model.requestSavePlace("Another"))
        activity.closeAdmissions()
        let drained = await activity.drain(timeout: 2)
        XCTAssertFalse(drained)
        let saved = try await archive.load()
        XCTAssertEqual(saved.map(\.name), ["Home"])
        XCTAssertEqual(model.successfulSaveSequence, 0)
        let reopened = MacLocationModel(source: FakeLocationSource(), archive: archive, activity: activity)
        XCTAssertNotNil(reopened.operationNotice)
        activity.resumeAfterCancelledTermination()
        XCTAssertFalse(reopened.requestSavePlace("Home"))
        reopened.clearOperationNotice()
        activity.closeAdmissions()
        let afterAcknowledgement = await activity.drain(timeout: 1)
        XCTAssertTrue(afterAcknowledgement)
        let stillSaved = try await archive.load()
        XCTAssertEqual(stillSaved.count, 1)
    }

    func testSlowRulerLoadBlocksWritesAndPreservesOtherDisplays() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-slow")
        defer { MacToolboxTestRoot.remove(root) }
        let url = root.appendingPathComponent("ruler.json")
        let store = MacRulerCalibrationStore(url: url)
        let seed = MacRulerModel(store: store)
        await seed.load(display: displayA); await seed.calibrate(separation: 428)
        await seed.load(display: displayB); await seed.calibrate(separation: 400)
        let original = try Data(contentsOf: url)
        let gate = RulerLoadGate()
        let model = MacRulerModel(store: store, loadRecords: { await gate.wait(); return try await store.load() })
        let loading = Task { await model.load(display: displayA) }
        await gate.waitUntilEntered()
        XCTAssertFalse(model.storageIsReady)
        await model.calibrate(separation: 450)
        await model.clearCalibration()
        XCTAssertEqual(try Data(contentsOf: url), original)
        await gate.release(); await loading.value
        XCTAssertTrue(model.storageIsReady)
        XCTAssertEqual(model.records.count, 2)
        await model.calibrate(separation: 450)
        let records = try await store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.displayID == displayB.displayID })
    }

    func testSlowCorruptRulerLoadCannotBeOverwritten() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-slow-corrupt")
        defer { MacToolboxTestRoot.remove(root) }
        let url = root.appendingPathComponent("ruler.json")
        let original = Data("{broken".utf8); try original.write(to: url)
        let store = MacRulerCalibrationStore(url: url)
        let gate = RulerLoadGate()
        let model = MacRulerModel(store: store, loadRecords: { await gate.wait(); return try await store.load() })
        let loading = Task { await model.load(display: displayA) }
        await gate.waitUntilEntered()
        await model.calibrate(separation: 428); await model.clearCalibration()
        XCTAssertEqual(try Data(contentsOf: url), original)
        await gate.release(); await loading.value
        XCTAssertEqual(model.storageFailure, .corrupt)
        await model.calibrate(separation: 428)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRulerPostCommitFailureRemainsVisibleUntilReloadAcknowledged() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-uncertain")
        defer { MacToolboxTestRoot.remove(root) }
        let store = MacRulerCalibrationStore(url: root.appendingPathComponent("ruler.json"))
        let activity = MacInstrumentActivityCoordinator()
        let model = MacRulerModel(store: store, activity: activity,
            upsertRecord: { record in _ = try await store.upsert(record); throw InjectedFailure.afterCommit })
        await model.load(display: displayA)
        await model.calibrate(separation: 428)
        XCTAssertEqual(model.storageFailure, .save)
        let stored = try await store.load()
        XCTAssertEqual(stored.count, 1)
        activity.closeAdmissions()
        let rejected = await activity.drain(timeout: 1)
        XCTAssertFalse(rejected)
        let reopened = MacRulerModel(store: store, activity: activity)
        await reopened.load(display: displayA)
        XCTAssertEqual(reopened.storageFailure, .save)
        await reopened.acknowledgeStorageFailureAfterReload()
        let accepted = await activity.drain(timeout: 1)
        XCTAssertTrue(accepted)
        XCTAssertNotNil(reopened.calibration)
    }

    func testRulerStaleModelsPreserveOtherDisplayWhenRuntimeIDIsReused() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("ruler-interleaved")
        defer { MacToolboxTestRoot.remove(root) }
        let store = MacRulerCalibrationStore(url: root.appendingPathComponent("ruler.json"))
        let a = MacDisplayIdentity(displayID: 7, nativeScale: 2,
            size: CGSize(width: 1200, height: 900), name: "A", stableID: "display:1:1:1")
        let b = MacDisplayIdentity(displayID: 7, nativeScale: 2,
            size: CGSize(width: 1200, height: 900), name: "B", stableID: "display:1:1:2")
        let first = MacRulerModel(store: store), second = MacRulerModel(store: store)
        await first.load(display: a); await second.load(display: b)
        await first.calibrate(separation: 400)
        await second.calibrate(separation: 450)
        let both = try await store.load()
        XCTAssertEqual(Set(both.compactMap(\.stableID)), Set([a.stableID, b.stableID]))
        await first.calibrate(separation: 500)
        await second.clearCalibration()
        let remaining = try await store.load()
        XCTAssertEqual(remaining.map(\.stableID), [a.stableID])
    }

    func testOwnedLocationModelRetainsPendingDraftAndPublishesLateSuccess() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("location-reopen-success")
        defer { MacToolboxTestRoot.remove(root) }
        let archive = ToolboxLocationArchive(url: root.appendingPathComponent("places.json"))
        let activity = MacInstrumentActivityCoordinator(), gate = RulerLoadGate()
        let source = FakeLocationSource(); source.authorization = .authorized
        let model = MacLocationModel(source: source, archive: archive, activity: activity,
            saveOperation: { name, fix in await gate.wait(); return try await archive.save(name: name, fix: fix) })
        let models = MacInstrumentModels(activity: activity, archive: archive,
            rulerStore: MacRulerCalibrationStore(url: root.appendingPathComponent("ruler.json")),
            locationFactory: { model })
        let firstViewModel = models.location
        firstViewModel.activateLifecycle(); firstViewModel.start(); source.emitFix()
        firstViewModel.draftPlaceName = "Home"
        XCTAssertTrue(firstViewModel.requestSavePlace(firstViewModel.draftPlaceName))
        await gate.waitUntilEntered()
        let reopenedViewModel = models.location
        XCTAssertTrue(firstViewModel === reopenedViewModel)
        XCTAssertEqual(reopenedViewModel.draftPlaceName, "Home")
        XCTAssertTrue(reopenedViewModel.saving)
        reopenedViewModel.draftPlaceName = "Work"
        await gate.release()
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertEqual(reopenedViewModel.places.map(\.name), ["Home"])
        XCTAssertEqual(reopenedViewModel.draftPlaceName, "Work")
    }

    func testOwnedLocationModelRetainsDraftAndFailureAfterReopen() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("location-reopen-failure")
        defer { MacToolboxTestRoot.remove(root) }
        let archive = ToolboxLocationArchive(url: root.appendingPathComponent("places.json"))
        let activity = MacInstrumentActivityCoordinator(), gate = RulerLoadGate()
        let source = FakeLocationSource(); source.authorization = .authorized
        let model = MacLocationModel(source: source, archive: archive, activity: activity,
            saveOperation: { _, _ in await gate.wait(); throw InjectedFailure.afterCommit })
        let models = MacInstrumentModels(activity: activity, archive: archive,
            rulerStore: MacRulerCalibrationStore(url: root.appendingPathComponent("ruler.json")),
            locationFactory: { model })
        let first = models.location
        first.activateLifecycle(); first.start(); source.emitFix(); first.draftPlaceName = "Home"
        XCTAssertTrue(first.requestSavePlace(first.draftPlaceName))
        await gate.waitUntilEntered()
        let reopened = models.location
        await gate.release()
        let drained = await activity.drain(timeout: 2)
        XCTAssertFalse(drained)
        XCTAssertTrue(first === reopened)
        XCTAssertEqual(reopened.draftPlaceName, "Home")
        XCTAssertNotNil(reopened.operationNotice)
        XCTAssertNotNil(reopened.fix)
    }

    func testLateOldLocationLoadCannotOverwriteCompletedSave() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("location-late-load")
        defer { MacToolboxTestRoot.remove(root) }
        let archive = ToolboxLocationArchive(url: root.appendingPathComponent("places.json"))
        let gate = RulerLoadGate(), activity = MacInstrumentActivityCoordinator()
        let source = FakeLocationSource(); source.authorization = .authorized
        let model = MacLocationModel(source: source, archive: archive, activity: activity,
            loadOperation: {
                let snapshot = try await archive.load()
                await gate.wait()
                return snapshot
            })
        model.activateLifecycle(); model.start(); source.emitFix()
        let oldLoad = Task { await model.loadPlaces() }
        await gate.waitUntilEntered()
        model.draftPlaceName = "Home"
        XCTAssertTrue(model.requestSavePlace(model.draftPlaceName))
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertEqual(model.places.map(\.name), ["Home"])
        await gate.release(); await oldLoad.value
        XCTAssertEqual(model.places.map(\.name), ["Home"])
        XCTAssertEqual(model.draftPlaceName, "")
    }

    func testOwnedPhotoModelRetainsImagePointsAndExportReceipt() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("photo-reopen")
        defer { MacToolboxTestRoot.remove(root) }
        let activity = MacInstrumentActivityCoordinator()
        let models = MacInstrumentModels(activity: activity,
            archive: ToolboxLocationArchive(url: root.appendingPathComponent("places.json")),
            rulerStore: MacRulerCalibrationStore(url: root.appendingPathComponent("ruler.json")))
        let first = models.photo
        await first.load(data: try SyntheticImage.png(width: 40, height: 40))
        first.addReferencePoint(pixel: PhotoPoint(0, 0)); first.addReferencePoint(pixel: PhotoPoint(20, 0))
        first.referenceValueText = "10"; first.applyCalibration()
        let target = root.appendingPathComponent("annotated.png")
        first.exportAnnotatedPNG(to: target)
        let reopened = models.photo
        let drained = await activity.drain(timeout: 2)
        XCTAssertTrue(drained)
        XCTAssertTrue(first === reopened)
        XCTAssertNotNil(reopened.image)
        XCTAssertEqual(reopened.referencePointCount, 2)
        XCTAssertNotNil(reopened.lastExportError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}

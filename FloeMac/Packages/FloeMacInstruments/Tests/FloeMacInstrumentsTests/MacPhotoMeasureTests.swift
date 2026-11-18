// SPDX-License-Identifier: MPL-2.0

import Foundation
import Darwin
import XCTest
@testable import FloeMacInstruments
import FloeToolboxUtilities

@MainActor
final class MacPhotoMeasureTests: XCTestCase {
    func testExistingDestinationAndCancellationLeaveTargetsUntouched() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-exclusive")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("existing.png")
        let original = Data("existing".utf8), replacement = Data("replacement".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(replacement, to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
        let newURL = directory.appendingPathComponent("new.png")
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(replacement, to: newURL, beforeCommit: { _ in throw CancellationError() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
    }

    func testExportCommitsVerifiedNewDestination() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-commit")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        let payload = try SyntheticImage.png(width: 30, height: 30)
        let outcome = try MacPhotoFileIO.writeNew(payload, to: url)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["new.png"], "Anonymous staging leaves no named copy")
    }

    func testExportRejectsRacingTargetAndPreservesCompetitor() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-race")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        let competing = Data("competing".utf8)
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(Data("mine".utf8), to: url, beforeCommit: { _ in
            try competing.write(to: url, options: .withoutOverwriting)
        }))
        XCTAssertEqual(try Data(contentsOf: url), competing)
    }

    func testExportIgnoresCompetingNamedFileAndDoesNotDeleteIt() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-stage")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        let outcome = try MacPhotoFileIO.writeNew(Data("mine".utf8), to: url, beforeCommit: { parent in
            try Data("other".utf8).write(to: parent.appendingPathComponent("payload"))
        })
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: url), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("payload")), Data("other".utf8))
    }

    func testUnsupportedCloneFailsWithoutOutputOrStagingCopy() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-unsupported")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        XCTAssertThrowsError(try MacPhotoAtomicExport.write(Data("mine".utf8), to: url, clone: { _, _, _ in
            errno = ENOTSUP
            return -1
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testUncertainDirectorySyncIsNotReportedAsVerified() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-sync")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        let outcome = try MacPhotoAtomicExport.write(Data("mine".utf8), to: url, syncDirectory: { _ in false })
        XCTAssertEqual(outcome, .committedDurabilityUncertain)
        XCTAssertEqual(try Data(contentsOf: url), Data("mine".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["new.png"])
    }

    func testCancellationAfterCommitBeginsReportsCommittedOutcome() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export-commit-cancel")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("new.png")
        let control = MacPhotoExportControl()
        let outcome = try MacPhotoAtomicExport.write(Data("mine".utf8), to: url, control: control, clone: { source, parent, name in
            let result = fclonefileat(source, parent, name, 0)
            control.cancel()
            return result
        })
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(try Data(contentsOf: url), Data("mine".utf8))
    }

    func testExportRejectsParentDirectoryReplacement() throws {
        let root = try MacToolboxTestRoot.makeDirectory("photo-export-parent")
        defer { MacToolboxTestRoot.remove(root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let old = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let url = parent.appendingPathComponent("new.png")
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(Data("mine".utf8), to: url, beforeCommit: { _ in
            try FileManager.default.moveItem(at: parent, to: old)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("new.png").path))
    }

    func testExportRejectsSymlinkParentAndTarget() throws {
        let root = try MacToolboxTestRoot.makeDirectory("photo-export-symlink")
        defer { MacToolboxTestRoot.remove(root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(Data("mine".utf8), to: alias.appendingPathComponent("new.png")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("new.png").path))
        let target = real.appendingPathComponent("target")
        let link = real.appendingPathComponent("new.png")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MacPhotoFileIO.writeNew(Data("mine".utf8), to: link))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testExportCancellationBeforeCommitDoesNotCreateTarget() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("photo-export-cancel")
        defer { MacToolboxTestRoot.remove(root) }
        let target = root.appendingPathComponent("new.png")
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try MacPhotoFileIO.writeNew(Data("mine".utf8), to: target, beforeCommit: { _ in entered.signal(); resume.wait() })
        }
        defer { task.cancel(); resume.signal() }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        XCTAssertTrue(reached)
        task.cancel()
        resume.signal()
        do { _ = try await task.value; XCTFail("cancelled export committed") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testModelImmediateCancelBeforeWorkerCannotCommit() async throws {
        let root = try MacToolboxTestRoot.makeDirectory("photo-export-model-cancel")
        defer { MacToolboxTestRoot.remove(root) }
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: try SyntheticImage.png(width: 40, height: 40))
        model.addReferencePoint(pixel: PhotoPoint(0, 0))
        model.addReferencePoint(pixel: PhotoPoint(20, 0))
        model.referenceValueText = "10"
        model.applyCalibration()
        let target = root.appendingPathComponent("new.png")
        model.exportAnnotatedPNG(to: target)
        model.cancelExport()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testBoundedReaderRejectsOversizedFileAndAcceptsSyntheticFile() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-bound")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("image.bin")
        let bytes = Data("synthetic".utf8)
        try bytes.write(to: url)
        XCTAssertEqual(try MacPhotoFileIO.read(url), bytes)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(MacPhotoDecoder.maximumEncodedBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try MacPhotoFileIO.read(url))
    }

    func testReaderRejectsSymlinkFIFOAndReplacementAfterSelection() throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-identity")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("chosen")
        let original = directory.appendingPathComponent("original")
        try Data("original".utf8).write(to: url)
        let expected = try MacPhotoFileIO.identity(url)
        XCTAssertEqual(try MacPhotoFileIO.read(url, expected: expected), Data("original".utf8))
        try FileManager.default.moveItem(at: url, to: original)
        try Data("replacement".utf8).write(to: url)
        XCTAssertThrowsError(try MacPhotoFileIO.read(url, expected: expected))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        XCTAssertThrowsError(try MacPhotoFileIO.identity(url))
        XCTAssertThrowsError(try MacPhotoFileIO.read(url, expected: expected))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertThrowsError(try MacPhotoFileIO.identity(url))
        XCTAssertThrowsError(try MacPhotoFileIO.read(url, expected: expected))
    }

    func testCancelBeforeImportTaskRunsCannotLoadImage() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-cancel")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("image.png")
        try SyntheticImage.png(width: 20, height: 20).write(to: url)
        let model = MacPhotoMeasureModel()
        model.importImage(from: url)
        model.cancelImport()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.image)
        XCTAssertEqual(model.phase, .empty)
    }

    func testBoundedReaderObservesCancellationBetweenChunks() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-read-cancel")
        defer { MacToolboxTestRoot.remove(directory) }
        let url = directory.appendingPathComponent("image.bin")
        try Data(repeating: 3, count: 200_000).write(to: url)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try MacPhotoFileIO.read(url, onChunk: { entered.signal(); resume.wait() })
        }
        defer { task.cancel(); resume.signal() }
        let reachedChunk = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        XCTAssertTrue(reachedChunk)
        task.cancel()
        resume.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled reader must not return a complete file")
        } catch is CancellationError {
        }
    }
    func testDecodePreservesPixelDimensionsAndOrientation() throws {
        let data = try SyntheticImage.png(width: 400, height: 300)
        let decoded = try MacPhotoDecoder.decode(data)
        XCTAssertEqual(decoded.pixels, PhotoPoint(400, 300))
        XCTAssertFalse(decoded.wasDownsampled)
        XCTAssertEqual(decoded.image.width, 400)
        XCTAssertEqual(decoded.image.height, 300)
    }

    func testCalibrationLengthAreaAndAngleUseImagePixels() async throws {
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: try SyntheticImage.png(width: 400, height: 300))
        model.setViewSize(CGSize(width: 800, height: 600))
        XCTAssertEqual(model.transform?.scale ?? 0, 2, accuracy: 0.0001)
        model.addReferencePoint(pixel: PhotoPoint(0, 0))
        model.addReferencePoint(pixel: PhotoPoint(200, 0))
        model.referenceValueText = "100"
        model.applyCalibration()
        XCTAssertTrue(model.isCalibrated)

        model.addVertex(pixel: PhotoPoint(100, 100))
        model.addVertex(pixel: PhotoPoint(300, 100))
        XCTAssertEqual(model.readout.total, 0.1, accuracy: 1e-9)
        XCTAssertEqual(PhotoUnit.millimeter.format(model.readout.total), "100 mm")

        model.clearMeasurements()
        model.mode = .area
        model.addVertex(pixel: PhotoPoint(100, 100))
        model.addVertex(pixel: PhotoPoint(300, 100))
        model.addVertex(pixel: PhotoPoint(300, 200))
        model.addVertex(pixel: PhotoPoint(100, 200))
        let area = try XCTUnwrap(model.readout.area)
        XCTAssertEqual(area, 0.005, accuracy: 1e-9)
        XCTAssertEqual(PhotoUnit.centimeter.areaFormat(area), "50.00 cm²")

        model.clearMeasurements()
        model.mode = .angle
        model.addVertex(pixel: PhotoPoint(200, 100))
        model.addVertex(pixel: PhotoPoint(100, 100))
        model.addVertex(pixel: PhotoPoint(100, 200))
        XCTAssertEqual(try XCTUnwrap(model.readout.angles.first), 90, accuracy: 1e-6)
    }

    func testTapUsesThePresentationTransformButStoresImagePixels() async throws {
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: try SyntheticImage.png(width: 400, height: 300))
        model.setViewSize(CGSize(width: 800, height: 600))
        model.tap(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(model.referencePointCount, 1)
        XCTAssertEqual(try XCTUnwrap(model.store.referencePoints.first?.position.x), 200, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.store.referencePoints.first?.position.y), 150, accuracy: 0.01)
    }

    func testNewImageDiscardsPreviousCalibrationAndMeasurements() async throws {
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: try SyntheticImage.png(width: 400, height: 300))
        model.addReferencePoint(pixel: PhotoPoint(0, 0))
        model.addReferencePoint(pixel: PhotoPoint(200, 0))
        model.referenceValueText = "100"
        model.applyCalibration()
        model.addVertex(pixel: PhotoPoint(100, 100))
        XCTAssertTrue(model.isCalibrated)
        XCTAssertEqual(model.readout.pointCount, 1)

        await model.load(data: try SyntheticImage.png(width: 200, height: 100))
        XCTAssertFalse(model.isCalibrated)
        XCTAssertEqual(model.readout.pointCount, 0)
        XCTAssertEqual(model.imagePixels, PhotoPoint(200, 100))
    }

    func testInvalidImageFailsWithoutInventingDimensions() async {
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: Data([0x00, 0x01, 0x02, 0x03]))
        XCTAssertNil(model.image)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNotNil(model.hint)
    }

    func testExportProducesARealPNGAtTheSourceDimensions() async throws {
        let directory = try MacToolboxTestRoot.makeDirectory("photo-export")
        defer { MacToolboxTestRoot.remove(directory) }
        let model = MacPhotoMeasureModel(unit: .millimeter)
        await model.load(data: try SyntheticImage.png(width: 400, height: 300))
        model.addReferencePoint(pixel: PhotoPoint(0, 0))
        model.addReferencePoint(pixel: PhotoPoint(200, 0))
        model.referenceValueText = "100"
        model.applyCalibration()
        model.addVertex(pixel: PhotoPoint(100, 100))
        model.addVertex(pixel: PhotoPoint(300, 100))

        let data = try model.annotatedPNGData()
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let decoded = try MacPhotoDecoder.decode(data)
        XCTAssertEqual(decoded.pixels, PhotoPoint(400, 300))
        let url = directory.appendingPathComponent("annotated.png")
        try data.write(to: url, options: .atomic)
        XCTAssertGreaterThan(try XCTUnwrap(try? Data(contentsOf: url).count), 0)
    }
}

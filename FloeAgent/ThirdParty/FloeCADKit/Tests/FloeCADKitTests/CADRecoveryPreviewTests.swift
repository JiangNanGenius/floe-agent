import XCTest
import UIKit
@testable import FloeCAD

/// E33: real `.floecad` packages exercise the non-mutating recovery preview and
/// the atomic restore-copy. Every assertion uses the real store/facade; no
/// hand-built manifest is trusted as evidence.
@MainActor
final class CADRecoveryPreviewTests: XCTestCase {
    private var workDir: URL!

    /// A 1x1 PNG. The store only binds preview bytes by digest; UIKit decodes
    /// this so the preview sheet can display a real previous artifact.
    private static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3VAAAAAElFTkSuQmCC")!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADRecoveryPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeRecoveryCopyPromotion = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

    private func manifest(_ root: URL) throws -> CADManifest {
        try JSONDecoder().decode(CADManifest.self,
                                 from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    private func record(_ root: URL) throws -> CADDocumentRecord {
        try JSONDecoder().decode(CADDocumentRecord.self,
                                 from: Data(contentsOf: root.appendingPathComponent("document.json")))
    }

    /// Every regular file under the package, keyed by relative path. Used to
    /// prove the preview and the failed restores never touch the source bytes.
    private func packageBytes(_ root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            result[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private func directoryEntries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func addRectExtrude(_ document: FloeCADDocument,
                                sketchName: String,
                                at point: (min: [Int], max: [Int]) = ([0, 0], [12, 10]))
    throws {
        let sketch = document.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"\#(sketchName)"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sketch.payload) as? [String: Any])
        let id = try XCTUnwrap(object["sketchID"] as? String)
        let entities = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(id)",
         "entities":[{"kind":"rect","min":\(point.min),"max":\(point.max)}]}}
        """.utf8))
        XCTAssertTrue(entities.isOK, entities.message ?? "")
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(id)","seedPoint":[2,2],"distance":5}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
    }

    /// Revision 3: the verified `previous/` commit (revision 2) carries real
    /// geometry; the current commit adds one more sketch so the two commits
    /// differ.
    private func editedPackage(named name: String = "Box") async throws -> URL {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        try addRectExtrude(document, sketchName: "Base")
        document.project.materialsData = try JSONEncoder().encode(
            CADMaterialLibrary(entries: [CADMaterialDefinition(name: "Recovered Material")]))
        document.project.drawingsData = try JSONEncoder().encode(
            CADDrawingSet.standardSheet(for: UUID(), title: "Sheet"))
        document.project.thumbnail = Self.tinyPNG
        var saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let extraSketch = document.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Current Only"}}"#.utf8))
        XCTAssertTrue(extraSketch.isOK, extraSketch.message ?? "")
        saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        XCTAssertEqual(try manifest(url).revision, 3)
        XCTAssertEqual(try manifest(url.appendingPathComponent("previous")).revision, 2)
        return url
    }

    private func corruptCurrentDocument(_ url: URL) throws {
        try Data("{".utf8).write(to: url.appendingPathComponent("document.json"))
    }

    private func damagedPreview(_ url: URL,
                                file: StaticString = #filePath, line: UInt = #line)
    async throws -> CADRecoveryPreview {
        let inspection = await FloeCADDocument.recoveryInspection(at: url)
        guard case .damaged(_, let preview?) = inspection else {
            XCTFail("expected a damaged inspection with a verified previous preview",
                    file: file, line: line)
            throw CocoaError(.featureUnsupported)
        }
        return preview
    }

    private func row(_ preview: CADRecoveryPreview,
                     kind: CADRecoveryRowKind,
                     category: CADRecoveryCategory) -> CADRecoveryReportRow? {
        preview.report.rows.first { $0.kind == kind && $0.category == category }
    }

    // MARK: Preview

    func testPreviewReadsVerifiedPreviousWithoutMutatingAnySourceByte() async throws {
        let url = try await editedPackage()
        let previousManifest = try manifest(url.appendingPathComponent("previous"))
        let previousRecord = try record(url.appendingPathComponent("previous"))
        let before = try packageBytes(url)
        let parentBefore = try directoryEntries(workDir)
        try corruptCurrentDocument(url)
        let corrupted = try packageBytes(url)

        let inspection = await FloeCADDocument.recoveryInspection(at: url)
        guard case .damaged(let damage, let preview?) = inspection else {
            return XCTFail("expected a preview from the verified previous commit")
        }
        XCTAssertEqual(damage.code, "unreadable_document")
        XCTAssertEqual(preview.previous.revision, previousManifest.revision)
        XCTAssertEqual(preview.previous.contentSHA256, previousManifest.contentSHA256)
        XCTAssertEqual(preview.previous.modelSHA256, previousManifest.modelSHA256)
        XCTAssertEqual(preview.previous.name, previousManifest.name)
        XCTAssertEqual(preview.contents.bodies, previousRecord.bodies.count)
        XCTAssertEqual(preview.contents.sketches, previousRecord.sketches.count)
        XCTAssertEqual(preview.contents.features, previousRecord.features.count)
        XCTAssertEqual(preview.contents.materialCount, 1)
        XCTAssertEqual(preview.contents.drawingPageCount, 4)
        XCTAssertEqual(preview.contents.hasPreviewImage, true)
        XCTAssertEqual(preview.currentRevisionClaim, 3)
        XCTAssertEqual(preview.currentReportedCounts?["sketches"],
                       previousRecord.sketches.count + 1,
                       "the damaged manifest's counts are exposed as unverified context")

        XCTAssertEqual(row(preview, kind: .recovered, category: .bodies)?.count,
                       previousRecord.bodies.count)
        XCTAssertEqual(row(preview, kind: .recovered, category: .sketches)?.count,
                       previousRecord.sketches.count)
        XCTAssertEqual(row(preview, kind: .recovered, category: .features)?.count,
                       previousRecord.features.count)
        XCTAssertEqual(row(preview, kind: .recovered, category: .materials)?.count, 1)
        XCTAssertEqual(row(preview, kind: .recovered, category: .drawingPages)?.count, 4)
        XCTAssertNotNil(row(preview, kind: .unknown, category: .changesSincePrevious))
        XCTAssertNil(row(preview, kind: .retainedInOriginal, category: .namedVersions))
        XCTAssertNil(row(preview, kind: .unavailable, category: .missingDamagedPreview))

        // Exact read-only proof: the current corrupt bytes, the verified
        // previous commit and the rest of the package are unchanged, and no
        // manifest/staging/sibling recovery point was created.
        XCTAssertEqual(try packageBytes(url), corrupted)
        XCTAssertNotEqual(corrupted, before, "the deliberate corruption changed bytes")
        XCTAssertEqual(try directoryEntries(workDir), parentBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path))
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNil(identity, "inspection must not promote previous")
    }

    func testPreviewImageIsTheVerifiedPreviousViewportArtifact() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let preview = try await damagedPreview(url)
        let previous = try record(url.appendingPathComponent("previous"))
        XCTAssertEqual(previous.bodies.count, preview.contents.bodies)
        XCTAssertEqual(preview.previewImage, Self.tinyPNG,
                       "the preview must be the digest-bound previous artifact, not a new render")
    }

    func testMissingCurrentManifestIsPreviewedWithoutPromotionAndOrdinaryOpenStillRecovers() async throws {
        let url = try await editedPackage()
        let previousManifest = try manifest(url.appendingPathComponent("previous"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        let before = try packageBytes(url)

        let preview = try await damagedPreview(url)
        XCTAssertEqual(preview.damage.code, "missing_manifest")
        XCTAssertEqual(preview.previous.revision, previousManifest.revision)
        XCTAssertEqual(preview.previous.contentSHA256, previousManifest.contentSHA256)
        XCTAssertEqual(try packageBytes(url), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manifest.json").path),
            "preview must not promote previous")

        // The ordinary store open keeps its proven in-place recovery for
        // internal callers; only the interactive host intercepts first.
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(opened.revision, previousManifest.revision)
        opened.close()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manifest.json").path))
        let interrupted = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0.hasPrefix(".\(url.lastPathComponent).interrupted-") }
        XCTAssertEqual(interrupted.count, 1)
    }

    func testCancelAfterPreviewCreatesNoDestinationOrPartialPackage() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let sourceBefore = try packageBytes(url)
        let parentBefore = try directoryEntries(workDir)

        // The UI "Cancel" path only discards the preview; no restore call is
        // made. The damaged package and the folder must be exactly unchanged.
        _ = try await damagedPreview(url)
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertEqual(try directoryEntries(workDir), parentBefore)
        XCTAssertFalse(try directoryEntries(workDir).contains {
            $0.contains("Recovered") || $0.contains(".restore-")
        })
    }

    // MARK: Restore

    func testRestoreCopyCreatesVerifiedNewPackageAndPreservesEverySourceByte() async throws {
        let url = try await editedPackage()
        let previousRoot = url.appendingPathComponent("previous")
        let previousManifest = try manifest(previousRoot)
        let previousRecord = try record(previousRoot)
        try corruptCurrentDocument(url)
        let sourceBefore = try packageBytes(url)
        let previewValue = try await damagedPreview(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        let result = try await FloeCADDocument.restorePreviousCopy(previewValue, to: destination)

        XCTAssertEqual(result.packageURL.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(result.revision, previousManifest.revision)
        XCTAssertEqual(result.contentSHA256, previousManifest.contentSHA256)
        XCTAssertEqual(result.modelSHA256, previousManifest.modelSHA256)
        XCTAssertEqual(result.report, previewValue.report)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("previous/manifest.json").path),
            "a restore copy starts as a standalone package at the previous revision")

        // Original and previous bytes are untouched.
        XCTAssertEqual(try packageBytes(url), sourceBefore)

        // The new package verifies independently of the damaged source.
        let stored = await FloeCADDocument.storedIdentity(at: destination)
        XCTAssertEqual(stored?.revision, previousManifest.revision)
        XCTAssertEqual(stored?.contentSHA256, previousManifest.contentSHA256)
        XCTAssertEqual(stored?.modelSHA256, previousManifest.modelSHA256)

        let opened = try await FloeCADDocument.open(at: destination)
        XCTAssertEqual(opened.revision, previousManifest.revision)
        XCTAssertEqual(opened.contentSHA256, previousManifest.contentSHA256)
        XCTAssertEqual(opened.summary().bodyCount, previousRecord.bodies.count)
        XCTAssertEqual(opened.summary().sketchCount, previousRecord.sketches.count)
        XCTAssertEqual(opened.summary().featureCount, previousRecord.features.count)
        XCTAssertEqual(try record(destination).materials, previousRecord.materials)
        XCTAssertEqual(try record(destination).drawings, previousRecord.drawings)

        // Continued editing: a real command commits revision+1 in the copy.
        let edit = opened.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"After recovery"}}"#.utf8))
        XCTAssertTrue(edit.isOK, edit.message ?? "")
        let saved = await opened.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(saved.revision, previousManifest.revision + 1)
        opened.close()
        XCTAssertEqual(try manifest(destination).revision, previousManifest.revision + 1)
    }

    func testCorruptPreviousIsUnavailableAndNeverBecomesAFalsePreview() async throws {
        let url = try await editedPackage()
        let previousDocument = url.appendingPathComponent("previous/document.json")
        try Data("{".utf8).write(to: previousDocument)
        try corruptCurrentDocument(url)
        let before = try packageBytes(url)
        let parentBefore = try directoryEntries(workDir)

        let inspection = await FloeCADDocument.recoveryInspection(at: url)
        guard case .damaged(_, let preview) = inspection else {
            return XCTFail("a damaged current package must not inspect as intact")
        }
        XCTAssertNil(preview, "an unverified previous commit must never be previewed")
        XCTAssertEqual(try packageBytes(url), before)
        XCTAssertEqual(try directoryEntries(workDir), parentBefore)

        do {
            let opened = try await FloeCADDocument.open(at: url)
            opened.close()
            XCTFail("ordinary open must not promote an unverified previous commit")
        } catch {}
        XCTAssertEqual(try packageBytes(url), before)
    }

    func testSourceChangedAfterPreviewIsRefusedThenRefreshRestores() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let preview = try await damagedPreview(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        // A second write to the damaged document happens after the user saw
        // the preview.
        try Data("{{".utf8).write(to: url.appendingPathComponent("document.json"))
        let afterChange = try packageBytes(url)
        do {
            _ = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)
            XCTFail("a stale preview must not be applied")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .sourceChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try packageBytes(url), afterChange)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })

        // A refreshed preview has a different fingerprint and restores the
        // same verified previous commit.
        let refreshed = try await damagedPreview(url)
        XCTAssertNotEqual(refreshed.sourceFingerprint, preview.sourceFingerprint)
        let result = try await FloeCADDocument.restorePreviousCopy(
            refreshed, to: destination)
        XCTAssertEqual(result.contentSHA256, preview.previous.contentSHA256)
        XCTAssertEqual(try packageBytes(url), afterChange)
    }

    // MARK: Fail-closed destinations

    func testExistingDestinationIsRefusedAndNoPartialPackageIsLeft() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let preview = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("other work".utf8).write(to: destination.appendingPathComponent("sentinel.txt"))

        do {
            _ = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)
            XCTFail("an existing destination must never be overwritten")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .destinationExists(destination))
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sentinel.txt")),
                       Data("other work".utf8))
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testDestinationOutsideThePackageFolderIsRefused() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let preview = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let folder = workDir.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("Box Recovered.floecad")

        do {
            _ = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)
            XCTFail("a recovery copy must stay beside the damaged package")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .destinationOutsideSource)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try packageBytes(url), sourceBefore)
    }

    func testFailedAtomicPromotionLeavesNoDestinationAndNoStaging() async throws {
        enum InjectedFailure: Error { case stop }
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let preview = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")
        CADDocumentFaultInjection.beforeRecoveryCopyPromotion = { throw InjectedFailure.stop }
        defer { CADDocumentFaultInjection.beforeRecoveryCopyPromotion = nil }

        do {
            _ = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)
            XCTFail("the injected promotion failure must refuse")
        } catch let error as CADRecoveryError {
            guard case .copyFailed = error else {
                return XCTFail("expected copyFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    // MARK: Truthful report

    func testReportDisclosesRealRetainedItemsAndRealOmissionsOnly() async throws {
        let url = try await editedPackage()
        let previousRoot = url.appendingPathComponent("previous")
        let previousRecord = try record(previousRoot)
        try corruptCurrentDocument(url)

        // Facts that exist ONLY in the damaged package.
        let versions = url.appendingPathComponent("versions")
        try FileManager.default.createDirectory(
            at: versions.appendingPathComponent("checkpoint-1"),
            withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(
            to: versions.appendingPathComponent("checkpoint-1/manifest.json"))
        try Data("notes".utf8).write(to: url.appendingPathComponent("notes.txt"))
        let images = url.appendingPathComponent("blobs/images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("newer image".utf8).write(to: images.appendingPathComponent("new.img"))
        // The damaged manifest still declares the preview the writer saved;
        // the file itself is gone. This is a real omission, not an invented
        // field-level loss.
        try FileManager.default.removeItem(at: url.appendingPathComponent("blobs/thumbnail.img"))

        let sourceBefore = try packageBytes(url)
        let preview = try await damagedPreview(url)

        XCTAssertEqual(row(preview, kind: .retainedInOriginal, category: .namedVersions)?.count, 1)
        XCTAssertEqual(row(preview, kind: .retainedInOriginal, category: .otherItems)?.count, 1)
        XCTAssertEqual(row(preview, kind: .retainedInOriginal, category: .newerResources)?.count, 1)
        XCTAssertNotNil(row(preview, kind: .unavailable, category: .missingDamagedPreview))
        XCTAssertNotNil(row(preview, kind: .unknown, category: .changesSincePrevious))
        // No invented per-field loss: the only unknown row is the honest
        // "changes since previous" statement, and the only unavailable row is
        // the provable missing preview artifact.
        let unknownRows = preview.report.rows.filter { $0.kind == .unknown }
        XCTAssertEqual(unknownRows.map(\.category), [.changesSincePrevious])
        let unavailableRows = preview.report.rows.filter { $0.kind == .unavailable }
        XCTAssertEqual(unavailableRows.map(\.category), [.missingDamagedPreview])

        let destination = workDir.appendingPathComponent("Box Recovered.floecad")
        let result = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)
        XCTAssertEqual(result.report, preview.report)
        // The copy is exactly the verified previous commit; the damaged
        // package keeps every newer/extra item byte for byte.
        XCTAssertEqual(try record(destination).materials, previousRecord.materials)
        XCTAssertEqual(try record(destination).drawings, previousRecord.drawings)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("versions").path))
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("blobs/images/new.img").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: versions.appendingPathComponent("checkpoint-1/manifest.json").path))
    }

    // MARK: Pure destination naming

    func testSuggestedDestinationSkipsExistingNames() throws {
        let package = workDir.appendingPathComponent("Part.floecad")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let first = CADRecoveryCopyDestination.suggestedURL(for: package, suffix: "Recovered")
        XCTAssertEqual(first.lastPathComponent, "Part Recovered.floecad")
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL,
                       workDir.standardizedFileURL)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = CADRecoveryCopyDestination.suggestedURL(for: package, suffix: "Recovered")
        XCTAssertEqual(second.lastPathComponent, "Part Recovered 2.floecad")
        let localized = CADRecoveryCopyDestination.suggestedURL(for: package, suffix: "恢复副本")
        XCTAssertEqual(localized.lastPathComponent, "Part 恢复副本.floecad")
        let fallback = CADRecoveryCopyDestination.suggestedURL(for: package, suffix: "  ")
        XCTAssertEqual(fallback.lastPathComponent, "Part Recovered 2.floecad")
    }

    // MARK: Atomic step and active-ownership fences

    private enum RestoreAttempt: Sendable {
        case success(revision: Int)
        case refused(CADRecoveryError)
        case failed(String)
    }

    private func attemptRestore(_ preview: CADRecoveryPreview,
                                to destination: URL) async -> RestoreAttempt {
        do {
            let result = try await FloeCADDocument.restorePreviousCopy(
                preview, to: destination)
            return .success(revision: result.revision)
        } catch let error as CADRecoveryError {
            return .refused(error)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func testCallerCancellationStillCompletesTheAtomicCopy() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let previewValue = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        // The atomic copy is a single store step: canceling the VIEW task must
        // not abort between staging and promotion. The caller fences its
        // presentation separately and records the real outcome.
        let task = Task {
            try await FloeCADDocument.restorePreviousCopy(previewValue, to: destination)
        }
        task.cancel()
        let result = try await task.value

        XCTAssertEqual(result.revision, previewValue.previous.revision)
        XCTAssertEqual(result.contentSHA256, previewValue.previous.contentSHA256)
        let stored = await FloeCADDocument.storedIdentity(at: destination)
        XCTAssertEqual(stored?.revision, previewValue.previous.revision)
        XCTAssertEqual(stored?.contentSHA256, previewValue.previous.contentSHA256)
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testConcurrentRestoresCreateExactlyOneVerifiedCopy() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let previewValue = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        async let first = attemptRestore(previewValue, to: destination)
        async let second = attemptRestore(previewValue, to: destination)
        let firstOutcome = await first
        let secondOutcome = await second

        var successes = 0
        var refusals: [CADRecoveryError] = []
        for outcome in [firstOutcome, secondOutcome] {
            switch outcome {
            case .success:
                successes += 1
            case .refused(let error):
                refusals.append(error)
            case .failed(let message):
                XCTFail("unexpected restore failure: \(message)")
            }
        }
        XCTAssertEqual(successes, 1,
                       "exactly one writer may create the copy")
        XCTAssertEqual(refusals, [.destinationExists(destination)],
                       "the serialized second writer must refuse, never rename over the first")
        let stored = await FloeCADDocument.storedIdentity(at: destination)
        XCTAssertEqual(stored?.revision, previewValue.previous.revision)
        XCTAssertEqual(stored?.contentSHA256, previewValue.previous.contentSHA256)
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testDestinationCreatedDuringPromotionIsNeverReplaced() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let previewValue = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        // Simulate another writer landing the destination in the
        // verify -> stage window. The final promotion must refuse and leave
        // that writer's bytes untouched.
        CADDocumentFaultInjection.beforeRecoveryCopyPromotion = {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try Data("other work".utf8).write(
                to: destination.appendingPathComponent("sentinel.txt"))
        }
        defer { CADDocumentFaultInjection.beforeRecoveryCopyPromotion = nil }

        do {
            _ = try await FloeCADDocument.restorePreviousCopy(
                previewValue, to: destination)
            XCTFail("a destination created during promotion must never be replaced")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .destinationExists(destination))
        }
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("sentinel.txt")),
            Data("other work".utf8))
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testDestinationMustKeepPackageExtensionAndADanglingLinkIsOccupied() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let previewValue = try await damagedPreview(url)
        let sourceBefore = try packageBytes(url)

        let wrongExtension = workDir.appendingPathComponent("Box Recovered.txt")
        do {
            _ = try await FloeCADDocument.restorePreviousCopy(
                previewValue, to: wrongExtension)
            XCTFail("a recovered copy must stay a .floecad package")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .destinationNotPackage(wrongExtension))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongExtension.path))

        let linked = workDir.appendingPathComponent("Box Recovered.floecad")
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: workDir.appendingPathComponent("Missing Target"))
        do {
            _ = try await FloeCADDocument.restorePreviousCopy(
                previewValue, to: linked)
            XCTFail("an occupied (even dangling) destination must never be replaced")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .destinationExists(linked))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: linked.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, FileAttributeType.typeSymbolicLink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path),
                       "the link keeps pointing at the missing target; nothing was renamed over it")
        XCTAssertEqual(try packageBytes(url), sourceBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testSymbolicLinkInPreviousIsRefusedAndForeignBytesStayUntouched() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        // Review a real, verified previous commit first. The link is then
        // swapped in between review and restore, which is exactly the window a
        // containment refusal must cover.
        let previewValue = try await damagedPreview(url)
        let previous = url.appendingPathComponent("previous")
        let foreign = workDir.appendingPathComponent("Foreign Previous")
        try FileManager.default.moveItem(at: previous, to: foreign)
        try FileManager.default.createSymbolicLink(at: previous,
                                                   withDestinationURL: foreign)
        let foreignBefore = try packageBytes(foreign)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        do {
            _ = try await FloeCADDocument.restorePreviousCopy(
                previewValue, to: destination)
            XCTFail("a linked previous tree must never be copied into a package")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .sourceNotContained)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try packageBytes(foreign), foreignBefore)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testInitialLinkedPreviousIsNeverPreviewedAndForeignBytesStayUntouched() async throws {
        let url = try await editedPackage()
        let previous = url.appendingPathComponent("previous")
        let foreign = workDir.appendingPathComponent("Foreign Linked Previous.floecad")
        try FileManager.default.moveItem(at: previous, to: foreign)
        try FileManager.default.createSymbolicLink(at: previous,
                                                   withDestinationURL: foreign)
        try corruptCurrentDocument(url)
        let foreignBefore = try packageBytes(foreign)
        let manifestBefore = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let documentBefore = try Data(contentsOf: url.appendingPathComponent("document.json"))
        let entriesBefore = try directoryEntries(workDir)

        // The link exists BEFORE the first inspection. Without containment the
        // store follows it, verifies the foreign package and would show its
        // revision as this damaged document's previous save.
        let inspection = await FloeCADDocument.recoveryInspection(at: url)
        guard case .damaged(_, let preview) = inspection else {
            XCTFail("a damaged package must report damage, not an intact package")
            return
        }
        XCTAssertNil(preview,
                     "a linked previous tree must never become a verified previous preview")
        XCTAssertEqual(try packageBytes(foreign), foreignBefore,
                       "the foreign package must not be read or written")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")),
                       manifestBefore)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("document.json")),
                       documentBefore)
        XCTAssertEqual(try directoryEntries(workDir), entriesBefore,
                       "inspection must not create a recovery path")
        let attributes = try FileManager.default.attributesOfItem(atPath: previous.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, FileAttributeType.typeSymbolicLink,
                       "the refusal must not replace the link with a package")
    }

    func testNestedLinkInsidePreviousIsNeverPreviewedAndSourceBytesStayUntouched() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let foreignDirectory = workDir.appendingPathComponent("Foreign Resource")
        try FileManager.default.createDirectory(at: foreignDirectory,
                                                withIntermediateDirectories: true)
        let foreignFile = foreignDirectory.appendingPathComponent("foreign.txt")
        try Data("foreign bytes".utf8).write(to: foreignFile)
        let link = url.appendingPathComponent("previous/nested-resource")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: foreignFile)
        let foreignBefore = try Data(contentsOf: foreignFile)
        let packageBefore = try packageBytes(url)

        // The blob store already refuses a linked blob; the outer `previous/`
        // tree must apply the same rule for every nested entry, because restore
        // would refuse to copy this tree.
        let inspection = await FloeCADDocument.recoveryInspection(at: url)
        guard case .damaged(_, let preview) = inspection else {
            XCTFail("a damaged package must report damage, not an intact package")
            return
        }
        XCTAssertNil(preview,
                     "a nested link in previous must never produce a verified preview")
        XCTAssertEqual(try Data(contentsOf: foreignFile), foreignBefore)
        XCTAssertEqual(try packageBytes(url), packageBefore,
                       "inspection must leave every source byte unchanged")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, FileAttributeType.typeSymbolicLink)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-") && !$0.contains(".unverified-")
        })
    }

    func testPreviousChangedAfterPreviewIsRefused() async throws {
        let url = try await editedPackage()
        try corruptCurrentDocument(url)
        let previewValue = try await damagedPreview(url)
        let destination = workDir.appendingPathComponent("Box Recovered.floecad")

        // The preview's fingerprint covers every regular file in `previous/`,
        // including files the current document does not attribute. A change
        // there after review is a stale preview, not a fresh recovery.
        try Data("changed after review".utf8).write(
            to: url.appendingPathComponent("previous/notes-after-preview.txt"))
        let changed = try packageBytes(url)
        do {
            _ = try await FloeCADDocument.restorePreviousCopy(
                previewValue, to: destination)
            XCTFail("a changed previous commit must not be applied")
        } catch let error as CADRecoveryError {
            XCTAssertEqual(error, .sourceChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try packageBytes(url), changed)
        XCTAssertTrue(try directoryEntries(workDir).allSatisfy {
            !$0.contains(".restore-")
        })
    }

    func testPresentationFenceRejectsStaleAndCrossSourceAdoption() throws {
        let origin = workDir.appendingPathComponent("Origin.floecad")
        let copy = workDir.appendingPathComponent("Origin Recovered.floecad")
        let otherSource = workDir.appendingPathComponent("Other.floecad")
        let otherCopy = workDir.appendingPathComponent("Other Recovered.floecad")

        var fence = CADRecoveryPresentationFence()
        let ticket = fence.begin(sourceURL: origin)
        XCTAssertTrue(fence.accepts(ticket))
        XCTAssertEqual(fence.visibleURL, origin.standardizedFileURL)
        XCTAssertFalse(fence.isShowingRecoveredCopy)

        // A copy produced for another package is never adopted.
        XCTAssertNil(fence.adopt(ticket, copyURL: otherCopy,
                                 resultSourceURL: otherSource))
        XCTAssertNil(fence.activeCopyURL)

        XCTAssertEqual(fence.adopt(ticket, copyURL: copy,
                                   resultSourceURL: origin),
                       copy.standardizedFileURL)
        XCTAssertEqual(fence.visibleURL, copy.standardizedFileURL)
        XCTAssertTrue(fence.isShowingRecoveredCopy)
        // One adoption per preview: a second (late) result cannot retarget it.
        XCTAssertFalse(fence.accepts(ticket))
        XCTAssertNil(fence.adopt(ticket, copyURL: otherCopy,
                                 resultSourceURL: origin))

        // Reloading the adopted copy keeps the active copy; retargeting the
        // presentation to any other file drops it immediately.
        let reload = fence.begin(sourceURL: copy)
        XCTAssertEqual(fence.activeCopyURL, copy.standardizedFileURL)
        XCTAssertTrue(fence.accepts(reload))
        let retarget = fence.begin(sourceURL: otherSource)
        XCTAssertNil(fence.activeCopyURL)
        XCTAssertEqual(fence.originURL, otherSource.standardizedFileURL)
        XCTAssertFalse(fence.accepts(reload))
        XCTAssertTrue(fence.accepts(retarget))

        fence.invalidate()
        XCTAssertNil(fence.visibleURL)
        XCTAssertFalse(fence.accepts(retarget))
        XCTAssertNil(fence.adopt(retarget, copyURL: otherCopy,
                                 resultSourceURL: otherSource))
    }
}

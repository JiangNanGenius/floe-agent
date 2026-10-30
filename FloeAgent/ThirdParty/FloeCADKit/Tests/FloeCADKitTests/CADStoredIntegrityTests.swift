import XCTest
import UIKit
import CryptoKit
import Dispatch
@testable import FloeCAD

/// Uses packages produced by the real store/facade. Corruption is deliberately
/// still decodable in several cases: parser success cannot prove identity.
@MainActor
final class CADStoredIntegrityTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADStoredIntegrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        if let workDir { try FileManager.default.removeItem(at: workDir) }
    }

    private func boxPackage(_ name: String = "Box") async throws -> URL {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: sketch.payload) as? [String: Any])
        let id = try XCTUnwrap(object["sketchID"] as? String)
        let entities = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(id)",
         "entities":[{"kind":"rect","min":[0,0],"max":[12,10]}]}}
        """.utf8))
        XCTAssertTrue(entities.isOK, entities.message ?? "")
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(id)","seedPoint":[2,2],"distance":5}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        return url
    }

    private func manifest(_ url: URL) throws -> CADManifest {
        try JSONDecoder().decode(CADManifest.self,
                                 from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
    }

    private func record(_ url: URL) throws -> CADDocumentRecord {
        try JSONDecoder().decode(CADDocumentRecord.self,
                                 from: Data(contentsOf: url.appendingPathComponent("document.json")))
    }

    /// Covers current AND previous bytes. Failed reads must not silently
    /// promote a backup, rewrite a manifest or discard residual geometry.
    private func packageBytes(_ url: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        let prefix = url.path + "/"
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private func assertRejectedWithoutWriting(_ url: URL,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) async throws {
        let before = try packageBytes(url)
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNil(identity, "corrupt content must not return a verified identity", file: file, line: line)
        XCTAssertThrowsError(try FileCADDocumentStore(packageURL: url).readWithoutRecovery(),
                             file: file, line: line)
        do {
            let opened = try await FloeCADDocument.open(at: url)
            opened.close()
            XCTFail("ordinary open must reject a corrupt committed package", file: file, line: line)
        } catch {
            // The manifest exists: this is not interrupted-commit recovery.
        }
        XCTAssertEqual(try packageBytes(url), before,
                       "failed inspection/open must preserve current and previous bytes", file: file, line: line)
    }

    func testDecodableGeometryTamperInvalidatesStoredIdentityAndOpen() async throws {
        let url = try await boxPackage()
        let meshPath = try XCTUnwrap(try record(url).bodies.first?.meshBlob)
        let meshURL = url.appendingPathComponent(meshPath)
        var mesh = try MeshBlob.decode(Data(contentsOf: meshURL))
        let original = mesh.positions[0].x
        mesh.positions[0].x += 0.125
        let changed = MeshBlob.encode(mesh)
        try changed.write(to: meshURL)
        XCTAssertNotEqual(try MeshBlob.decode(changed).positions[0].x, original,
                          "fixture must still decode as usable geometry")
        try await assertRejectedWithoutWriting(url)
    }

    func testMissingDeclaredBRepFailsInsteadOfSilentlyBecomingMeshOnly() async throws {
        let url = try await boxPackage()
        let expected = try manifest(url)
        let path = try XCTUnwrap(try record(url).bodies.first?.brepBlob,
                                "the production extrude must produce an exact B-rep")
        let blob = url.appendingPathComponent(path)
        let savedBlob = workDir.appendingPathComponent("retained.brep")
        try FileManager.default.moveItem(at: blob, to: savedBlob)
        try await assertRejectedWithoutWriting(url)
        try FileManager.default.moveItem(at: savedBlob, to: blob)
        let restored = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(restored?.contentSHA256, expected.contentSHA256)
        XCTAssertEqual(restored?.modelSHA256, expected.modelSHA256)
    }

    func testRawDocumentBytesAreVerifiedWithoutReencoding() async throws {
        let url = try await boxPackage()
        let documentURL = url.appendingPathComponent("document.json")
        var bytes = try Data(contentsOf: documentURL)
        bytes.append(contentsOf: [0x20, 0x0A])
        _ = try JSONDecoder().decode(CADDocumentRecord.self, from: bytes)
        try bytes.write(to: documentURL)
        try await assertRejectedWithoutWriting(url)
    }

    func testChangedDecodableDocumentRecordIsRejected() async throws {
        let url = try await boxPackage()
        var changed = try record(url)
        changed.bodies[0].name = "Changed outside the commit"
        try JSONEncoder().encode(changed).write(to: url.appendingPathComponent("document.json"))
        try await assertRejectedWithoutWriting(url)
    }

    func testManifestSemanticMetadataIsCheckedByCanonicalModelDigest() async throws {
        let url = try await boxPackage()
        var changed = try manifest(url)
        // Legacy content hashes do not include manifest metadata. The additive
        // model digest DOES include the editable name/unit/tolerance contract.
        changed.name = "Uncommitted rename"
        try JSONEncoder().encode(changed).write(to: url.appendingPathComponent("manifest.json"))
        try await assertRejectedWithoutWriting(url)
    }

    func testHistoricalManifestWithoutModelDigestStillVerifiesContent() async throws {
        let url = try await boxPackage()
        let manifestURL = url.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                                  as? [String: Any])
        object.removeValue(forKey: "modelSHA256")
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        let before = try packageBytes(url)
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(identity?.contentSHA256, try manifest(url).contentSHA256)
        XCTAssertNil(identity?.modelSHA256)
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(opened.summary().bodyCount, 1)
        opened.close()
        XCTAssertEqual(try packageBytes(url), before,
                       "reading a historical package must not upgrade/rewrite it")
    }

    func testNewerKnownWireSchemaOpensReadOnlyWithoutRewriting() async throws {
        let url = try await boxPackage()
        var future = try manifest(url)
        future.schemaVersion = Project.currentFormatVersion + 1
        try JSONEncoder().encode(future).write(to: url.appendingPathComponent("manifest.json"))
        let before = try packageBytes(url)
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(identity?.modelSHA256, future.modelSHA256,
                       "the existing semantic digest does not include schema/app-build metadata")
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertTrue(opened.isReadOnly)
        opened.close()
        XCTAssertEqual(try packageBytes(url), before)
    }

    func testFutureUnknownFieldsNeverReturnAnUnverifiedSemanticIdentity() async throws {
        let url = try await boxPackage()
        let documentURL = url.appendingPathComponent("document.json")
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
                               as? [String: Any])
        raw["futureAnalysis"] = ["version": 2, "fieldThisBuildDoesNotKnow": "retained"]
        let futureBytes = try JSONSerialization.data(withJSONObject: raw)
        try futureBytes.write(to: documentURL)
        var future = try manifest(url)
        future.schemaVersion = Project.currentFormatVersion + 1
        // A future producer's canonical identity cannot be reconstructed by
        // this reader. Its legacy byte identity still has the SAME contract.
        future.modelSHA256 = String(repeating: "0", count: 64)
        var content = SHA256()
        content.update(data: futureBytes)
        let known = try record(url)
        let paths = Set(known.bodies.flatMap { [$0.meshBlob, $0.brepBlob].compactMap { $0 } }
                        + known.images.compactMap(\.imageBlob))
        for path in paths.sorted() {
            let bytes = try Data(contentsOf: url.appendingPathComponent(path))
            content.update(data: Data(path.utf8))
            content.update(data: Data(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().utf8))
        }
        if let preview = future.thumbnailSHA256 { content.update(data: Data(preview.utf8)) }
        future.contentSHA256 = content.finalize().map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(future).write(to: url.appendingPathComponent("manifest.json"))
        let before = try packageBytes(url)
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(identity?.contentSHA256, future.contentSHA256)
        XCTAssertNil(identity?.modelSHA256, "never repeat an unchecked semantic claim")
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertTrue(opened.isReadOnly)
        opened.close()
        XCTAssertEqual(try packageBytes(url), before)
    }

    func testRecordWithoutIndividualBlobDigestUsesCompleteContentProof() async throws {
        let url = try await boxPackage()
        let store = FileCADDocumentStore(packageURL: url)
        let project = try store.read()
        var payload = try store.makePayload(project)
        payload.document.bodies[0].meshSHA256 = nil
        payload.document.bodies[0].brepSHA256 = nil
        _ = try store.performWrite(payload)
        let valid = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(valid, "optional legacy per-record digests must not become mandatory")
        let meshURL = url.appendingPathComponent(try XCTUnwrap(payload.document.bodies[0].meshBlob))
        var mesh = try MeshBlob.decode(Data(contentsOf: meshURL))
        mesh.positions[0].x += 0.25
        try MeshBlob.encode(mesh).write(to: meshURL)
        try await assertRejectedWithoutWriting(url)
    }

    private func png() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 10))
        return try XCTUnwrap(renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 10))
        }.pngData())
    }

    func testPreviewOnlyCommitKeepsModelIdentityAndVerifiesPreviewBytes() async throws {
        let url = try await boxPackage()
        let document = try await FloeCADDocument.open(at: url)
        let base = try manifest(url)
        let originalRecords = try record(url)
        let brepPath = try XCTUnwrap(originalRecords.bodies.first?.brepBlob)
        let originalBRep = try Data(contentsOf: url.appendingPathComponent(brepPath))
        let preview = try png()
        let saved = await document.saveViewportPreview(preview)
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(saved.modelSHA256, base.modelSHA256)
        XCTAssertNotEqual(saved.contentSHA256, base.contentSHA256)
        let afterPreview = try record(url)
        XCTAssertEqual(afterPreview.bodies.map(\.transform), originalRecords.bodies.map(\.transform))
        XCTAssertEqual(afterPreview.sketches.map(\.data), originalRecords.sketches.map(\.data))
        XCTAssertEqual(afterPreview.features.map(\.kind), originalRecords.features.map(\.kind))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(brepPath)), originalBRep,
                       "a preview must not reserialize an unchanged analytic solid")
        document.close()
        let verified = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(verified?.modelSHA256, base.modelSHA256)
        XCTAssertEqual(verified?.contentSHA256, saved.contentSHA256)
        var changed = preview
        changed.append(0)
        try changed.write(to: url.appendingPathComponent("blobs/thumbnail.img"))
        try await assertRejectedWithoutWriting(url)
    }

    func testCleanPreviewSaveIncludesExplicitProjectMetadataChanges() async throws {
        let url = try await boxPackage()
        let document = try await FloeCADDocument.open(at: url)
        let base = try manifest(url)
        document.project.name = "Renamed model"
        document.project.unitRaw = "in"
        let preview = try png()
        let saved = await document.saveViewportPreview(preview)
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertNotEqual(saved.modelSHA256, base.modelSHA256,
                          "preserving opaque records must not discard real metadata edits")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().name, "Renamed model")
        XCTAssertEqual(reopened.summary().unit, "in")
        reopened.close()
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(identity?.modelSHA256, saved.modelSHA256)
    }

    func testPreviewCommitFailureKeepsDraftPreviewAndAllowsAnExactRetry() async throws {
        let url = try await boxPackage()
        let document = try await FloeCADDocument.open(at: url)
        let original = try manifest(url)
        let before = try packageBytes(url)
        let preview = try png()
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "CADStoredIntegrityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected preview commit failure"])
        }
        let failed = await document.saveViewportPreview(preview)
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(try packageBytes(url), before)
        XCTAssertEqual(document.project.thumbnail, preview, "keep the failed draft for retry")
        let retried = await document.saveViewportPreview(preview)
        XCTAssertTrue(retried.succeeded, retried.error ?? "")
        XCTAssertEqual(retried.modelSHA256, original.modelSHA256)
        document.close()
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(identity?.modelSHA256, original.modelSHA256)
    }

    private nonisolated static func waitForCommitGate(_ gate: DispatchSemaphore) -> Bool {
        gate.wait(timeout: .now() + 5) == .success
    }

    func testPreviewSaveDoesNotAcknowledgeAnEditMadeWhileItsPayloadCommits() async throws {
        let url = try await boxPackage()
        let document = try await FloeCADDocument.open(at: url)
        let originalSketchCount = document.summary().sketchCount
        let capturedGeneration = document.session.changeCount
        let enteredCommit = DispatchSemaphore(value: 0)
        let finishCommit = DispatchSemaphore(value: 0)
        CADDocumentFaultInjection.beforeCommit = {
            enteredCommit.signal()
            if finishCommit.wait(timeout: .now() + 5) != .success {
                throw NSError(domain: "CADStoredIntegrityTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "test did not release preview commit"])
            }
        }
        defer {
            finishCommit.signal()
            CADDocumentFaultInjection.beforeCommit = nil
        }
        let preview = try png()
        let saving = Task { await document.saveViewportPreview(preview) }
        let entered = await Task.detached { Self.waitForCommitGate(enteredCommit) }.value
        guard entered else {
            finishCommit.signal()
            _ = await saving.value
            return XCTFail("preview never reached the controlled commit gate")
        }
        XCTAssertEqual(document.session.changeCount, capturedGeneration,
                       "the payload must reach its commit gate before the new edit")
        let edit = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"While saving"}}"#.utf8))
        XCTAssertTrue(edit.isOK, edit.message ?? "")
        XCTAssertEqual(document.session.changeCount, capturedGeneration + 1,
                       "a real command must create a new generation after payload capture")
        finishCommit.signal()
        let saved = await saving.value
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertTrue(document.hasUnsavedChanges,
                      "an earlier payload must not acknowledge a later command generation")
        XCTAssertEqual(try record(url).sketches.count, originalSketchCount)
        let next = await document.save()
        XCTAssertTrue(next.succeeded, next.error ?? "")
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try record(url).sketches.count, originalSketchCount + 1)
        document.close()
    }

    private func imagePackage(hasPayload: Bool) throws -> URL {
        let url = workDir.appendingPathComponent("Image.floecad")
        let project = Project(name: "Image")
        let image = InsertedImage(name: "Reference", plane: .worldXY,
                                  width: 12, height: 10, imageData: Data())
        let persisted = PersistedImage(imageID: image.id.raw,
                                       infoData: try JSONEncoder().encode(image),
                                       imageData: hasPayload ? try png() : Data())
        persisted.project = project
        project.images.append(persisted)
        let store = FileCADDocumentStore(packageURL: url)
        try FileCADDocumentStore.createPackage(at: url, payload: store.makePayload(project), overwrite: false)
        return url
    }

    func testAbsentOptionalPreviewAndImagePayloadRemainReadable() async throws {
        let url = try imagePackage(hasPayload: false)
        let project = try FileCADDocumentStore(packageURL: url).readWithoutRecovery()
        XCTAssertNil(project.thumbnail)
        XCTAssertEqual(project.images.count, 1)
        XCTAssertTrue(project.images[0].imageData.isEmpty)
        // An unclaimed old preview is not part of the committed identity.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("blobs"),
                                                withIntermediateDirectories: true)
        try png().write(to: url.appendingPathComponent("blobs/thumbnail.img"))
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(identity)
    }

    func testDeclaredImagePayloadCannotGoMissing() async throws {
        let url = try imagePackage(hasPayload: true)
        let imagePath = try XCTUnwrap(try record(url).images.first?.imageBlob)
        try FileManager.default.removeItem(at: url.appendingPathComponent(imagePath))
        try await assertRejectedWithoutWriting(url)
    }

    func testIdentityInspectionNeverPromotesPreviousOrChangesInterruptedBytes() async throws {
        let url = try await boxPackage()
        let previous = url.appendingPathComponent("previous")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("manifest.json").path))
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        let before = try packageBytes(url)
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNil(identity)
        XCTAssertEqual(try packageBytes(url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path))
    }

    func testOrdinaryOpenRecoversVerifiedPreviousAndRetainsInterruptedPackage() async throws {
        let url = try await boxPackage()
        let previousIdentity = try manifest(url.appendingPathComponent("previous"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        let residual = Data("residual newer bytes".utf8)
        try residual.write(to: url.appendingPathComponent("residual.data"))
        let before = try packageBytes(url)
        let opened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(opened.revision, previousIdentity.revision)
        opened.close()
        let retained = try FileManager.default.contentsOfDirectory(at: workDir,
                                                                  includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".\(url.lastPathComponent).interrupted-") }
        XCTAssertEqual(retained.count, 1)
        let recoveryPoint = try XCTUnwrap(retained.first)
        XCTAssertEqual(try packageBytes(recoveryPoint), before)
        let recoveredIdentity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(recoveredIdentity?.contentSHA256, previousIdentity.contentSHA256)
    }

    func testCorruptPreviousIsNeverPromotedOverInterruptedBytes() async throws {
        let url = try await boxPackage()
        try FileManager.default.removeItem(at: url.appendingPathComponent("manifest.json"))
        let previousJSON = url.appendingPathComponent("previous/document.json")
        var bytes = try Data(contentsOf: previousJSON)
        bytes.append(0x20)
        try bytes.write(to: previousJSON)
        let before = try packageBytes(url)
        do {
            let opened = try await FloeCADDocument.open(at: url)
            opened.close()
            XCTFail("an unverified previous commit must not be promoted")
        } catch { }
        XCTAssertEqual(try packageBytes(url), before)
    }
}

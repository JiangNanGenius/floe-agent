//
//  StoreRecoveryTests.swift
//  FloeCADKitTests
//
//  Failure-injection regressions for the document package (review
//  2026-10-09):
//    * an overwrite that fails AFTER moving the old package aside must
//      restore/keep the old document — a failed create never deletes data;
//    * a commit that fails before rotation keeps the previous package valid;
//    * a stale-payload commit is refused by the revision guard, not applied.
//

import XCTest
@testable import FloeCAD

final class StoreRecoveryTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CADDocumentFaultInjection.beforeCreateSwap = nil
        CADDocumentFaultInjection.beforeCommit = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func addBox(_ document: FloeCADDocument, size: Double,
                        file: StaticString = #filePath, line: UInt = #line) {
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"S"}}"#.utf8))
        let object = (try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any]
        guard let sketchID = object?["sketchID"] as? String else {
            return XCTFail("no sketch id", file: file, line: line)
        }
        let outcome = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[\(size),\(size)]}]}}
        """.utf8))
        XCTAssertTrue(outcome.isOK, "\(outcome.message ?? "")", file: file, line: line)
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":\(size)}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, "\(extrude.message ?? "")", file: file, line: line)
    }

    private func siblingDebris() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        return contents.filter { $0.hasPrefix(".") || $0.contains(".staging-")
            || $0.contains(".old-") || $0.contains(".create-") || $0.contains(".rotate-") }
    }

    // MARK: Overwrite create failure

    func testOverwriteCreateFailureNeverDeletesExistingDocument() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let original = try await FloeCADDocument.create(at: url, name: "Original")
        addBox(original, size: 10)
        let originalSave = await original.save()
        XCTAssertTrue(originalSave.succeeded, originalSave.error ?? "")
        let originalSHA = originalSave.contentSHA256
        let originalRevision = originalSave.revision
        original.close()

        CADDocumentFaultInjection.beforeCreateSwap = {
            throw NSError(domain: "FloeCADTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected create failure"])
        }
        do {
            _ = try await FloeCADDocument.create(at: url, name: "Replacement", overwrite: true)
            XCTFail("create must fail under fault injection")
        } catch {
            // expected
        }
        CADDocumentFaultInjection.beforeCreateSwap = nil

        // The original document must still be there, byte-identical in revision
        // and content identity.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "failed overwrite deleted the existing document")
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().name, "Original")
        XCTAssertEqual(reopened.summary().revision, originalRevision)
        XCTAssertEqual(reopened.summary().contentSHA256, originalSHA)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        reopened.close()
        XCTAssertTrue(siblingDebris().isEmpty,
                      "staging/backup debris left behind: \(siblingDebris())")
    }

    func testOverwriteCreateSuccessKeepsPreviousSnapshot() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let original = try await FloeCADDocument.create(at: url, name: "Original")
        original.close()
        let replacement = try await FloeCADDocument.create(at: url, name: "Replacement",
                                                           overwrite: true)
        XCTAssertEqual(replacement.summary().name, "Replacement")
        replacement.close()
        // The replaced package stays recoverable as the new package's
        // previous snapshot.
        let previous = url.appendingPathComponent("previous/snapshot/manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path),
                      "replaced package must be retained as previous snapshot")
    }

    // MARK: Commit failure

    func testCommitFailureLeavesPreviousCommitValidAndRetrySucceeds() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Commit")
        addBox(document, size: 10)
        let first = await document.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")

        addBox(document, size: 4)
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "FloeCADTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "injected commit failure"])
        }
        let failed = await document.save()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded, "injected commit failure must be reported")
        document.close()

        // On disk the previous commit is untouched and reopens cleanly.
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().revision, first.revision)
        XCTAssertEqual(reopened.summary().contentSHA256, first.contentSHA256)
        reopened.close()

        // A retry after the injected failure commits normally.
        let second = try await FloeCADDocument.open(at: url)
        addBox(second, size: 4)
        // Clear the cache-independent failure path: no injection set.
        let retried = await second.save()
        XCTAssertTrue(retried.succeeded, retried.error ?? "")
        XCTAssertGreaterThan(retried.revision, first.revision)
        second.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    // MARK: Revision guard

    func testStalePayloadIsRefusedByRevisionGuard() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Guard")
        addBox(document, size: 10)
        let store = document.store

        // Build a payload at the current revision, then commit something else.
        let stale = try store.makePayload(document.project)
        addBox(document, size: 3)
        let fresh = await document.save()
        XCTAssertTrue(fresh.succeeded, fresh.error ?? "")

        XCTAssertThrowsError(try store.performWrite(stale)) { error in
            guard case CADDocumentStoreError.revisionMoved = error else {
                return XCTFail("expected revisionMoved, got \(error)")
            }
        }
        document.close()
    }
}

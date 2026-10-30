// FloeAppTests — App host commit/rollback contract for external native part
// references (E01 review repairs).
//
// These are REAL-document host tests: the real FloeCAD kernel/store, the real
// `CadDocumentCenter`, the real `CADAssemblyReferenceBridge` and the real CAS
// save path. Only the failure/cancellation timing is deterministic:
//
//   * a failed host save rolls back EXACTLY the reference command, never an
//     unrelated later edit or an already-committed command;
//   * a later real edit during the save suspension blocks the rollback and
//     both the reference and the later edit are preserved/reported;
//   * a concurrent save that commits the same command is reported as
//     committed and is never undone by the later failed explicit save;
//   * the real runtime cancellation token stops the call before any mutation.
//
// The target registration for this new file is owned by the primary agent.

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

@MainActor
final class NativeCADPartReferenceHostTests: XCTestCase {

    private var workspace: URL!
    private var owner: UUID!
    private var liveDocument: FloeCADDocument?

    private var targetURL: URL { workspace.appendingPathComponent("Target.floecad") }

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-reference-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        owner = UUID()
    }

    override func tearDown() async throws {
        CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil
        liveDocument?.saveFailureForTesting = nil
        liveDocument?.saveSuspensionForTesting = nil
        liveDocument = nil
        if let workspace {
            let target = workspace.appendingPathComponent("Target.floecad")
            if FileManager.default.fileExists(atPath: target.path) {
                await FloeCAD3DBridge.shared.releaseDocument(at: target)
            }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    // MARK: - Helpers

    private func access() -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-1", workspacePath: workspace.path,
                          ownerKind: "chat", ownerID: owner)
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): \(outcome.message ?? "")")
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBodySource(named name: String) async throws -> URL {
        let url = workspace.appendingPathComponent("\(name).floecad")
        let source = try await FloeCADDocument.create(at: url, name: name)
        let sketch = try run(source, #"{"op":"sketch.create","args":{"name":"Base"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(source, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """)
        let extrude = try run(source, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[5,5],"distance":10}}
        """)
        XCTAssertNotNil((extrude["producedBodyIDs"] as? [String])?.first
                        ?? (extrude["changedBodyIDs"] as? [String])?.first)
        let save = await source.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        source.close()
        return url
    }

    /// Create the target package and return the SAME cached live document the
    /// center bridge will use (so the deterministic test seams are on it).
    private func makeLiveTarget() async throws -> FloeCADDocument {
        let created = try await FloeCADDocument.create(at: targetURL, name: "Target")
        created.close()
        let live = try await FloeCAD3DBridge.shared.openDocument(at: targetURL)
        liveDocument = live
        return live
    }

    private func reference(
        _ center: CadDocumentCenter, action: String, source: String,
        referenceID: UUID? = nil,
        expectedSourceSHA256: String? = nil,
        expectedStagedSHA256: String? = nil,
        cancellation: CancellationToken = CancellationToken()
    ) async throws -> [String: Any] {
        var payload: [String: Any] = ["action": action, "path": source]
        if let referenceID { payload["reference_id"] = referenceID.uuidString }
        if let expectedSourceSHA256 {
            payload["expected_source_sha256"] = expectedSourceSHA256
        }
        if let expectedStagedSHA256 {
            payload["expected_staged_sha256"] = expectedStagedSHA256
        }
        let request = try JSONSerialization.data(
            withJSONObject: ["kind": "reference", "payload": payload])
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))
        let reply = try await center.reference(
            documentID: "Target.floecad", requestJSON: text,
            access: access(), cancellation: cancellation)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
            "reference host reply must be a JSON object: \(reply)")
    }

    private func makeCenter() -> CadDocumentCenter {
        CadDocumentCenter(nativeProposalStoreFileURL:
            workspace.appendingPathComponent("proposals-\(UUID().uuidString).json"))
    }

    // MARK: - Save failure rollback

    func testFailedAttachCommitRollsBackExactlyTheReference() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        live.saveFailureForTesting = "simulated host commit failure"

        let reply = try await reference(center, action: "attach", source: sourceURL.lastPathComponent)
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["error"] as? String, "reference_commit_failed", "\(reply)")
        XCTAssertEqual(reply["mutated"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["rolledBack"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["state"] as? String, "rolled_back", "\(reply)")
        XCTAssertEqual(reply["reference_present"] as? Bool, false, "\(reply)")
        XCTAssertFalse(live.hasUnsavedChanges)
        XCTAssertNil(live.pendingOwnedCommand)

        // The one-shot failure is consumed; the document remains writable and
        // can commit a fresh reference normally.
        let saved = await live.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let retry = try await reference(center, action: "attach", source: sourceURL.lastPathComponent)
        XCTAssertEqual(retry["ok"] as? Bool, true, "\(retry)")
        XCTAssertEqual(retry["committed"] as? Bool, true, "\(retry)")
        XCTAssertEqual(retry["reference_present"] as? Bool, true, "\(retry)")
    }

    func testFailedAttachCommitWithLaterEditPreservesReferenceAndEdit() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        live.saveFailureForTesting = "simulated host commit failure"
        live.saveSuspensionForTesting = {
            live.saveSuspensionForTesting = nil
            // A real later document edit while the explicit commit is waiting
            // to start. It must not be erased by a blind undo.
            let outcome = live.executeJSON(Data(
                #"{"op":"sketch.create","args":{"name":"Later Edit"}}"#.utf8))
            XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        }

        let reply = try await reference(center, action: "attach", source: sourceURL.lastPathComponent)
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["mutated"] as? Bool, true,
                       "a reference that remains must never be reported as nothing applied: \(reply)")
        XCTAssertEqual(reply["rolledBack"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["state"] as? String, "unsaved_later_edits", "\(reply)")
        XCTAssertEqual(reply["reference_present"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["document_dirty"] as? Bool, true, "\(reply)")
        XCTAssertTrue(live.hasUnsavedChanges,
                      "the reference and the later edit both remain unsaved")
        XCTAssertNotNil(reply["recovery"] as? String)
    }

    func testConcurrentSaveCommitIsReportedAndNeverRolledBack() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        live.saveFailureForTesting = "simulated explicit-save failure"
        live.saveSuspensionForTesting = {
            live.saveSuspensionForTesting = nil
            // Another save commits the same reference command while the
            // explicit save is still waiting. This is a real store commit;
            // temporarily move the one-shot failure aside so it fails the
            // OUTER explicit save, not this concurrent commit.
            let injected = live.saveFailureForTesting
            live.saveFailureForTesting = nil
            let outcome = await live.save()
            live.saveFailureForTesting = injected
            XCTAssertTrue(outcome.succeeded, outcome.error ?? "")
        }

        let reply = try await reference(center, action: "attach", source: sourceURL.lastPathComponent)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["committed"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["rolledBack"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["state"] as? String, "committed_by_concurrent_save", "\(reply)")
        XCTAssertEqual(reply["reference_present"] as? Bool, true, "\(reply)")
        XCTAssertFalse(live.hasUnsavedChanges)

        // The committed reference is still there after a real reopen.
        let revision = live.revision
        let reopened = try await FloeCADDocument.open(at: targetURL)
        XCTAssertEqual(reopened.revision, revision)
        reopened.close()
    }

    /// The verified App-owned update path re-reads the actual source package
    /// and pins its real revision/hash; the removed metadata-only action cannot
    /// provide this. A second source body changes the package identity without
    /// changing the referenced body.
    func testVerifiedHostUpdatePinsActualSourceIdentity() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        let attach = try await reference(center, action: "attach",
                                         source: sourceURL.lastPathComponent)
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let attachedReference = try XCTUnwrap(attach["reference"] as? [String: Any])
        let referenceID = try XCTUnwrap(UUID(uuidString: attachedReference["id"] as? String ?? ""))
        let pinnedSourceHash = try XCTUnwrap(attachedReference["sourceContentHash"] as? String)
        let pinnedStagedHash = try XCTUnwrap(attachedReference["stagedGeometryHash"] as? String)

        // A real second source revision: add another body, then commit it.
        let source = try await FloeCADDocument.open(at: sourceURL)
        let sketch = try run(source, #"{"op":"sketch.create","args":{"name":"Extra"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(source, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[20,0],"max":[30,10]}]}}
        """)
        // A new sketch record changes the verified package identity without
        // rebuilding the referenced body, so the pinned body id stays valid
        // while the source revision/content hash genuinely advance.
        let sourceSave = await source.save()
        XCTAssertTrue(sourceSave.succeeded, sourceSave.error ?? "")
        source.close()
        let actualIdentityValue = await FloeCADDocument.storedIdentity(at: sourceURL)
        let actualIdentity = try XCTUnwrap(actualIdentityValue)
        XCTAssertNotEqual(actualIdentity.contentSHA256, pinnedSourceHash,
                          "the test must produce a genuinely newer source package")

        let update = try await reference(
            center, action: "update", source: sourceURL.lastPathComponent,
            referenceID: referenceID,
            expectedSourceSHA256: pinnedSourceHash,
            expectedStagedSHA256: pinnedStagedHash)
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(update["committed"] as? Bool, true, "\(update)")
        XCTAssertEqual(live.pendingOwnedCommand, nil)

        let request = #"{"kind":"assembly","payload":{"action":"references"}}"#
        let reply = try await center.threeDAction(documentID: "Target.floecad",
                                                  requestJSON: request, access: access())
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
        let rows = try XCTUnwrap(object["references"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == referenceID.uuidString })
        XCTAssertEqual(row["sourceContentHash"] as? String, actualIdentity.contentSHA256)
        XCTAssertEqual(row["sourceRevision"] as? Int, actualIdentity.revision)
        XCTAssertEqual(row["verifierSchemaVersion"] as? Int,
                       FloeCADDocument.supportedPackageSchemaVersion)
    }

    func testLateCancellationAfterSourceLoadStopsBeforeAnyMutation() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        let token = CancellationToken()
        let target = targetURL
        CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = { observedURL in
            guard observedURL.standardizedFileURL == target.standardizedFileURL else { return }
            token.cancel()
            CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil
        }
        defer { CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil }

        do {
            _ = try await reference(center, action: "attach",
                                    source: sourceURL.lastPathComponent,
                                    cancellation: token)
            XCTFail("cancellation observed after the source load must refuse before mutation")
        } catch FloeError.cancelled {
            // expected
        }
        XCTAssertFalse(live.hasUnsavedChanges)
        XCTAssertNil(live.pendingOwnedCommand)
    }

    func testCancelledRuntimeTokenStopsBeforeAnyMutation() async throws {
        let sourceURL = try await makeBodySource(named: "Gear")
        let live = try await makeLiveTarget()
        let center = makeCenter()
        let token = CancellationToken()
        token.cancel()

        do {
            _ = try await reference(center, action: "attach",
                                    source: sourceURL.lastPathComponent,
                                    cancellation: token)
            XCTFail("a cancelled runtime token must refuse the reference call")
        } catch FloeError.cancelled {
            // expected
        }
        XCTAssertFalse(live.hasUnsavedChanges)
        XCTAssertNil(live.pendingOwnedCommand)
        let save = await live.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
    }
}

#endif

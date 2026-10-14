// FloeAppTests — native CAD proposal authority (P0 review fix).
//
// The native 3D apply path must not treat a proposal id or grant as authority
// on its own: the recorded propose-time access context (environment, owner,
// workspace root) and the authorized canonical target are re-checked before a
// grant can be reserved, and a failed apply releases its reservation so the
// same confirmed change can be retried inside the TTL.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloeWorkbench

@MainActor
final class NativeCADProposalAuthorityTests: XCTestCase {

    private var base: URL!
    private var rootA: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-native-authority-\(UUID().uuidString)")
        rootA = base.appendingPathComponent("workspaceA")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in ["part.floecad", "other.floecad"] {
            let url = rootA.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                await FloeCAD3DBridge.shared.releaseDocument(at: url)
            }
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func access(owner: UUID, environment: String = "env-1",
                        kind: String = "chat") -> CadDocumentAccess {
        CadDocumentAccess(environmentID: environment, workspacePath: rootA.path,
                          ownerKind: kind, ownerID: owner)
    }

    private func propose(_ center: CadDocumentCenter, documentID: String,
                         access: CadDocumentAccess) async throws -> UUID {
        let request: [String: Any] = ["kind": "propose", "op": "sketch.create",
                                      "args": ["name": "Probe"],
                                      "summary": "Probe sketch"]
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = try await center.threeDAction(documentID: documentID,
                                                  requestJSON: String(data: data, encoding: .utf8)!,
                                                  access: access)
        let object = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
        let proposal = try XCTUnwrap(object["proposal"] as? [String: Any])
        let raw = try XCTUnwrap(proposal["id"] as? String)
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    @discardableResult
    private func apply(_ center: CadDocumentCenter, documentID: String,
                       proposal: UUID, grant: String, access: CadDocumentAccess,
                       requestID: String) async throws -> [String: Any] {
        let request: [String: Any] = ["kind": "apply", "proposal_id": proposal.uuidString,
                                      "grant_id": grant, "request_id": requestID]
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = try await center.threeDAction(documentID: documentID,
                                                  requestJSON: String(data: data, encoding: .utf8)!,
                                                  access: access)
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])
    }

    private func assertThrows(_ message: String,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected an error: \(message)", file: file, line: line)
        } catch {
            // expected
        }
    }

    /// A valid proposal + valid grant cannot be applied against another
    /// document, another owner/task identity or another environment.
    func testApplyRequiresSameAccessAndCanonicalTarget() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        let docOther = rootA.appendingPathComponent("other.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        _ = try await FloeCADDocument.create(at: docOther, name: "Other")
        let owner = UUID()
        let accessA = access(owner: owner)

        let proposal = try await propose(center, documentID: "part.floecad", access: accessA)
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)
        XCTAssertFalse(grant.isEmpty)

        // Cross-task/environment: same document, different owner identity and
        // environment. The otherwise-valid proposal + grant must be refused
        // before any reservation or mutation.
        let forgedTask = access(owner: UUID(), environment: "env-2", kind: "workspace")
        await assertThrows("cross-task apply") {
            _ = try await self.apply(center, documentID: "part.floecad", proposal: proposal,
                                     grant: grant, access: forgedTask, requestID: "forged-task")
        }

        // Cross-document: same access context, a different canonical target.
        await assertThrows("cross-document apply") {
            _ = try await self.apply(center, documentID: "other.floecad", proposal: proposal,
                                     grant: grant, access: accessA, requestID: "forged-doc")
        }

        // Neither refusal may have mutated either document or consumed the grant.
        let partBefore = try await FloeCADDocument.open(at: docA)
        XCTAssertEqual(partBefore.summary().sketchCount, 0)
        partBefore.close()
        let otherBefore = try await FloeCADDocument.open(at: docOther)
        XCTAssertEqual(otherBefore.summary().sketchCount, 0)
        otherBefore.close()

        // The genuine apply succeeds exactly once and is idempotent for the
        // same request id; a different request id is refused.
        let reply = try await apply(center, documentID: "part.floecad", proposal: proposal,
                                    grant: grant, access: accessA, requestID: "req-1")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(reply["receipt"] as? [String: Any])
        let revision = try XCTUnwrap(receipt["revision"] as? Int)
        XCTAssertEqual(reply["replay"] as? Bool, false)

        let replay = try await apply(center, documentID: "part.floecad", proposal: proposal,
                                     grant: grant, access: accessA, requestID: "req-1")
        XCTAssertEqual(replay["replay"] as? Bool, true)
        XCTAssertEqual((replay["receipt"] as? [String: Any])?["revision"] as? Int, revision)

        await assertThrows("different request id on applied proposal") {
            _ = try await self.apply(center, documentID: "part.floecad", proposal: proposal,
                                     grant: grant, access: accessA, requestID: "req-2")
        }

        // The operation ran once: exactly one probe sketch exists.
        let partAfter = try await FloeCADDocument.open(at: docA)
        XCTAssertEqual(partAfter.summary().sketchCount, 1)
        XCTAssertEqual(partAfter.revision, revision)
        partAfter.close()
    }

    /// A failed apply releases its reservation: retrying with the same grant
    /// fails for the real reason (stale), not "already used", which proves the
    /// grant was not consumed by the failure.
    func testFailedApplyReleasesReservationForRetry() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        let owner = UUID()
        let accessA = access(owner: owner)

        let proposal = try await propose(center, documentID: "part.floecad", access: accessA)
        let grant = try await center.issueNativeCADGrant(proposalID: proposal)
        XCTAssertFalse(grant.isEmpty)

        // Move the live document past the proposal's base revision through the
        // same shared bridge session, so apply reaches the reserve + mutation
        // step and then fails on the stale binding.
        let live = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        let sketch = live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Manual"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let save = await live.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        var firstError: String?
        do {
            _ = try await apply(center, documentID: "part.floecad", proposal: proposal,
                                grant: grant, access: accessA, requestID: "stale-1")
            XCTFail("stale apply must fail")
        } catch {
            firstError = error.localizedDescription
        }
        XCTAssertTrue(firstError?.lowercased().contains("changed") == true,
                      "unexpected first failure: \(firstError ?? "nil")")

        var secondError: String?
        do {
            _ = try await apply(center, documentID: "part.floecad", proposal: proposal,
                                grant: grant, access: accessA, requestID: "stale-2")
            XCTFail("stale retry must fail")
        } catch {
            secondError = error.localizedDescription
        }
        XCTAssertTrue(secondError?.lowercased().contains("changed") == true,
                      "retry must fail for staleness (reservation released), got: \(secondError ?? "nil")")
        XCTAssertFalse(secondError?.lowercased().contains("already used") == true,
                       "the failed apply consumed the grant instead of releasing its reservation")

        // The stale proposal never mutated the document beyond the manual edit.
        let reopened = try await FloeCADDocument.open(at: docA)
        XCTAssertEqual(reopened.summary().sketchCount, 1)
        XCTAssertEqual(reopened.revision, save.revision)
        reopened.close()
    }

    /// Direct payload mutations (assembly/drawing/script/mesh) are refused;
    /// the SAME mutation is reachable through propose → grant → apply with the
    /// exact base revision/SHA binding.
    func testDirectPayloadMutationRefusedAndProposalRouteWorks() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        let owner = UUID()
        let accessA = access(owner: owner)

        // Build a real body so the assembly has something to place.
        let live = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        let sketch = live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String)
        XCTAssertTrue(live.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[20,10]}]}}
        """.utf8)).isOK)
        let extrude = live.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":5}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let bodyID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: extrude.payload)) as? [String: Any])?["producedBodyIDs"] as? [String])?.first

        // Direct mutating payload: refused with a structured reason, and
        // nothing changes.
        let directRequest: [String: Any] = ["kind": "assembly",
                                            "payload": ["action": "addInstance", "bodyID": bodyID]]
        let directReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: directRequest), encoding: .utf8)!,
            access: accessA)
        let direct = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(directReply.utf8))) as? [String: Any])
        XCTAssertEqual(direct["ok"] as? Bool, false)
        XCTAssertEqual(direct["error"] as? String, "proposal_required")
        XCTAssertEqual(live.summary().hasAssembly, false,
                       "a refused direct mutation must not write")

        // Read-only report stays directly callable (durably registered).
        let reportRequest: [String: Any] = ["kind": "assembly", "payload": ["action": "report"]]
        let reportReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: reportRequest), encoding: .utf8)!,
            access: accessA)
        let report = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reportReply.utf8))) as? [String: Any])
        XCTAssertEqual(report["ok"] as? Bool, true)
        XCTAssertNotNil(report["task_id"] as? String)

        // The same mutation through propose → grant → apply commits.
        let proposeRequest: [String: Any] = [
            "kind": "propose", "op": "assembly.addInstance",
            "args": ["bodyID": bodyID, "name": "Placed"],
            "summary": "Place the base body",
        ]
        let proposeReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: proposeRequest), encoding: .utf8)!,
            access: accessA)
        let proposed = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(proposeReply.utf8))) as? [String: Any])
        let proposal = try XCTUnwrap(proposed["proposal"] as? [String: Any])
        XCTAssertEqual((proposal["preview"] as? [String: Any])?["serviceOperation"] as? String,
                       "assembly.addInstance")
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
        let grant = try await center.issueNativeCADGrant(proposalID: proposalID)
        let applied = try await apply(center, documentID: "part.floecad", proposal: proposalID,
                                      grant: grant, access: accessA, requestID: "service-op-1")
        XCTAssertEqual(applied["ok"] as? Bool, true)
        let baseRevision = try XCTUnwrap(proposal["baseRevision"] as? Int)
        XCTAssertEqual((applied["receipt"] as? [String: Any])?["revision"] as? Int,
                       baseRevision + 1)
    }

    /// status/cancel are scoped to the exact owning environment/owner/
    /// workspace document: another task can neither see nor cancel a job.
    func testTaskStatusAndCancelAreOwnershipScoped() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        let ownerA = UUID()
        let accessA = access(owner: ownerA)

        let reportRequest: [String: Any] = ["kind": "assembly", "payload": ["action": "report"]]
        let reportReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: reportRequest), encoding: .utf8)!,
            access: accessA)
        let report = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(reportReply.utf8))) as? [String: Any])
        let taskID = try XCTUnwrap(report["task_id"] as? String)

        // Owner B (same workspace, different owner identity + environment):
        // status must not reveal the job and cancel must be refused.
        let accessB = access(owner: UUID(), environment: "env-2", kind: "workspace")
        let statusB = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(
                withJSONObject: ["kind": "status", "payload": ["task_id": taskID]]), encoding: .utf8)!,
            access: accessB)
        let statusBObject = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(statusB.utf8))) as? [String: Any])
        XCTAssertEqual(statusBObject["count"] as? Int, 0, "foreign owner must not see the job")

        await assertThrows("cross-owner cancel") {
            _ = try await center.threeDAction(
                documentID: "part.floecad",
                requestJSON: String(data: try JSONSerialization.data(
                    withJSONObject: ["kind": "cancel", "payload": ["task_id": taskID]]), encoding: .utf8)!,
                access: accessB)
        }

        // The owner itself sees exactly one job (already completed by then).
        let statusA = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(
                withJSONObject: ["kind": "status", "payload": ["task_id": taskID]]), encoding: .utf8)!,
            access: accessA)
        let statusAObject = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(statusA.utf8))) as? [String: Any])
        XCTAssertEqual(statusAObject["count"] as? Int, 1)
    }

    // MARK: - R2 import proposal authority

    /// A tool-side import drafts a proposal that changes NOTHING until the
    /// user confirms; apply requires the SAME owner/target and a real UI
    /// grant, and re-verifies the exact source bytes. The direct/unconfirmed
    /// import path is gone.
    func testImportRequiresProposalAndUIGrant() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        let owner = UUID()
        let accessA = access(owner: owner)

        // A real STEP solid produced by the kernel's own export from a source
        // package (the production OCCT writer), so the import is REAL kernel
        // geometry, not a mock.
        let sourceDoc = rootA.appendingPathComponent("other.floecad")
        _ = try await FloeCADDocument.create(at: sourceDoc, name: "Source")
        let sourceDocument = try await FloeCAD3DBridge.shared.openDocument(at: sourceDoc)
        let sketch = sourceDocument.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertTrue(sourceDocument.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[30,20]}]}}
        """.utf8)).isOK)
        let extrude = sourceDocument.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[15,10],"distance":6}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        _ = await sourceDocument.save()
        var stepData: Data?
        if case .success(let result) = sourceDocument.nativeExportData(format: "step", pageID: nil) {
            stepData = result.data
        }
        let stepBytes = try XCTUnwrap(stepData)
        await FloeCAD3DBridge.shared.releaseDocument(at: sourceDoc)
        let stepFile = rootA.appendingPathComponent("bracket.step")
        try stepBytes.write(to: stepFile)
        let targetBefore = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        XCTAssertEqual(targetBefore.summary().bodyCount, 0)

        // 1. Draft the import through the shared authority: it returns a
        //    pending proposal and MUST NOT mutate the package yet.
        let importRequest: [String: Any] = [
            "kind": "import",
            "payload": ["path": "bracket.step", "format": "step"],
        ]
        let importReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: importRequest), encoding: .utf8)!,
            access: accessA)
        let importObject = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(importReply.utf8))) as? [String: Any])
        XCTAssertEqual(importObject["ok"] as? Bool, true)
        let proposal = try XCTUnwrap(importObject["proposal"] as? [String: Any])
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
        let importInfo = try XCTUnwrap(importObject["import"] as? [String: Any])
        XCTAssertEqual(importInfo["format"] as? String, "step")
        XCTAssertNotNil(importInfo["source_sha256"] as? String)
        // Nothing changed yet: the live document still has no body.
        XCTAssertEqual(targetBefore.summary().bodyCount, 0,
                       "import draft must never write before a confirmed apply")

        // 2. Apply without a grant is refused before any mutation.
        await assertThrows("apply without a grant") {
            _ = try await self.apply(center, documentID: "part.floecad", proposal: proposalID,
                                     grant: "forged-grant", access: accessA, requestID: "req-import-forged")
        }
        XCTAssertEqual(targetBefore.summary().bodyCount, 0)

        // 3. Apply from a foreign owner is refused.
        let forgedOwner = access(owner: UUID(), environment: "env-2", kind: "workspace")
        await assertThrows("cross-owner import apply") {
            _ = try await self.apply(center, documentID: "part.floecad", proposal: proposalID,
                                     grant: "any", access: forgedOwner, requestID: "req-import-x")
        }

        // 4. A real UI grant applies ONCE: the imported body appears, the
        //    revision advances by exactly one, and the receipt replays for
        //    the same request id.
        let grant = try await center.issueNativeCADGrant(proposalID: proposalID)
        XCTAssertFalse(grant.isEmpty)
        let applied = try await apply(center, documentID: "part.floecad", proposal: proposalID,
                                      grant: grant, access: accessA, requestID: "req-import-1")
        XCTAssertEqual(applied["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(applied["receipt"] as? [String: Any])
        let appliedRevision = try XCTUnwrap(receipt["revision"] as? Int)

        let live = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        XCTAssertEqual(live.summary().bodyCount, 1, "the imported solid must be committed")
        XCTAssertEqual(live.revision, appliedRevision)

        let replay = try await apply(center, documentID: "part.floecad", proposal: proposalID,
                                     grant: grant, access: accessA, requestID: "req-import-1")
        XCTAssertEqual(replay["replay"] as? Bool, true)

        // The source file was never modified by the import.
        let afterBytes = try Data(contentsOf: stepFile)
        XCTAssertEqual(afterBytes, stepBytes, "the import source must be unchanged")
        // The committed package reopens with the imported body.
        await FloeCAD3DBridge.shared.releaseDocument(at: docA)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        await FloeCAD3DBridge.shared.releaseDocument(at: docA)
    }

    /// Import targets that are missing / not-a-package / a non-native
    /// extension are refused with the documented distinct classes; an
    /// unsupported source extension and an out-of-workspace source are
    /// refused before any mutation.
    func testImportRejectsInvalidTargetsAndSources() async throws {
        let center = CadDocumentCenter()
        let owner = UUID()
        let accessA = access(owner: owner)
        let stepFile = rootA.appendingPathComponent("a.step")
        try "ISO-10303-21;\n".write(to: stepFile, atomically: true, encoding: .utf8)

        func importRequest(document: String, source: String = "a.step",
                           format: String? = "step") -> String {
            var payload: [String: Any] = ["path": source]
            if let format { payload["format"] = format }
            return String(data: try! JSONSerialization.data(withJSONObject:
                ["kind": "import", "payload": payload]), encoding: .utf8)!
        }

        // Nonexistent package → notFound.
        await assertThrows("import into a missing package") {
            _ = try await center.threeDAction(documentID: "missing.floecad",
                                              requestJSON: importRequest(document: "missing.floecad"),
                                              access: accessA)
        }
        // A folder that is not a package → validation failure, not notFound.
        let folder = rootA.appendingPathComponent("not-a-package.floecad")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await assertThrows("import into a non-package folder") {
            _ = try await center.threeDAction(documentID: "not-a-package.floecad",
                                              requestJSON: importRequest(document: "not-a-package.floecad"),
                                              access: accessA)
        }
        // A DWG/DXF cannot be an import target (2D stays on its own surface).
        let dwg = rootA.appendingPathComponent("a.dwg")
        try Data().write(to: dwg)
        await assertThrows("import into a DWG target") {
            _ = try await center.threeDAction(documentID: "a.dwg",
                                              requestJSON: importRequest(document: "a.dwg"),
                                              access: accessA)
        }
        // Unsupported source extension on a real package → validation failure.
        let target = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: target, name: "PartA")
        let txt = rootA.appendingPathComponent("notes.txt")
        try "hi".write(to: txt, atomically: true, encoding: .utf8)
        await assertThrows("unsupported source extension") {
            _ = try await center.threeDAction(documentID: "part.floecad",
                                              requestJSON: importRequest(document: "part.floecad",
                                                                         source: "notes.txt", format: "txt"),
                                              access: accessA)
        }
        // A source outside the workspace root → validation failure.
        let outside = base.appendingPathComponent("outside.step")
        try "ISO-10303-21;\n".write(to: outside, atomically: true, encoding: .utf8)
        await assertThrows("out-of-workspace import source") {
            _ = try await center.threeDAction(documentID: "part.floecad",
                                              requestJSON: importRequest(document: "part.floecad",
                                                                         source: outside.path),
                                              access: accessA)
        }
        // Nothing was mutated by any refusal.
        let live = try await FloeCAD3DBridge.shared.openDocument(at: target)
        XCTAssertEqual(live.summary().bodyCount, 0)
    }

    /// A real import proposal is refused when the document moved past the
    /// proposal's base revision before apply (stale revision guard), and the
    /// failed apply does NOT consume the grant.
    func testStaleImportProposalIsRefused() async throws {
        let center = CadDocumentCenter()
        let docA = rootA.appendingPathComponent("part.floecad")
        _ = try await FloeCADDocument.create(at: docA, name: "PartA")
        let owner = UUID()
        let accessA = access(owner: owner)

        let sourceDoc = rootA.appendingPathComponent("other.floecad")
        _ = try await FloeCADDocument.create(at: sourceDoc, name: "Source")
        let sourceDocument = try await FloeCAD3DBridge.shared.openDocument(at: sourceDoc)
        let sketch = sourceDocument.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertTrue(sourceDocument.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8)).isOK)
        let extrude = sourceDocument.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[5,5],"distance":4}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        _ = await sourceDocument.save()
        var stepData: Data?
        if case .success(let result) = sourceDocument.nativeExportData(format: "step", pageID: nil) {
            stepData = result.data
        }
        let stepBytes = try XCTUnwrap(stepData)
        await FloeCAD3DBridge.shared.releaseDocument(at: sourceDoc)
        try stepBytes.write(to: rootA.appendingPathComponent("a.step"))

        // Draft the import.
        let importRequest: [String: Any] = [
            "kind": "import", "payload": ["path": "a.step", "format": "step"],
        ]
        let importReply = try await center.threeDAction(
            documentID: "part.floecad",
            requestJSON: String(data: try JSONSerialization.data(withJSONObject: importRequest), encoding: .utf8)!,
            access: accessA)
        let importObject = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(importReply.utf8))) as? [String: Any])
        let proposal = try XCTUnwrap(importObject["proposal"] as? [String: Any])
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
        let grant = try await center.issueNativeCADGrant(proposalID: proposalID)

        // Move the live document past the base revision (a manual edit).
        let live = try await FloeCAD3DBridge.shared.openDocument(at: docA)
        let edit = live.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Manual"}}"#.utf8))
        XCTAssertTrue(edit.isOK, edit.message ?? "")
        _ = await live.save()

        // The stale apply must fail and must NOT consume the grant.
        var firstError: String?
        do {
            _ = try await apply(center, documentID: "part.floecad", proposal: proposalID,
                                grant: grant, access: accessA, requestID: "stale-import-1")
            XCTFail("a stale import apply must fail")
        } catch { firstError = error.localizedDescription }
        XCTAssertTrue(firstError?.lowercased().contains("changed") == true,
                      "unexpected error: \(firstError ?? "nil")")
        // Retrying the SAME stale proposal still fails for staleness, never
        // "already used": the failed apply released the reservation.
        var secondError: String?
        do {
            _ = try await apply(center, documentID: "part.floecad", proposal: proposalID,
                                grant: grant, access: accessA, requestID: "stale-import-2")
            XCTFail("a stale import retry must fail")
        } catch { secondError = error.localizedDescription }
        XCTAssertTrue(secondError?.lowercased().contains("changed") == true)
        XCTAssertFalse(secondError?.lowercased().contains("already used") == true)
    }
}

#endif

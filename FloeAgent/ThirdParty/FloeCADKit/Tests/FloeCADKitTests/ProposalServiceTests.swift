//
//  ProposalServiceTests.swift
//  FloeCADKitTests
//
//  Explicit-effect contract for native CAD proposals: propose evaluates on a
//  throwaway copy and never writes; apply needs a UI-issued single-use grant,
//  refuses stale documents and forged/missing grants, and commits with CAS.
//

import XCTest
@testable import FloeCAD

final class ProposalServiceTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADProposal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(at: workDir.appendingPathComponent("p.floecad"),
                                                    name: "Proposal")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func createSketchID(_ document: FloeCADDocument, name: String) -> String {
        let outcome = document.executeJSON(Data("""
        {"op":"sketch.create","args":{"name":"\(name)"}}
        """.utf8))
        let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any]
        return object?["sketchID"] as? String ?? ""
    }

    func testProposeDoesNotMutateLiveDocument() async throws {
        let service = CADProposalService()
        let sketchID = createSketchID(document, name: "Base")
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[30,20]}]}}
        """.utf8))
        _ = await document.save()
        let revisionBefore = document.revision
        let shaBefore = document.contentSHA256
        let bodiesBefore = document.summary().bodyCount

        let operation = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":5}}
        """
        let proposal = try await service.propose(document: document, operationJSON: operation,
                                           summary: "Extrude a 30×20×5 block")
        XCTAssertEqual(proposal.baseRevision, revisionBefore)
        XCTAssertEqual(proposal.baseContentSHA256, shaBefore)
        XCTAssertEqual(proposal.preview.bodyCountBefore, bodiesBefore)
        XCTAssertEqual(proposal.preview.bodyCountAfter, bodiesBefore + 1)
        XCTAssertEqual(proposal.preview.volumeAfterMM3, 30 * 20 * 5, accuracy: 1e-3)
        XCTAssertFalse(proposal.preview.failed)

        // The live document never changed.
        XCTAssertEqual(document.revision, revisionBefore)
        XCTAssertEqual(document.contentSHA256, shaBefore)
        XCTAssertEqual(document.summary().bodyCount, bodiesBefore)
    }

    func testProposeFlushesUnsavedEditsIntoThePreview() async throws {
        let service = CADProposalService()
        let sketchID = createSketchID(document, name: "Unsaved")
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[9,5]}]}}
        """.utf8))
        // Deliberately NOT saved: the preview must flush the in-memory edit
        // and include the resulting body.
        XCTAssertTrue(document.hasUnsavedChanges)
        let operation = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":2}}
        """
        let proposal = try await service.propose(document: document, operationJSON: operation,
                                                 summary: "Extrude unsaved profile")
        XCTAssertFalse(document.hasUnsavedChanges, "propose must flush the live revision")
        XCTAssertEqual(proposal.preview.bodyCountBefore, 0)
        XCTAssertEqual(proposal.preview.bodyCountAfter, 1)
        XCTAssertEqual(proposal.preview.volumeAfterMM3, 9 * 5 * 2, accuracy: 1e-3)
        XCTAssertEqual(proposal.baseRevision, document.revision)
        XCTAssertEqual(proposal.baseContentSHA256, document.contentSHA256)
    }

    func testForgedOrMissingGrantIsRefused() async throws {
        let service = CADProposalService()
        let sketchID = createSketchID(document, name: "Base")
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8))
        _ = await document.save()
        let operation = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":3}}
        """
        let proposal = try await service.propose(document: document, operationJSON: operation,
                                           summary: "Extrude")

        do {
            _ = try await service.apply(document: document, proposalID: proposal.id,
                                        grantID: UUID().uuidString)
            XCTFail("a forged grant must be refused")
        } catch let error as CADProposalError {
            XCTAssertEqual(error.code, "grant_required")
        }
        XCTAssertEqual(document.summary().bodyCount, 0, "refused apply must not mutate")
    }

    func testIssueGrantApplyCommitsAndReopens() async throws {
        let service = CADProposalService()
        let sketchID = createSketchID(document, name: "Base")
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[12,8]}]}}
        """.utf8))
        _ = await document.save()
        let operation = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":4}}
        """
        let proposal = try await service.propose(document: document, operationJSON: operation,
                                           summary: "Extrude a 12×8×4 block")
        let grantID = try service.issueGrant(proposalID: proposal.id)
        let receipt = try await service.apply(document: document, proposalID: proposal.id,
                                              grantID: grantID)
        XCTAssertEqual(receipt.proposalID, proposal.id)
        XCTAssertGreaterThan(receipt.revision, proposal.baseRevision)
        XCTAssertNotEqual(receipt.contentSHA256, proposal.baseContentSHA256)
        XCTAssertEqual(document.summary().bodyCount, 1)

        // Idempotent replay with the SAME consumed grant returns the original
        // receipt without mutating again.
        let replay = try await service.apply(document: document, proposalID: proposal.id,
                                             grantID: grantID)
        XCTAssertEqual(replay.revision, receipt.revision)
        XCTAssertEqual(document.summary().bodyCount, 1)
        // A different (forged or newly guessed) grant is refused.
        do {
            _ = try await service.apply(document: document, proposalID: proposal.id,
                                        grantID: UUID().uuidString)
            XCTFail("a different grant must not authorise a second mutation")
        } catch let error as CADProposalError {
            XCTAssertEqual(error.code, "already_applied")
        }

        // Reopen sees the committed body.
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        let bodies = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: reopened.snapshotJSON())) as? [String: Any])?["bodies"] as? [[String: Any]])
        XCTAssertEqual((bodies.first?["volumeMM3"] as? Double) ?? 0, 12 * 8 * 4, accuracy: 1e-3)
        reopened.close()
    }

    func testStaleProposalIsRefusedAndLeavesDocumentIntact() async throws {
        let service = CADProposalService()
        let sketchID = createSketchID(document, name: "Base")
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8))
        _ = await document.save()
        let operation = """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":2}}
        """
        let proposal = try await service.propose(document: document, operationJSON: operation,
                                           summary: "Extrude")
        let grantID = try service.issueGrant(proposalID: proposal.id)

        // Move the document on after drafting.
        _ = document.executeJSON(Data("""
        {"op":"sketch.create","args":{"name":"Later"}}
        """.utf8))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded)
        let revisionAfter = document.revision
        let bodiesAfter = document.summary().bodyCount

        do {
            _ = try await service.apply(document: document, proposalID: proposal.id,
                                        grantID: grantID)
            XCTFail("a stale proposal must be refused")
        } catch let error as CADProposalError {
            XCTAssertEqual(error.code, "stale_proposal")
        }
        XCTAssertEqual(document.revision, revisionAfter)
        XCTAssertEqual(document.summary().bodyCount, bodiesAfter)
    }

    func testMalformedOperationIsRejected() async throws {
        let service = CADProposalService()
        await assertProposeThrows(service, operationJSON: "not json")
        await assertProposeThrows(service, operationJSON: #"{"args":{}}"#)
    }

    private func assertProposeThrows(_ service: CADProposalService,
                                     operationJSON: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async {
        do {
            _ = try await service.propose(document: document,
                                          operationJSON: operationJSON,
                                          summary: "bad")
            XCTFail("malformed operation must be refused", file: file, line: line)
        } catch {
            // expected
        }
    }
}

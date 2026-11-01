//
//  NativeCADImportSchedulingTests.swift
//  FloeAppTests
//
//  E31-R2 App-level qualification for native import scheduling:
//
//    * the real tool import of a STEP/IGES source drafts and applies through
//      the production host/bridge while its read+tessellation runs off the
//      MainActor (deterministic off-main checkpoint) and the MainActor
//      heartbeat/phys_footprint are measured;
//    * the manual Workbench path (`probeMeshOffMain` + units prompt and
//      `importExactOffMain`) uses the SAME prepared values, never reparses the
//      source, and commits exactly one undo step;
//    * the AgentExec `document.import` path is asynchronous: the sync entry
//      refuses with `import_requires_async`, while `executeAsync` performs the
//      real off-main parse;
//    * a cancel during the real exact parse, and a close/switch while it is
//      running, leave no proposal, body, revision or source change;
//    * an over-budget exact parse is refused before any body is built.
//
//  Metrics are real `task_vm_info.phys_footprint` of this test process and a
//  MainActor heartbeat. Root runs this on the pinned iPad Simulator; it is NOT
//  a physical-iPad memory or latency measurement.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(UIKit)
import Darwin
import Foundation
import simd
import XCTest
@testable import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

@MainActor
final class NativeCADImportSchedulingTests: XCTestCase {
    private var workspace: URL!
    private var center: CadDocumentCenter!
    private var ownerID = UUID()

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-import-scheduling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
        ownerID = UUID()
        CADExactImportService.testCheckpoint = nil
        MeshImportKit.testParseCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
    }

    override func tearDown() async throws {
        CADExactImportService.testCheckpoint = nil
        MeshImportKit.testParseCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
        let url = workspace?.appendingPathComponent("Part.floecad")
        if let url {
            for proposal in FloeCAD3DBridge.shared.pendingProposals(for: url) {
                FloeCAD3DBridge.shared.discard(proposalID: proposal.id)
            }
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
        }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    // MARK: - Fixtures

    private var documentURL: URL { workspace.appendingPathComponent("Part.floecad") }

    private func makeTargetDocument() async throws {
        let document = try await FloeCADDocument.create(at: documentURL, name: "Part")
        document.close()
    }

    private func makeContext(_ token: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "e31-sched-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: token, environmentID: "env-e31-r2",
                    conversationID: UUID())
    }

    private func access() -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-e31-r2", workspacePath: workspace.path,
                          ownerKind: "workspace", ownerID: ownerID)
    }

    private func storedIdentity() async -> (revision: Int, sha: String)? {
        guard let identity = await FloeCADDocument.storedIdentity(at: documentURL) else { return nil }
        return (identity.revision, identity.contentSHA256)
    }

    private func requireStoredIdentity() async throws -> (revision: Int, sha: String) {
        let captured = await storedIdentity()
        return try XCTUnwrap(captured)
    }

    private func bodyCount() async throws -> Int {
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        return document.summary().bodyCount
    }

    /// Build a real plate in a temporary document and export real STEP/IGES.
    private func exactFixture(format: String) async throws -> Data {
        let directory = workspace.appendingPathComponent("exact-\(UUID().uuidString)",
                                                         isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("source.floecad"), name: "Source")
        defer { source.close() }
        let sketch = try XCTUnwrap(run(source, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try run(source, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[0,0],"max":[60,40]}]}}
        """)
        _ = try run(source, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[30,20],"distance":10}}
        """)
        let result = source.nativeExportData(format: format, pageID: nil)
        switch result {
        case .success(let (data, _)):
            XCTAssertFalse(data.isEmpty, "the real \(format.uppercased()) writer produced no bytes")
            return data
        case .failure(let error):
            throw error
        }
    }

    /// Two real exact solids in one STEP payload (for a cancel between
    /// prepared bodies). The kernel writes both; nothing is hand-authored.
    private func twoSolidSTEP() throws -> Data {
        let first = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 20, depth: 20, height: 20), placement: .identity))
        let second = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        var moved = Transform3D.identity
        moved.translation = SIMD3<Double>(40, 0, 0)
        let placed = try XCTUnwrap(OCCTKernel.transformed(second, by: moved))
        let url = workspace.appendingPathComponent("two-solids-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([first, placed], to: url))
        return try Data(contentsOf: url)
    }

    /// A real open-surface IGES file from OCCT's own writer (DEBUG fixture
    /// support; the product writer is the same kernel writer).
    private func surfaceIGES() throws -> Data {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 20, depth: 20, height: 20), placement: .identity))
        let face = try XCTUnwrap(OCCTKernel.debugStandaloneFace(from: box))
        let url = workspace.appendingPathComponent("surface-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([face], to: url, brepMode: true))
        return try Data(contentsOf: url)
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any]
        else {
            throw CADDocumentError(code: outcome.errorCode ?? "fixture_failed",
                                   message: outcome.message ?? json)
        }
        return object
    }

    // MARK: - Tool import (draft + apply)

    private struct ImportReply {
        let proposalID: UUID?
        let summary: String
    }

    private func runToolImport(source: String, format: String,
                               context: ToolContext) async throws -> ImportReply {
        let tool = CadDocumentTool(host: center)
        let payload: [String: Any] = [
            "action": "import",
            "path": "Part.floecad",
            "source_path": source,
            "format": format,
        ]
        let args = try JSONDecoder().decode(
            CadDocumentArguments.self,
            from: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        try tool.validate(args)
        let output = try await tool.execute(args, context: context)
        let summary = output.summary
        var id: UUID?
        if let open = summary.firstIndex(of: "{"),
           let close = summary.lastIndex(of: "}"),
           let data = String(summary[open...close]).data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let proposal = object["proposal"] as? [String: Any],
           let raw = proposal["id"] as? String {
            id = UUID(uuidString: raw)
        }
        return ImportReply(proposalID: id, summary: summary)
    }

    private func applyProposal(_ id: UUID) async throws -> CADApplyReceipt {
        let grant = try await center.issueNativeCADGrant(proposalID: id)
        return try await center.applyNativeCAD(proposalID: id, grantID: grant)
    }

    private func importRequest(_ source: String, format: String) throws -> String {
        let object: [String: Any] = [
            "kind": "import",
            "payload": ["path": source, "format": format],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
                                                           options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: - Real tool STEP import

    func testToolSTEPImportRunsOffMainAndCommitsOneUndoStep() async throws {
        try await makeTargetDocument()
        let step = try await exactFixture(format: "step")
        let sourceURL = workspace.appendingPathComponent("plate.step")
        try step.write(to: sourceURL)
        let sourceSHA = FloeDigest.sha256Hex(step)
        let identityBefore = try await requireStoredIdentity()

        let recorder = ExactCheckpointRecorder()
        CADExactImportService.testCheckpoint = { recorder.record($0) }
        defer { CADExactImportService.testCheckpoint = nil }

        let sampler = E31SchedulingFootprint()
        sampler.start()
        let heartbeat = E31SchedulingHeartbeat()
        heartbeat.start()
        let reply = try await runToolImport(source: "plate.step", format: "step",
                                            context: makeContext())
        heartbeat.stop()
        let draftMemory = sampler.stop()

        let proposalID = try XCTUnwrap(reply.proposalID, reply.summary)
        XCTAssertTrue(recorder.sawOffMain,
                      "the real STEP read/tessellation must run off the MainActor")
        XCTAssertTrue(recorder.sawPhase("read"))
        XCTAssertGreaterThan(heartbeat.ticks, 0)
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "the off-main STEP draft blocked the MainActor for \(heartbeat.maxGap)s")
        let pendingPreview = await center.pendingNativeProposals(for: documentURL)
        XCTAssertEqual(pendingPreview.count, 1)
        let previewBodies = try await bodyCount()
        XCTAssertEqual(previewBodies, 0, "a draft must not mutate the live document")
        let previewIdentity = try await requireStoredIdentity()
        XCTAssertEqual(previewIdentity.revision, identityBefore.revision)

        let applySampler = E31SchedulingFootprint()
        applySampler.start()
        let applyHeartbeat = E31SchedulingHeartbeat()
        applyHeartbeat.start()
        let receipt = try await applyProposal(proposalID)
        applyHeartbeat.stop()
        let applyMemory = applySampler.stop()

        XCTAssertEqual(receipt.revision, identityBefore.revision + 1)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1,
                       "the exact import must be one undo step")
        XCTAssertNotNil(document.session.document.bodies.first?.brep,
                        "the imported STEP plate must stay an exact solid")
        XCTAssertFalse(recorder.sawMainThreadBody,
                       "body preparation must never run on the MainActor")
        XCTAssertLessThan(applyHeartbeat.maxGap, 0.5,
                          "the off-main STEP apply blocked the MainActor for \(applyHeartbeat.maxGap)s")
        XCTAssertEqual(try Data(contentsOf: sourceURL), step)
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: sourceURL)), sourceSHA)
        let pendingAfterApply = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pendingAfterApply.isEmpty)
        attachMetrics("tool-step", fields: [
            "sourceBytes": step.count,
            "bodies": 1,
            "phaseCount": recorder.phases.count,
            "sawOffMain": true,
            "previewMainActorMaxGapSeconds": heartbeat.maxGap,
            "applyMainActorMaxGapSeconds": applyHeartbeat.maxGap,
            "previewMainActorTicks": heartbeat.ticks,
            "applyMainActorTicks": applyHeartbeat.ticks,
            "revisionDelta": receipt.revision - identityBefore.revision,
            "undoSteps": 1,
            "sourceUnchanged": true,
        ], memory: draftMemory, heartbeat: heartbeat, extraMemory: applyMemory)
    }

    func testToolIGESSurfaceImportKeepsOpenSurfaceSemanticsAcrossScheduling() async throws {
        try await makeTargetDocument()
        let iges = try surfaceIGES()
        let sourceURL = workspace.appendingPathComponent("surface.igs")
        try iges.write(to: sourceURL)
        let identityBefore = try await requireStoredIdentity()
        let recorder = ExactCheckpointRecorder()
        CADExactImportService.testCheckpoint = { recorder.record($0) }
        defer { CADExactImportService.testCheckpoint = nil }

        let draftSampler = E31SchedulingFootprint()
        draftSampler.start()
        let heartbeat = E31SchedulingHeartbeat()
        heartbeat.start()
        let reply = try await runToolImport(source: "surface.igs", format: "iges",
                                            context: makeContext())
        heartbeat.stop()
        let draftMemory = draftSampler.stop()
        let proposalID = try XCTUnwrap(reply.proposalID, reply.summary)
        XCTAssertTrue(recorder.sawOffMain)
        XCTAssertGreaterThanOrEqual(recorder.maxIGESRoots, 1,
                                    "the real IGES fixture must carry at least one root")
        XCTAssertTrue(reply.summary.lowercased().contains("surface"), reply.summary)
        XCTAssertGreaterThan(heartbeat.ticks, 0)
        XCTAssertLessThan(heartbeat.maxGap, 0.5)

        let applySampler = E31SchedulingFootprint()
        applySampler.start()
        let applyHeartbeat = E31SchedulingHeartbeat()
        applyHeartbeat.start()
        let receipt = try await applyProposal(proposalID)
        applyHeartbeat.stop()
        let applyMemory = applySampler.stop()
        XCTAssertEqual(receipt.revision, identityBefore.revision + 1)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        XCTAssertGreaterThanOrEqual(document.summary().bodyCount, 1)
        let surfaces = document.session.document.bodies.filter { $0.surfaceBRep != nil }
        XCTAssertGreaterThanOrEqual(surfaces.count, 1)
        XCTAssertTrue(surfaces.allSatisfy { $0.brep == nil },
                      "an IGES surface must never become a solid B-rep body")
        XCTAssertLessThan(applyHeartbeat.maxGap, 0.5)
        attachMetrics("tool-iges-surface", fields: [
            "sourceBytes": iges.count,
            "bodyCount": document.summary().bodyCount,
            "surfaceBodies": surfaces.count,
            "sawOffMain": true,
            "previewMainActorMaxGapSeconds": heartbeat.maxGap,
            "applyMainActorMaxGapSeconds": applyHeartbeat.maxGap,
            "previewMainActorTicks": heartbeat.ticks,
            "applyMainActorTicks": applyHeartbeat.ticks,
            "revisionDelta": receipt.revision - identityBefore.revision,
            "sourceUnchanged": try Data(contentsOf: sourceURL) == iges,
        ], memory: draftMemory, heartbeat: heartbeat, extraMemory: applyMemory)
    }

    // MARK: - Cancellation / close-switch fences

    func testCancelDuringExactParseLeavesNoProposalBodyOrRevision() async throws {
        try await makeTargetDocument()
        let step = try twoSolidSTEP()
        let sourceURL = workspace.appendingPathComponent("cancel.step")
        try step.write(to: sourceURL)
        let identityBefore = try await requireStoredIdentity()
        let token = CancellationToken()
        let gate = E31SchedulingExactGate(hold: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { gate.checkpoint($0) }
        defer { CADExactImportService.testCheckpoint = nil }

        let task = Task { @MainActor () -> Error? in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.importRequest("cancel.step", format: "step"),
                    access: self.access(), cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        XCTAssertTrue(gate.observedOffMain,
                      "the cancelled STEP parse must run off the MainActor")
        token.cancel()
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("expected FloeError.cancelled, got \(String(describing: error))")
        }
        let pendingAfterCancel = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pendingAfterCancel.isEmpty)
        let bodiesAfterCancel = try await bodyCount()
        XCTAssertEqual(bodiesAfterCancel, 0)
        let identityAfterCancel = try await requireStoredIdentity()
        XCTAssertEqual(identityAfterCancel.revision, identityBefore.revision)
        XCTAssertEqual(identityAfterCancel.sha, identityBefore.sha)
        XCTAssertEqual(try Data(contentsOf: sourceURL), step)
    }

    func testCloseAndSwitchDuringExactParseFencesTheLateCommit() async throws {
        try await makeTargetDocument()
        let step = try twoSolidSTEP()
        let sourceURL = workspace.appendingPathComponent("switch.step")
        try step.write(to: sourceURL)
        let token = CancellationToken()
        let gate = E31SchedulingExactGate(hold: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { gate.checkpoint($0) }
        defer { CADExactImportService.testCheckpoint = nil }
        let original = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)

        let task = Task { @MainActor () -> Error? in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.importRequest("switch.step", format: "step"),
                    access: self.access(), cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        // Release commits the clean session's package metadata as one new
        // revision (the bridge always saves on release). That commit is the
        // baseline for the reopened identity; the late exact parse must add
        // no body and no further identity change.
        let released = await FloeCAD3DBridge.shared.releaseDocumentOutcome(
            at: documentURL, expected: original)
        let release = try XCTUnwrap(released,
                                    "the bridge must own the exact session it opened")
        XCTAssertNil(release.error, release.error ?? "")
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("a close/switch must cancel the draft, got \(String(describing: error))")
        }
        XCTAssertEqual(reopened.summary().bodyCount, 0,
                       "a late exact parse must not commit into the newer session")
        XCTAssertEqual(reopened.revision, release.revision,
                       "the reopened session must match the release commit, not a late import")
        XCTAssertEqual(reopened.contentSHA256, release.contentSHA256)
        let pendingAfterApply = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pendingAfterApply.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sourceURL), step)
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL, expected: reopened)
    }

    // MARK: - Manual Workbench path

    func testManualSTEPImportUsesPreparedPlanAndOneUndoStep() async throws {
        try await makeTargetDocument()
        let step = try await exactFixture(format: "step")
        let sourceURL = workspace.appendingPathComponent("manual.step")
        try step.write(to: sourceURL)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        let model = document.viewModel()
        let recorder = ExactCheckpointRecorder()
        CADExactImportService.testCheckpoint = { recorder.record($0) }
        defer { CADExactImportService.testCheckpoint = nil }

        let heartbeat = E31SchedulingHeartbeat()
        heartbeat.start()
        // A sub-5 ms import cannot be proven live by counting only the ticks
        // that happen to land inside it: the first heartbeat tick and the
        // post-import tick are ordered explicitly so the max-gap sample spans
        // the whole import instead of silently staying at zero samples.
        await heartbeat.waitForTick()
        let ticksBeforeImport = heartbeat.ticks
        let ok = await model.importExactOffMain(data: step, fileName: "manual.step",
                                               format: "step")
        await heartbeat.waitForTick()
        XCTAssertGreaterThan(heartbeat.ticks, ticksBeforeImport,
                             "the MainActor heartbeat must still tick after the import")
        heartbeat.stop()
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.sawOffMain)
        XCTAssertGreaterThan(heartbeat.ticks, 0)
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "the manual STEP parse blocked the MainActor for \(heartbeat.maxGap)s")
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
        XCTAssertGreaterThan(document.session.document.bodies.first?.render.triangleCount ?? 0, 0)
        XCTAssertNotNil(document.session.document.bodies.first?.brep)
        XCTAssertEqual(try Data(contentsOf: sourceURL), step)
        // The parsed plan is applied once: no second exact read for the commit.
        XCTAssertEqual(recorder.count(of: "read"), 1)
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
    }

    func testManualMeshProbeAndUnitsPromptDoNotReparse() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 20_000)
        let sourceURL = workspace.appendingPathComponent("manual.glb")
        try glb.write(to: sourceURL)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        let model = document.viewModel()
        let recorder = MeshParseRecorder()
        MeshImportKit.testParseCheckpoint = { recorder.record($0) }
        defer { MeshImportKit.testParseCheckpoint = nil }

        let probedValue = await model.probeMeshOffMain(data: glb, fileName: "manual.glb")
        let probe = try XCTUnwrap(probedValue)
        XCTAssertTrue(recorder.sawOffMain, "the manual mesh probe must parse off-main")
        // "start" is emitted once by a real parse; a budget charge also fires
        // for the units-scale copy, so charges alone cannot prove "no reparse".
        let parsesAfterProbe = recorder.parseCount
        XCTAssertGreaterThan(parsesAfterProbe, 0)

        await model.importMeshProbe(probe, unit: .millimetres)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
        XCTAssertEqual(recorder.parseCount, parsesAfterProbe,
                       "applying the units prompt must not reparse the source")
        XCTAssertEqual(try Data(contentsOf: sourceURL), glb)
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
    }

    // MARK: - AgentExec document.import

    func testAgentExecImportIsAsyncAndSyncEntryRefusesExplicitly() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 5_000)
        let sourceURL = workspace.appendingPathComponent("agent.glb")
        try glb.write(to: sourceURL)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        let operation: [String: Any] = [
            "op": "document.import",
            "args": ["path": sourceURL.path, "fileName": "agent.glb"],
        ]
        let sync = document.execute(operation)
        XCTAssertFalse(sync.isOK)
        XCTAssertEqual(sync.errorCode, "import_requires_async")
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertFalse(document.session.undoStack.canUndo)

        let recorder = MeshParseRecorder()
        MeshImportKit.testParseCheckpoint = { recorder.record($0) }
        defer { MeshImportKit.testParseCheckpoint = nil }
        let async = await document.executeAsync(operation)
        XCTAssertTrue(async.isOK, async.message ?? "")
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
        XCTAssertTrue(recorder.sawOffMain)
        XCTAssertEqual(try Data(contentsOf: sourceURL), glb)
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
    }

    // MARK: - Budget refusal

    func testOverBudgetExactParseIsRefusedBeforeCommit() async throws {
        try await makeTargetDocument()
        let step = try await exactFixture(format: "step")
        let sourceURL = workspace.appendingPathComponent("budget.step")
        try step.write(to: sourceURL)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        let identityBefore = try await requireStoredIdentity()
        // The open advances changeCount by one (DocumentSession.load); a
        // refused parse must add nothing beyond that fixture baseline.
        let changeCountAfterLoad = document.session.changeCount
        let tight = MeshImportLimits(maximumTriangles: 1,
                                     maximumParts: 4_096,
                                     maximumExpandedBytes: 256 * 1024 * 1024,
                                     maximumArchiveEntries: 5_000)
        let sampler = E31SchedulingFootprint()
        sampler.start()
        let ok = await modelImportWithTightBudget(document: document, data: step, limits: tight)
        let memory = sampler.stop()
        XCTAssertFalse(ok)
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertEqual(document.session.changeCount, changeCountAfterLoad,
                       "a refused exact import must not add any document mutation")
        let identityAfterRefusal = await storedIdentity()
        XCTAssertEqual(identityAfterRefusal?.revision, identityBefore.revision)
        XCTAssertEqual(try Data(contentsOf: sourceURL), step)
        XCTAssertLessThan(memory.peakDelta, 64 * 1024 * 1024,
                          "the declaration/budget refusal must not allocate a body")
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
    }

    private func modelImportWithTightBudget(document: FloeCADDocument, data: Data,
                                            limits: MeshImportLimits) async -> Bool {
        let model = document.viewModel()
        return await model.importExactOffMain(data: data, fileName: "budget.step",
                                              format: "step", limits: limits)
    }

    // MARK: - Fixtures

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func gridGLB(triangles: Int) throws -> Data {
        let quads = max(1, triangles / 2)
        var nx = 1
        while nx * nx * 2 < quads { nx += 1 }
        let ny = max(1, quads / nx)
        let vertexCount = (nx + 1) * (ny + 1)
        var positions = Data()
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for y in 0...ny {
            for x in 0...nx {
                let p = SIMD3<Float>(Float(x), Float(y), 0)
                minV = simd_min(minV, p); maxV = simd_max(maxV, p)
                for value in [p.x, p.y, p.z] { appendUInt32(value.bitPattern, to: &positions) }
            }
        }
        var indices = Data()
        let row = UInt32(nx + 1)
        for y in 0..<ny {
            for x in 0..<nx {
                let i = UInt32(y) * row + UInt32(x)
                for value in [i, i + 1, i + row, i + 1, i + row + 1, i + row] {
                    appendUInt32(value, to: &indices)
                }
            }
        }
        let positionBytes = positions.count
        var jsonData = try JSONSerialization.data(withJSONObject: [
            "asset": ["version": "2.0", "generator": "E31-R2 fixture"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["name": "Grid", "primitives": [[
                "attributes": ["POSITION": 0], "indices": 1, "mode": 4
            ]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": vertexCount,
                 "type": "VEC3", "min": [minV.x, minV.y, minV.z],
                 "max": [maxV.x, maxV.y, maxV.z]],
                ["bufferView": 1, "componentType": 5125, "count": indices.count / 4,
                 "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionBytes],
                ["buffer": 0, "byteOffset": positionBytes, "byteLength": indices.count],
            ],
            "buffers": [["byteLength": positionBytes + indices.count]],
        ], options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var bin = positions
        bin.append(indices)
        while bin.count % 4 != 0 { bin.append(0) }
        var out = Data([0x67, 0x6C, 0x54, 0x46])
        appendUInt32(2, to: &out)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + bin.count), to: &out)
        appendUInt32(UInt32(jsonData.count), to: &out)
        appendUInt32(0x4E4F534A, to: &out)
        out.append(jsonData)
        appendUInt32(UInt32(bin.count), to: &out)
        appendUInt32(0x004E4942, to: &out)
        out.append(bin)
        return out
    }

    // MARK: - Metrics

    private func attachMetrics(_ name: String, fields: [String: Any],
                               memory: E31SchedulingFootprint.Snapshot,
                               heartbeat: E31SchedulingHeartbeat,
                               extraMemory: E31SchedulingFootprint.Snapshot? = nil) {
        var payload = fields
        payload["case"] = name
        payload["memoryScope"] = "task_vm_info.phys_footprint of the FloeAppTests process, sampled every 50 ms; test-host memory, not device pressure"
        payload["baselineBytes"] = memory.baselineBytes
        payload["peakBytes"] = memory.peakBytes
        payload["peakDeltaBytes"] = memory.peakDelta
        payload["samples"] = memory.sampleCount
        if let extraMemory {
            payload["applyBaselineBytes"] = extraMemory.baselineBytes
            payload["applyPeakBytes"] = extraMemory.peakBytes
            payload["applyPeakDeltaBytes"] = extraMemory.peakDelta
            payload["applySamples"] = extraMemory.sampleCount
        }
        payload["mainActorMaxGapSeconds"] = heartbeat.maxGap
        payload["mainActorTicks"] = heartbeat.ticks
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("E31-R2 metrics must be a valid JSON object")
            return
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "E31_SCHED_METRICS_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("E31_SCHED_METRICS \(name) \(text)")
    }
}

// MARK: - Test harness

@MainActor
private final class E31SchedulingHeartbeat {
    private(set) var maxGap: TimeInterval = 0
    private(set) var ticks = 0
    private var task: Task<Void, Never>?
    private var last = Date()

    func start() {
        task?.cancel()
        last = Date()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
                guard !Task.isCancelled else { break }
                let now = Date()
                let gap = now.timeIntervalSince(last)
                if gap > maxGap { maxGap = gap }
                last = now
                ticks += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Suspend until one more heartbeat tick has been observed. A very short
    /// import otherwise finishes before the 5 ms sampler fires and `ticks`
    /// stays zero even though the MainActor was never blocked. The deadline
    /// prevents a dead sampler from hanging the test; the surrounding tick
    /// assertions then fail with the real evidence.
    func waitForTick(timeout: TimeInterval = 2) async {
        let target = ticks + 1
        let deadline = Date().addingTimeInterval(timeout)
        while ticks < target, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

nonisolated private final class E31SchedulingFootprint: @unchecked Sendable {
    struct Snapshot: Sendable {
        let baselineBytes: Int
        let peakBytes: Int
        let sampleCount: Int
        var peakDelta: Int { max(0, peakBytes - baselineBytes) }
    }

    private let lock = NSLock()
    private var baseline = 0
    private var peak = 0
    private var samples = 0
    private var task: Task<Void, Never>?

    func start() {
        lock.lock()
        baseline = Self.readFootprint()
        peak = baseline
        samples = 1
        lock.unlock()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    func stop() -> Snapshot {
        task?.cancel()
        task = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(baselineBytes: baseline, peakBytes: peak, sampleCount: samples)
    }

    private func sample() {
        let value = Self.readFootprint()
        lock.lock()
        if value > peak { peak = value }
        samples += 1
        lock.unlock()
    }

    private static func readFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

nonisolated private final class ExactCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CADExactImportCheckpoint] = []
    private var offMain = false
    private var mainThreadBody = false
    private var igesRoots = 0

    func record(_ checkpoint: CADExactImportCheckpoint) {
        lock.lock()
        recorded.append(checkpoint)
        if !checkpoint.ranOnMainThread { offMain = true }
        if checkpoint.phase == "body" && checkpoint.ranOnMainThread { mainThreadBody = true }
        if checkpoint.phase == "body" && checkpoint.format == "iges" {
            igesRoots = max(igesRoots, checkpoint.bodyCount)
        }
        lock.unlock()
    }

    var phases: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.phase)
    }
    func count(of phase: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.phase == phase }.count
    }
    func sawPhase(_ phase: String) -> Bool { count(of: phase) > 0 }
    var sawOffMain: Bool { lock.lock(); defer { lock.unlock() }; return offMain }
    var sawMainThreadBody: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadBody }
    var maxIGESRoots: Int { lock.lock(); defer { lock.unlock() }; return igesRoots }
}

nonisolated private final class MeshParseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var offMain = false
    private var charges = 0
    private var parses = 0

    func record(_ checkpoint: MeshImportCheckpoint) {
        lock.lock()
        if !checkpoint.ranOnMainThread { offMain = true }
        if checkpoint.phase == "charge" { charges += 1 }
        if checkpoint.phase == "start" { parses += 1 }
        lock.unlock()
    }

    var sawOffMain: Bool { lock.lock(); defer { lock.unlock() }; return offMain }
    var chargeCount: Int { lock.lock(); defer { lock.unlock() }; return charges }
    /// One per real `MeshImportKit.probe` entry. A units-scale copy charges
    /// its own budget but never enters the parser, so this is the signal that
    /// proves the source was not parsed twice.
    var parseCount: Int { lock.lock(); defer { lock.unlock() }; return parses }
}

nonisolated private final class E31SchedulingExactGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let hold: String
    private let atBody: Int
    private var offMain = false
    private var held = false

    init(hold: String, atBody: Int) {
        self.hold = hold
        self.atBody = atBody
    }

    func checkpoint(_ checkpoint: CADExactImportCheckpoint) {
        guard checkpoint.phase == hold,
              atBody == 0 || checkpoint.bodyIndex == atBody else { return }
        lock.lock()
        offMain = !checkpoint.ranOnMainThread
        let shouldHold = !held
        held = true
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 20)
    }

    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.entered.wait(timeout: .now() + 20)
                continuation.resume()
            }
        }
    }

    func releaseGate() { release.signal() }

    var observedOffMain: Bool { lock.lock(); defer { lock.unlock() }; return offMain }
}
#endif

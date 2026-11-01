//
//  NativeCADImportLimitsTests.swift
//  FloeAppTests
//
//  E31 App-level qualification for native 3D import:
//
//    * an over-budget COMPRESSED asset (a zip whose declared expansion is
//      400 MiB) is refused before the destination buffer exists, the source
//      bytes are unchanged and the document has no new body/revision;
//    * a representative accepted GLB imports through the REAL tool -> host ->
//      bridge path while the MainActor heartbeat keeps ticking (the parse is
//      off-main), then commits exactly one body with one undo step;
//    * cancelling during the real parse (deterministic first-allocation gate)
//      leaves no proposal, body, revision or source change;
//    * cancelling the caller Task (switch/close equivalent) is fenced the same
//      way, and closing the document cancels the draft;
//    * a normal STL import still works after the scheduling change.
//
//  Metrics are real: `task_vm_info.phys_footprint` of this test process and a
//  MainActor heartbeat. Root runs this on the pinned Simulator; it is NOT a
//  physical-iPad memory or latency measurement.
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
final class NativeCADImportLimitsTests: XCTestCase {
    private var workspace: URL!
    private var center: CadDocumentCenter!
    private var ownerID = UUID()

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-import-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
        ownerID = UUID()
    }

    override func tearDown() async throws {
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
        ToolContext(runID: UUID(), toolCallID: "e31-import-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: token, environmentID: "env-e31",
                    conversationID: UUID())
    }

    private func storedIdentity() async -> (revision: Int, sha: String)? {
        guard let identity = await FloeCADDocument.storedIdentity(at: documentURL) else { return nil }
        return (identity.revision, identity.contentSHA256)
    }

    private func bodyCount() async throws -> Int {
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        return document.summary().bodyCount
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Deflate zip entry whose DECLARED uncompressed size is 400 MiB while the
    /// compressed payload is two bytes. The budget must refuse the declaration
    /// before `ZipReader.inflate` allocates the destination.
    private func overBudgetZip() -> Data {
        let name = Array("model.obj".utf8)
        let payload = Data([0x03, 0x00])   // empty final deflate block
        let declared: UInt32 = 400 * 1024 * 1024
        var out = Data()
        out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        appendUInt16(20, to: &out)
        appendUInt16(0, to: &out)
        appendUInt16(8, to: &out)
        appendUInt16(0, to: &out)
        appendUInt16(0, to: &out)
        appendUInt32(0, to: &out)
        appendUInt32(UInt32(payload.count), to: &out)
        appendUInt32(declared, to: &out)
        appendUInt16(UInt16(name.count), to: &out)
        appendUInt16(0, to: &out)
        out.append(contentsOf: name)
        out.append(payload)
        var central = Data()
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        appendUInt16(20, to: &central)
        appendUInt16(20, to: &central)
        appendUInt16(0, to: &central)
        appendUInt16(8, to: &central)
        appendUInt16(0, to: &central)
        appendUInt16(0, to: &central)
        appendUInt32(0, to: &central)
        appendUInt32(UInt32(payload.count), to: &central)
        appendUInt32(declared, to: &central)
        appendUInt16(UInt16(name.count), to: &central)
        appendUInt16(0, to: &central)
        appendUInt16(0, to: &central)
        appendUInt16(0, to: &central)
        appendUInt16(0, to: &central)
        appendUInt32(0, to: &central)
        appendUInt32(0, to: &central)
        central.append(contentsOf: name)
        let centralOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendUInt16(0, to: &out)
        appendUInt16(0, to: &out)
        appendUInt16(1, to: &out)
        appendUInt16(1, to: &out)
        appendUInt32(UInt32(central.count), to: &out)
        appendUInt32(UInt32(centralOffset), to: &out)
        appendUInt16(0, to: &out)
        return out
    }

    /// A self-contained GLB grid with `triangles` triangles (indexed UInt32).
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
                for value in [p.x, p.y, p.z] {
                    appendUInt32(value.bitPattern, to: &positions)
                }
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
            "asset": ["version": "2.0", "generator": "E31 fixture"],
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

    private func smallSTL() -> Data {
        let vertices: [(Float, Float, Float)] = [(0, 0, 0), (10, 0, 0),
                                                 (0, 10, 0), (0, 0, 10)]
        let faces = [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)]
        var data = Data(repeating: 0, count: 80)
        appendUInt32(UInt32(faces.count), to: &data)
        for face in faces {
            for _ in 0..<3 { appendUInt32(0, to: &data) }
            for index in [face.0, face.1, face.2] {
                let v = vertices[index]
                appendUInt32(v.0.bitPattern, to: &data)
                appendUInt32(v.1.bitPattern, to: &data)
                appendUInt32(v.2.bitPattern, to: &data)
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    // MARK: - Tool helpers

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

    // MARK: - Over-budget compressed asset

    func testOverBudgetZipIsRefusedBeforeAllocationAndPreservesSourceAndDocument() async throws {
        try await makeTargetDocument()
        let bomb = overBudgetZip()
        let sourceURL = workspace.appendingPathComponent("bomb.zip")
        try bomb.write(to: sourceURL)
        let sourceSHA = FloeDigest.sha256Hex(bomb)
        let capturedIdentity = await storedIdentity()
        let identityBefore = try XCTUnwrap(capturedIdentity)

        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        XCTAssertEqual(document.summary().bodyCount, 0)
        // The open itself advances changeCount by one (DocumentSession.load):
        // that is the fixture's baseline, not an import mutation.
        let changeCountAfterLoad = document.session.changeCount
        let sampler = E31FootprintSampler()
        sampler.start()
        let heartbeat = E31Heartbeat()
        heartbeat.start()
        let outcome = await document.executeJSONAsync(Data("""
        {"op":"document.import","args":{"path":\(try jsonString(sourceURL.path)),"fileName":"bomb.zip"}}
        """.utf8))
        heartbeat.stop()
        let memory = sampler.stop()

        XCTAssertFalse(outcome.isOK, "a 400 MiB declared expansion must be refused")
        let message = outcome.message ?? ""
        XCTAssertTrue(message.contains("budget") || message.contains("MiB"), message)
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertEqual(document.session.changeCount, changeCountAfterLoad,
                       "a refused import must not add any document mutation")
        XCTAssertEqual(try Data(contentsOf: sourceURL), bomb, "the import source must be unchanged")
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: sourceURL)), sourceSHA)
        let capturedAfter = await storedIdentity()
        let identityAfter = try XCTUnwrap(capturedAfter)
        XCTAssertEqual(identityAfter.revision, identityBefore.revision)
        XCTAssertEqual(identityAfter.sha, identityBefore.sha)
        let pending = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pending.isEmpty, "a refused import must not leave a pending proposal")
        XCTAssertLessThan(memory.peakDelta, 64 * 1024 * 1024,
                          "refusal allocated \(memory.peakDelta) bytes for a declaration-only bomb")
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "the metadata-only refusal blocked the MainActor for \(heartbeat.maxGap)s")
        attachE31Metrics("overbudget-zip", fields: [
            "declaredMiB": 400,
            "budgetMiB": 256,
            "resultError": outcome.errorCode ?? "",
            "resultMessage": String(message.prefix(240)),
            "sourceUnchanged": true,
            "bodyCount": 0,
            "revisionUnchanged": true,
            "proposalCount": pending.count,
        ], memory: memory, heartbeat: heartbeat)
    }

    // MARK: - Accepted import

    func testAcceptedGLBImportRunsOffMainAndCommitsOnce() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 50_000)
        XCTAssertLessThan(glb.count, 10 * 1024 * 1024,
                          "the fixture must fit the workspace read cap")
        let sourceURL = workspace.appendingPathComponent("mesh.glb")
        try glb.write(to: sourceURL)
        let sourceSHA = FloeDigest.sha256Hex(glb)
        let capturedIdentity = await storedIdentity()
        let identityBefore = try XCTUnwrap(capturedIdentity)
        let token = CancellationToken()
        let context = makeContext(token)

        let sampler = E31FootprintSampler()
        sampler.start()
        let heartbeat = E31Heartbeat()
        heartbeat.start()
        let reply = try await runToolImport(source: "mesh.glb", format: "glb", context: context)
        heartbeat.stop()
        let previewMemory = sampler.stop()

        let proposalID = try XCTUnwrap(reply.proposalID, reply.summary)
        let pendingPreview = await center.pendingNativeProposals(for: documentURL)
        XCTAssertEqual(pendingPreview.count, 1)
        let capturedPreview = await storedIdentity()
        let previewIdentity = try XCTUnwrap(capturedPreview)
        XCTAssertEqual(previewIdentity.revision, identityBefore.revision,
                       "a pending proposal must not advance the package")
        let previewBodies = try await bodyCount()
        XCTAssertEqual(previewBodies, 0)
        XCTAssertLessThan(heartbeat.maxGap, 0.5,
                          "the off-main parse blocked the MainActor for \(heartbeat.maxGap)s")
        XCTAssertGreaterThan(heartbeat.ticks, 0)

        let applySampler = E31FootprintSampler()
        applySampler.start()
        let applyHeartbeat = E31Heartbeat()
        applyHeartbeat.start()
        let receipt = try await applyProposal(proposalID)
        applyHeartbeat.stop()
        let applyMemory = applySampler.stop()

        XCTAssertEqual(receipt.revision, identityBefore.revision + 1)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1,
                       "the whole import must be exactly one undo step")
        XCTAssertEqual(try Data(contentsOf: sourceURL), glb, "the source must be unchanged")
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: sourceURL)), sourceSHA)
        let pendingAfterApply = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pendingAfterApply.isEmpty)
        XCTAssertLessThan(applyHeartbeat.maxGap, 0.5,
                          "the apply parse blocked the MainActor for \(applyHeartbeat.maxGap)s")
        attachE31Metrics("accepted-glb", fields: [
            "sourceBytes": glb.count,
            "expectedTriangles": 50_000,
            "importedBodies": 1,
            "previewMainActorMaxGapSeconds": heartbeat.maxGap,
            "previewMainActorTicks": heartbeat.ticks,
            "applyMainActorMaxGapSeconds": applyHeartbeat.maxGap,
            "applyMainActorTicks": applyHeartbeat.ticks,
            "revisionDelta": receipt.revision - identityBefore.revision,
            "undoSteps": 1,
            "sourceUnchanged": true,
        ], memory: previewMemory, heartbeat: heartbeat, extraMemory: applyMemory)
    }

    func testCancellingTheAuthorizedApplyBeforeMutationKeepsTheProposalPending() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 50_000)
        try glb.write(to: workspace.appendingPathComponent("apply-cancel.glb"))
        let capturedIdentity = await storedIdentity()
        let identityBefore = try XCTUnwrap(capturedIdentity)
        // The host re-authorizes an apply against the SAME propose-time access
        // (environment, workspace, owner kind + id). The tool drafts under its
        // own derived access, so the token-aware host apply must present that
        // exact access; otherwise it is correctly refused as unauthorized
        // before the parse can observe any cancellation.
        let importContext = makeContext()
        let importAccess = CadDocumentTool.access(for: importContext)
        let importReply = try await runToolImport(source: "apply-cancel.glb", format: "glb",
                                                  context: importContext)
        let proposalID = try XCTUnwrap(importReply.proposalID, importReply.summary)
        let grant = try await center.issueNativeCADGrant(proposalID: proposalID)

        let gate = E31ParseGate()
        MeshImportKit.testParseCheckpoint = { checkpoint in gate.checkpoint(checkpoint) }
        let token = CancellationToken()
        let task = Task<Error?, Never> { @MainActor in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.applyRequest(proposalID: proposalID, grant: grant),
                    access: importAccess,
                    cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        token.cancel()
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("expected FloeError.cancelled, got \(String(describing: error))")
        }
        let pending = await center.pendingNativeProposals(for: documentURL)
        XCTAssertEqual(pending.count, 1, "a cancelled apply must return the proposal to pending")
        let bodies = try await bodyCount()
        XCTAssertEqual(bodies, 0, "a cancelled apply must not mutate the document")
        let capturedAfter = await storedIdentity()
        let identityAfter = try XCTUnwrap(capturedAfter)
        XCTAssertEqual(identityAfter.revision, identityBefore.revision)
        XCTAssertEqual(identityAfter.sha, identityBefore.sha)
    }

    func testNormalSTLImportStillWorksAfterTheSchedulingChange() async throws {
        try await makeTargetDocument()
        let stl = smallSTL()
        try stl.write(to: workspace.appendingPathComponent("tetra.stl"))
        let capturedIdentity = await storedIdentity()
        let identityBefore = try XCTUnwrap(capturedIdentity)
        let reply = try await runToolImport(source: "tetra.stl", format: "stl",
                                            context: makeContext())
        let proposalID = try XCTUnwrap(reply.proposalID, reply.summary)
        _ = try await applyProposal(proposalID)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.revision, identityBefore.revision + 1)
        XCTAssertEqual(document.session.document.bodies.first?.render.triangleCount, 4)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("tetra.stl")), stl)
    }

    // MARK: - Cancel during real work

    func testCancelDuringParseLeavesNoProposalBodyOrSourceChange() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 400_000)
        let sourceURL = workspace.appendingPathComponent("cancel.glb")
        try glb.write(to: sourceURL)
        let sourceSHA = FloeDigest.sha256Hex(glb)
        let capturedIdentity = await storedIdentity()
        let identityBefore = try XCTUnwrap(capturedIdentity)
        let token = CancellationToken()
        let gate = E31ParseGate()
        MeshImportKit.testParseCheckpoint = { checkpoint in gate.checkpoint(checkpoint) }

        let task = Task<Error?, Never> { @MainActor in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.importRequest("cancel.glb", format: "glb"),
                    access: self.access(),
                    cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        XCTAssertTrue(gate.observedOffMain, "the parse must run off the MainActor")
        token.cancel()
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("expected FloeError.cancelled, got \(String(describing: error))")
        }
        let pending = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pending.isEmpty)
        let bodies = try await bodyCount()
        XCTAssertEqual(bodies, 0)
        let capturedAfter = await storedIdentity()
        let identityAfter = try XCTUnwrap(capturedAfter)
        XCTAssertEqual(identityAfter.revision, identityBefore.revision)
        XCTAssertEqual(identityAfter.sha, identityBefore.sha)
        XCTAssertEqual(try Data(contentsOf: sourceURL), glb)
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: sourceURL)), sourceSHA)
    }

    func testCancellingTheCallerTaskFencesTheLateProposal() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 400_000)
        try glb.write(to: workspace.appendingPathComponent("task-cancel.glb"))
        let gate = E31ParseGate()
        MeshImportKit.testParseCheckpoint = { checkpoint in gate.checkpoint(checkpoint) }
        let token = CancellationToken()

        let task = Task<Error?, Never> { @MainActor in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.importRequest("task-cancel.glb", format: "glb"),
                    access: self.access(),
                    cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        task.cancel()
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("expected FloeError.cancelled, got \(String(describing: error))")
        }
        let pending = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pending.isEmpty)
        let bodies = try await bodyCount()
        XCTAssertEqual(bodies, 0)
    }

    func testClosingTheDocumentCancelsAnInFlightDraft() async throws {
        try await makeTargetDocument()
        let glb = try gridGLB(triangles: 400_000)
        try glb.write(to: workspace.appendingPathComponent("close-cancel.glb"))
        let gate = E31ParseGate()
        MeshImportKit.testParseCheckpoint = { checkpoint in gate.checkpoint(checkpoint) }
        let token = CancellationToken()
        let document = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)

        let task = Task<Error?, Never> { @MainActor in
            do {
                _ = try await self.center.threeDAction(
                    documentID: "Part.floecad",
                    requestJSON: try self.importRequest("close-cancel.glb", format: "glb"),
                    access: self.access(),
                    cancellation: token)
                return nil
            } catch {
                return error
            }
        }
        await gate.waitEntered()
        await FloeCAD3DBridge.shared.releaseDocument(at: documentURL, expected: document)
        gate.releaseGate()
        let error = await task.value
        guard case FloeError.cancelled? = error as? FloeError else {
            return XCTFail("expected FloeError.cancelled, got \(String(describing: error))")
        }
        let pending = await center.pendingNativeProposals(for: documentURL)
        XCTAssertTrue(pending.isEmpty, "a close must not persist a late proposal")
    }

    // MARK: - Helpers

    private func access() -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-e31", workspacePath: workspace.path,
                          ownerKind: "workspace", ownerID: ownerID)
    }

    private func applyRequest(proposalID: UUID, grant: String) throws -> String {
        let object: [String: Any] = [
            "kind": "apply",
            "proposal_id": proposalID.uuidString,
            "grant_id": grant,
            "request_id": "e31-apply-\(proposalID.uuidString)",
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
                                                           options: [.sortedKeys]), as: UTF8.self)
    }

    private func importRequest(_ source: String, format: String) throws -> String {
        let object: [String: Any] = [
            "kind": "import",
            "payload": ["path": source, "format": format],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
                                                           options: [.sortedKeys]), as: UTF8.self)
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Metrics

    private func attachE31Metrics(_ name: String, fields: [String: Any],
                                  memory: E31FootprintSampler.Snapshot,
                                  heartbeat: E31Heartbeat,
                                  extraMemory: E31FootprintSampler.Snapshot? = nil) {
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
            XCTFail("E31 metrics must be a valid JSON object")
            return
        }
        let attachment = XCTAttachment(string: text)
        attachment.name = "E31_METRICS_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("E31_METRICS \(name) \(text)")
    }
}

// MARK: - Test harness

@MainActor
private final class E31Heartbeat {
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
}

nonisolated private final class E31ParseGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var offMain = false

    func checkpoint(_ checkpoint: MeshImportCheckpoint) {
        // The "start" phase fires before any geometry work; gate on the first
        // real allocation so the cancel lands inside the parse, before the
        // array it would grow.
        guard checkpoint.phase == "charge" else { return }
        lock.lock()
        offMain = !checkpoint.ranOnMainThread
        lock.unlock()
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

    var observedOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offMain
    }
}

nonisolated private final class E31FootprintSampler: @unchecked Sendable {
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
#endif

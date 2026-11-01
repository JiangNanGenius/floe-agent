//
//  CADImportLimitsUIFixture.swift
//  FloeApp — DEBUG-only E31 native import-limit UI fixture.
//
//  Launch with `-ui-testing --ui-test-cad-fixture` plus exactly one of:
//    --ui-test-cad-import-accepted    real GLB import proposal (shipped banner)
//    --ui-test-cad-import-rejected    400 MiB declared zip refused by the real
//                                     kernel import path, source preserved
//    --ui-test-cad-import-cancelled   cancel during the real parse, no late
//                                     proposal/body/source change
//
//  Every value shown in the status line is READ BACK from the real services
//  after the real call: stored identity, source SHA-256, body/proposal counts
//  and the actual refusal/cancellation result. The fixture never synthesises
//  a success, a refusal or a cancellation. It owns only its fixed synthetic
//  conversation/workspace and removes nothing else.
//
//  The accepted mode presents the SHIPPED FilePreviewView banner, exactly like
//  the E26 fixture, so Apply/Discard are the product controls.
//
//  Root owns compilation and the real Simulator run; this file is source-ready.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import Foundation
import simd
import FloeCAD
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

@MainActor
enum CADImportLimitsUIFixture {
    enum Mode: String, CaseIterable {
        case accepted = "--ui-test-cad-import-accepted"
        case rejected = "--ui-test-cad-import-rejected"
        case cancelled = "--ui-test-cad-import-cancelled"
        // E31-R2: exact STEP/IGES scheduling + the manual Workbench path.
        case exactAccepted = "--ui-test-cad-import-exact-accepted"
        case exactCancelled = "--ui-test-cad-import-exact-cancelled"
        case manualStep = "--ui-test-cad-import-manual-step"

        static func selected(from arguments: [String]) -> Mode? {
            allCases.first { arguments.contains($0.rawValue) }
        }
    }

    struct Prepared {
        let mode: Mode
        let workspaceRelativePath: String
        let conversationID: UUID
        /// Nil for the accepted flows (the shipped banner/workbench is the
        /// surface); a real post-call diagnostic for rejected/cancelled.
        let status: String?
        /// True for the manual Workbench path, which the harness must present
        /// with the real editor (not the FilePreview banner).
        var presentWorkbench: Bool = false
    }

    static let conversationID = UUID(uuidString: "E31C0DE0-0000-4000-8000-00000000E311")!
    static let conversationTitle = "E31 import limits fixture"
    static let documentName = "E31 Import Limits"
    static let documentRelativePath = "ImportLimits.floecad"
    static let acceptedSourceName = "AcceptedGrid.glb"
    static let rejectedSourceName = "OverBudget.zip"
    static let exactSourceName = "ExactPlate.step"
    static let exactCancelSourceName = "ExactCancel.step"
    static let manualStepName = "ManualStep.step"

    static func prepare(mode: Mode, in environment: AppEnvironment) async throws -> Prepared {
        try await waitForPersistence(environment)
        try await ensureFixtureConversation(environment)
        try await environment.workspaceCenter.openTaskWorkspace(conversationID: conversationID)
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw fixtureError("The E31 fixture could not open its task workspace.")
        }
        guard let workspace = environment.workspaceCenter.currentWorkspace,
              workspace.kind == .privateTask,
              workspace.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)" else {
            throw fixtureError("The E31 fixture workspace is not its own private task root.")
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let documentURL = root.appendingPathComponent(documentRelativePath)
        let seed = try await FloeCADDocument.create(at: documentURL, name: documentName)
        let baseIdentity = (seed.revision, seed.contentSHA256)
        seed.close()

        let status: String?
        switch mode {
        case .accepted:
            try gridGLB(triangles: 120_000)
                .write(to: root.appendingPathComponent(acceptedSourceName), options: .atomic)
            let token = CancellationToken()
            let proposalReply = try await environment.cadDocumentCenter.threeDAction(
                documentID: documentRelativePath,
                requestJSON: try importRequest(source: acceptedSourceName, format: "glb"),
                access: uiAccess(root: root),
                cancellation: token)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(proposalReply.utf8)))
                    as? [String: Any],
                  object["ok"] as? Bool == true,
                  let proposal = object["proposal"] as? [String: Any],
                  let raw = proposal["id"] as? String,
                  UUID(uuidString: raw) != nil else {
                throw fixtureError("The E31 accepted GLB proposal was refused: \(proposalReply)")
            }
            let pending = await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL)
            guard pending.count == 1 else {
                throw fixtureError("The E31 accepted import must leave exactly one pending proposal.")
            }
            status = nil
        case .exactAccepted:
            let bytes = try await exactFixture(format: "step", solids: 1, in: root)
            try bytes.write(to: root.appendingPathComponent(exactSourceName), options: .atomic)
            let token = CancellationToken()
            let proposalReply = try await environment.cadDocumentCenter.threeDAction(
                documentID: documentRelativePath,
                requestJSON: try importRequest(source: exactSourceName, format: "step"),
                access: uiAccess(root: root),
                cancellation: token)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(proposalReply.utf8)))
                    as? [String: Any],
                  object["ok"] as? Bool == true,
                  let proposal = object["proposal"] as? [String: Any],
                  let raw = proposal["id"] as? String,
                  UUID(uuidString: raw) != nil else {
                throw fixtureError("The E31 exact STEP proposal was refused: \(proposalReply)")
            }
            let pending = await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL)
            guard pending.count == 1 else {
                throw fixtureError("The E31 exact import must leave exactly one pending proposal.")
            }
            status = nil
        case .exactCancelled:
            let bytes = try await exactFixture(format: "step", solids: 2, in: root)
            let sourceURL = root.appendingPathComponent(exactCancelSourceName)
            try bytes.write(to: sourceURL, options: .atomic)
            let sourceSHA = FloeDigest.sha256Hex(bytes)
            let gate = ExactParseGate()
            CADDebugFixtures.installExactImportCheckpoint { gate.checkpoint($0) }
            defer { CADDebugFixtures.installExactImportCheckpoint(nil) }
            let token = CancellationToken()
            let task = Task { @MainActor () -> Error? in
                do {
                    _ = try await environment.cadDocumentCenter.threeDAction(
                        documentID: documentRelativePath,
                        requestJSON: try importRequest(source: exactCancelSourceName,
                                                       format: "step"),
                        access: uiAccess(root: root),
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
            let pending = await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL)
            let identity = await FloeCADDocument.storedIdentity(at: documentURL)
            let afterBytes = try Data(contentsOf: sourceURL)
            let sourceUnchanged = afterBytes == bytes
                && FloeDigest.sha256Hex(afterBytes) == sourceSHA
            let live = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
            let bodyCount = live.summary().bodyCount
            await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
            guard case FloeError.cancelled? = error as? FloeError,
                  pending.isEmpty, bodyCount == 0, sourceUnchanged,
                  identity?.revision == baseIdentity.0,
                  identity?.contentSHA256 == baseIdentity.1,
                  gate.observedOffMain else {
                throw fixtureError("The E31 exact cancelled import was not clean: "
                    + "error=\(String(describing: error)) bodies=\(bodyCount) "
                    + "proposals=\(pending.count) sourceUnchanged=\(sourceUnchanged) "
                    + "offMain=\(gate.observedOffMain)")
            }
            status = "cancelled bodies=0 proposals=0 revisionUnchanged=true "
                + "sourceUnchanged=true sourceSHA=\(sourceSHA.prefix(12)) "
                + "parse=offmain formatted=step"
        case .manualStep:
            let bytes = try await exactFixture(format: "step", solids: 1, in: root)
            let sourceURL = root.appendingPathComponent(manualStepName)
            try bytes.write(to: sourceURL, options: .atomic)
            // The real Workbench editor consumes this trigger on appear and
            // runs the same async exact import the Import menu starts.
            CADDebugFixtures.pendingManualImportPath = sourceURL.path
            return Prepared(mode: mode, workspaceRelativePath: documentRelativePath,
                            conversationID: conversationID, status: nil,
                            presentWorkbench: true)
        case .rejected:
            let bomb = overBudgetZip()
            let sourceURL = root.appendingPathComponent(rejectedSourceName)
            try bomb.write(to: sourceURL, options: .atomic)
            let sourceSHA = FloeDigest.sha256Hex(bomb)
            let document = try await FloeCADDocument.open(at: documentURL)
            let outcome = await document.executeJSONAsync(Data("""
            {"op":"document.import","args":{"path":\(try jsonString(sourceURL.path)),"fileName":"OverBudget.zip"}}
            """.utf8))
            let bodyCount = document.summary().bodyCount
            document.close()
            let identity = await FloeCADDocument.storedIdentity(at: documentURL)
            let pending = await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL)
            let afterBytes = try Data(contentsOf: sourceURL)
            let sourceUnchanged = afterBytes == bomb
                && FloeDigest.sha256Hex(afterBytes) == sourceSHA
            guard !outcome.isOK, bodyCount == 0,
                  pending.isEmpty, sourceUnchanged,
                  identity?.revision == baseIdentity.0,
                  identity?.contentSHA256 == baseIdentity.1 else {
                throw fixtureError("The E31 over-budget import did not refuse cleanly: "
                    + "ok=\(outcome.isOK) bodies=\(bodyCount) proposals=\(pending.count) "
                    + "sourceUnchanged=\(sourceUnchanged)")
            }
            let message = outcome.message ?? ""
            status = "overbudget code=\(outcome.errorCode ?? "none") bodies=0 proposals=0 "
                + "revisionUnchanged=true sourceUnchanged=true "
                + "sourceSHA=\(sourceSHA.prefix(12)) detail=\(String(message.prefix(160)))"
        case .cancelled:
            let glb = try gridGLB(triangles: 300_000)
            let sourceURL = root.appendingPathComponent("CancelGrid.glb")
            try glb.write(to: sourceURL, options: .atomic)
            let sourceSHA = FloeDigest.sha256Hex(glb)
            let gate = ParseGate()
            CADDebugFixtures.installImportParseCheckpoint { chargedBytes in
                gate.checkpoint(chargedBytes)
            }
            defer { CADDebugFixtures.installImportParseCheckpoint(nil) }
            let token = CancellationToken()
            let task = Task { @MainActor () -> Error? in
                do {
                    _ = try await environment.cadDocumentCenter.threeDAction(
                        documentID: documentRelativePath,
                        requestJSON: try importRequest(source: "CancelGrid.glb", format: "glb"),
                        access: uiAccess(root: root),
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
            let pending = await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL)
            let identity = await FloeCADDocument.storedIdentity(at: documentURL)
            let afterBytes = try Data(contentsOf: sourceURL)
            let sourceUnchanged = afterBytes == glb
                && FloeDigest.sha256Hex(afterBytes) == sourceSHA
            let live = try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
            let bodyCount = live.summary().bodyCount
            await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
            guard case FloeError.cancelled? = error as? FloeError,
                  pending.isEmpty, bodyCount == 0, sourceUnchanged,
                  identity?.revision == baseIdentity.0,
                  identity?.contentSHA256 == baseIdentity.1 else {
                throw fixtureError("The E31 cancelled import was not clean: "
                    + "error=\(String(describing: error)) bodies=\(bodyCount) "
                    + "proposals=\(pending.count) sourceUnchanged=\(sourceUnchanged)")
            }
            status = "cancelled bodies=0 proposals=0 revisionUnchanged=true "
                + "sourceUnchanged=true sourceSHA=\(sourceSHA.prefix(12)) "
                + "parse=offmain chargedAtGate=\(gate.chargedBytes)"
        }

        try writeManifest(mode: mode, root: root, base: baseIdentity, status: status)
        return Prepared(mode: mode, workspaceRelativePath: documentRelativePath,
                        conversationID: conversationID, status: status)
    }

    // MARK: - Exact fixtures

    /// Real STEP bytes from the production document writer: a plate (sketch →
    /// extrude) per solid. `solids: 2` gives the deterministic cancel fixture
    /// two prepared bodies; nothing is hand-authored.
    private static func exactFixture(format: String, solids: Int,
                                     in root: URL) async throws -> Data {
        let sourceURL = root.appendingPathComponent("ExactSource-\(UUID().uuidString).floecad")
        let source = try await FloeCADDocument.create(at: sourceURL, name: "Exact Source")
        do {
            for index in 0..<solids {
                let sketchID = try run(source, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String
                guard let sketchID else {
                    throw fixtureError("The exact fixture could not create its sketch.")
                }
                let x = Double(index) * 100
                try run(source, """
                {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)","entities":[{"kind":"rect","min":[\(x),0],"max":[\(x + 60),40]}]}}
                """)
                try run(source, """
                {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[\(x + 30),20],"distance":10}}
                """)
            }
            // Persist the real solids before the bridge opens the package for
            // the production exact writer; two live instances must not race.
            let saved = await source.save()
            source.close()
            guard saved.succeeded else {
                throw fixtureError("The exact fixture source could not be saved: "
                    + (saved.error ?? "unknown error"))
            }
        } catch {
            source.close()
            throw error
        }
        do {
            // The App fixture cannot call the kernel-internal raw writer; use
            // the production bridge export path (same exact writer + receipt).
            let exported = try await FloeCAD3DBridge.shared.exportNativeData(
                at: sourceURL, format: format, pageID: nil)
            await FloeCAD3DBridge.shared.releaseDocument(at: sourceURL)
            guard let data = exported.data, !data.isEmpty else {
                throw fixtureError("The exact fixture writer produced no bytes.")
            }
            return data
        } catch {
            await FloeCAD3DBridge.shared.releaseDocument(at: sourceURL)
            throw error
        }
    }

    /// The fixture's only document-command helper: the production executor.
    private static func run(_ document: FloeCADDocument, _ json: String) throws
        -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload))
                as? [String: Any] else {
            throw fixtureError("The exact fixture command failed: \(outcome.message ?? json)")
        }
        return object
    }

    /// Holds the REAL exact parse at its prepared-body checkpoint so the UI
    /// fixture can cancel deterministically.
    nonisolated private final class ExactParseGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var offMain = false
        private var held = false

        func checkpoint(_ checkpoint: CADExactImportCheckpoint) {
            guard checkpoint.phase == "body", checkpoint.bodyIndex == 1 else { return }
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

    // MARK: - Fixtures

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func overBudgetZip() -> Data {
        let name = Array("model.obj".utf8)
        let payload = Data([0x03, 0x00])   // empty final deflate block
        let declared: UInt32 = 400 * 1024 * 1024
        var out = Data()
        out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        for value in [UInt16(20), 0, 8, 0, 0] { appendUInt16(value, to: &out) }
        appendUInt32(0, to: &out)
        appendUInt32(UInt32(payload.count), to: &out)
        appendUInt32(declared, to: &out)
        appendUInt16(UInt16(name.count), to: &out)
        appendUInt16(0, to: &out)
        out.append(contentsOf: name)
        out.append(payload)
        var central = Data()
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        for value in [UInt16(20), 20, 0, 8, 0, 0] { appendUInt16(value, to: &central) }
        appendUInt32(0, to: &central)
        appendUInt32(UInt32(payload.count), to: &central)
        appendUInt32(declared, to: &central)
        appendUInt16(UInt16(name.count), to: &central)
        for value in [UInt16(0), 0, 0, 0] { appendUInt16(value, to: &central) }
        appendUInt32(0, to: &central)
        appendUInt32(0, to: &central)
        central.append(contentsOf: name)
        let offset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        for value in [UInt16(0), 0, 1, 1] { appendUInt16(value, to: &out) }
        appendUInt32(UInt32(central.count), to: &out)
        appendUInt32(UInt32(offset), to: &out)
        appendUInt16(0, to: &out)
        return out
    }

    private static func gridGLB(triangles: Int) throws -> Data {
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

    // MARK: - Real calls / helpers

    private static func importRequest(source: String, format: String) throws -> String {
        let object: [String: Any] = [
            "kind": "import",
            "summary": "Import \(source) (\(format.uppercased()))",
            "payload": ["path": source, "format": format],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
                                                           options: [.sortedKeys]), as: UTF8.self)
    }

    private static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value,
                                                    options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private static func uiAccess(root: URL) -> CadDocumentAccess {
        CadDocumentCenter.uiAccess(workspaceRoot: root, conversationID: conversationID,
                                   environmentID: nil)
    }

    private static func waitForPersistence(_ environment: AppEnvironment) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !environment.persistenceReady {
            guard Date() < deadline else {
                throw fixtureError("The App database was not ready for the E31 fixture.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func ensureFixtureConversation(_ environment: AppEnvironment) async throws {
        if try await environment.conversationStore.conversation(id: conversationID) == nil {
            try await environment.conversationStore.saveConversation(ConversationRecord(
                id: conversationID,
                title: conversationTitle,
                createdAt: Date(),
                updatedAt: Date()))
        }
    }

    private static func writeManifest(mode: Mode, root: URL,
                                      base: (Int, String), status: String?) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support
            .appendingPathComponent("FloeAgent/CADFixtures/E31ImportLimitsUI", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "schema": 1,
            "mode": mode.rawValue,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "conversation_id": conversationID.uuidString,
            "workspace_root": root.path,
            "document_relative_path": documentRelativePath,
            "base_document_revision": base.0,
            "base_document_content_sha256": base.1,
            "fixture_origin": "production FloeCADDocument + cad.document host; GLB/zip bytes "
                + "are generated inside the fixture; no user file is read or changed",
            "note": "The status line (rejected/cancelled) is read back from the actual call: "
                + "outcome code/message, stored revision/SHA, body count, proposal count and "
                + "source byte equality. Nothing is fabricated.",
        ]
        if let status { manifest["actual_status"] = status }
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func fixtureError(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "fixture_failed", message: message)
    }

    nonisolated private final class ParseGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var charged = 0

        func checkpoint(_ chargedBytes: Int) {
            lock.lock()
            charged = chargedBytes
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

        var chargedBytes: Int {
            lock.lock()
            defer { lock.unlock() }
            return charged
        }
    }
}
#endif

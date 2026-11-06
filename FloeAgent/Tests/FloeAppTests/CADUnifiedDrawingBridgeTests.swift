// SPDX-License-Identifier: MPL-2.0
// Actual App-local adapters: native OCCT drawing → real bundled WASM DWG
// writer → DWG edit/save/reparse → native editable sketch → package reopen.
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCAD

@Suite("Unified native drawing and DWG bridge", .serialized)
@MainActor struct CADUnifiedDrawingBridgeTests {
    private func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CADDocumentError(code: "test_json", message: "Expected a native CAD JSON object.")
        }
        return result
    }
    private func command(_ document: FloeCADDocument, _ value: [String: Any]) throws -> [String: Any] {
        let result = document.execute(value)
        #expect(result.isOK, "\(result.errorCode ?? ""): \(result.message ?? "")")
        guard result.isOK else { throw CADDocumentError(code: result.errorCode ?? "test_command", message: result.message ?? "CAD command failed.") }
        return try object(result.payload)
    }

    /// Hold the REAL store after staging and verification, then re-adopt the
    /// same cached document while the old presentation awaits its commit.
    @Test func delayedReleaseCannotCloseSamePathReadoption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawingReadoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Working.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Readoption")
        created.close()
        let bridge = FloeCAD3DBridge.shared
        let original = try await bridge.openDocument(at: url)
        let baselineRevision = original.revision
        let gate = DrawingBridgeCommitGate()
        var releasing: Task<CADSaveOutcome?, Never>?
        defer {
            // Always unblock the real writer BEFORE revoking its store lease.
            gate.release()
            CADDocumentFaultInjection.beforeCommit = nil
            original.close()
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try command(original, ["op": "sketch.create", "args": ["name": "Before handoff"]])
        #expect(original.hasUnsavedChanges)
        CADDocumentFaultInjection.beforeCommit = { try gate.suspendFirstCommit() }
        do {
            let oldRelease = Task { @MainActor in
                await bridge.releaseDocumentOutcome(at: url, expected: original)
            }
            releasing = oldRelease
            let entered = await gate.waitUntilEntered()
            #expect(entered, "The real staged package commit must reach the bounded gate")
            guard entered else { throw DrawingBridgeCommitGate.Failure.didNotEnter }
            #expect(gate.observedOffMain)
            let current = try await bridge.openDocument(at: url)
            #expect(current === original, "This regression requires re-adopting the same live instance")
            #expect(!current.isClosed)
            gate.release()
            let staleRelease = await oldRelease.value
            releasing = nil
            CADDocumentFaultInjection.beforeCommit = nil
            #expect(staleRelease == nil, "An old presentation no longer owns a release receipt")
            #expect(!current.isClosed, "The old release must not close the new presentation")
            #expect(current.revision > baselineRevision, "The blocked save must really commit")
            #expect(!current.hasUnsavedChanges)
            #expect(!gate.timedOut)

            // The new presentation remains usable and can perform its own
            // real save/release; the old lease did not strand the document.
            _ = try command(current, ["op": "sketch.create", "args": ["name": "After handoff"]])
            let closed = await bridge.releaseDocumentOutcome(at: url, expected: current)
            #expect(closed?.succeeded == true)
            #expect(current.isClosed)
            let cold = try await FloeCADDocument.open(at: url)
            defer { cold.close() }
            #expect(cold.summary().sketchCount == 2)
        } catch {
            gate.release()
            CADDocumentFaultInjection.beforeCommit = nil
            if let releasing { _ = await releasing.value }
            throw error
        }
    }

    @Test func nativeEngineeringDWGEditAndNativeSketchColdReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedDrawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var documents: [FloeCADDocument] = []
        defer { for document in documents { document.close() }; try? FileManager.default.removeItem(at: directory) }
        let source = try await FloeCADDocument.create(at: directory.appendingPathComponent("Source.floecad"), name: "工程图 Bridge")
        documents.append(source); CADDrawingModelBridge.configure(source)
        let sketch = try command(source, ["op": "sketch.create", "args": ["name": "Plate"]])
        let sketchID = try #require(sketch["sketchID"] as? String)
        _ = try command(source, ["op": "sketch.addEntities", "args": ["sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0,0], "max": [40,30]]]]])
        let extrusion = try command(source, ["op": "feature.extrude", "args": ["sketchID": sketchID, "seedPoint": [20,15], "distance": 10]])
        let bodyID = try #require(((extrusion["producedBodyIDs"] as? [String]) ?? (extrusion["changedBodyIDs"] as? [String]))?.first)
        let drawing = CADDrawingService(document: source)
        let made = await drawing.handleAsync(action: "multiViewSheet", args: ["bodyID": bodyID, "title": "工程图 Bridge"])
        #expect(made["ok"] as? Bool == true, "\(made["message"] ?? "")")
        let pages = drawing.handle(action: "pages", args: [:])
        let firstPage = try #require((pages["pages"] as? [[String: Any]])?.first)
        let pageID = try #require((firstPage["id"] as? String).flatMap(UUID.init(uuidString:)))
        let sourceChangeCount = source.session.changeCount
        let dwg = try await drawing.exportDataAsync(pageID: pageID, format: "dwg")
        #expect(String(decoding: dwg.prefix(6), as: UTF8.self) == "AC1032")
        #expect(source.session.changeCount == sourceChangeCount, "Export must not mutate the native document")
        let sourceSaved = await source.save(); #expect(sourceSaved.succeeded, "\(sourceSaved.error ?? "")")

        let host = CadWebEngineSession()
        var editedDWG = Data()
        var editedLine: CADSketchTransferCurve?
        do {
            try await host.start()
            _ = try await host.open(bytes: dwg, format: "dwg")
            let initial = try await host.transferSketch()
            #expect(initial.insertionUnits == 4); #expect(initial.unitScaleMM == 1)
            #expect(initial.selectedLayers.contains("GEOMETRY"))
            let line = try #require(initial.curves.first { $0.kind == .line && $0.layer == "GEOMETRY" })
            let originalStart = try #require(line.start)
            let request = try JSONSerialization.data(withJSONObject: ["operation": "move", "handle": line.handle, "delta": [2,3,0]])
            _ = try await host.edit(String(decoding: request, as: UTF8.self))
            let moved = try await host.transferSketch(handles: [line.handle])
            let movedStart = try #require(moved.curves.first?.start)
            #expect(abs(movedStart[0] - originalStart[0] - 2) < 1e-7)
            #expect(abs(movedStart[1] - originalStart[1] - 3) < 1e-7)
            try await host.undo()
            #expect(try await host.transferSketch(handles: [line.handle]).curves.first?.start == originalStart)
            try await host.redo()
            editedDWG = try await host.save()
            _ = try await host.open(bytes: editedDWG, format: "dwg")
            let reopened = try await host.transferSketch(handles: [line.handle])
            #expect(reopened.draftRevision == 0)
            #expect(reopened.unitScaleMM == 1)
            #expect(reopened.curves.first?.start == movedStart)
            editedLine = reopened.curves.first
            await host.shutdown()
        } catch { await host.shutdown(); throw error }

        let target = try await FloeCADDocument.create(at: directory.appendingPathComponent("Sketch.floecad"), name: "Transferred sketch")
        documents.append(target); CADDrawingModelBridge.configure(target)
        let decode = try #require(target.drawingSketchDecoder)
        let transfer = try await decode(editedDWG, "Engineering.dwg")
        #expect(transfer.sourceBytes == editedDWG)
        #expect(transfer.sourceSHA256 == CADSketchTransferEnvelope.digest(editedDWG))
        let expectedLine = try #require(editedLine)
        #expect(transfer.snapshot.curves.contains { $0.handle == expectedLine.handle && $0.start == expectedLine.start })
        try target.viewModel().importDrawingTransfer(transfer, placement: .init(target: .front, unitScaleMM: 1, acceptOmissions: true))
        #expect(target.summary().sketchCount == 1)
        #expect(target.session.document.sketches.first?.entities.count == transfer.snapshot.curves.count)
        target.session.undo(); #expect(target.summary().sketchCount == 0)
        target.session.redo(); #expect(target.summary().sketchCount == 1)
        let targetSaved = await target.save(); #expect(targetSaved.succeeded, "\(targetSaved.error ?? "")")
        target.close()
        let cold = try await FloeCADDocument.open(at: target.url); documents.append(cold)
        let restored = try #require(cold.session.document.sketches.first)
        #expect(restored.plane == .worldXY)
        #expect(restored.drawingSource?.sourceBytes == editedDWG)
        #expect(restored.drawingSource?.snapshot == transfer.snapshot)
        #expect(restored.drawingSource?.placement?.unitScaleMM == 1)
    }
}

private nonisolated final class DrawingBridgeCommitGate: @unchecked Sendable {
    nonisolated enum Failure: Error { case didNotEnter, commitTimedOut }
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var released = false
    private var offMain = false
    private var timeout = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func suspendFirstCommit() throws {
        let state = lock.withLock { () -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard !entered else { return (false, nil) }
            entered = true; offMain = !Thread.isMainThread
            let pending = waiter; waiter = nil
            return (!released, pending)
        }
        state.1?.resume(returning: true)
        guard state.0 else { return }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            lock.withLock { timeout = true }
            throw Failure.commitTimedOut
        }
    }
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard !entered else { return nil }
                    timeout = true
                    let pending = waiter; waiter = nil
                    return pending
                }
                pending?.resume(returning: false)
            }
            let ready = lock.withLock { () -> Bool in
                if entered { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume(returning: true) }
        }
    }
    func release() {
        let signal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if signal { semaphore.signal() }
    }
    var observedOffMain: Bool { lock.withLock { offMain } }
    var timedOut: Bool { lock.withLock { timeout } }
}
#endif

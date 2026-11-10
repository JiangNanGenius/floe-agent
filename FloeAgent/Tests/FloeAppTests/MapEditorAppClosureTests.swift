// SPDX-License-Identifier: MPL-2.0
// Candidate for the existing FloeAppTests target. Root owns actual App execution.
#if canImport(UIKit) && DEBUG
import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
import FloeCore
import FloeModels
import FloeTools
import FloeGISKit
import FloeHeavyEditorSupport
@testable import FloeApp

/// Mount the production surface; neither the renderer, original, command
/// registry, project store nor task access service is replaced by a fake.
/// DOM pointer events below exercise WK/OpenLayers handlers, not UIKit's
/// hardware gesture delivery. The separate UI checklist covers that boundary.
@MainActor final class MapEditorAppClosureTests: XCTestCase {
    private struct Work {
        let app: AppEnvironment
        let record: PersonalContentRecord
        let directory: URL
        let session: GISProjectSession
        let window: UIWindow
    }

    private func mountedWork() async throws -> Work {
        let app = try await appQualificationEnvironment()
        let service = PersonalContentService.shared
        let record = try await service.create(kind: .geography, title: "QA-Map-App-" + UUID().uuidString)
        let directory = try await service.library().resolve(record.id).url
        var mountedWindow: UIWindow?
        var openedSession: GISProjectSession?
        do {
            let session = try await GISProjectSession.open(id: record.id, directory: directory)
            openedSession = session
            try session.beginPresentation()
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            XCTAssertEqual(scenes.count, 1, "Use the one canonical App test-host scene")
            let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil)
            let window = UIWindow(windowScene: scene)
            mountedWindow = window
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView:
                GISProjectEditorSurface(session: session, onClose: {}, onAssistant: {}))
            window.makeKeyAndVisible()
            window.rootViewController?.view.layoutIfNeeded()
            try await wait("Mounted real WK canvas") {
                try await self.read(session, "Boolean(window.FloeEditor?.nativeChrome && document.querySelector('.canvas-frame .ol-viewport canvas') && document.querySelector('.ol-viewport').getBoundingClientRect().width > 100)") == .bool(true)
            }
            return Work(app: app, record: record, directory: directory, session: session, window: window)
        } catch {
            // Only this exact newly-created work is eligible for cleanup.
            mountedWindow?.isHidden = true
            mountedWindow?.rootViewController = nil
            await openedSession?.presentationEnded()
            try? await GISProjectSession.prepareForFileAction(id: record.id, directory: directory)
            try? await PersonalLibraryFileActions.deleteFromFiles(.work(record), usingTrash: false, environment: app)
            throw error
        }
    }

    private func cleanup(_ work: Work) async throws {
        work.window.isHidden = true
        work.window.rootViewController = nil
        await work.session.presentationEnded()
        try await GISProjectSession.prepareForFileAction(id: work.record.id, directory: work.directory)
        let current = try await PersonalContentService.shared.library().resolve(work.record.id).record
        try await PersonalLibraryFileActions.deleteFromFiles(.work(current), usingTrash: false, environment: work.app)
    }

    private func withWork(_ body: (Work) async throws -> Void) async throws {
        let work = try await mountedWork()
        do { try await body(work) }
        catch { try? await cleanup(work); throw error }
        try await cleanup(work)
    }

    private func wait(_ title: String, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            try Task.checkCancellation()
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        XCTFail("Timed out: \(title)")
        throw NSError(domain: "MapAppAcceptance", code: 1,
            userInfo: [NSLocalizedDescriptionKey: title])
    }

    private func read(_ session: GISProjectSession, _ expression: String) async throws -> EditorJSON {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            session.controller.webView.evaluateJavaScript("JSON.stringify(\(expression))") { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value = value as? String { continuation.resume(returning: value) }
                else { continuation.resume(throwing: HeavyEditorError.invalidDocument) }
            }
        }
        return try EditorJSON.decode(Data(text.utf8))
    }

    @discardableResult private func command(_ session: GISProjectSession, _ name: String,
        _ arguments: [String: EditorJSON] = [:]) async throws -> EditorJSON {
        let result = try await session.controller.execute(name, arguments: .object(arguments),
            expectedRevision: session.controller.document.revision)
        XCTAssertNil(session.controller.errorMessage)
        try await session.requireOriginal()
        return result["result"]
    }

    private func features(_ session: GISProjectSession, layerID: String) throws -> [EditorJSON] {
        let saved = try GISProjectOriginal.read(id: session.id, directory: session.directory)
        let layer = try XCTUnwrap(saved.state["layers"].array.first { $0["id"].string == layerID })
        return layer["data"]["features"].array
    }

    /// Only DOM events are dispatched. The helper never assigns engine state,
    /// calls a geometry handler, injects a result or bypasses e.perform/native.
    private func pointer(_ session: GISProjectSession, from: CGPoint, to: CGPoint? = nil,
        device: String = "touch") async throws {
        let destination = to ?? from
        let value: EditorJSON = .object([
            "from": .array([.number(Double(from.x)), .number(Double(from.y))]),
            "to": .array([.number(Double(destination.x)), .number(Double(destination.y))]), "device": .string(device)])
        let script = Self.pointerScript.replacingOccurrences(of: "__ARGUMENT_JSON__", with: try value.text())
        let text: String = try await withCheckedThrowingContinuation { continuation in
            session.controller.webView.callAsyncJavaScript(script, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let text = value as? String { continuation.resume(returning: text) }
                    else { continuation.resume(throwing: HeavyEditorError.invalidDocument) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertEqual(text, "dispatched", "A dispatch receipt is not an editing-success assertion")
    }

    // Fractional locations are measured from this actual live OL viewport.
    private static let pointerScript = #"""
    const a = __ARGUMENT_JSON__;
    const viewport = document.querySelector('.canvas-frame .ol-viewport');
    if (!viewport || !window.PointerEvent) throw new Error('Real OL viewport/PointerEvent unavailable');
    const rect = viewport.getBoundingClientRect();
    if (rect.width <= 100 || rect.height <= 100) throw new Error('Map has no usable layout');
    const target = viewport.querySelector('canvas');
    if (!target) throw new Error('The production map did not render a canvas');
    const point = p => [rect.left + rect.width * p[0], rect.top + rect.height * p[1]];
    const start = point(a.from), finish = point(a.to);
    const pause = () => new Promise(resolve => requestAnimationFrame(resolve));
    const send = (type, p, buttons) => target.dispatchEvent(new PointerEvent(type, {
      bubbles:true, cancelable:true, composed:true, pointerId:73, isPrimary:true,
      pointerType:a.device, button:0, buttons, clientX:p[0], clientY:p[1],
      pressure:buttons ? 0.5 : 0, width:1, height:1
    }));
    send('pointerdown', start, 1); await pause();
    if (Math.hypot(finish[0]-start[0], finish[1]-start[1]) > 0) {
      for (let i=1;i<=8;i++) {
        send('pointermove', [start[0]+(finish[0]-start[0])*i/8, start[1]+(finish[1]-start[1])*i/8], 1);
        await pause();
      }
    }
    send('pointerup', finish, 0); await pause();
    return 'dispatched';
    """#

    private func featurePoint(_ session: GISProjectSession, layerID: String, featureID: String,
        vertex: Int? = nil) async throws -> CGPoint {
        // This fixture's document/layer CRS is explicitly EPSG:4326. Pixel
        // mapping uses OL's real captured extent after every pan/re-render.
        let point = try await read(session, """
        (() => { const e=window.FloeEditor, f=e.state.layers.find(l=>l.id===\(try EditorJSON.string(layerID).text())).data.features.find(f=>String(f.id)===\(try EditorJSON.string(featureID).text()));
        const c=\(vertex.map { "f.geometry.coordinates[\($0)]" } ?? "f.geometry.coordinates"), v=e.nativeSnapshot().view, b=v.extent;
        if(v.extentCRS!=='EPSG:4326'||!b)throw new Error('Unexpected map projection');
        return [(c[0]-b[0])/(b[2]-b[0]),(b[3]-c[1])/(b[3]-b[1])]; })()
        """)
        let x = try XCTUnwrap(point.array.first?.number), y = try XCTUnwrap(point.array.last?.number)
        XCTAssertTrue((0.05...0.95).contains(x) && (0.05...0.95).contains(y), "Fixture target must be visibly inside the actual map")
        return CGPoint(x: x, y: y)
    }

    func testRealWKInputPersistsGeometryAndReopensTheSameOriginal() async throws {
        try await withWork { work in
            let session = work.session
            _ = try await command(session, "layer.create", ["name": .string("Acceptance vectors"), "crs": .string("EPSG:4326")])
            let layerID = try XCTUnwrap(session.controller.presentation["selectedLayer"]["id"].string)
            _ = try await command(session, "gis.ui.options", ["snapping": .bool(false), "fingerDrawing": .bool(false)])
            _ = try await command(session, "gis.ui.tool", ["tool": .string("Point")])
            let oldCenter = try await read(session, "window.FloeEditor.nativeSnapshot().view.center")
            try await pointer(session, from: CGPoint(x: 0.7, y: 0.7), to: CGPoint(x: 0.8, y: 0.6))
            try await wait("Finger navigation updates the real map") {
                try await self.read(session, "window.FloeEditor.nativeSnapshot().view.center") != oldCenter
            }
            XCTAssertEqual(try features(session, layerID: layerID).count, 0, "Finger navigation must not draw")

            try await pointer(session, from: CGPoint(x: 0.6, y: 0.6), device: "mouse")
            try await wait("Mouse point commits through WK/host") { try self.features(session, layerID: layerID).count == 1 }
            let pointID = try XCTUnwrap(try features(session, layerID: layerID).first?["id"].string)
            _ = try await command(session, "gis.ui.tool", ["tool": .string("select")])
            let pointLocation = try await featurePoint(session, layerID: layerID, featureID: pointID)
            try await pointer(session, from: pointLocation)
            try await wait("Real hit selection returns to the native presentation") {
                session.controller.presentation["selection"]["featureIDs"].array.contains(.string(pointID))
            }

            _ = try await command(session, "gis.ui.options", ["fingerDrawing": .bool(true)])
            _ = try await command(session, "gis.ui.tool", ["tool": .string("LineString")])
            for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.75, y: 0.3)] {
                try await pointer(session, from: p)
            }
            _ = try await command(session, "gis.ui.canvas", ["action": .string("finishDrawing")])
            try await wait("Line commits") { try self.features(session, layerID: layerID).count == 2 }
            let line = try XCTUnwrap(try features(session, layerID: layerID).first { $0["geometry"]["type"].string == "LineString" })
            let lineID = try XCTUnwrap(line["id"].string)
            XCTAssertEqual(line["geometry"]["coordinates"].array.count, 3)

            _ = try await command(session, "gis.ui.tool", ["tool": .string("Polygon")])
            for p in [CGPoint(x: 0.35, y: 0.75), CGPoint(x: 0.45, y: 0.55), CGPoint(x: 0.55, y: 0.75)] {
                try await pointer(session, from: p)
            }
            _ = try await command(session, "gis.ui.canvas", ["action": .string("finishDrawing")])
            try await wait("Polygon commits") { try self.features(session, layerID: layerID).count == 3 }
            let polygon = try XCTUnwrap(try features(session, layerID: layerID).first { $0["geometry"]["type"].string == "Polygon" })
            let ring = polygon["geometry"]["coordinates"].array.first?.array ?? []
            XCTAssertEqual(ring.count, 4); XCTAssertEqual(ring.first, ring.last)

            _ = try await command(session, "gis.ui.selection", ["layer": .string(layerID), "features": .array([.string(lineID)])])
            _ = try await command(session, "gis.ui.tool", ["tool": .string("modify")])
            let vertex = try await featurePoint(session, layerID: layerID, featureID: lineID, vertex: 0)
            try await pointer(session, from: vertex, to: CGPoint(x: vertex.x + 0.04, y: vertex.y + 0.06), device: "mouse")
            try await wait("Vertex edit commits actual geometry") {
                try self.features(session, layerID: layerID).first { $0["id"].string == lineID }?["geometry"] != line["geometry"]
            }
            let edited = try features(session, layerID: layerID)
            _ = try await command(session, "history.undo")
            XCTAssertEqual(try features(session, layerID: layerID).first { $0["id"].string == lineID }?["geometry"], line["geometry"])
            _ = try await command(session, "history.redo")
            XCTAssertEqual(try features(session, layerID: layerID), edited)
            try await session.controller.save()
            let closed = await session.flushForClose()
            XCTAssertTrue(closed, "No leaked command/model lease may prevent close")
            let durable = try GISProjectOriginal.read(id: session.id, directory: session.directory)
            let savedEvidence = XCTAttachment(string: try durable.state.text())
            savedEvidence.name = "Actual map geometry after WK edit and disk save"
            savedEvidence.lifetime = .keepAlways; add(savedEvidence)
            work.window.isHidden = true; work.window.rootViewController = nil
            let reopened = try await GISProjectSession.open(id: session.id, directory: session.directory)
            XCTAssertFalse(reopened === session, "A closed session must not stand in for disk reopen")
            XCTAssertEqual(reopened.controller.document, durable.document)
            XCTAssertEqual(try features(reopened, layerID: layerID), edited)
            await reopened.presentationEnded()
        }
    }

    func testRegisteredModelQueryReturnsActualSavedFeaturesAndRejectsAnUngrantableEdit() async throws {
        try await withWork { work in
            let session = work.session, app = work.app
            _ = try await command(session, "layer.create", ["name": .string("Model query"), "crs": .string("EPSG:4326")])
            let layerID = try XCTUnwrap(session.controller.presentation["selectedLayer"]["id"].string)
            let added = try await command(session, "feature.add", ["layer": .string(layerID), "geometry": .string("Point"),
                "coordinates": .array([.number(151.18), .number(-33.88)]), "properties": .object(["qaMarker": .string("saved-native-feature")])])
            let featureID = try XCTUnwrap(added["featureID"].string)
            let before = try GISProjectOriginal.read(id: session.id, directory: session.directory)
            let conversationID = try await app.studioCoordinator.assistant(for: work.record)
            let runID = UUID(), now = Date()
            try await app.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "running",
                goal: "Read this saved map through its registered GIS tool", startedAt: now))
            func closeRun() async throws {
                try await app.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "completed",
                    goal: "Read this saved map through its registered GIS tool", startedAt: now, endedAt: Date()))
            }
            do {
                let library = try await PersonalContentService.shared.library()
                let stores = await library.typedServiceStorePaths()
                var context = ToolContext(runID: runID, toolCallID: "map-app-query-" + UUID().uuidString,
                    allowedToolNames: GISProductionHost.names, serviceStorePaths: stores,
                    cancellation: CancellationToken(), conversationID: conversationID,
                    frozenEffectiveCatalogNames: GISProductionHost.names)
                context.executionToolName = "gis.query"
                let query = try XCTUnwrap(ToolRunnerRegistry.shared.runner(named: "gis.query"), "Use the App's actual registered bridge")
                let arguments: EditorJSON = .object(["projectID": .string(session.id.uuidString),
                    "baseRevision": .number(Double(before.document.revision)), "command": .string("query.attributes"),
                    "arguments": .object(["layer": .string(layerID), "field": .string("qaMarker"), "operator": .string("equals"), "value": .string("saved-native-feature")])])
                let output = try await query.execute(argumentsJSON: arguments.data(), context: context)
                XCTAssertEqual(output.exitStatus, 0)
                let body = try EditorJSON.decode(Data(try XCTUnwrap(output.capturedOutput).utf8))
                XCTAssertEqual(body["projectID"].string?.lowercased(), session.id.uuidString.lowercased())
                XCTAssertEqual(body["baseRevision"].number, Double(before.document.revision))
                XCTAssertEqual(body["sourceSHA256"].string, before.sha256)
                XCTAssertEqual(body["result"].array.count, 1)
                XCTAssertEqual(body["result"].array.first?["id"].string, featureID)
                XCTAssertEqual(body["result"].array.first?["qaMarker"].string, "saved-native-feature")
                XCTAssertEqual(body["access"]["canEdit"], .bool(true), "Real assistant binding must survive query")
                XCTAssertEqual(try GISProjectOriginal.read(id: session.id, directory: session.directory).sha256, before.sha256)
                let returnedEvidence = XCTAttachment(string: try body.text())
                returnedEvidence.name = "Registered GIS query actual return and source SHA"
                returnedEvidence.lifetime = .keepAlways; add(returnedEvidence)

                // No fabricated approval UUID/runtime token. The very same
                // bound task cannot turn this read context into an edit.
                let invoke = try XCTUnwrap(ToolRunnerRegistry.shared.runner(named: "gis.invoke"))
                context.executionToolName = "gis.invoke"
                let edit: EditorJSON = .object(["projectID": .string(session.id.uuidString),
                    "baseRevision": .number(Double(before.document.revision)), "command": .string("feature.add"),
                    "arguments": .object(["layer": .string(layerID), "geometry": .string("Point"),
                        "coordinates": .array([.number(0), .number(0)]), "properties": .object([:])])])
                do { _ = try await invoke.execute(argumentsJSON: edit.data(), context: context); XCTFail("An ungranted model edit must be denied") }
                catch { XCTAssertEqual(try GISProjectOriginal.read(id: session.id, directory: session.directory).sha256, before.sha256) }
                XCTAssertFalse(session.controller.isWorking)
                XCTAssertEqual(session.controller.queuedOperationCount, 0)
                try await closeRun()
            } catch { try? await closeRun(); throw error }
        }
    }
}
#endif

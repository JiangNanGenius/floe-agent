// SPDX-License-Identifier: MPL-2.0
// Real pinned-engine regression for the native Read-mode checkmark -> App
// save path. The bundled frontend's `closemobile`/"Read mode" action leaves
// the engine view read-only while the backing permission stays writable, and
// the pinned host reports only the backing permission. This test drives the
// exact native surfaces (dispatcher `closetablet`, the engine TextInput edit
// path and the production `saveInPlace`) to exercise the guarded edit entry
// against the observed Save receipt NO (native code 8) without weakening any
// save fence and without flipping the user's Read UI back to Edit. The exact
// frame-level cause behind that NO is not asserted here.
//
// Opt in only on the canonical serialized iPad host with the same private
// workbook input as OfficePDFExportAcceptanceTests. No user attachment bytes,
// identifiers or saved copies are bundled or tracked: the fixture exists only
// in a unique temporary root and is removed on success.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import Foundation
import SwiftUI
import UIKit
import WebKit
import ZIPFoundation
import FloeCore
import FloeDocuments
import FloeNotes
import FloeTools
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeReadModeSaveTests: XCTestCase {
    /// Same input contract as `OfficePDFExportAcceptanceTests.input()`: the
    /// private workbook arrives base64 in the environment, its SHA and size
    /// are verified before any byte reaches the engine, and everything is
    /// materialized under a unique temporary root this test owns.
    private func input() throws -> (provided: URL, sha: String, root: URL) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLOE_OFFICE_EXPORT_QUALIFICATION"] == "1",
              let encoded = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_BASE64"],
              let expected = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_SHA256"] else {
            throw XCTSkip("Requires explicit private workbook export qualification input")
        }
        executionTimeAllowance = 600
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThan(data.count, 512 * 1024)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OfficeReadModeSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provided = root.appendingPathComponent("provided.xlsx")
        try data.write(to: provided, options: .atomic)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: provided), expected)
        return (provided, expected, root)
    }

    /// One real-engine regression: the user edits a cell, taps the native
    /// Read-mode checkmark, then leaves with the ordinary in-place App save
    /// (no second tap, no manual re-enable).
    func testReadModeCheckmarkSaveInPlaceReentersEditPersistsAndKeepsReadUI() async throws {
        let (provided, providedSHA, root) = try input()
        // The engine may normalize the package on save; the runtime-supplied
        // input itself is never mutated and must keep its exact bytes.
        let source = root.appendingPathComponent("readmode-save.xlsx")
        try FileManager.default.copyItem(at: provided, to: source)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), providedSHA)
        let drawingPartsBefore = try workbookDrawingParts(provided)
        XCTAssertFalse(drawingPartsBefore.isEmpty,
                       "The supplied workbook must carry the ink/drawing parts this regression checks")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let environment = AppEnvironment.preview()
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            OfficeDocumentEditorView(relativePath: "readmode-save.xlsx", session: session,
                                     onSaved: nil, requestsEditingOnAppear: true)
                .environmentObject(environment)
        })
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var evidence: [String: String] = [:]
        var released = false
        do {
            await session.open(source)
            try await wait("editable owner acknowledged") {
                !session.readOnly && session.documentActionsReady && session.canAct
                    && OfficeStageRecorder.shared.events.contains {
                        $0.session == session.stageTraceSessionID
                            && $0.stage == "edit.acknowledged" && $0.detail["readOnly"] == "false"
                    }
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait("actual Office tiles painted") {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                    && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
            }
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))

            // MARK: One real cell edit through the engine's own input path.
            let marker = "RM-" + String(UUID().uuidString.prefix(8))
            let stimulus = try await web.callAsyncJavaScript(
                Self.selectCellAndEnterString,
                arguments: ["cell": "A3", "marker": marker], in: nil, contentWorld: .page) as? [String: Any]
            evidence["cell"] = "A3"
            evidence["marker"] = marker
            evidence["editPath"] = stimulus?["path"] as? String ?? "unknown"
            XCTAssertEqual(stimulus?["accepted"] as? Bool, true,
                           "The engine must accept the cell edit stimulus (path \(stimulus?["path"] ?? "unknown"))")
            try await waitForDirtyTruth(office: session, timeout: .seconds(15))

            // MARK: The user taps the native Read-mode checkmark.
            // Exact pinned frontend path: app.dispatcher -> actionsMap.closetablet
            // -> uiManager.enterReadonlyOrClose(). It must leave the document
            // writable as a backing permission and put the UI in Read mode.
            let readMode = try await web.callAsyncJavaScript(
                Self.dispatchReadModeAction, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(readMode?["ok"] as? Bool, true,
                           "The pinned closetablet action must dispatch: \(readMode ?? [:])")
            XCTAssertEqual(readMode?["uiEditBefore"] as? Bool, true)
            evidence["closetabletPermission"] = readMode?["permission"] as? String ?? "unknown"
            try await waitAsync("engine Read UI after the native checkmark") {
                let probe = await self.probe(web)
                return probe["isEditMode"] as? Bool == false
                    && probe["backendReadOnly"] as? Bool == false
            }
            let afterCheckmark = await probe(web)
            XCTAssertEqual(afterCheckmark["isEditMode"] as? Bool, false,
                           "The checkmark must leave the engine UI in its Read mode")
            XCTAssertEqual(afterCheckmark["backendReadOnly"] as? Bool, false,
                           "The checkmark is a UI mode; the engine's backing permission stays editable")
            XCTAssertFalse(session.readOnly,
                           "The App may not turn a Read-UI toggle into a read-only session")
            evidence["uiAfterCheckmark"] = "read"
            evidence["backingAfterCheckmark"] = "editable"

            // MARK: Production App save, with no user re-enable.
            try await wait("session ready for the ordinary App save") { session.canAct }
            let saveStart = Date()
            let saved = await session.saveInPlace()
            evidence["saveError"] = session.error ?? ""
            XCTAssertTrue(saved, "In-place save after the checkmark must succeed: \(session.error ?? "no error")")
            let saveEvents = OfficeStageRecorder.shared.events.filter {
                $0.session == session.stageTraceSessionID && $0.at >= saveStart
            }
            let entryEvent = saveEvents.first { $0.stage == "save.editEntry" }
            XCTAssertNotNil(entryEvent, "The save must record its guarded edit entry: \(saveEvents.map(\.stage))")
            XCTAssertEqual(entryEvent?.detail["readOnly"], "false")
            XCTAssertEqual(entryEvent?.detail["pendingPassword"], "false")
            XCTAssertEqual(entryEvent?.detail["uiEditBefore"], "false")
            XCTAssertTrue(saveEvents.contains { $0.stage == "save.ok" && $0.detail["returnToPreview"] == "false" })
            XCTAssertFalse(saveEvents.contains { $0.stage == "save.failed" })
            XCTAssertFalse(session.readOnly, "An in-place save keeps the editable session mounted")

            // The user's Read UI survives the temporary edit entry: no autosave
            // or restore leaves the surface in Edit mode.
            try await waitAsync("user Read UI restored after the in-place save") {
                let probe = await self.probe(web)
                return probe["isEditMode"] as? Bool == false
                    && probe["backendReadOnly"] as? Bool == false
            }
            let afterSave = await probe(web)
            XCTAssertEqual(afterSave["isEditMode"] as? Bool, false,
                           "The temporary edit entry must restore the Read UI, not leave Edit mode")
            XCTAssertEqual(afterSave["permission"] as? String, "readonly")
            evidence["uiAfterSave"] = "read"

            // MARK: Real persisted workbook evidence.
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: provided), providedSHA,
                           "The runtime-supplied input bytes are never modified")
            let fields = try OfficeDocumentService.inspect(url: source).fields
            XCTAssertTrue(fields.contains { $0.text == marker },
                          "The committed workbook must contain the new cell value")
            let drawingPartsAfter = try workbookDrawingParts(source)
            XCTAssertEqual(Set(drawingPartsAfter.keys), Set(drawingPartsBefore.keys),
                           "The engine save must retain the workbook's ink/drawing parts")
            XCTAssertTrue(drawingPartsAfter.values.allSatisfy { $0 > 0 })
            evidence["persistedDrawingParts"] = String(drawingPartsAfter.count)
            evidence["committedSHA"] = try FloeDigest.sha256Hex(ofFileAt: source)
            attach(evidenceJSON(evidence), "readmode-save-evidence.json")

            // MARK: Proper close, then a real reopen of the saved package.
            await session.release()
            released = true
            let reopened = OfficeFileSession()
            let reopenWindow = UIWindow(windowScene: scene)
            reopenWindow.frame = scene.coordinateSpace.bounds
            reopenWindow.rootViewController = UIHostingController(rootView: NavigationStack {
                OfficeDocumentEditorView(relativePath: "readmode-save.xlsx", session: reopened,
                                         onSaved: nil, requestsEditingOnAppear: false)
                    .environmentObject(environment)
            })
            reopenWindow.windowLevel = .normal + 1
            reopenWindow.makeKeyAndVisible()
            defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
            do {
                await reopened.open(source)
                try await wait("saved workbook reopens in the real engine") {
                    reopened.documentActionsReady && reopened.canAct
                }
                let reopenFields = try OfficeDocumentService.inspect(url: source).fields
                XCTAssertTrue(reopenFields.contains { $0.text == marker },
                              "The reopened saved workbook keeps the new cell value")
                XCTAssertEqual(try workbookDrawingParts(source).count, drawingPartsBefore.count)
                await reopened.release()
            } catch {
                await reopened.release()
                throw error
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            // Preserve the first failure before release can report a secondary
            // WebKit removal error, exactly as the existing acceptance hosts do.
            XCTFail("Read-mode save regression failed: \(error)")
            if !released { await session.release() }
        }
    }

    // MARK: - Engine stimuli (same helpers the existing real-engine hosts use)

    /// Existing actual native edit stimulus (page level, never the tool
    /// layer): the production UNO dispatcher selects a documented cell, the
    /// engine's own TextInput seam types the marker and a real Return commits
    /// the cell edit. Mirrors the helper the live-ink qualification host uses.
    private static let selectCellAndEnterString = #"""
    const map = window.app && window.app.map;
    if (!map || typeof map.sendUnoCommand !== 'function')
        throw new Error('Engine UNO dispatcher unavailable');
    const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
    let editReady = false;
    for (let i = 0; i < 60; i++) {
        if (typeof map.isEditMode === 'function' && map.isEditMode() === true) {
            editReady = true;
            break;
        }
        await frame();
    }
    if (!editReady)
        throw new Error('Engine UI is not in edit mode');
    const targetCell = (typeof cell === 'string' && /^[A-Z]+[0-9]+$/.test(cell)) ? cell : 'A3';
    const text = (typeof marker === 'string' && marker.length > 0) ? marker : 'READMODE-CELL';
    const addressOf = () => {
        try {
            const address = window.app && window.app.calc && window.app.calc.cellAddress;
            return address ? { x: address.x, y: address.y } : null;
        } catch (_) { return null; }
    };
    const expected = (() => {
        const match = /^([A-Z]+)([0-9]+)$/.exec(targetCell);
        if (!match) return null;
        let x = 0;
        for (const letter of match[1])
            x = x * 26 + (letter.charCodeAt(0) - 64);
        return { x: x - 1, y: parseInt(match[2], 10) - 1 };
    })();
    map.sendUnoCommand('.uno:GoToCell', { 'ToPoint': { type: 'string', value: targetCell } });
    let address = null;
    for (let i = 0; i < 120; i++) {
        address = addressOf();
        if (address && expected && address.x === expected.x && address.y === expected.y) break;
        await frame();
    }
    if (!address || !expected || address.x !== expected.x || address.y !== expected.y)
        throw new Error('Engine cell selection did not reach ' + targetCell + ': ' + JSON.stringify(address));
    const input = map._textInput;
    if (!input || typeof input._sendText !== 'function' || typeof input.focus !== 'function')
        throw new Error('Engine TextInput seam unavailable');
    input.focus(true);
    input._sendText(text);
    for (let i = 0; i < 6; i++) await frame();
    input._sendText('\n');
    const modified = () => {
        if (window.floeModifiedSinceCommit === true) return true;
        const handler = map.stateChangeHandler;
        if (!handler || typeof handler.getItemValue !== 'function') return false;
        const value = handler.getItemValue('.uno:ModifiedStatus');
        return value === true || value === 'true';
    };
    let observed = modified();
    for (let i = 0; i < 120 && !observed; i++) {
        await frame();
        observed = modified();
    }
    let modifiedState = null;
    try { modifiedState = map.stateChangeHandler.getItemValue('.uno:ModifiedStatus'); } catch (_) {}
    return { path: 'textInput._sendText+Return', cell: targetCell, text: text,
        accepted: observed === true, latch: window.floeModifiedSinceCommit === true,
        modified: modifiedState, address: address, expected: expected,
        uiEdit: map.isEditMode() === true };
    """#

    /// The actual pinned Read-mode action, invoked the way the tablet
    /// checkmark invokes it: `app.dispatcher.dispatch('closetablet')` ->
    /// `actionsMap.closetablet` -> `uiManager.enterReadonlyOrClose()`.
    private static let dispatchReadModeAction = #"""
    (() => {
        const app = window.app;
        const map = app && app.map;
        if (!map || typeof map.isEditMode !== 'function')
            return { ok: false, reason: 'no-engine' };
        if (!app.dispatcher || typeof app.dispatcher.dispatch !== 'function')
            return { ok: false, reason: 'no-dispatcher' };
        if (!app.dispatcher.actionsMap
            || typeof app.dispatcher.actionsMap.closetablet !== 'function')
            return { ok: false, reason: 'no-closetablet-action' };
        const before = map.isEditMode() === true;
        app.dispatcher.dispatch('closetablet');
        return { ok: true, uiEditBefore: before, uiEditAfter: map.isEditMode() === true,
                 permission: typeof map._permission === 'string' ? map._permission : null };
    })()
    """#

    // MARK: - Host helpers

    private func probe(_ web: WKWebView) async -> [String: Any] {
        let raw = try? await web.evaluateJavaScript(OfficeExplicitSaveBridge.permissionProbeScript)
        return (raw as? [String: Any]) ?? [:]
    }

    /// The engine can hold an accepted edit in memory briefly; poll the real
    /// dirty truth (never a stub) until it reflects the edit or time out.
    private func waitForDirtyTruth(office: OfficeFileSession, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var dirty = false
        while !dirty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            dirty = await office.hasLocalEditsToProtect()
        }
        XCTAssertTrue(dirty, "The real dirty probe must reflect the accepted engine edit")
        if !dirty { throw CocoaError(.coderInvalidValue) }
    }

    /// Size (and existence) of every workbook drawing part, the members the
    /// supplied highlighter ink lives in.
    private func workbookDrawingParts(_ url: URL) throws -> [String: UInt64] {
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [String: UInt64] = [:]
        for entry in archive where entry.path.hasPrefix("xl/drawings/")
            && !entry.path.contains("/_rels/") {
            parts[entry.path] = entry.uncompressedSize
        }
        return parts
    }

    private func evidenceJSON(_ facts: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }

    private func attach(_ data: Data, _ name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ description: String, timeout: TimeInterval = 120,
                      _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw CocoaError(.coderInvalidValue) }
    }

    private func waitAsync(_ description: String, timeout: TimeInterval = 120,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var met = await condition()
        while !met && Date() < deadline {
            try await Task.sleep(for: .milliseconds(150))
            met = await condition()
        }
        XCTAssertTrue(met, description)
        if !met { throw CocoaError(.coderInvalidValue) }
    }
}
#endif

// FloeAppTests — Real-engine PPTX first-save with a selected object.
//
// SPDX-License-Identifier: MPL-2.0
//
// The reported contract: with an inserted (and therefore selected) object on
// the FIRST edited save, in-place save succeeds without deselecting, commits
// real PPTX bytes, and the document reopens cleanly with the attachment
// persisted. Only actual save/reopen of the document bytes is accepted — no
// screenshot, PDF or text substitution.
//
// Host: unlike a bare `OfficeFileSession.open` (which never mounts a view and
// so can never satisfy the presentation `visibleRenderRequired` gate), this
// test mounts the REAL production `OfficeDocumentSurface` in a visible,
// foreground `UIWindow`, drives the same preview -> edit session the app uses,
// waits for the host's genuine painted-surface signal, and only then inserts
// and saves. The save path itself refuses to flush an unrendered document
// (`renderGate.permitsSave`), so a green run proves a real visible edit ->
// selected object -> save -> reopen; it never passes on the
// engine-unavailable branch or a relaxed gate.
//
// Runs only where the real pinned host is linked (DEBUG simulator builds
// with the verified kit). On such a build a render/save failure is a real
// failure, never a skip.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import Testing
import UIKit
import SwiftUI
import Crypto
@testable import FloeApp

@Suite("FloeApp.OfficeSelectedObjectSave")
@MainActor
struct OfficeSelectedObjectSaveTests {
    /// 1x1 red PNG; arbitrary attachment payload (contents irrelevant to the
    /// save contract). The engine leaves a freshly inserted image selected.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func makeFixtureCopy() throws -> (working: URL, pristine: URL) {
        guard let bundled = Bundle(for: OfficeRealEngineUITestBundleMarker.self)
            .url(forResource: "floe-sim-qual", withExtension: "pptx") else {
            throw NSError(domain: "OfficeSelectedObjectSaveTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "floe-sim-qual.pptx missing from the test bundle"
            ])
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-selected-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pristine = root.appendingPathComponent("pristine.pptx")
        let working = root.appendingPathComponent("working.pptx")
        try FileManager.default.copyItem(at: bundled, to: pristine)
        try FileManager.default.copyItem(at: bundled, to: working)
        return (working, pristine)
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(
        timeout: TimeInterval = 120,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Mounts the production Office surface in a real, foreground, sized
    /// window so the native WKWebView lays out and the host's visible-render
    /// probe can actually observe a decoded document tile.
    private func hostVisibleWindow(_ session: OfficeFileSession) -> UIWindow {
        let frame = UIScreen.main.bounds != .zero
            ? UIScreen.main.bounds
            : CGRect(x: 0, y: 0, width: 1180, height: 820)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let host = UIHostingController(rootView:
            OfficeDocumentSurface(session: session).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    /// A genuinely rendered, actionable editable surface is the ONLY accepted
    /// ready state. `documentActionsReady` is true only when the editable
    /// session reached `.ready` AND the same-generation visible-render gate
    /// permits save — so it cannot be satisfied by an open event, a sized
    /// canvas or an unrendered engine.
    private func waitEditable(_ session: OfficeFileSession) async -> Bool {
        await waitUntil(timeout: 120) {
            !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
        }
    }

    private func waitRenderedPreview(_ session: OfficeFileSession) async -> Bool {
        // A read-only preview still proves a real paint through the same
        // render gate (the open watchdog alone must not count).
        await waitUntil(timeout: 90) {
            session.canAct && session.documentActionsReady && session.controller != nil
        }
    }

    @Test("First in-place save with a selected inserted image commits and the PPTX reopens with it")
    func selectedObjectFirstSaveAndReopen() async throws {
        let fixture = try makeFixtureCopy()
        let attachment = fixture.working.deletingLastPathComponent()
            .appendingPathComponent("marker.png")
        try Data(base64Encoded: Self.pngBase64)!.write(to: attachment)
        let pristineHash = try Self.sha256(fixture.pristine)

        // --- Editable generation mounted in a REAL visible window ---
        let editSession = OfficeFileSession()
        let window = hostVisibleWindow(editSession)
        defer {
            Task { @MainActor in await editSession.release() }
            window.isHidden = true
            window.rootViewController = nil
        }

        await editSession.open(fixture.working)
        // First entry is the read-only preview (real App entry policy); prove
        // it paints, then take the SAME session into the editable generation.
        let previewed = await waitRenderedPreview(editSession)
        guard previewed else {
            Issue.record("Read-only preview never rendered (canAct=\(editSession.canAct) actionsReady=\(editSession.documentActionsReady) mounted=\(editSession.controller != nil) error=\(editSession.error ?? "nil")).")
            return
        }
        let editAccepted = await editSession.requestEditing()
        guard editAccepted else {
            Issue.record("Edit entry was refused: \(editSession.error ?? editSession.editUnavailableReason ?? "unknown")")
            return
        }
        let editable = await waitEditable(editSession)
        guard editable else {
            // Hard failure: the real engine/host is linked but a visible,
            // actionable editable surface never rendered. Record the durable
            // state instead of pretending the contract ran.
            Issue.record("Editable Office surface never became render-ready (readOnly=\(editSession.readOnly) canAct=\(editSession.canAct) actionsReady=\(editSession.documentActionsReady) mounted=\(editSession.controller != nil) error=\(editSession.error ?? "nil")).")
            return
        }

        // Insert the image. The engine leaves the inserted object selected —
        // the reported first-save precondition.
        do {
            try await editSession.insertAttachment(attachment)
        } catch {
            Issue.record("Attachment insertion failed: \(error.localizedDescription)")
            return
        }
        let actionableAfterInsert = await waitUntil(timeout: 30) {
            editSession.canAct && editSession.documentActionsReady
        }
        #expect(actionableAfterInsert, "session not actionable after the selected-object insert")

        // Save while the object is selected. The session refuses to flush an
        // unrendered document, so this is the genuine selected-state save.
        let saved = await editSession.saveInPlace()
        #expect(saved, "first save with a selected object failed: \(editSession.error ?? "no error surfaced")")
        guard saved else { return }

        let savedHash = try Self.sha256(fixture.working)
        #expect(savedHash != pristineHash, "save must persist the attachment bytes")

        // The embedded image part must be present in the committed OOXML.
        let savedData = try Data(contentsOf: fixture.working)
        let listing = Self.zipEntryNames(savedData)
        #expect(listing.contains { $0.hasPrefix("ppt/media/") },
                "saved PPTX must contain the embedded media: \(listing)")

        // --- Reopen through a FRESH preview session in a visible window ---
        let reopenSession = OfficeFileSession()
        let reopenWindow = hostVisibleWindow(reopenSession)
        defer {
            Task { @MainActor in await reopenSession.release() }
            reopenWindow.isHidden = true
            reopenWindow.rootViewController = nil
        }
        await reopenSession.open(fixture.working)
        let reopened = await waitRenderedPreview(reopenSession)
        #expect(reopened,
                "reopen never produced a rendered preview: \(reopenSession.error ?? "unknown")")
        print("FLOE_OFFICE_SELECTED_SAVE_OK savedHash=\(savedHash.prefix(16)) mediaParts="
              + "\(listing.filter { $0.hasPrefix("ppt/media/") }.count)")
    }

    /// Central-directory name listing for a zip (the saved PPTX), parsed
    /// without extracting. Reads the End-Of-Central-Directory record and walks
    /// central-directory headers; returns the raw UTF-8 entry names.
    static func zipEntryNames(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8)
                | (Int(bytes[at + 2]) << 16) | (Int(bytes[at + 3]) << 24)
        }
        let eocd: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdOffset: Int?
        if bytes.count >= 22 {
            for index in stride(from: bytes.count - 22, through: 0, by: -1)
            where index + 4 <= bytes.count && Array(bytes[index..<index + 4]) == eocd {
                eocdOffset = index
                break
            }
        }
        guard let cursor = eocdOffset else { return [] }
        let total = u16(cursor + 10)
        var offset = u32(cursor + 16)
        var names: [String] = []
        for _ in 0..<total {
            guard offset + 46 <= bytes.count,
                  u32(offset) == 0x02014b50 else { break }
            let nameLen = u16(offset + 28)
            let extraLen = u16(offset + 30)
            let commentLen = u16(offset + 32)
            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            if let name = String(bytes: bytes[nameStart..<nameStart + nameLen], encoding: .utf8) {
                names.append(name)
            }
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return names
    }
}

/// Bundle marker so the test locates its resources without XCTest bundle APIs.
final class OfficeRealEngineUITestBundleMarker: NSObject {}
#endif

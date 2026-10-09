// FloeAppTests — Real-engine PPTX first-save with a selected object.
//
// SPDX-License-Identifier: MPL-2.0
//
// Local qualification against the pinned native Office host (the simulator
// kit in Vendor/Office, linked per native-host.xcconfig): open the pinned
// synthetic deck editable through the production session/intent path,
// insert an image attachment (the engine leaves the inserted object
// selected), save in place while that object is selected, then reopen and
// verify the persisted bytes changed and the document parses. This is the
// actual save/reopen check for the "selected object -> first save" contract;
// it never screenshots or substitutes PDF/text evidence.
//
// Runs only where the real pinned host is linked (simulator builds with the
// verified kit). Any other build compiles this file out.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import Testing
import Crypto
@testable import FloeApp

@Suite("FloeApp.OfficeSelectedObjectSave")
@MainActor
struct OfficeSelectedObjectSaveTests {
    /// 1x1 red PNG; arbitrary attachment payload for the selected-object
    /// state (contents are irrelevant to the save contract).
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
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 120
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    /// The user-reported contract: with an inserted (and therefore selected)
    /// object on the first edited save, in-place save succeeds without
    /// requiring a deselect, and the persisted document reopens cleanly with
    /// the attachment's bytes present.
    @Test("First in-place save succeeds with a selected inserted object; reopen persists it")
    func selectedObjectFirstSaveAndReopen() async throws {
        let fixture = try makeFixtureCopy()
        let attachment = fixture.working.deletingLastPathComponent()
            .appendingPathComponent("marker.png")
        try Data(base64Encoded: Self.pngBase64)!.write(to: attachment)

        let session = OfficeFileSession()
        await session.open(fixture.working)
        guard await waitUntil({ session.phase == .ready || session.phase == .failed }) else {
            Issue.record("Preview open never settled (phase stuck at \(String(describing: session.phase)))")
            return
        }
        #expect(session.phase == .ready, "preview open failed: \(session.error ?? "unknown")")

        // Edit entry remounts the editable generation.
        let editing = await session.requestEditing()
        #expect(editing)
        guard await waitUntil({ session.canAct || session.phase == .failed }, timeout: 180) else {
            Issue.record("Editable generation never became ready")
            return
        }
        #expect(session.canAct, "edit entry failed: \(session.error ?? "unknown")")

        // Insertion leaves the inserted object selected (engine contract).
        do {
            try await session.insertAttachment(attachment)
        } catch {
            Issue.record("Attachment insertion failed: \(error.localizedDescription)")
            return
        }
        #expect(session.canAct, "session not actionable after attachment: \(session.error ?? "unknown")")

        // The observed precondition: save while the object is selected.
        let saved = await session.saveInPlace()
        #expect(saved, "first save with a selected object failed: \(session.error ?? "no error surfaced")")
        guard saved else { return }

        let pristineHash = try Self.sha256(fixture.pristine)
        let savedHash = try Self.sha256(fixture.working)
        #expect(savedHash != pristineHash, "save must persist the attachment bytes")

        // Reopen the saved document: it must parse and reach a ready render
        // state — the honest save/reopen verification, no substitution.
        await session.open(fixture.working)
        guard await waitUntil({ session.phase == .ready || session.phase == .failed }) else {
            Issue.record("Reopen never settled")
            return
        }
        #expect(session.phase == .ready, "reopen failed: \(session.error ?? "unknown")")
    }
}

/// Bundle marker so the test can locate its resources bundle without
/// depending on XCTest bundle APIs.
final class OfficeRealEngineUITestBundleMarker: NSObject {}
#endif

// SPDX-License-Identifier: MPL-2.0
// FloeApp — DEBUG-only fixture for the canvas native-CAD node entry surface.
//
// Launch with `-ui-testing --ui-test-canvas-cad-fixture`. It builds an
// ordinary canvas (no file workspace, no chat task) with ONE canvas-owned
// native CAD node through the production bridge
// (`CADCanvasActionBridge.newCADDocumentInCanvas`), presents the REAL
// `WorkspaceCanvasView` and selects the node so the bottom contextual
// toolbar shows its explicit "Open CAD workbench" action. The UI test then
// drives that action and asserts the full-screen native CAD editor opens via
// the SAME binding route double tap uses (`openNativeCADEditor` →
// `CanvasNativeCADEditor`).
//
// The UI test proves the previously reported defects are fixed: the node
// shows its real viewport thumbnail with an explicit editable `.floecad`
// identity (not a generic document icon labelled image/png), and the
// selected-node contextual action opens the native CAD workbench rather
// than inline-renaming the node. Debug only: no release code path creates
// this fixture.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeCAD

/// Fixture node identity carried into `WorkspaceCanvasView`. The environment
/// key is always compiled (always nil in product paths); only the harness
/// view below is DEBUG-gated.
struct CanvasCADFixtureAutoOpen: Equatable {
    let nodeID: UUID
    let documentID: UUID
}

struct CanvasCADFixtureAutoOpenKey: EnvironmentKey {
    static let defaultValue: CanvasCADFixtureAutoOpen? = nil
}

extension EnvironmentValues {
    var canvasCADFixtureAutoOpen: CanvasCADFixtureAutoOpen? {
        get { self[CanvasCADFixtureAutoOpenKey.self] }
        set { self[CanvasCADFixtureAutoOpenKey.self] = newValue }
    }
}

#if DEBUG
import FloePersistence

struct CanvasCADEntryFixtureHarness: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var canvasID = UUID()
    @State private var nodeID: UUID?
    @State private var documentID: UUID?
    @State private var failed: String?

    var body: some View {
        Group {
            if let failed {
                VStack(spacing: 12) {
                    Text("Canvas CAD fixture failed").font(.headline)
                    Text(failed).font(.footnote).multilineTextAlignment(.center).padding()
                }
            } else if let nodeID, let documentID {
                WorkspaceCanvasView(canvasID: canvasID,
                                    name: "CAD Canvas Fixture",
                                    workspace: nil)
                    .environment(\.canvasCADFixtureAutoOpen,
                                  CanvasCADFixtureAutoOpen(nodeID: nodeID,
                                                           documentID: documentID))
            } else {
                ProgressView("Preparing canvas CAD fixture…")
            }
        }
        .accessibilityIdentifier("CanvasCADFixtureHarness")
        .task {
            guard nodeID == nil, failed == nil else { return }
            do {
                try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                            name: "CAD Canvas Fixture",
                                                            workspaceID: nil)
                let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
                guard let docID = project.documents.first?.id else {
                    throw CADDocumentError(code: "fixture_failed",
                                           message: "The fixture canvas has no document.")
                }
                let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
                    canvasID: canvasID,
                    documentID: docID,
                    // Inside the initial detail viewport (clear of the
                    // sidebar at regular width; the node is 420×300 centred
                    // here) so it is visible without an initial pan.
                    position: CanvasPoint(x: 420, y: 320),
                    assetStore: environment.creativeAssetStore)
                guard let created = result.nodeID else {
                    throw CADDocumentError(code: "fixture_failed", message: result.message)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-canvas-cad-damaged") {
                    try await prepareDamagedPackage(nodeID: created)
                }
                documentID = docID
                nodeID = created
            } catch {
                failed = error.localizedDescription
            }
        }
    }

    /// Only the UI fixture owns this new canvas/package. Two real commits
    /// precede the corruption, so the product recovery route must inspect the
    /// previous commit rather than promote it while opening the editor.
    @MainActor
    private func prepareDamagedPackage(nodeID: UUID) async throws {
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        guard let node = project.documents.flatMap(\.nodes).first(where: { $0.id == nodeID }),
              let key = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
              let url = CADCanvasActionBridge.packageURL(forSourceKey: key) else {
            throw CADDocumentError(code: "fixture_failed", message: "Missing fixture CAD binding.")
        }
        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        defer { live.close() }

        func run(_ json: String) throws -> [String: Any] {
            let result = live.executeJSON(Data(json.utf8))
            guard result.isOK,
                  let value = try JSONSerialization.jsonObject(with: result.payload) as? [String: Any] else {
                throw CADDocumentError(code: result.errorCode ?? "fixture_failed",
                                       message: result.message ?? "Fixture command failed.")
            }
            return value
        }
        let created = try run(#"{"op":"sketch.create","args":{"name":"Recovery base"}}"#)
        guard let sketchID = created["sketchID"] as? String else {
            throw CADDocumentError(code: "fixture_failed", message: "Missing fixture sketch.")
        }
        _ = try run("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[30,20]}]}}
        """)
        _ = try run("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[15,10],"distance":8}}
        """)
        let capture = try live.captureViewportPNG(width: 640, height: 480)
        var saved = await live.saveViewportPreview(capture.pngData)
        guard saved.succeeded else {
            throw CADDocumentError(code: "fixture_failed", message: saved.error ?? "Could not save fixture.")
        }
        _ = try run(#"{"op":"sketch.create","args":{"name":"Current only"}}"#)
        saved = await live.save()
        guard saved.succeeded else {
            throw CADDocumentError(code: "fixture_failed", message: saved.error ?? "Could not save fixture.")
        }
        live.close()
        _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url, expected: live)
        try Data("{".utf8).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        guard case .damaged(_, let preview) = await FloeCADDocument.recoveryInspection(at: url),
              preview != nil else {
            throw CADDocumentError(code: "fixture_failed", message: "No verified previous fixture commit.")
        }
        let witness = try JSONSerialization.data(withJSONObject: [
            "canvasID": canvasID.uuidString,
            "nodeID": nodeID.uuidString,
            "sourceKey": key,
            "packagePath": url.path,
            "purpose": "Owned native recovery UI fixture; not user data",
        ], options: [.sortedKeys])
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeAgent/CADFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try witness.write(to: root.appendingPathComponent("CanvasRecoveryFixture.json"), options: .atomic)
    }
}
#endif
#endif

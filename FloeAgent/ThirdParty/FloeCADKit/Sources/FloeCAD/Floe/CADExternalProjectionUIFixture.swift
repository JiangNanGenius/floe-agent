// SPDX-License-Identifier: MPL-2.0
// DEBUG-only starting document and live readback for the shipped Project tool.
#if DEBUG && canImport(SwiftUI)
import Foundation
import SwiftUI
import simd
import UIKit
import MetalKit

@MainActor
public enum CADExternalProjectionUIFixture {
    static let targetName = "Linked projection"

    public static func open(broken: Bool) async throws -> FloeCADDocument {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/CADFixtures/ExternalProjection", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(broken ? "broken.floecad" : "pick.floecad")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let document = try await FloeCADDocument.create(at: url, name: "External projection")
        do {
            let sourceSketch = Sketch(name: "Projection source", plane: .ground, entities: [
                .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60))])
            let bodyID = BodyID()
            let source = FeatureNode(name: "Projection plate", kind: .extrude(
                profile: ProfileRef(sketchID: sourceSketch.id, entityIDs: sourceSketch.entities.map(\.id),
                    holeEntityIDs: [], seedPoint: SIMD2(50, 30)),
                plane: PlaneRef(source: .sketch(sourceSketch.id)), distance: Expr(value: 10),
                symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []), outputBodyIDs: [bodyID])
            document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sourceSketch)], title: "Projection plate")
            document.session.perform(SetItemVisibilityCommand(item: .sketch(sourceSketch.id), isHidden: true))
            let target = Sketch(name: targetName, plane: .readable(origin: SIMD3(50, -5, -30), normal: SIMD3(0, 1, 0)))
            document.session.perform(AddSketchCommand(sketch: target))
            guard document.session.lastEvalErrors.isEmpty,
                  let frozen = document.session.associativeSources(for: [bodyID])[bodyID],
                  let brep = frozen.snapshot.body.brep else { throw failure("Source did not build") }
            if broken {
                let names = ElementNaming.edgeNames(adjacency: OCCTKernel.edgeFaceAdjacency(brep),
                    names: frozen.snapshot.kernelNames)
                let curves = OCCTKernel.edgeCurves(brep)
                guard let selected = names.first(where: { index, _ in
                    guard let curve = curves[index], curve.isLine else { return false }
                    return simd_length((curve.start + curve.end) / 2 - SIMD3(50, 10, -60)) < 1e-5
                })?.value else { throw failure("Named source edge missing") }
                let projected = ProjectionKit.linked(snapshot: frozen.snapshot, version: frozen.version,
                    onto: target.plane, selected: [selected])
                guard projected.entities.count == 1, projected.references.count == 1,
                      document.session.performWithSketchRebuild(AddProjectedSketchEntitiesCommand(
                        sketchID: target.id, entities: projected.entities, references: projected.references,
                        title: "Project"), sketchID: target.id) else { throw failure("Projection did not build") }
                document.session.deleteFeature(source.id)
                guard document.session.document.body(with: bodyID) == nil,
                      document.session.document.features.node(source.id) == nil,
                      document.viewModel().brokenExternalReferenceCount(in:
                        document.session.document.sketches.first(where: { $0.id == target.id }) ?? target) == 1
                else { throw failure("Actual source deletion did not leave a broken link") }
            }
            let saved = await document.save()
            guard saved.succeeded else { throw failure(saved.error ?? "Save failed") }
            document.viewModel().openItemSketch(target.id)
            return document
        } catch { document.close(); throw error }
    }

    private static func failure(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "external_projection_fixture", message: message)
    }
}

/// No fixture controls execute an edit. XCUITest uses real palette buttons and
/// viewport taps; this panel only reports the live document and camera.
public struct CADExternalProjectionReadbackPanel: View {
    let document: FloeCADDocument
    @State private var cameraReady = false
    public init(document: FloeCADDocument) { self.document = document }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let model = document.viewModel()
            let sketch = document.session.document.sketches.first { $0.name == CADExternalProjectionUIFixture.targetName }
            let broken = sketch.map { model.brokenExternalReferenceCount(in: $0) } ?? -1
            let armed: Bool = { if case .sketching(_, .project?) = model.mode { return true }; return false }()
            VStack(alignment: .leading, spacing: 2) {
                row("CADProjectionState", "references=\(sketch?.externalReferences?.count ?? 0) entities=\(sketch?.entities.count ?? 0) broken=\(broken) selected=\(model.selectedSketchEntityIDs.count) armed=\(armed) ready=\(cameraReady)")
                row("CADProjectionEdgeScreen", screen(model.cameraControl?.worldToScreenPoint(SIMD3(50, 10, -60))))
                row("CADProjectionLineScreen", screen(model.cameraControl?.worldToScreenPoint(SIMD3(50, -5, -60))))
                row("CADProjectionError", model.errorMessage ?? "none")
                row("CADProjectionCamera", (model.cameraControl as? ViewportCoordinator)?.projectionQualificationState ?? "camera=none")
                row("CADProjectionViewTree", liveViewports(model))
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
        }
        .task {
            for _ in 0..<600 {
                if let camera = document.viewModel().cameraControl,
                   let sketch = document.viewModel().activeSketch,
                   camera.worldToScreenPoint(sketch.plane.origin) != nil {
                    camera.fitTo(bounds: (SIMD3(-10, -5, -70), SIMD3(110, 10, 10)))
                    try? await Task.sleep(for: .milliseconds(600))
                    if Task.isCancelled { return }
                    camera.moveCameraHeadOn(to: sketch.plane)
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { cameraReady = true }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
        }
    }

    private func liveViewports(_ model: EditorViewModel) -> String {
        var results: [String] = []
        func visit(_ view: UIView, depth: Int) {
            guard depth < 50, results.count < 8 else { return }
            if let viewport = view as? MTKView {
                let owner = (viewport as? CADViewportMTKView)?.coordinator
                results.append("\(Int(viewport.bounds.width))x\(Int(viewport.bounds.height)) win=\(viewport.window != nil) owner=\(owner === model.cameraControl) render=\(viewport.delegate != nil)")
            }
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { visit(window, depth: 0) }
        }
        return results.isEmpty ? "MTKViews=none" : results.joined(separator: " | ")
    }

    private func screen(_ point: CGPoint?) -> String {
        guard let point else { return "pending" }
        return String(format: "%.3f,%.3f", locale: Locale(identifier: "en_US_POSIX"), point.x, point.y)
    }
    private func row(_ id: String, _ value: String) -> some View {
        Text(value).accessibilityLabel(value).accessibilityIdentifier(id)
    }
}
#endif

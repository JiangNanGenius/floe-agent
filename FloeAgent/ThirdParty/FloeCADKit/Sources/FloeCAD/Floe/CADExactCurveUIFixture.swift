// SPDX-License-Identifier: MPL-2.0
// DEBUG starting document and read-only camera/model observations. All edits
// are driven through the shipped palette, picker, viewport and command stack.
#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import simd

@MainActor
public enum CADExactCurveUIFixture {
    static let sketchName = "Exact curves"
    static let sourceID = UUID(uuidString: "AC037004-0000-4000-8000-000000000001")!

    public static func open(reopen: Bool) async throws -> FloeCADDocument {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/CADFixtures/ExactCurves", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("curves.floecad")
        let document: FloeCADDocument
        if reopen {
            document = try await FloeCADDocument.open(at: url)
        } else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            document = try await FloeCADDocument.create(at: url, name: "Exact curves")
            let sketch = Sketch(name: sketchName, plane: .ground, entities: [
                .ellipse(id: sourceID, center: .zero, radiusX: 30, radiusY: 18, rotation: 0),
                .line(id: UUID(), a: SIMD2(0,-40), b: SIMD2(0,40)),
                .line(id: UUID(), a: SIMD2(25,-40), b: SIMD2(25,40))])
            document.session.perform(AddSketchCommand(sketch: sketch))
            let saved = await document.save()
            guard saved.succeeded else {
                document.close()
                throw CADDocumentError(code: "curve_fixture_save", message: saved.error ?? "Save failed")
            }
        }
        guard let sketch = document.session.document.sketches.first(where: { $0.name == sketchName }) else {
            document.close()
            throw CADDocumentError(code: "curve_fixture_missing", message: "The saved sketch is missing.")
        }
        document.viewModel().openItemSketch(sketch.id)
        return document
    }
}

public struct CADExactCurveReadbackPanel: View {
    let document: FloeCADDocument
    @State private var ready = false
    public init(document: FloeCADDocument) { self.document = document }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let model = document.viewModel()
            let sketch = document.session.document.sketches.first { $0.name == CADExactCurveUIFixture.sketchName }
            let exactCount = sketch?.entities.filter { if case .exactCurve = $0 { return true }; return false }.count ?? 0
            let source = sketch?.entities.first { $0.id == CADExactCurveUIFixture.sourceID }
            let definition = source.flatMap { try? SketchCurveDefinition($0) }
            VStack(alignment: .leading, spacing: 1) {
                row("CADExactCurveState", "entities=\(sketch?.entities.count ?? -1) exact=\(exactCount) links=\(sketch?.curveOffsetLinks.count ?? -1) source=\(source != nil) ready=\(ready)")
                row("CADExactCurveInterval", definition.map { String(format: "%.8f,%.8f", locale: Locale(identifier: "en_US_POSIX"), $0.interval.lower, $0.interval.upper) } ?? "missing")
                row("CADExactCurvePick", screen(SIMD2(30,0), sketch: sketch, model: model))
                row("CADExactCurveEndPick", screen(SIMD2(0,-18), sketch: sketch, model: model))
                row("CADExactCurveError", model.errorMessage ?? "none")
            }
            .font(.system(size: 9, design: .monospaced)).lineLimit(1)
            .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
        }
        .task {
            for _ in 0..<600 {
                let model = document.viewModel()
                if let camera = model.cameraControl, let sketch = model.activeSketch,
                   camera.worldToScreenPoint(sketch.plane.origin) != nil {
                    let a = sketch.plane.toWorld(SIMD2(-45,-48))
                    let b = sketch.plane.toWorld(SIMD2(45,48))
                    camera.fitTo(bounds: (simd_min(a,b) - SIMD3(repeating: 2),
                                          simd_max(a,b) + SIMD3(repeating: 2)))
                    try? await Task.sleep(for: .milliseconds(600))
                    if Task.isCancelled { return }
                    camera.moveCameraHeadOn(to: sketch.plane)
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { ready = true }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
        }
    }

    private func row(_ id: String, _ value: String) -> some View {
        Text(value).accessibilityLabel(value).accessibilityIdentifier(id)
    }
    private func screen(_ point: SIMD2<Double>, sketch: Sketch?, model: EditorViewModel) -> String {
        guard let sketch, let value = model.cameraControl?.worldToScreenPoint(sketch.plane.toWorld(point)) else { return "pending" }
        return String(format: "%.3f,%.3f", locale: Locale(identifier: "en_US_POSIX"), value.x, value.y)
    }
}
#endif

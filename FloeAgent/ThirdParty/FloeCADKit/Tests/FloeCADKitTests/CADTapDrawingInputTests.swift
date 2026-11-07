// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import FloeCAD

@Suite("Tap-built CAD geometry respects physical drawing input", .serialized)
@MainActor struct CADTapDrawingInputTests {
    /// Same typed source → model event used by the real viewport, with known
    /// sketch-plane rays instead of requiring Metal or synthetic UITouch objects.
    private final class TapBridge: ViewportGestureDelegate {
        let model: EditorViewModel
        init(model: EditorViewModel) { self.model = model }
        func gestureTapped(at point: CGPoint, source: CADViewportInputSource) {
            let world = SketchPlane.ground.toWorld(SIMD2(Double(point.x), Double(point.y)))
            model.handle(.tap(ray: Ray(origin: SIMD3<Float>(world) + SIMD3(0, 100, 0), direction: SIMD3(0, -1, 0))), source: source)
        }
        func gestureTapped(at point: CGPoint) { Issue.record("Physical taps must retain their source.") }
        func gestureDoubleTapped(at point: CGPoint) {}
        func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool { false }
        func gestureDragChanged(at point: CGPoint) {}
        func gestureDragEnded(at point: CGPoint) {}
        func gestureLongPressed(at point: CGPoint) {}
        func gestureHovered(at point: CGPoint?) {}
        func gesturePencilDoubleTapped() {}
    }
    private final class LegacyTapDelegate: ViewportGestureDelegate {
        var taps = 0
        func gestureTapped(at point: CGPoint) { taps += 1 }
        func gestureDoubleTapped(at point: CGPoint) {}
        func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool { false }
        func gestureDragChanged(at point: CGPoint) {}
        func gestureDragEnded(at point: CGPoint) {}
        func gestureLongPressed(at point: CGPoint) {}
        func gestureHovered(at point: CGPoint?) {}
        func gesturePencilDoubleTapped() {}
    }
    @Test func fingerCannotPlaceOrAdvanceLineAndRectangleButCanSelectExistingGeometry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADTapInput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Tap.floecad"), name: "Tap input")
        let model = document.viewModel(), originalPreference = model.fingerDrawingEnabled
        defer { model.fingerDrawingEnabled = originalPreference; document.close(); try? FileManager.default.removeItem(at: directory) }
        let sketch = Sketch(name: "Physical input", plane: .ground)
        document.session.perform(AddSketchCommand(sketch: sketch))
        model.openItemSketch(sketch.id)
        model.startSketch(tool: .line)
        model.fingerDrawingEnabled = false
        let controller = ViewportGestureController(), bridge = TapBridge(model: model)
        controller.delegate = bridge
        let undo = document.session.undoStack.undoCommands.count
        controller.deliverTap(at: CGPoint(x: 10, y: 10), source: .finger)
        controller.deliverTap(at: CGPoint(x: 30, y: 10), source: .finger)
        #expect(!model.tapChainActive)
        #expect(model.activeSketch?.entities.isEmpty == true)
        #expect(document.session.undoStack.undoCommands.count == undo)

        controller.deliverTap(at: CGPoint(x: 10, y: 10), source: .pencil)
        #expect(model.tapChainActive)
        controller.deliverTap(at: CGPoint(x: 25, y: 30), source: .finger)
        #expect(model.tapChainActive, "An ignored finger must not end the Pencil's unfinished chain.")
        #expect(model.activeSketch?.entities.isEmpty == true)
        controller.deliverTap(at: CGPoint(x: 40, y: 10), source: .pointer)
        let line = try #require(model.activeSketch?.entities.first)
        guard case let .line(_, a, b) = line else { Issue.record("Expected the real tap-built line."); return }
        #expect(a == SIMD2(10, 10) && b == SIMD2(40, 10))
        let afterLine = document.session.undoStack.undoCommands.count
        let wasSelected = model.selectedSketchEntityIDs.contains(line.id)
        controller.deliverTap(at: CGPoint(x: 25, y: 10), source: .finger)
        #expect(model.selectedSketchEntityIDs.contains(line.id) != wasSelected, "Finger taps retain the existing geometry-selection toggle.")
        #expect(model.activeSketch?.entities.count == 1)
        #expect(document.session.undoStack.undoCommands.count == afterLine)

        model.startSketch(tool: .rect)
        model.setRectangleType(.diagonal)
        controller.deliverTap(at: CGPoint(x: 50, y: 50), source: .finger)
        controller.deliverTap(at: CGPoint(x: 70, y: 70), source: .finger)
        #expect(model.activeSketch?.entities.count == 1)
        #expect(document.session.undoStack.undoCommands.count == afterLine)
        controller.deliverTap(at: CGPoint(x: 80, y: 80), source: .pencil)
        #expect(model.activeSketch?.entities.count == 1, "Rejected finger taps must not leave a hidden rectangle anchor.")
        controller.deliverTap(at: CGPoint(x: 100, y: 100), source: .pointer)
        #expect((model.activeSketch?.entities.count ?? 0) > 1)

        model.startSketch(tool: .text)
        controller.deliverTap(at: CGPoint(x: 120, y: 120), source: .finger)
        #expect(model.textPlacement != nil, "Explicit text placement is not freehand drawing.")
        model.startSketch(tool: .line)
        model.fingerDrawingEnabled = true
        controller.deliverTap(at: CGPoint(x: 140, y: 140), source: .finger)
        #expect(model.tapChainActive)
        model.startSketch(tool: .line)
        model.fingerDrawingEnabled = false
        let legacyPoint = SketchPlane.ground.toWorld(SIMD2(160, 160))
        model.handle(.tap(ray: Ray(origin: SIMD3<Float>(legacyPoint) + SIMD3(0, 100, 0), direction: SIMD3(0, -1, 0))))
        #expect(model.tapChainActive, "Legacy synthetic model taps keep their existing semantics.")

        // Source-aware delivery still reaches existing legacy delegates.
        let legacy = LegacyTapDelegate()
        controller.delegate = legacy
        controller.deliverTap(at: .zero, source: .pencil)
        #expect(legacy.taps == 1)
    }
}
#endif

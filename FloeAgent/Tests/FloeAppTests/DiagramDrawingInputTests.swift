// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(PencilKit)
import Foundation
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import FloeDiagramUI

@Suite("Diagram PencilKit physical drawing input")
@MainActor struct DiagramDrawingInputTests {
    @Test func sourceFilterKeepsRealInkAndNativeRecognizerWhileToggling() {
        let canvas = PKCanvasView()
        let points = [CGPoint(x: 10, y: 12), CGPoint(x: 30, y: 40)].enumerated().map { offset, point in
            PKStrokePoint(location: point, timeOffset: Double(offset) / 60, size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1)))])
        let savedInk = canvas.drawing.dataRepresentation(), recognizer = canvas.drawingGestureRecognizer
        let precision = Set([UITouch.TouchType.pencil, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) })
        DiagramDrawingInputPolicy.apply(to: canvas, fingerDrawing: false)
        #expect(canvas.drawingPolicy == .anyInput)
        #expect(Set(recognizer.allowedTouchTypes) == precision)
        DiagramDrawingInputPolicy.apply(to: canvas, fingerDrawing: true)
        #expect(Set(recognizer.allowedTouchTypes) == precision.union([NSNumber(value: UITouch.TouchType.direct.rawValue)]))
        DiagramDrawingInputPolicy.apply(to: canvas, fingerDrawing: false)
        #expect(Set(recognizer.allowedTouchTypes) == precision)
        #expect(canvas.drawingGestureRecognizer === recognizer)
        #expect(canvas.drawing.dataRepresentation() == savedInk)
        #expect(canvas.drawing.strokes.count == 1)
    }
    @Test func persistentFingerChoiceStartsOffAndDoesNotBecomeDocumentContent() throws {
        let name = "DiagramDrawingInputTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var choice = AppStorage(wrappedValue: false, DiagramDrawingInputPolicy.preferenceKey, store: defaults)
        #expect(!choice.wrappedValue)
        choice.wrappedValue = true
        #expect(AppStorage(wrappedValue: false, DiagramDrawingInputPolicy.preferenceKey, store: defaults).wrappedValue)
    }
}
#endif

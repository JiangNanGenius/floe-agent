// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeDiagramCore

@Test func nativeInkGeometryRecognizesBoxesEllipsesAndArrows() {
    let rect = DiagramInkStroke(points: [.init(x: 10, y: 10), .init(x: 110, y: 10), .init(x: 110, y: 70), .init(x: 10, y: 70), .init(x: 10, y: 10)])
    let ellipse = DiagramInkStroke(points: (0...64).map { i in let t = Double(i)/64*Double.pi*2; return .init(x: 200+60*cos(t), y: 100+40*sin(t)) })
    let arrow = [DiagramInkStroke(points: [.init(x: 0, y: 0), .init(x: 120, y: 0)]),
                 .init(points: [.init(x: 120, y: 0), .init(x: 94, y: -18)]),
                 .init(points: [.init(x: 120, y: 0), .init(x: 94, y: 18)])]
    let shapes = DiagramInkRecognizer.recognize([rect, ellipse])
    #expect(shapes.contains { if case .rectangle = $0 { return true }; return false })
    #expect(shapes.contains { if case .ellipse = $0 { return true }; return false })
    #expect(DiagramInkRecognizer.recognize(arrow).contains { if case .arrow = $0 { return true }; return false })
    #expect(DiagramInkRecognizer.recognize([.init(points: [.init(x: 0, y: 0), .init(x: 120, y: 0)])]).isEmpty)
}

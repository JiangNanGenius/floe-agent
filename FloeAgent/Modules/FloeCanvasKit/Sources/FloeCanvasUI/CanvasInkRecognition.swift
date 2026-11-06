import Foundation
import FloeCanvasCore

/// A pending convert/keep decision for recognized ink geometry.
public struct CanvasInkRecognitionSession: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var results: [CanvasInkRecognition.Result]
    /// Page drawing bytes with the recognized gesture strokes removed —
    /// used when the user chooses not to keep the original ink.
    public var clearedPencilData: Data
    public var pageID: UUID?
    public var expectedRevision: Int64?

    public init(
        id: UUID = UUID(),
        results: [CanvasInkRecognition.Result],
        clearedPencilData: Data,
        pageID: UUID? = nil,
        expectedRevision: Int64? = nil
    ) {
        self.id = id
        self.results = results
        self.clearedPencilData = clearedPencilData
        self.pageID = pageID
        self.expectedRevision = expectedRevision
    }
}

/// Geometry recognition for hand-drawn strokes (UI_BRIEF: recognize
/// line/arrow/closed-box geometry into editable objects, with an explicit
/// Keep-ink choice). Pure functions over world-space points — fully
/// testable without PencilKit. Acceptance is synthetic: recognition quality
/// and physical Pencil latency have separate limits; this never claims
/// device latency evidence.
public enum CanvasInkRecognition {
    public enum Shape: Hashable, Sendable {
        case line(start: CanvasGeometry.Point, end: CanvasGeometry.Point)
        case arrow(start: CanvasGeometry.Point, end: CanvasGeometry.Point)
        case box(frame: CanvasGeometry.Frame)
    }

    public struct Result: Hashable, Sendable {
        public var shape: Shape
        /// Axis-aligned world bounds of the source stroke(s).
        public var bounds: CanvasGeometry.Frame
        /// Confidence hint for UI ordering (not a statistical measure).
        public var confidence: Double

        public init(
            shape: Shape,
            bounds: CanvasGeometry.Frame,
            confidence: Double
        ) {
            self.shape = shape
            self.bounds = bounds
            self.confidence = confidence
        }
    }

    /// Tolerance ratios (world units are irrelevant — all relative to size).
    public static let closedTolerance: Double = 0.18
    public static let straightTolerance: Double = 0.08
    public static let minStrokeLength: Double = 24
    public static let arrowHeadRatio: Double = 0.35

    /// Classifies one stroke's point list. Points must be world-space,
    /// ordered along the stroke. Returns nil for anything unrecognized —
    /// the original ink stays untouched.
    public static func recognize(
        points: [CanvasGeometry.Point]
    ) -> Result? {
        guard points.count >= 2 else { return nil }
        let bounds = Self.bounds(of: points)
        let span = max(bounds.size.width, bounds.size.height)
        guard span >= minStrokeLength else { return nil }

        if isClosed(points) {
            if let box = recognizeBox(points: points, bounds: bounds) {
                return box
            }
        }
        return recognizeLine(points: points, bounds: bounds)
    }

    /// Classifies a multi-stroke gesture: a long straight main stroke with
    /// one or two short head strokes near an endpoint becomes an arrow.
    public static func recognize(
        strokes: [[CanvasGeometry.Point]]
    ) -> Result? {
        guard !strokes.isEmpty else { return nil }
        if strokes.count == 1 {
            return recognize(points: strokes[0])
        }
        let sorted = strokes.sorted { length(of: $0) > length(of: $1) }
        guard let shaft = sorted.first,
              let shaftResult = recognizeLine(
                  points: shaft, bounds: bounds(of: shaft)),
              case .line(let start, let end) = shaftResult.shape else {
            return recognize(points: strokes[0])
        }
        let shaftLength = distance(start, end)
        guard shaftLength >= minStrokeLength else { return nil }
        let headStrokes = sorted.dropFirst().filter {
            let len = length(of: $0)
            return len >= shaftLength * 0.08
                && len <= shaftLength * arrowHeadRatio + 8
        }
        guard !headStrokes.isEmpty else { return shaftResult }
        let headRadius = max(shaftLength * 0.22, 20)
        for head in headStrokes {
            guard let first = head.first, let last = head.last else { continue }
            let nearStart = distance(first, start) <= headRadius
                || distance(last, start) <= headRadius
            let nearEnd = distance(first, end) <= headRadius
                || distance(last, end) <= headRadius
            if nearStart || nearEnd {
                let tip = nearEnd ? end : start
                let tail = nearEnd ? start : end
                return Result(
                    shape: .arrow(start: tail, end: tip),
                    bounds: union(bounds(of: shaft), bounds(of: head)),
                    confidence: 0.8)
            }
        }
        return shaftResult
    }

    // MARK: Primitives

    public static func bounds(
        of points: [CanvasGeometry.Point]
    ) -> CanvasGeometry.Frame {
        guard let first = points.first else {
            return .init(center: .zero, size: .init(width: 1, height: 1))
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return .init(
            center: .init(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
            size: .init(
                width: max(1, maxX - minX),
                height: max(1, maxY - minY)))
    }

    static func union(
        _ lhs: CanvasGeometry.Frame,
        _ rhs: CanvasGeometry.Frame
    ) -> CanvasGeometry.Frame {
        let minX = min(lhs.minX, rhs.minX)
        let minY = min(lhs.minY, rhs.minY)
        let maxX = max(lhs.maxX, rhs.maxX)
        let maxY = max(lhs.maxY, rhs.maxY)
        return .init(
            center: .init(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
            size: .init(width: maxX - minX, height: maxY - minY))
    }

    static func distance(
        _ lhs: CanvasGeometry.Point,
        _ rhs: CanvasGeometry.Point
    ) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    static func length(of points: [CanvasGeometry.Point]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += distance(points[index - 1], points[index])
        }
        return total
    }

    static func isClosed(_ points: [CanvasGeometry.Point]) -> Bool {
        guard let first = points.first,
              let last = points.last else { return false }
        let bounds = bounds(of: points)
        let span = max(bounds.size.width, bounds.size.height)
        guard span > 0 else { return false }
        return distance(first, last) <= span * closedTolerance
    }

    static func recognizeLine(
        points: [CanvasGeometry.Point],
        bounds: CanvasGeometry.Frame
    ) -> Result? {
        guard let first = points.first,
              let last = points.last else { return nil }
        let chord = distance(first, last)
        guard chord >= minStrokeLength else { return nil }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let chordLength = max(chord, .ulpOfOne)
        var maxDeviation = 0.0
        for point in points {
            let t = ((point.x - first.x) * dx + (point.y - first.y) * dy)
                / (chordLength * chordLength)
            let projection = CanvasGeometry.Point(
                x: first.x + t * dx,
                y: first.y + t * dy)
            maxDeviation = max(maxDeviation, distance(point, projection))
        }
        guard maxDeviation <= chord * straightTolerance else { return nil }
        return Result(
            shape: .line(start: first, end: last),
            bounds: bounds,
            confidence: 1 - maxDeviation / max(chord, 1))
    }

    static func recognizeBox(
        points: [CanvasGeometry.Point],
        bounds: CanvasGeometry.Frame
    ) -> Result? {
        let ratio = min(bounds.size.width, bounds.size.height)
            / max(max(bounds.size.width, bounds.size.height), 1)
        guard ratio > 0.15 else { return nil }
        let area = bounds.size.width * bounds.size.height
        guard area >= minStrokeLength * minStrokeLength * 0.5 else { return nil }
        return Result(
            shape: .box(frame: bounds),
            bounds: bounds,
            confidence: 0.9)
    }
}

/// Builds the one-commit conversion batch shared by the store and tests.
public enum CanvasInkObjectConversionBatchBuilder {
    public static func batch(
        pageID: UUID,
        results: [CanvasInkRecognition.Result],
        keepInk: Bool,
        clearedPencilData: Data
    ) -> CanvasDocumentBatch {
        var operations: [CanvasEditOperation] = results.map { result in
            switch result.shape {
            case .line(let start, let end):
                return .insertNode(CanvasNodeSnapshot(
                    content: .shape(kind: .line, text: ""),
                    frame: .init(
                        center: .init(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                        size: .init(
                            width: max(40, abs(end.x - start.x)),
                            height: max(40, abs(end.y - start.y))))))
            case .arrow(let start, let end):
                return .insertNode(CanvasNodeSnapshot(
                    content: .shape(kind: .arrow, text: ""),
                    frame: .init(
                        center: .init(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
                        size: .init(
                            width: max(48, abs(end.x - start.x)),
                            height: max(48, abs(end.y - start.y))))))
            case .box(let frame):
                return .insertNode(CanvasNodeSnapshot(
                    content: .shape(kind: .rectangle, text: ""),
                    frame: frame))
            }
        }
        if !keepInk {
            operations.append(.setPencilDrawingData(clearedPencilData))
        }
        return CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .editPage(.init(
                pageID: pageID,
                scope: .wholeDocument,
                operations: operations))
        ])
    }
}

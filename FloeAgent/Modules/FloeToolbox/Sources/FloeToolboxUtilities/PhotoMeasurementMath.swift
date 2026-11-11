import Foundation

/// Image-plane point in pixels. The origin is the decoded image's top-left
/// corner with y increasing downward, matching pixel row order. All
/// measurements live in this space so results are invariant to view zoom,
/// pan and device orientation.
public struct PhotoPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ x: Double, _ y: Double) { self.init(x: x, y: y) }
    public static let zero = PhotoPoint(0, 0)
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// Physical units for the calibrated reference and readouts. Values are
/// stored in meters internally; conversions are exact.
public enum PhotoUnit: String, CaseIterable, Codable, Sendable {
    case millimeter, centimeter, meter, inch

    public var metersPerUnit: Double {
        switch self {
        case .millimeter: 0.001
        case .centimeter: 0.01
        case .meter: 1
        case .inch: 0.0254
        }
    }

    public var symbol: String {
        switch self {
        case .millimeter: "mm"
        case .centimeter: "cm"
        case .meter: "m"
        case .inch: "in"
        }
    }

    public static func `default`(metric: Bool) -> PhotoUnit { metric ? .centimeter : .inch }

    /// Converts meters into this unit.
    public func convert(_ meters: Double) -> Double { meters / metersPerUnit }

    /// Human-readable value with adaptive precision so the readout stays compact.
    public func format(_ meters: Double) -> String {
        let value = convert(meters)
        let digits: Int
        let magnitude = abs(value)
        if magnitude >= 100 { digits = 0 }
        else if magnitude >= 10 { digits = 1 }
        else if magnitude >= 1 { digits = 2 }
        else { digits = 3 }
        // Grouping is disabled so readouts are identical in every locale and
        // remain easy to scan inside compact instrument labels.
        return value.formatted(.number.grouping(.never).precision(.fractionLength(digits))) + " " + symbol
    }

    /// Accessible readout that does not rely on symbols alone.
    public func accessibilityFormat(_ meters: Double) -> String {
        let value = convert(meters)
        let name: String
        switch self {
        case .millimeter: name = "millimeters"
        case .centimeter: name = "centimeters"
        case .meter: name = "meters"
        case .inch: name = "inches"
        }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, name)
    }

    private var squareFactor: Double { 1 / (metersPerUnit * metersPerUnit) }
    private var squareSymbol: String {
        switch self {
        case .millimeter: "mm²"
        case .centimeter: "cm²"
        case .meter: "m²"
        case .inch: "in²"
        }
    }

    public func areaFormat(_ squareMeters: Double) -> String {
        let value = squareMeters * squareFactor
        let digits: Int
        let magnitude = abs(value)
        if magnitude >= 1000 { digits = 0 }
        else if magnitude >= 100 { digits = 1 }
        else if magnitude >= 1 { digits = 2 }
        else { digits = 3 }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(digits))) + " " + squareSymbol
    }

    public func areaAccessibilityFormat(_ squareMeters: Double) -> String {
        let value = squareMeters * squareFactor
        let name: String
        switch self {
        case .millimeter: name = "square millimeters"
        case .centimeter: name = "square centimeters"
        case .meter: name = "square meters"
        case .inch: name = "square inches"
        }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, name)
    }
}

public enum PhotoMeasurementError: Error, Equatable, Sendable {
    case nonFinite
    case invalidLength
    case zeroDistance
    case insufficientPoints
    case duplicatePoints
    case degeneratePolygon
    case selfIntersecting
    case tooManyPoints
}

/// A calibrated scale derived from a real reference segment the user placed
/// on the image and the physical length they entered for it.
public struct PhotoCalibration: Equatable, Sendable {
    public let start: PhotoPoint
    public let end: PhotoPoint
    /// Reference length in meters. Always finite and > 0.
    public let lengthMeters: Double
    /// Distance between the reference points in image pixels. Finite and > 0.
    public let pixelDistance: Double
    /// Meters per image pixel. Finite and > 0.
    public let metersPerPixel: Double
}

/// A user-placed point on the image. Reference points define the scale;
/// vertices are the actual measurements.
public struct PhotoMeasurePoint: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case reference, vertex }
    public let id: UUID
    public var position: PhotoPoint
    public var role: Role
    public init(id: UUID = UUID(), position: PhotoPoint, role: Role) {
        self.id = id; self.position = position; self.role = role
    }
}

public enum PhotoMeasureMode: String, CaseIterable, Sendable {
    case length, area, angle
}

/// Live readout for the current mode. Physical values are present only while
/// a valid calibration exists; pixel values are always available.
public struct PhotoMeasureReadout: Equatable, Sendable {
    public var pointCount: Int = 0
    public var segmentLengthsPixels: [Double] = []
    public var totalPixels: Double = 0
    public var segmentLengths: [Double] = []
    public var total: Double = 0
    public var areaSquarePixels: Double? = nil
    public var area: Double? = nil
    /// One angle per completed triple, in degrees (0, 180].
    public var angles: [Double] = []
    public var hasCalibration = false
}

/// Pure deterministic geometry for photo measurement. Every function is
/// total: non-finite input never produces a finite-looking result.
public enum PhotoMeasurementMath {
    /// Reference points closer than this (in pixels) cannot define a scale.
    public static let minimumReferencePixelDistance: Double = 1
    /// Consecutive vertices closer than this are duplicates.
    public static let duplicateTolerancePixels: Double = 0.5
    /// Polygons smaller than this are treated as accidental taps.
    public static let minimumPolygonAreaSquarePixels: Double = 0.25
    /// Hard bound on placed measurement vertices.
    public static let maximumVertices = 64

    /// Euclidean distance in pixels; nil for non-finite input.
    public static func distance(_ a: PhotoPoint, _ b: PhotoPoint) -> Double? {
        guard a.isFinite, b.isFinite else { return nil }
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Total polyline length in pixels; nil if any point is non-finite.
    public static func polylineLength(_ points: [PhotoPoint]) -> Double? {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            guard let segment = distance(points[index - 1], points[index]) else { return nil }
            total += segment
        }
        return total
    }

    /// Signed shoelace area in square pixels; nil for non-finite input.
    public static func shoelaceArea(_ polygon: [PhotoPoint]) -> Double? {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for index in 0..<polygon.count {
            let current = polygon[index], next = polygon[(index + 1) % polygon.count]
            guard current.isFinite, next.isFinite else { return nil }
            sum += current.x * next.y - next.x * current.y
        }
        return sum / 2
    }

    /// Simple planar polygon area in square pixels. Rejects insufficient,
    /// duplicated, degenerate and self-intersecting input so area is never
    /// computed across unrelated regions of the image.
    public static func polygonArea(_ points: [PhotoPoint]) throws -> Double {
        guard points.count >= 3 else { throw PhotoMeasurementError.insufficientPoints }
        for point in points where !point.isFinite { throw PhotoMeasurementError.nonFinite }
        for index in 0..<points.count {
            let d = distance(points[index], points[(index + 1) % points.count]) ?? .infinity
            if d < duplicateTolerancePixels { throw PhotoMeasurementError.duplicatePoints }
        }
        guard let area = shoelaceArea(points), area.isFinite else { throw PhotoMeasurementError.nonFinite }
        // Self-intersection is diagnosed before the area floor: a bowtie's
        // signed lobes cancel to a near-zero shoelace sum, but the shape
        // error is the actionable one for the user.
        guard !hasSelfIntersection(points) else { throw PhotoMeasurementError.selfIntersecting }
        guard abs(area) >= minimumPolygonAreaSquarePixels else { throw PhotoMeasurementError.degeneratePolygon }
        return abs(area)
    }

    /// Interior angle at `vertex` between `first` and `second`, in degrees
    /// within (0, 180]. Nil for non-finite or coincident points.
    public static func angle(vertex: PhotoPoint, first: PhotoPoint, second: PhotoPoint) -> Double? {
        guard vertex.isFinite, first.isFinite, second.isFinite else { return nil }
        let u = PhotoPoint(first.x - vertex.x, first.y - vertex.y)
        let v = PhotoPoint(second.x - vertex.x, second.y - vertex.y)
        let uLength = (u.x * u.x + u.y * u.y).squareRoot()
        let vLength = (v.x * v.x + v.y * v.y).squareRoot()
        guard uLength > 1e-12, vLength > 1e-12 else { return nil }
        let cosine = min(max((u.x * v.x + u.y * v.y) / (uLength * vLength), -1), 1)
        return acos(cosine) * 180 / Double.pi
    }

    /// True when any two non-adjacent edges properly intersect or overlap.
    public static func hasSelfIntersection(_ polygon: [PhotoPoint]) -> Bool {
        guard polygon.count >= 4 else { return false }
        let count = polygon.count
        for first in 0..<count {
            for second in (first + 1)..<count {
                let adjacent = second == first + 1 || (first == 0 && second == count - 1)
                if adjacent { continue }
                if segmentsIntersect(polygon[first], polygon[(first + 1) % count],
                                     polygon[second], polygon[(second + 1) % count]) {
                    return true
                }
            }
        }
        return false
    }

    /// Closed-segment intersection including collinear overlap.
    public static func segmentsIntersect(_ p1: PhotoPoint, _ p2: PhotoPoint,
                                         _ q1: PhotoPoint, _ q2: PhotoPoint) -> Bool {
        func orientation(_ a: PhotoPoint, _ b: PhotoPoint, _ c: PhotoPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func onSegment(_ a: PhotoPoint, _ b: PhotoPoint, _ point: PhotoPoint) -> Bool {
            min(a.x, b.x) <= point.x && point.x <= max(a.x, b.x)
                && min(a.y, b.y) <= point.y && point.y <= max(a.y, b.y)
        }
        let d1 = orientation(q1, q2, p1)
        let d2 = orientation(q1, q2, p2)
        let d3 = orientation(p1, p2, q1)
        let d4 = orientation(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        let epsilon = 1e-12
        if abs(d1) <= epsilon && onSegment(q1, q2, p1) { return true }
        if abs(d2) <= epsilon && onSegment(q1, q2, p2) { return true }
        if abs(d3) <= epsilon && onSegment(p1, p2, q1) { return true }
        if abs(d4) <= epsilon && onSegment(p1, p2, q2) { return true }
        return false
    }

    /// Builds a calibration from two reference points and the real length
    /// between them. Throws for non-finite input, non-positive lengths and
    /// reference points that are too close to resolve a scale.
    public static func makeCalibration(start: PhotoPoint, end: PhotoPoint,
                                       value: Double, unit: PhotoUnit) throws -> PhotoCalibration {
        guard start.isFinite, end.isFinite, value.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard value > 0 else { throw PhotoMeasurementError.invalidLength }
        guard let pixelDistance = distance(start, end), pixelDistance.isFinite else {
            throw PhotoMeasurementError.nonFinite
        }
        guard pixelDistance >= minimumReferencePixelDistance else { throw PhotoMeasurementError.zeroDistance }
        let lengthMeters = value * unit.metersPerUnit
        guard lengthMeters.isFinite, lengthMeters > 0 else { throw PhotoMeasurementError.invalidLength }
        return PhotoCalibration(start: start, end: end, lengthMeters: lengthMeters,
                                pixelDistance: pixelDistance, metersPerPixel: lengthMeters / pixelDistance)
    }

    public static func physicalLength(pixels: Double, calibration: PhotoCalibration) -> Double? {
        guard pixels.isFinite, pixels >= 0 else { return nil }
        return pixels * calibration.metersPerPixel
    }

    public static func physicalArea(squarePixels: Double, calibration: PhotoCalibration) -> Double? {
        guard squarePixels.isFinite, squarePixels >= 0 else { return nil }
        return squarePixels * calibration.metersPerPixel * calibration.metersPerPixel
    }

    /// Readout for the placed vertices under the current mode. Physical
    /// values appear only when calibrated; polygon area appears only once the
    /// shape is complete and simple, so partial input never reports a number.
    public static func readout(mode: PhotoMeasureMode, vertices: [PhotoMeasurePoint],
                               calibration: PhotoCalibration?) -> PhotoMeasureReadout {
        var result = PhotoMeasureReadout()
        let points = vertices.map(\.position)
        result.pointCount = points.count
        result.hasCalibration = calibration != nil
        switch mode {
        case .length:
            result.segmentLengthsPixels = (1..<max(points.count, 1)).compactMap { index in
                distance(points[index - 1], points[index])
            }
            result.totalPixels = polylineLength(points) ?? 0
        case .area:
            if points.count >= 3, let calibration,
               let squarePixels = try? polygonArea(points) {
                result.areaSquarePixels = squarePixels
                result.area = physicalArea(squarePixels: squarePixels, calibration: calibration)
            }
        case .angle:
            // Vertices are consumed in triples; the angle is measured at the
            // middle point of each completed triple.
            var index = 0
            while index + 2 <= points.count - 1 {
                if let value = angle(vertex: points[index + 1], first: points[index], second: points[index + 2]) {
                    result.angles.append(value)
                }
                index += 3
            }
        }
        if let calibration {
            result.segmentLengths = result.segmentLengthsPixels.compactMap {
                physicalLength(pixels: $0, calibration: calibration)
            }
            result.total = physicalLength(pixels: result.totalPixels, calibration: calibration) ?? 0
        }
        return result
    }
}

/// Mapping between image pixel coordinates and view points. All measurement
/// data stays in pixels; this is only the presentation transform, which is
/// why zooming and panning never change a measurement.
public struct PhotoViewTransform: Equatable, Sendable {
    /// View points per image pixel. Finite and > 0.
    public let scale: Double
    /// Image origin (top-left) in view points. Finite.
    public let offset: PhotoPoint

    public init?(scale: Double, offset: PhotoPoint) {
        guard scale.isFinite, scale > 0, offset.isFinite else { return nil }
        self.scale = scale
        self.offset = offset
    }

    public func viewPoint(fromImage point: PhotoPoint) -> PhotoPoint {
        PhotoPoint(offset.x + point.x * scale, offset.y + point.y * scale)
    }

    public func imagePoint(fromView point: PhotoPoint) -> PhotoPoint {
        PhotoPoint((point.x - offset.x) / scale, (point.y - offset.y) / scale)
    }

    /// Aspect-fit transform centering the image inside the view.
    public static func fitting(imageSize: PhotoPoint, into viewSize: PhotoPoint) -> PhotoViewTransform? {
        guard imageSize.isFinite, viewSize.isFinite, imageSize.x > 0, imageSize.y > 0,
              viewSize.x > 0, viewSize.y > 0 else { return nil }
        let scale = min(viewSize.x / imageSize.x, viewSize.y / imageSize.y)
        guard scale.isFinite, scale > 0 else { return nil }
        let offset = PhotoPoint((viewSize.x - imageSize.x * scale) / 2,
                                (viewSize.y - imageSize.y * scale) / 2)
        return PhotoViewTransform(scale: scale, offset: offset)
    }

    /// Zoom by a factor around an anchor expressed in view points. The anchor
    /// stays fixed on screen. Nil for invalid input or out-of-range results.
    public func zoomed(by factor: Double, anchor: PhotoPoint,
                       limits: ClosedRange<Double> = 0.02...64) -> PhotoViewTransform? {
        guard factor.isFinite, factor > 0, anchor.isFinite, !limits.isEmpty else { return nil }
        let newScale = min(max(scale * factor, limits.lowerBound), limits.upperBound)
        guard newScale.isFinite, newScale > 0 else { return nil }
        let imageAnchor = imagePoint(fromView: anchor)
        let newOffset = PhotoPoint(anchor.x - imageAnchor.x * newScale,
                                   anchor.y - imageAnchor.y * newScale)
        return PhotoViewTransform(scale: newScale, offset: newOffset)
    }

    public func panned(by delta: PhotoPoint) -> PhotoViewTransform? {
        guard delta.isFinite else { return nil }
        return PhotoViewTransform(scale: scale, offset: PhotoPoint(offset.x + delta.x, offset.y + delta.y))
    }

    /// Constrains panning so the image always covers the view: at least one
    /// axis is pinned to an edge while the other may float if the image is
    /// smaller than the view on that axis. Standard photo-viewer behavior.
    public func clampedPan(imageSize: PhotoPoint, viewSize: PhotoPoint) -> PhotoViewTransform {
        func clampedOffset(imageExtent: Double, viewExtent: Double, current: Double) -> Double {
            if imageExtent * scale <= viewExtent {
                // Center the smaller axis.
                return (viewExtent - imageExtent * scale) / 2
            }
            let minimum = viewExtent - imageExtent * scale
            let maximum = 0.0
            return min(max(current, minimum), maximum)
        }
        let newX = clampedOffset(imageExtent: imageSize.x, viewExtent: viewSize.x, current: offset.x)
        let newY = clampedOffset(imageExtent: imageSize.y, viewExtent: viewSize.y, current: offset.y)
        return PhotoViewTransform(scale: scale, offset: PhotoPoint(newX, newY)) ?? self
    }
}

/// Image-bound measurement state. Binding a different image identity discards
/// the calibration and every measurement, because pixel coordinates no longer
/// refer to the same scene. This type is pure so the lifecycle is testable
/// without any UI or image decoding.
public struct PhotoMeasureStore: Equatable, Sendable {
    public private(set) var imageID: UUID?
    public private(set) var referencePoints: [PhotoMeasurePoint] = []
    public private(set) var vertices: [PhotoMeasurePoint] = []
    public private(set) var calibration: PhotoCalibration?
    private var appliedValue: Double?
    private var appliedUnit: PhotoUnit?

    public init() {}

    public var isCalibrated: Bool { calibration != nil }
    public var hasReferencePair: Bool { referencePoints.count == 2 }

    /// Binds to an image. A new identity invalidates all prior calibration
    /// and measurements; rebinding the same identity keeps them.
    public mutating func beginImage(_ id: UUID) {
        if imageID != id {
            reset()
            imageID = id
        }
    }

    public mutating func reset() {
        referencePoints = []
        vertices = []
        calibration = nil
        appliedValue = nil
        appliedUnit = nil
    }

    public mutating func addReferencePoint(_ position: PhotoPoint, id: UUID = UUID()) throws {
        guard position.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard referencePoints.count < 2 else { throw PhotoMeasurementError.tooManyPoints }
        referencePoints.append(PhotoMeasurePoint(id: id, position: position, role: .reference))
    }

    public mutating func moveReferencePoint(id: UUID, to position: PhotoPoint) throws {
        guard position.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard let index = referencePoints.firstIndex(where: { $0.id == id }) else { return }
        referencePoints[index].position = position
        refreshCalibration()
    }

    public mutating func removeReferencePoint(id: UUID) {
        referencePoints.removeAll { $0.id == id }
        calibration = nil
        appliedValue = nil
        appliedUnit = nil
    }

    /// Commits the physical length for the two placed reference points.
    public mutating func applyCalibration(value: Double, unit: PhotoUnit) throws {
        guard value.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard value > 0 else { throw PhotoMeasurementError.invalidLength }
        guard referencePoints.count == 2 else { throw PhotoMeasurementError.insufficientPoints }
        calibration = try PhotoMeasurementMath.makeCalibration(
            start: referencePoints[0].position, end: referencePoints[1].position,
            value: value, unit: unit)
        appliedValue = value
        appliedUnit = unit
    }

    public mutating func addVertex(_ position: PhotoPoint, id: UUID = UUID()) throws {
        guard position.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard vertices.count < PhotoMeasurementMath.maximumVertices else { throw PhotoMeasurementError.tooManyPoints }
        vertices.append(PhotoMeasurePoint(id: id, position: position, role: .vertex))
    }

    public mutating func moveVertex(id: UUID, to position: PhotoPoint) throws {
        guard position.isFinite else { throw PhotoMeasurementError.nonFinite }
        guard let index = vertices.firstIndex(where: { $0.id == id }) else { return }
        vertices[index].position = position
    }

    public mutating func removeVertex(id: UUID) {
        vertices.removeAll { $0.id == id }
    }

    /// Removes the most recent vertex, or the most recent reference point
    /// when no vertices remain.
    public mutating func undo() {
        if !vertices.isEmpty { vertices.removeLast(); return }
        if !referencePoints.isEmpty {
            referencePoints.removeLast()
            calibration = nil
            appliedValue = nil
            appliedUnit = nil
        }
    }

    public mutating func clearVertices() {
        vertices.removeAll()
    }

    /// Recomputes the scale after reference points move, preserving the
    /// committed physical length.
    private mutating func refreshCalibration() {
        guard let appliedValue, let appliedUnit, referencePoints.count == 2 else { return }
        calibration = try? PhotoMeasurementMath.makeCalibration(
            start: referencePoints[0].position, end: referencePoints[1].position,
            value: appliedValue, unit: appliedUnit)
    }
}

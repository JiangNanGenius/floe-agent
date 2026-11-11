import Foundation
import Testing
@testable import FloeToolboxUtilities

private func pt(_ x: Double, _ y: Double) -> PhotoPoint { PhotoPoint(x, y) }

// MARK: - Calibration

@Test func photoCalibrationComputesMetersPerPixel() throws {
    let calibration = try PhotoMeasurementMath.makeCalibration(
        start: pt(0, 0), end: pt(100, 0), value: 1, unit: .meter)
    #expect(calibration.pixelDistance == 100)
    #expect(calibration.lengthMeters == 1)
    #expect(calibration.metersPerPixel == 0.01)

    let centimeters = try PhotoMeasurementMath.makeCalibration(
        start: pt(0, 0), end: pt(50, 0), value: 10, unit: .centimeter)
    #expect(centimeters.lengthMeters == 0.1)
    #expect(centimeters.metersPerPixel == 0.002)
}

@Test func photoCalibrationRejectsZeroNegativeAndNonFiniteInput() {
    #expect(throws: PhotoMeasurementError.invalidLength) {
        try PhotoMeasurementMath.makeCalibration(start: pt(0, 0), end: pt(10, 0), value: 0, unit: .meter)
    }
    #expect(throws: PhotoMeasurementError.invalidLength) {
        try PhotoMeasurementMath.makeCalibration(start: pt(0, 0), end: pt(10, 0), value: -2, unit: .meter)
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try PhotoMeasurementMath.makeCalibration(start: pt(0, 0), end: pt(10, 0), value: .nan, unit: .meter)
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try PhotoMeasurementMath.makeCalibration(start: pt(0, .infinity), end: pt(10, 0), value: 1, unit: .meter)
    }
}

@Test func photoCalibrationRejectsZeroDistanceReferences() {
    #expect(throws: PhotoMeasurementError.zeroDistance) {
        try PhotoMeasurementMath.makeCalibration(start: pt(5, 5), end: pt(5, 5), value: 1, unit: .meter)
    }
    // Sub-pixel references cannot resolve a usable scale.
    #expect(throws: PhotoMeasurementError.zeroDistance) {
        try PhotoMeasurementMath.makeCalibration(start: pt(0, 0), end: pt(0.4, 0), value: 1, unit: .meter)
    }
}

@Test func photoPhysicalConversionsStayWithinCalibration() {
    let calibration = PhotoCalibration(start: pt(0, 0), end: pt(200, 0),
                                       lengthMeters: 2, pixelDistance: 200, metersPerPixel: 0.01)
    #expect(PhotoMeasurementMath.physicalLength(pixels: 50, calibration: calibration) == 0.5)
    #expect(PhotoMeasurementMath.physicalArea(squarePixels: 10_000, calibration: calibration) == 1)
    #expect(PhotoMeasurementMath.physicalLength(pixels: -1, calibration: calibration) == nil)
    #expect(PhotoMeasurementMath.physicalLength(pixels: .nan, calibration: calibration) == nil)
    #expect(PhotoMeasurementMath.physicalArea(squarePixels: .infinity, calibration: calibration) == nil)
}

// MARK: - Geometry

@Test func photoDistanceAndPolylineAreDeterministic() {
    #expect(PhotoMeasurementMath.distance(pt(0, 0), pt(3, 4)) == 5)
    #expect(PhotoMeasurementMath.distance(pt(1, 1), pt(1, 1)) == 0)
    #expect(PhotoMeasurementMath.distance(pt(0, 0), pt(.nan, 1)) == nil)
    #expect(PhotoMeasurementMath.polylineLength([]) == 0)
    #expect(PhotoMeasurementMath.polylineLength([pt(0, 0)]) == 0)
    #expect(PhotoMeasurementMath.polylineLength([pt(0, 0), pt(3, 4), pt(3, 8)]) == 9)
    #expect(PhotoMeasurementMath.polylineLength([pt(0, 0), pt(.infinity, 0)]) == nil)
}

@Test func photoPolygonAreaComputesSquareTriangleAndConcaveL() throws {
    #expect(try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 0), pt(10, 10), pt(0, 10)]) == 100)
    #expect(try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 0), pt(0, 10)]) == 50)
    let concave = [pt(0, 0), pt(30, 0), pt(30, 10), pt(10, 10), pt(10, 30), pt(0, 30)]
    #expect(try PhotoMeasurementMath.polygonArea(concave) == 500)
    // Winding order must not change magnitude.
    #expect(try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(0, 10), pt(10, 10), pt(10, 0)]) == 100)
}

@Test func photoPolygonAreaRejectsInsufficientDuplicateDegenerateAndSelfIntersectingInput() {
    #expect(throws: PhotoMeasurementError.insufficientPoints) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 0)])
    }
    #expect(throws: PhotoMeasurementError.duplicatePoints) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 0), pt(10, 0.1)])
    }
    #expect(throws: PhotoMeasurementError.degeneratePolygon) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 0), pt(20, 0)])
    }
    // Sides stay above the 0.5 px duplicate tolerance while the area stays
    // below the 0.25 px² floor.
    #expect(throws: PhotoMeasurementError.degeneratePolygon) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(0.6, 0), pt(0.3, 0.5)])
    }
    #expect(throws: PhotoMeasurementError.selfIntersecting) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, 10), pt(10, 0), pt(0, 10)])
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try PhotoMeasurementMath.polygonArea([pt(0, 0), pt(10, .nan), pt(0, 10)])
    }
}

@Test func photoAngleMeasuresInteriorAnglesInDegrees() {
    let right = PhotoMeasurementMath.angle(vertex: pt(0, 0), first: pt(10, 0), second: pt(0, 10))
    #expect(right != nil && abs(right! - 90) < 1e-9)
    let straight = PhotoMeasurementMath.angle(vertex: pt(0, 0), first: pt(-5, 0), second: pt(5, 0))
    #expect(straight != nil && abs(straight! - 180) < 1e-9)
    let acute = PhotoMeasurementMath.angle(vertex: pt(0, 0), first: pt(10, 0), second: pt(10, 10))
    #expect(acute != nil && abs(acute! - 45) < 1e-9)
    // Coincident or non-finite input has no meaningful angle.
    #expect(PhotoMeasurementMath.angle(vertex: pt(0, 0), first: pt(0, 0), second: pt(5, 5)) == nil)
    #expect(PhotoMeasurementMath.angle(vertex: pt(0, 0), first: pt(.nan, 0), second: pt(5, 5)) == nil)
}

@Test func photoSelfIntersectionIgnoresAdjacentEdgesAndTriangles() {
    #expect(!PhotoMeasurementMath.hasSelfIntersection([pt(0, 0), pt(10, 0), pt(10, 10)]))
    #expect(!PhotoMeasurementMath.hasSelfIntersection([pt(0, 0), pt(10, 0), pt(10, 10), pt(0, 10)]))
    #expect(PhotoMeasurementMath.segmentsIntersect(pt(0, 0), pt(10, 10), pt(0, 10), pt(10, 0)))
    #expect(PhotoMeasurementMath.segmentsIntersect(pt(0, 0), pt(10, 0), pt(5, 0), pt(15, 0)))
    #expect(!PhotoMeasurementMath.segmentsIntersect(pt(0, 0), pt(10, 0), pt(0, 10), pt(10, 10)))
}

// MARK: - Zoom / coordinate invariance

@Test func photoViewTransformFitsImageAspectIntoViewport() {
    let fit = PhotoViewTransform.fitting(imageSize: pt(400, 300), into: pt(800, 600))
    #expect(fit != nil)
    #expect(fit!.scale == 2)
    #expect(fit!.offset == pt(0, 0))

    let letterboxed = PhotoViewTransform.fitting(imageSize: pt(400, 300), into: pt(600, 600))
    #expect(letterboxed != nil)
    #expect(letterboxed!.scale == 1.5)
    #expect(letterboxed!.offset == pt(0, 75))

    #expect(PhotoViewTransform.fitting(imageSize: pt(0, 300), into: pt(600, 600)) == nil)
    #expect(PhotoViewTransform.fitting(imageSize: pt(400, 300), into: pt(.nan, 600)) == nil)
    #expect(PhotoViewTransform(scale: 0, offset: .zero) == nil)
    #expect(PhotoViewTransform(scale: .nan, offset: .zero) == nil)
}

@Test func photoViewTransformRoundTripsBetweenViewAndImage() {
    let transform = PhotoViewTransform(scale: 3.5, offset: pt(40, -12))!
    let imagePoint = pt(123.4, 567.8)
    let viewPoint = transform.viewPoint(fromImage: imagePoint)
    let recovered = transform.imagePoint(fromView: viewPoint)
    #expect(abs(recovered.x - imagePoint.x) < 1e-9)
    #expect(abs(recovered.y - imagePoint.y) < 1e-9)
}

@Test func photoMeasurementsAreInvariantToZoomAndPan() {
    // The same two scene points rendered under very different zoom/pan
    // transforms must recover to identical image coordinates, so a measured
    // length never depends on how the user zoomed.
    let imageSize = pt(4000, 3000)
    let base = PhotoViewTransform.fitting(imageSize: imageSize, into: pt(800, 600))!
    let zoomed = base.zoomed(by: 4, anchor: pt(200, 300))!
        .panned(by: pt(-70, 44))!

    let sceneA = pt(1600, 1200)
    let sceneB = pt(2050, 1500)
    for transform in [base, zoomed] {
        let viewA = transform.viewPoint(fromImage: sceneA)
        let viewB = transform.viewPoint(fromImage: sceneB)
        let recoveredA = transform.imagePoint(fromView: viewA)
        let recoveredB = transform.imagePoint(fromView: viewB)
        #expect(abs(recoveredA.x - sceneA.x) < 1e-9 && abs(recoveredA.y - sceneA.y) < 1e-9)
        #expect(abs(recoveredB.x - sceneB.x) < 1e-9 && abs(recoveredB.y - sceneB.y) < 1e-9)
        let length = PhotoMeasurementMath.distance(recoveredA, recoveredB)
        #expect(length != nil && abs(length! - 540.8326913195984) < 1e-6)
    }
}

@Test func photoZoomKeepsAnchorFixedAndClampsScale() {
    let transform = PhotoViewTransform.fitting(imageSize: pt(1000, 800), into: pt(500, 400))!
    let anchor = pt(250, 200)
    let doubled = transform.zoomed(by: 2, anchor: anchor)!
    let anchorAfter = doubled.viewPoint(fromImage: transform.imagePoint(fromView: anchor))
    #expect(abs(anchorAfter.x - anchor.x) < 1e-9)
    #expect(abs(anchorAfter.y - anchor.y) < 1e-9)

    let capped = transform.zoomed(by: 1e9, anchor: anchor, limits: 0.02...64)!
    #expect(capped.scale == 64)
    let tiny = transform.zoomed(by: 1e-9, anchor: anchor, limits: 0.02...64)!
    #expect(tiny.scale == 0.02)
    #expect(transform.zoomed(by: .nan, anchor: anchor) == nil)
}

@Test func photoClampedPanKeepsImageCoveringViewport() {
    let imageSize = pt(1000, 800)
    let viewSize = pt(500, 400)
    let fit = PhotoViewTransform.fitting(imageSize: imageSize, into: viewSize)!
    // Zoomed in 4x (scale 2): the image is 2000x1600 in a 500x400 view, so
    // panning far away pins the offset to the viewport edges.
    let zoomed = fit.zoomed(by: 4, anchor: pt(250, 200))!
    let clamped = zoomed.panned(by: pt(10_000, -10_000))!.clampedPan(imageSize: imageSize, viewSize: viewSize)
    #expect(clamped.offset == pt(0, -1200))
    let opposite = zoomed.panned(by: pt(-10_000, 10_000))!.clampedPan(imageSize: imageSize, viewSize: viewSize)
    #expect(opposite.offset == pt(-1500, 0))
}

// MARK: - Store lifecycle

@Test func photoStoreBindsCalibrationAndRejectsBadInput() throws {
    var store = PhotoMeasureStore()
    let first = UUID(), second = UUID()
    try store.addReferencePoint(pt(0, 0), id: first)
    #expect(throws: PhotoMeasurementError.insufficientPoints) {
        try store.applyCalibration(value: 1, unit: .meter)
    }
    try store.addReferencePoint(pt(100, 0), id: second)
    #expect(throws: PhotoMeasurementError.tooManyPoints) {
        try store.addReferencePoint(pt(5, 5))
    }
    #expect(throws: PhotoMeasurementError.invalidLength) {
        try store.applyCalibration(value: 0, unit: .meter)
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try store.applyCalibration(value: .infinity, unit: .meter)
    }
    try store.applyCalibration(value: 1, unit: .meter)
    #expect(store.isCalibrated)
    #expect(store.calibration?.metersPerPixel == 0.01)
}

@Test func photoStoreRejectsNonFinitePoints() {
    var store = PhotoMeasureStore()
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try store.addReferencePoint(pt(.nan, 0))
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try store.addVertex(pt(0, -.infinity))
    }
    try? store.addReferencePoint(pt(0, 0), id: UUID())
    try? store.addReferencePoint(pt(100, 0), id: UUID())
    try? store.applyCalibration(value: 1, unit: .meter)
    let id = UUID()
    try? store.addVertex(pt(10, 10), id: id)
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try store.moveVertex(id: id, to: pt(.nan, 5))
    }
    #expect(throws: PhotoMeasurementError.nonFinite) {
        try store.moveReferencePoint(id: UUID(), to: pt(0, .infinity))
    }
}

@Test func photoReplacingImageInvalidatesCalibrationAndMeasurements() throws {
    var store = PhotoMeasureStore()
    let imageA = UUID(), imageB = UUID()
    store.beginImage(imageA)
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(100, 0))
    try store.applyCalibration(value: 1, unit: .meter)
    try store.addVertex(pt(10, 10))
    #expect(store.isCalibrated)
    #expect(store.vertices.count == 1)

    store.beginImage(imageA) // Same image: everything survives.
    #expect(store.isCalibrated)
    #expect(store.vertices.count == 1)

    store.beginImage(imageB) // A different image: pixel coordinates are stale.
    #expect(!store.isCalibrated)
    #expect(store.vertices.isEmpty)
    #expect(store.referencePoints.isEmpty)
}

@Test func photoMovingReferencePointsRefreshesScale() throws {
    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    let start = UUID(), end = UUID()
    try store.addReferencePoint(pt(0, 0), id: start)
    try store.addReferencePoint(pt(100, 0), id: end)
    try store.applyCalibration(value: 1, unit: .meter)
    #expect(store.calibration?.metersPerPixel == 0.01)
    try store.moveReferencePoint(id: end, to: pt(200, 0))
    #expect(store.calibration?.metersPerPixel == 0.005)
}

@Test func photoUndoAndClearFollowEditOrder() throws {
    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    #expect(throws: PhotoMeasurementError.insufficientPoints) {
        try store.applyCalibration(value: 1, unit: .meter)
    }
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(100, 0))
    try store.applyCalibration(value: 2, unit: .centimeter)
    try store.addVertex(pt(10, 10))
    try store.addVertex(pt(20, 20))
    store.clearVertices()
    #expect(store.vertices.isEmpty)
    #expect(store.isCalibrated) // Clearing measurements keeps the scale.
    store.undo()
    #expect(store.referencePoints.count == 1) // Falls back to reference editing.
    #expect(!store.isCalibrated)
    store.undo()
    #expect(store.referencePoints.isEmpty)
}

@Test func photoStoreCapsVertexCount() throws {
    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(100, 0))
    try store.applyCalibration(value: 1, unit: .meter)
    for index in 0..<PhotoMeasurementMath.maximumVertices {
        try store.addVertex(pt(Double(index), 0))
    }
    #expect(throws: PhotoMeasurementError.tooManyPoints) {
        try store.addVertex(pt(999, 999))
    }
}

// MARK: - Readout

@Test func photoReadoutReportsPhysicalValuesOnlyWhenCalibrated() throws {
    var uncalibrated = PhotoMeasureStore()
    uncalibrated.beginImage(UUID())
    try uncalibrated.addVertex(pt(50, 50))
    var readout = PhotoMeasurementMath.readout(mode: .length, vertices: uncalibrated.vertices, calibration: nil)
    #expect(!readout.hasCalibration)
    #expect(readout.totalPixels == 0) // One point has no segments; pixels only.
    #expect(readout.segmentLengths.isEmpty) // Never a physical result before calibration.

    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(100, 0))
    try store.applyCalibration(value: 1, unit: .meter) // 0.01 m per pixel.
    try store.addVertex(pt(100, 0))
    try store.addVertex(pt(300, 400))
    readout = PhotoMeasurementMath.readout(mode: .length, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.hasCalibration)
    #expect(readout.segmentLengthsPixels.count == 1)
    let expectedPixels = 200_000.0.squareRoot() // (100,0) → (300,400)
    #expect(abs(readout.totalPixels - expectedPixels) < 1e-9)
    #expect(abs(readout.total - expectedPixels * 0.01) < 1e-9)
}

@Test func photoReadoutAreaAppearsOnlyForCompleteSimplePolygon() throws {
    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(10, 0))
    try store.applyCalibration(value: 1, unit: .meter) // 0.1 m per pixel.
    try store.addVertex(pt(0, 10))
    try store.addVertex(pt(10, 10))
    var readout = PhotoMeasurementMath.readout(mode: .area, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.areaSquarePixels == nil) // Partial polygon: no premature area.
    try store.addVertex(pt(10, 30))
    try store.addVertex(pt(0, 30))
    readout = PhotoMeasurementMath.readout(mode: .area, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.areaSquarePixels == 200)
    #expect(abs(readout.area! - 2) < 1e-9) // 200 px² * (0.1 m/px)².
}

@Test func photoReadoutAnglesConsumeTriples() throws {
    var store = PhotoMeasureStore()
    store.beginImage(UUID())
    try store.addReferencePoint(pt(0, 0))
    try store.addReferencePoint(pt(10, 0))
    try store.applyCalibration(value: 1, unit: .meter)
    try store.addVertex(pt(0, 0))
    try store.addVertex(pt(10, 0))
    var readout = PhotoMeasurementMath.readout(mode: .angle, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.angles.isEmpty) // Incomplete triple.
    try store.addVertex(pt(10, 10))
    readout = PhotoMeasurementMath.readout(mode: .angle, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.angles.count == 1)
    #expect(abs(readout.angles[0] - 90) < 1e-9)
    try store.addVertex(pt(20, 0))
    try store.addVertex(pt(30, 0))
    try store.addVertex(pt(30, 10))
    readout = PhotoMeasurementMath.readout(mode: .angle, vertices: store.vertices, calibration: store.calibration)
    #expect(readout.angles.count == 2)
    #expect(abs(readout.angles[1] - 90) < 1e-9)
}

@Test func photoUnitsConvertAndFormat() {
    #expect(PhotoUnit.centimeter.convert(0.5) == 50)
    #expect(PhotoUnit.inch.convert(0.0254) == 1)
    #expect(PhotoUnit.meter.format(2) == "2.00 m")
    // Magnitude-based precision gives two fraction digits in [1, 10).
    #expect(PhotoUnit.centimeter.format(0.01567) == "1.57 cm")
    // Grouping is disabled, so large values stay locale-stable.
    #expect(PhotoUnit.millimeter.format(2) == "2000 mm")
    #expect(PhotoUnit.inch.accessibilityFormat(0.0254) == "1.00 inches")
    #expect(PhotoUnit.meter.areaFormat(1) == "1.00 m²")
    #expect(PhotoUnit.default(metric: true) == .centimeter)
    #expect(PhotoUnit.default(metric: false) == .inch)
}

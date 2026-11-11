import Foundation
import simd
import Testing
@testable import FloeToolboxUtilities

private func p(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { SIMD3<Double>(x, y, z) }

@Test func spatialDistanceMatchesPythagoreanTripleAndUnitVectors() {
    #expect(SpatialMeasurementMath.distance(p(0, 0, 0), p(3, 4, 0)) == 5)
    #expect(SpatialMeasurementMath.distance(p(1, 2, 3), p(1, 2, 3)) == 0)
    #expect(SpatialMeasurementMath.distance(p(0, 0, 0), p(0, 0, 2.5)) == 2.5)
    let diagonal = SpatialMeasurementMath.distance(p(0, 0, 0), p(1, 1, 1))
    #expect(abs(diagonal - 3.squareRoot()) < 1e-12)
}

@Test func spatialPolylineLengthAccumulatesSegments() {
    let square = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0), p(0, 0, 0)]
    #expect(SpatialMeasurementMath.polylineLength(square) == 4)
    #expect(SpatialMeasurementMath.polylineLength([p(0, 0, 0)]) == 0)
    #expect(SpatialMeasurementMath.polylineLength([]) == 0)
    let stepped = [p(0, 0, 0), p(0.3, 0, 0), p(0.3, 0.4, 0.1)]
    #expect(abs(SpatialMeasurementMath.polylineLength(stepped) - (0.3 + 0.41231056256176694)) < 1e-9)
}

@Test func spatialPolygonAreaComputesSquareRectangleTriangleAndConcaveL() throws {
    let square = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0)]
    #expect(try SpatialMeasurementMath.polygonArea(square) == 1)
    let rectangle = [p(0, 0, 0), p(3, 0, 0), p(3, 2, 0), p(0, 2, 0)]
    #expect(try SpatialMeasurementMath.polygonArea(rectangle) == 6)
    let triangle = [p(0, 0, 0), p(4, 0, 0), p(0, 3, 0)]
    #expect(try SpatialMeasurementMath.polygonArea(triangle) == 6)
    let concaveL = [p(0, 0, 0), p(3, 0, 0), p(3, 1, 0), p(1, 1, 0), p(1, 3, 0), p(0, 3, 0)]
    #expect(try SpatialMeasurementMath.polygonArea(concaveL) == 5)
    // Winding order must not change magnitude.
    #expect(try SpatialMeasurementMath.polygonArea(square.reversed()) == 1)
}

@Test func spatialPolygonAreaRejectsInsufficientDuplicateAndDegenerateInput() {
    let two = [p(0, 0, 0), p(1, 0, 0)]
    #expect(throws: SpatialMeasurementMathError.insufficientPoints) { try SpatialMeasurementMath.polygonArea(two) }
    let duplicate = [p(0, 0, 0), p(1, 0, 0), p(1, 0.0001, 0)]
    #expect(throws: SpatialMeasurementMathError.duplicatePoints) { try SpatialMeasurementMath.polygonArea(duplicate) }
    let wrappedDuplicate = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0.0001, 0.0001, 0)]
    #expect(throws: SpatialMeasurementMathError.duplicatePoints) { try SpatialMeasurementMath.polygonArea(wrappedDuplicate) }
    let collinear = [p(0, 0, 0), p(1, 0, 0), p(2, 0, 0)]
    #expect(throws: SpatialMeasurementMathError.degeneratePolygon) { try SpatialMeasurementMath.polygonArea(collinear) }
    let nearZero = [p(0, 0, 0), p(0.001, 0, 0), p(0, 0.001, 0)]
    #expect(throws: SpatialMeasurementMathError.degeneratePolygon) { try SpatialMeasurementMath.polygonArea(nearZero) }
}

@Test func spatialPolygonAreaRejectsPointsOnDifferentPlanes() throws {
    // One corner lifted beyond the default 2 cm coplanarity tolerance.
    let bent = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0.05), p(0, 1, 0)]
    #expect(throws: SpatialMeasurementMathError.notCoplanar) { try SpatialMeasurementMath.polygonArea(bent) }
    // Three points define the floor; the fourth floats above it, so the four
    // taps can never be one physical surface.
    let twisted = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0.5, 0.5, 0.5)]
    #expect(throws: SpatialMeasurementMathError.notCoplanar) { try SpatialMeasurementMath.polygonArea(twisted) }
    // Small real-world plane roughness within tolerance still measures.
    let rough = [p(0, 0, 0.004), p(1, 0, -0.006), p(1, 1, 0.009), p(0, 1, -0.003)]
    #expect(try SpatialMeasurementMath.polygonArea(rough) > 0.99)
}

@Test func spatialPolygonAreaRejectsSelfIntersectingShapes() {
    let bowtie = [p(0, 0, 0), p(1, 1, 0), p(1, 0, 0), p(0, 1, 0)]
    #expect(throws: SpatialMeasurementMathError.selfIntersecting) { try SpatialMeasurementMath.polygonArea(bowtie) }
    // Five-point star: edges 0–2 and 2–4 cross non-adjacent partners.
    let star = [p(0, 0, 0), p(1, 2, 0), p(2, 0, 0), p(0, 1, 0), p(2, 1, 0)]
    #expect(throws: SpatialMeasurementMathError.selfIntersecting) { try SpatialMeasurementMath.polygonArea(star) }
}

@Test func spatialTriangulationCoversSquareAndConcavePolygonFully() {
    func triangleArea(_ polygon: [SIMD2<Double>], _ ear: SIMD3<UInt32>) -> Double {
        let a = polygon[Int(ear.x)]
        let b = polygon[Int(ear.y)]
        let c = polygon[Int(ear.z)]
        return abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }
    func total(_ polygon: [SIMD2<Double>]) -> Double {
        guard let ears = SpatialMeasurementMath.triangulate(polygon) else { return -1 }
        #expect(ears.count == polygon.count - 2)
        for ear in ears {
            #expect(ear.x != ear.y && ear.y != ear.z && ear.x != ear.z)
            for index in [ear.x, ear.y, ear.z] {
                #expect(index < UInt32(polygon.count))
            }
            // Counter-clockwise winding.
            let a = polygon[Int(ear.x)]
            let b = polygon[Int(ear.y)]
            let c = polygon[Int(ear.z)]
            #expect((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0)
        }
        return ears.reduce(0) { $0 + triangleArea(polygon, $1) }
    }
    let square = [SIMD2<Double>(0, 0), SIMD2<Double>(1, 0), SIMD2<Double>(1, 1), SIMD2<Double>(0, 1)]
    #expect(total(square) == 1)
    // Clockwise winding must triangulate to the same covered area.
    #expect(total(square.reversed()) == 1)
    let concaveL = [SIMD2<Double>(0, 0), SIMD2<Double>(3, 0), SIMD2<Double>(3, 1),
                    SIMD2<Double>(1, 1), SIMD2<Double>(1, 3), SIMD2<Double>(0, 3)]
    #expect(total(concaveL) == 5)
    let triangle = [SIMD2<Double>(0, 0), SIMD2<Double>(4, 0), SIMD2<Double>(0, 3)]
    #expect(total(triangle) == 6)
    // Production path: self-crossing input is refused by polygonArea before
    // any fill triangulation is attempted.
    #expect(throws: SpatialMeasurementMathError.selfIntersecting) {
        try SpatialMeasurementMath.polygonArea([p(0, 0, 0), p(1, 1, 0), p(1, 0, 0), p(0, 1, 0)])
    }
}

@Test func spatialSelfIntersectionIgnoresAdjacentEdgesAndTriangles() {    #expect(!SpatialMeasurementMath.hasSelfIntersection([SIMD2<Double>(0, 0), SIMD2<Double>(1, 0), SIMD2<Double>(1, 1)]))
    #expect(!SpatialMeasurementMath.hasSelfIntersection([SIMD2<Double>(0, 0), SIMD2<Double>(1, 0), SIMD2<Double>(1, 1), SIMD2<Double>(0, 1)]))
    #expect(SpatialMeasurementMath.segmentsIntersect(SIMD2<Double>(0, 0), SIMD2<Double>(2, 2), SIMD2<Double>(0, 2), SIMD2<Double>(2, 0)))
    #expect(SpatialMeasurementMath.segmentsIntersect(SIMD2<Double>(0, 0), SIMD2<Double>(2, 0), SIMD2<Double>(1, 0), SIMD2<Double>(3, 0)))
    #expect(!SpatialMeasurementMath.segmentsIntersect(SIMD2<Double>(0, 0), SIMD2<Double>(1, 0), SIMD2<Double>(0, 1), SIMD2<Double>(1, 1)))
}

@Test func spatialPlaneBasisFindsNormalAndDetectsCollinear() {
    let basis = SpatialMeasurementMath.planeBasis(for: [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0)])
    #expect(basis != nil)
    #expect(abs(simd_dot(basis!.normal, SIMD3<Double>(0, 0, 1))) > 0.999999)
    #expect(SpatialMeasurementMath.planeBasis(for: [p(0, 0, 0), p(1, 1, 1)]) == nil)
    #expect(SpatialMeasurementMath.planeBasis(for: [p(0, 0, 0), p(1, 0, 0), p(2, 0, 0)]) == nil)
    // Vertical plane normal lies in the horizontal plane.
    let wall = SpatialMeasurementMath.planeBasis(for: [p(0, 0, 0), p(0, 0, 2), p(0, 3, 2), p(0, 3, 0)])
    #expect(wall != nil && abs(wall!.normal.x) > 0.999999)
}

@Test func spatialUnitsConvertAndFormatWithAdaptivePrecision() {
    #expect(SpatialMeasurementUnit.millimeter.convert(0.5) == 500)
    #expect(SpatialMeasurementUnit.centimeter.convert(0.5) == 50)
    #expect(SpatialMeasurementUnit.meter.convert(0.5) == 0.5)
    #expect(SpatialMeasurementUnit.inch.convert(0.0254) == 1)
    #expect(SpatialMeasurementUnit.foot.convert(0.3048) == 1)
    #expect(SpatialMeasurementUnit.inch.convert(1) == 1000.0 / 25.4)
    #expect(abs(SpatialMeasurementUnit.foot.convert(1) - 1250.0 / 381.0) < 1e-9)
    #expect(SpatialMeasurementUnit.millimeter.format(2) == "2000 mm")
    #expect(SpatialMeasurementUnit.meter.format(2) == "2.00 m")
    #expect(SpatialMeasurementUnit.centimeter.format(0.01567) == "1.57 cm")
    #expect(SpatialMeasurementUnit.meter.format(12.345) == "12.3 m")
    #expect(SpatialMeasurementUnit.meter.format(123.456) == "123 m")
    #expect(SpatialMeasurementUnit.meter.accessibilityFormat(1.5) == "1.50 meters")
    #expect(SpatialMeasurementUnit.inch.accessibilityFormat(0.0254) == "1.00 inches")
    #expect(SpatialMeasurementUnit.default(metric: true) == .meter)
    #expect(SpatialMeasurementUnit.default(metric: false) == .inch)
}

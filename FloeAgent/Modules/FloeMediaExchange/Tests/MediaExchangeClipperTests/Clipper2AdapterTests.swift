// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MediaExchangeCore
@testable import MediaExchangeClipper

final class Clipper2AdapterTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ size: Double, id: String = "square") -> BezierPath {
        BezierPath(id: id, nodes: [
            BezierNode(point: GeometryPoint(x: x, y: y)),
            BezierNode(point: GeometryPoint(x: x + size, y: y)),
            BezierNode(point: GeometryPoint(x: x + size, y: y + size)),
            BezierNode(point: GeometryPoint(x: x, y: y + size))
        ], isClosed: true)
    }

    private func adapter() throws -> ClipperGeometryAdapter {
        try ClipperGeometryAdapter(quantizationScale: 1024, flatteningTolerance: 0.01)
    }

    func testBooleanOperationsOnOverlappingSquares() throws {
        let adapter = try adapter()
        let a = square(0, 0, 10, id: "a")
        let b = square(5, 0, 10, id: "b")
        let union = try adapter.boolean(.union, subject: [a], clip: [b])
        XCTAssertEqual(union.polygons.reduce(0) { $0 + $1.area }, 150, accuracy: 0.02)
        let intersection = try adapter.boolean(.intersection, subject: [a], clip: [b])
        XCTAssertEqual(intersection.polygons.reduce(0) { $0 + $1.area }, 50, accuracy: 0.02)
        let difference = try adapter.boolean(.difference, subject: [a], clip: [b])
        XCTAssertEqual(difference.polygons.reduce(0) { $0 + $1.area }, 50, accuracy: 0.02)
        let xor = try adapter.boolean(.xor, subject: [a], clip: [b])
        XCTAssertEqual(xor.polygons.reduce(0) { $0 + $1.area }, 100, accuracy: 0.02)
        XCTAssertEqual(union.metadata.operation, "union")
        XCTAssertEqual(union.metadata.inputPathCount, 2)
        XCTAssertEqual(union.metadata.quantizationScale, 1024)
        XCTAssertTrue(union.metadata.clipperVersion.contains("b496b454df168a2280354857c1cd90bd6fa7b4dd"))
    }

    func testFillRuleHoleAndOffset() throws {
        let adapter = try adapter()
        let outer = square(0, 0, 20, id: "outer")
        let inner = square(5, 5, 10, id: "inner")
        let hole = try adapter.boolean(.union, subject: [outer, inner], clip: [], fillRule: .evenOdd)
        XCTAssertEqual(abs(hole.polygons.reduce(0) { $0 + $1.signedArea }), 300, accuracy: 0.03)
        let offset = try adapter.offset([square(0, 0, 10, id: "offset")], delta: 2)
        XCTAssertEqual(offset.polygons.reduce(0) { $0 + $1.area }, 196, accuracy: 0.05)
        XCTAssertEqual(offset.metadata.operation, "offset")
        XCTAssertEqual(offset.metadata.outputPathCount, offset.polygons.count)
    }

    func testTessellationToleranceIsExplicitAndDoesNotMutateSource() throws {
        let adapter = try adapter()
        let curve = BezierPath(id: "curve", nodes: [
            BezierNode(
                point: GeometryPoint(x: 0, y: 0),
                controlIn: nil,
                controlOut: GeometryPoint(x: 0, y: 10)
            ),
            BezierNode(
                point: GeometryPoint(x: 10, y: 10),
                controlIn: GeometryPoint(x: 10, y: 0),
                controlOut: nil
            )
        ], isClosed: false)
        let before = curve
        let fine = try curve.flattened(tolerance: 0.01)
        let coarse = try curve.flattened(tolerance: 2)
        XCTAssertGreaterThan(fine.count, coarse.count)
        XCTAssertTrue(fine.allSatisfy(\.isFinite))
        let result = try adapter.boolean(.union, subject: [curve], clip: [])
        XCTAssertEqual(curve, before, "boolean must not mutate editable Bezier source")
        XCTAssertTrue(result.polygons.allSatisfy { $0.flatteningTolerance == 0.01 })
        XCTAssertThrowsError(try ClipperGeometryAdapter(flatteningTolerance: 0))
        XCTAssertThrowsError(try curve.flattened(tolerance: 0))
    }

    func testInvalidInputsFailExplicitly() throws {
        let adapter = try adapter()
        let bad = BezierPath(id: "bad", nodes: [
            BezierNode(point: GeometryPoint(x: .nan, y: 0)),
            BezierNode(point: GeometryPoint(x: 1, y: 0))
        ])
        XCTAssertThrowsError(try adapter.boolean(.union, subject: [bad], clip: []))
        XCTAssertThrowsError(try adapter.offset([square(0, 0, 1)], delta: .nan))
        XCTAssertThrowsError(try adapter.offset([square(0, 0, 1)], delta: 1, miterLimit: 0.5))
    }
}

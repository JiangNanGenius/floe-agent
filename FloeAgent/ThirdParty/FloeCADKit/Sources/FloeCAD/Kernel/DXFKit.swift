//
//  DXFKit.swift
//  openshape3d
//
//  DXF R12 sketch interchange. Export writes plane-local 2D coordinates as
//  ASCII DXF (LINE/CIRCLE/ARC; rect/ellipse/polygon become POLYLINE, the
//  polyline form R12 defines). Import parses the R12/R2000-common subset —
//  LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE/VERTEX/SEQEND — with a group-code
//  state machine, ignoring unknown entities; polylines arrive as line
//  segments because SketchEntity has no polyline case. Angles: DXF uses
//  degrees CCW from +X, matching the sketch arc convention in radians.
//  Convention: 1 model unit = 1 mm = 1 drawing unit.
//

import Foundation
import simd

nonisolated enum DXFKit {

    // MARK: - Export

    /// R12 ASCII DXF of the sketch entities in plane-local coordinates.
    /// `plane` documents the source; DXF output is 2D so it does not affect
    /// the emitted coordinates.
    static func exportSketch(entities: [SketchEntity], plane: SketchPlane) -> String {
        var out = """
        999
        openshape3d DXF export (units: mm)
        0
        SECTION
        2
        HEADER
        9
        $ACADVER
        1
        AC1009
        9
        $INSUNITS
        70
        4
        9
        $MEASUREMENT
        70
        1
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES

        """
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                out += "0\nLINE\n8\n0\n"
                out += pair(10, 20, a) + code(30, 0) + pair(11, 21, b) + code(31, 0)
            case let .rect(_, min, max):
                appendPolyline(
                    [min, SIMD2(max.x, min.y), max, SIMD2(min.x, max.y)],
                    closed: true, to: &out
                )
            case let .circle(_, center, radius):
                out += "0\nCIRCLE\n8\n0\n"
                out += pair(10, 20, center) + code(30, 0) + code(40, radius)
            case let .arc(_, center, radius, startAngle, endAngle):
                out += "0\nARC\n8\n0\n"
                out += pair(10, 20, center) + code(30, 0) + code(40, radius)
                out += code(50, startAngle * 180 / .pi) + code(51, endAngle * 180 / .pi)
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                appendPolyline(
                    SketchEntity.ellipsePoints(
                        center: center, radiusX: radiusX, radiusY: radiusY,
                        rotation: rotation, segments: ellipseSegments
                    ),
                    closed: true, to: &out
                )
            case let .polygon(_, center, radius, sides, rotation):
                appendPolyline(
                    SketchEntity.polygonPoints(
                        center: center, radius: radius, sides: sides, rotation: rotation
                    ),
                    closed: true, to: &out
                )
            case let .spline(_, points, closed):
                // Exported as a tessellated POLYLINE rather than a DXF SPLINE:
                // it round-trips through every reader (the R12 subset we target
                // has no SPLINE entity) at the cost of exact curvature.
                appendPolyline(
                    SketchEntity.splinePoints(points, closed: closed),
                    closed: closed, to: &out
                )
            }
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }

    /// Tessellation density for ellipse export (closed POLYLINE vertex count).
    static let ellipseSegments = 64

    private static func appendPolyline(
        _ points: [SIMD2<Double>], closed: Bool, to out: inout String
    ) {
        guard points.count >= 2 else { return }
        out += "0\nPOLYLINE\n8\n0\n66\n1\n70\n\(closed ? 1 : 0)\n"
        for p in points {
            out += "0\nVERTEX\n8\n0\n" + pair(10, 20, p) + code(30, 0)
        }
        out += "0\nSEQEND\n8\n0\n"
    }

    private static func code(_ groupCode: Int, _ value: Double) -> String {
        "\(groupCode)\n\(format(value))\n"
    }

    private static func pair(_ xCode: Int, _ yCode: Int, _ p: SIMD2<Double>) -> String {
        code(xCode, p.x) + code(yCode, p.y)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.9f", value)
    }

    // MARK: - Import

    /// Parses LINE, CIRCLE, ARC, LWPOLYLINE and POLYLINE/VERTEX/SEQEND from
    /// R12/R2000-common ASCII DXF. Unknown entities and malformed input are
    /// skipped gracefully; garbage yields an empty array, never a crash.
    static func importDXF(_ data: Data) -> [SketchEntity] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Group-code / value pairs; a dangling last code is dropped.
        var pairs = [(code: Int, value: String)]()
        pairs.reserveCapacity(lines.count / 2)
        var i = 0
        while i + 1 < lines.count {
            guard let groupCode = Int(lines[i]) else { i += 1; continue }
            pairs.append((groupCode, lines[i + 1]))
            i += 2
        }

        var entities = [SketchEntity]()
        var inEntitiesSection = false
        var currentType: String?
        var values = [Int: Double]()          // last value per group code
        var vertices = [SIMD2<Double>]()      // LWPOLYLINE inline vertices
        var pendingX: Double?
        // POLYLINE state: vertices collected from VERTEX entities until SEQEND.
        var polylineClosed: Bool?
        var polylineVertices = [SIMD2<Double>]()

        func finishEntity() {
            defer {
                currentType = nil
                values = [:]
                vertices = []
                pendingX = nil
            }
            guard inEntitiesSection, let type = currentType else { return }
            switch type {
            case "LINE":
                guard let x1 = values[10], let y1 = values[20],
                      let x2 = values[11], let y2 = values[21] else { return }
                entities.append(.line(id: UUID(), a: SIMD2(x1, y1), b: SIMD2(x2, y2)))
            case "CIRCLE":
                guard let x = values[10], let y = values[20],
                      let r = values[40], r > 0 else { return }
                entities.append(.circle(id: UUID(), center: SIMD2(x, y), radius: r))
            case "ARC":
                guard let x = values[10], let y = values[20],
                      let r = values[40], r > 0,
                      let start = values[50], let end = values[51] else { return }
                entities.append(.arc(
                    id: UUID(), center: SIMD2(x, y), radius: r,
                    startAngle: start * .pi / 180, endAngle: end * .pi / 180
                ))
            case "LWPOLYLINE":
                let closed = (Int((values[70] ?? 0).clampedToInt) & 1) != 0
                entities.append(contentsOf: polylineSegments(vertices, closed: closed))
            case "VERTEX":
                if polylineClosed != nil, let x = values[10], let y = values[20] {
                    polylineVertices.append(SIMD2(x, y))
                }
            case "SEQEND":
                if let closed = polylineClosed {
                    entities.append(contentsOf: polylineSegments(polylineVertices, closed: closed))
                }
                polylineClosed = nil
                polylineVertices = []
            default:
                break  // unknown entity: ignore gracefully
            }
        }

        for (groupCode, value) in pairs {
            if groupCode == 0 {
                finishEntity()
                switch value {
                case "SECTION", "ENDSEC", "EOF":
                    currentType = nil
                    if value != "SECTION" { inEntitiesSection = false }
                case "POLYLINE":
                    currentType = "POLYLINE"
                    polylineClosed = false  // may be updated by its 70 flag
                    polylineVertices = []
                default:
                    currentType = value
                }
                continue
            }
            if groupCode == 2, currentType == nil {
                // Section name following a SECTION marker.
                inEntitiesSection = (value == "ENTITIES")
                continue
            }
            guard currentType != nil else { continue }
            // `Double("nan")`, `Double("inf")` and `Double("1e999")` all
            // SUCCEED. Those values then trap in `Int(_: Double)` just below,
            // and — if they reach the sketch — in the profile/offset welds.
            // A malformed DXF is user-reachable through the file picker, so
            // drop non-finite values here (2026-08-25 review round 3).
            guard let number = Double(value), number.isFinite else { continue }
            if currentType == "POLYLINE", groupCode == 70 {
                // Clamp before Int(): a huge finite value traps too.
                polylineClosed = (Int(number.clampedToInt) & 1) != 0
                continue
            }
            if currentType == "LWPOLYLINE" {
                // Vertex coordinates repeat; pair each 10 with the next 20.
                if groupCode == 10 {
                    pendingX = number
                    continue
                }
                if groupCode == 20 {
                    if let x = pendingX {
                        vertices.append(SIMD2(x, number))
                        pendingX = nil
                    }
                    continue
                }
            }
            values[groupCode] = number
        }
        finishEntity()
        return entities
    }

    /// Consecutive-point line segments (plus the closing segment when closed),
    /// skipping degenerate zero-length edges.
    private static func polylineSegments(
        _ points: [SIMD2<Double>], closed: Bool
    ) -> [SketchEntity] {
        guard points.count >= 2 else { return [] }
        var segments = [SketchEntity]()
        for i in 0..<(points.count - 1) {
            appendSegment(points[i], points[i + 1], to: &segments)
        }
        if closed {
            appendSegment(points[points.count - 1], points[0], to: &segments)
        }
        return segments
    }

    private static func appendSegment(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, to segments: inout [SketchEntity]
    ) {
        guard simd_length(b - a) > 1e-9 else { return }
        segments.append(.line(id: UUID(), a: a, b: b))
    }
}

import Foundation
import simd
import OCCTShim

/// Classification is exact B-rep HLR. Only non-circular output curves are
/// sampled at the advertised chord deflection; no render mesh is consulted.
nonisolated struct CADHiddenLineEdge {
    nonisolated enum Curve {
        case line(SIMD2<Double>, SIMD2<Double>)
        case circle(SIMD2<Double>, Double)
        case arc(SIMD2<Double>, Double, Double, Double)
        case polyline([SIMD2<Double>])
    }
    /// The retained cover's primary source. sourceEdges retains every source
    /// span, including shorter spans absorbed from other assembly instances.
    var sourceIndex: Int
    var sourceEdges: [CADHiddenLineSourceEdge]
    var hidden: Bool
    var outline: Bool
    var curve: Curve
}

nonisolated struct CADHiddenLineSourceEdge {
    var nativeEdgeIndex: Int
    var nativeCurveType: Int
    var sourceIndex: Int
    var curve: CADHiddenLineEdge.Curve
}

extension OCCTKernel {
    /// Handles must already carry world placements. All sources participate
    /// together so a nearer part can hide a different part's edges.
    static func hiddenLineProjection(_ handles: [BRepHandle],
                                     origin: SIMD3<Double> = .zero,
                                     normal: SIMD3<Double>, xAxis: SIMD3<Double>,
                                     deflection: Double = 0.005) -> [CADHiddenLineEdge]? {
        let frame = [origin.x, origin.y, origin.z, normal.x, normal.y, normal.z,
                     xAxis.x, xAxis.y, xAxis.z]
        let data = frame.withUnsafeBytes { Data($0) }
        guard let result = OCCTBridge.hiddenLineProjection(shapes: handles.map(\.shape),
                                                           frame: data, deflection: deflection),
              let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              object["version"] as? Int == 2,
              object["normalization"] as? String == "occt-curve-containment-v1",
              object["method"] as? String == "occt-brep-hlr",
              let rows = object["edges"] as? [[String: Any]], rows.count <= 50000,
              let raw = object["sourceEdges"] as? [[String: Any]], raw.count <= 50000 else { return nil }
        func point(_ value: Any?) -> SIMD2<Double>? {
            guard let p = value as? [Double], p.count == 2, p.allSatisfy(\.isFinite) else { return nil }
            return SIMD2(p[0], p[1])
        }
        func decodeCurve(_ row: [String: Any]) -> CADHiddenLineEdge.Curve? {
            let curve: CADHiddenLineEdge.Curve
            switch row["kind"] as? String {
            case "line", "polyline":
                guard let raw = row["points"] as? [Any], raw.count >= 2, raw.count <= 100000 else { return nil }
                let points = raw.compactMap(point)
                guard points.count == raw.count else { return nil }
                if row["kind"] as? String == "line" {
                    guard points.count == 2 else { return nil }
                    curve = .line(points[0], points[1])
                } else { curve = .polyline(points) }
            case "circle", "arc":
                guard let center = point(row["center"]), let radius = row["radius"] as? Double,
                      radius.isFinite, radius > 0 else { return nil }
                if row["kind"] as? String == "circle" { curve = .circle(center, radius) }
                else {
                    guard let a = row["angles"] as? [Double], a.count == 2,
                          a.allSatisfy(\.isFinite), a[1] > a[0] else { return nil }
                    curve = .arc(center, radius, a[0], a[1])
                }
            default: return nil
            }
            return curve
        }
        var sourceEdges: [CADHiddenLineSourceEdge] = []
        for (index, row) in raw.enumerated() {
            guard let source = row["sourceIndex"] as? Int, handles.indices.contains(source),
                  let type = row["nativeCurveType"] as? Int, (0...8).contains(type),
                  row["hidden"] is Bool, let edgeClass = row["edgeClass"] as? Int, (0...2).contains(edgeClass),
                  let role = row["role"] as? String,
                  ["edges", "outline"].contains(role), let curve = decodeCurve(row) else { return nil }
            sourceEdges.append(CADHiddenLineSourceEdge(nativeEdgeIndex: index, nativeCurveType: type,
                                                       sourceIndex: source, curve: curve))
        }
        var edges: [CADHiddenLineEdge] = []
        var consumed = Set<Int>()
        for row in rows {
            guard let source = row["sourceIndex"] as? Int, handles.indices.contains(source),
                  let hidden = row["hidden"] as? Bool, let role = row["role"] as? String,
                  ["edges", "outline"].contains(role), let curve = decodeCurve(row),
                  let indices = row["sourceEdgeIndices"] as? [Int], !indices.isEmpty else { return nil }
            var contributions: [CADHiddenLineSourceEdge] = []
            for index in indices {
                guard sourceEdges.indices.contains(index), consumed.insert(index).inserted,
                      raw[index]["hidden"] as? Bool == hidden,
                      raw[index]["role"] as? String == role,
                      raw[index]["edgeClass"] as? Int == row["edgeClass"] as? Int else { return nil }
                contributions.append(sourceEdges[index])
            }
            guard contributions.contains(where: { $0.sourceIndex == source }) else { return nil }
            edges.append(CADHiddenLineEdge(sourceIndex: source, sourceEdges: contributions,
                                           hidden: hidden, outline: role == "outline", curve: curve))
        }
        // Every raw native HLR edge must appear in exactly one retained
        // cover's ownership ledger. Missing/doubled provenance fails closed.
        guard consumed.count == raw.count else { return nil }
        if handles.contains(where: \.containsSolid), edges.isEmpty { return nil }
        return edges
    }
}

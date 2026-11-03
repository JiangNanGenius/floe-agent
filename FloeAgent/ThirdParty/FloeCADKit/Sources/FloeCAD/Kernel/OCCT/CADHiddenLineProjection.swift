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
    var sourceIndex: Int
    var hidden: Bool
    var outline: Bool
    var curve: Curve
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
              object["version"] as? Int == 1,
              object["method"] as? String == "occt-brep-hlr",
              let rows = object["edges"] as? [[String: Any]], rows.count <= 50000 else { return nil }
        func point(_ value: Any?) -> SIMD2<Double>? {
            guard let p = value as? [Double], p.count == 2, p.allSatisfy(\.isFinite) else { return nil }
            return SIMD2(p[0], p[1])
        }
        var edges: [CADHiddenLineEdge] = []
        for row in rows {
            guard let source = row["sourceIndex"] as? Int, handles.indices.contains(source),
                  let hidden = row["hidden"] as? Bool else { return nil }
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
            edges.append(CADHiddenLineEdge(sourceIndex: source, hidden: hidden,
                                           outline: row["role"] as? String == "outline", curve: curve))
        }
        if handles.contains(where: \.containsSolid), edges.isEmpty { return nil }
        return edges
    }
}

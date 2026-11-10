// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Preserves the declared radius; polygon consumers use a bounded 1um
/// boundary error. DRC uses the outward envelope, never an inward clearance
/// approximation. Historical radius-less pads remain explicitly unsupported.
public enum EDARoundedPadGeometry {
    public static let boundaryErrorMillimetres = 0.001
    public static func validate(_ pad: EDAPad) throws {
        guard let radius = pad.roundRectangleRadius else { return }
        guard pad.shape == .roundRectangle, radius.isFinite, radius > 0,
              radius <= min(pad.size.x, pad.size.y) / 2 else { throw EDAError.invalid("rounded pad radius") }
        _ = try vertices(pad)
    }
    public static func vertices(_ pad: EDAPad, in footprint: EDAFootprint? = nil, containing: Bool = false) throws -> [EDAPoint] {
        guard pad.shape == .roundRectangle, let radius = pad.roundRectangleRadius,
              radius.isFinite, radius > 0, radius <= min(pad.size.x, pad.size.y) / 2 else {
            throw EDAError.unsupported("round rectangle pad radius missing or invalid")
        }
        let error = boundaryErrorMillimetres
        let step = 2 * acos(radius / (radius + error))
        let needed = max(2, Int(ceil((Double.pi / 2) / step)))
        guard needed <= 60 else { throw EDAError.unsupported("rounded pad precision budget") }
        let angleStep = (Double.pi / 2) / Double(needed)
        var local: [EDAPoint] = []
        func append(_ p: EDAPoint) { if local.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { local.append(p) } }
        for corner in 0..<4 {
            let center = EDAPoint((corner == 0 || corner == 3 ? 1 : -1) * (pad.size.x / 2 - radius),
                                  (corner < 2 ? 1 : -1) * (pad.size.y / 2 - radius))
            let start = Double(corner) * .pi / 2
            if containing {
                append(center + .init(radius * cos(start), radius * sin(start)))
                for i in 0..<needed {
                    let angle = start + (Double(i) + 0.5) * angleStep, outer = radius / cos(angleStep / 2)
                    append(center + .init(outer * cos(angle), outer * sin(angle)))
                }
                append(center + .init(radius * cos(start + .pi / 2), radius * sin(start + .pi / 2)))
            } else {
                for i in 0...needed {
                    let angle = start + Double(i) * angleStep
                    append(center + .init(radius * cos(angle), radius * sin(angle)))
                }
            }
        }
        if let first = local.first, let last = local.last, first.distance(to: last) < 1e-9 { local.removeLast() }
        return local.map {
            let p = $0.transformed(origin: pad.position, angle: pad.angle)
            return footprint?.point(p) ?? p
        }
    }
}

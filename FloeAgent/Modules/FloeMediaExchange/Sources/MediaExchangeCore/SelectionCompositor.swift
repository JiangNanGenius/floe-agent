// SPDX-License-Identifier: MPL-2.0
//
// Strict local selection compositor.
//
// The model may return a full-frame image, but only pixels covered by the
// user's selection may change. Every pixel whose selection coverage is zero
// is copied byte-for-byte from the base image. No full-frame rollback is used.

import Foundation

public enum SelectionMask: Sendable {
    /// Hard rectangular selection. The rectangle must be inside the canvas.
    case rectangle(PixelRect)
    /// Elliptical selection inscribed in `bounds`, with a 4x4 supersampled edge.
    case ellipse(PixelRect)
    /// Per-pixel coverage (0 = untouched, 255 = fully selected), row-major.
    case coverage(width: Int, height: Int, values: [UInt8])
}

public struct SelectionCompositeResult: Sendable {
    public let image: RGBAImage
    /// Pixels whose RGBA bytes differ from the base.
    public let changedPixels: Int
    /// Pixels with zero selection coverage (their bytes must equal the base).
    public let outsidePixels: Int
    /// Pixels with nonzero selection coverage.
    public let selectedPixels: Int
}

public enum SelectionCompositeError: Error, Equatable, CustomStringConvertible {
    case patchDimensionsMismatch(base: String, patch: String)
    case maskDimensionsMismatch(expected: String, actual: String)
    case rectangleOutsideCanvas(PixelRect, width: Int, height: Int)
    case invalidCoverageCount(expected: Int, actual: Int)
    case invalidOpacity(Double)
    case outsideSelectionChanged(count: Int)

    public var description: String {
        switch self {
        case let .patchDimensionsMismatch(base, patch):
            return "full-frame patch dimensions \(patch) do not match base \(base)"
        case let .maskDimensionsMismatch(expected, actual):
            return "selection mask dimensions \(actual) do not match base \(expected)"
        case let .rectangleOutsideCanvas(rect, width, height):
            return "selection rectangle \(rect) is outside \(width)x\(height) canvas"
        case let .invalidCoverageCount(expected, actual):
            return "selection coverage count \(actual) does not match \(expected)"
        case let .invalidOpacity(value):
            return "selection opacity \(value) is outside 0...1"
        case let .outsideSelectionChanged(count):
            return "\(count) pixels outside the selection changed"
        }
    }
}

public enum StrictSelectionCompositor {
    /// Composites a full-frame patch over `base` using `mask` and `opacity`.
    ///
    /// - Pixels with coverage 0 are copied from `base` without any arithmetic.
    /// - Pixels with coverage 255 and patch alpha 255 are replaced with the
    ///   patch bytes exactly.
    /// - Partial coverage or partial patch alpha uses straight-alpha source-over
    ///   inside the selection.
    public static func composite(
        base: RGBAImage,
        patch: RGBAImage,
        mask: SelectionMask,
        opacity: Double = 1
    ) throws -> SelectionCompositeResult {
        guard opacity >= 0, opacity <= 1 else {
            throw SelectionCompositeError.invalidOpacity(opacity)
        }
        guard base.width == patch.width, base.height == patch.height else {
            throw SelectionCompositeError.patchDimensionsMismatch(
                base: "\(base.width)x\(base.height)",
                patch: "\(patch.width)x\(patch.height)"
            )
        }
        let coverage = try resolvedCoverage(mask, width: base.width, height: base.height)
        var out = base.pixels
        var changed = 0
        var outside = 0
        var selected = 0
        let opacity13 = UInt32((opacity * 10_000).rounded())

        for i in stride(from: 0, to: out.count, by: 4) {
            let c = UInt32(coverage[i / 4])
            if c == 0 {
                outside += 1
                continue
            }
            selected += 1
            let patchAlpha = UInt32(patch.pixels[i + 3])
            // effective alpha = patchAlpha * coverage * opacity, all /255 then /255
            let effective = (patchAlpha * c * opacity13 + 1_275_000) / 2_550_000
            if effective == 0 {
                continue
            }
            let oldR = out[i], oldG = out[i + 1], oldB = out[i + 2], oldA = out[i + 3]
            let newR: UInt8
            let newG: UInt8
            let newB: UInt8
            let newA: UInt8
            if effective >= 255 && patchAlpha == 255 {
                newR = patch.pixels[i]
                newG = patch.pixels[i + 1]
                newB = patch.pixels[i + 2]
                newA = 255
            } else {
                let sa = Double(effective) / 255
                let da = Double(oldA) / 255
                let oa = sa + da * (1 - sa)
                if oa <= 0 {
                    newR = 0; newG = 0; newB = 0; newA = 0
                } else {
                    newA = UInt8(clamping: Int((oa * 255).rounded()))
                    newR = UInt8(clamping: Int(((Double(patch.pixels[i]) * sa + Double(oldR) * da * (1 - sa)) / oa).rounded()))
                    newG = UInt8(clamping: Int(((Double(patch.pixels[i + 1]) * sa + Double(oldG) * da * (1 - sa)) / oa).rounded()))
                    newB = UInt8(clamping: Int(((Double(patch.pixels[i + 2]) * sa + Double(oldB) * da * (1 - sa)) / oa).rounded()))
                }
            }
            if newR != oldR || newG != oldG || newB != oldB || newA != oldA {
                changed += 1
            }
            out[i] = newR
            out[i + 1] = newG
            out[i + 2] = newB
            out[i + 3] = newA
        }

        let image = try RGBAImage(width: base.width, height: base.height, pixels: out)
        try verifyOutsideUnchanged(result: image, base: base, mask: mask)
        return SelectionCompositeResult(
            image: image,
            changedPixels: changed,
            outsidePixels: outside,
            selectedPixels: selected
        )
    }

    /// Independent check used by tests and callers: throws if any pixel with
    /// zero selection coverage differs from the original base.
    public static func verifyOutsideUnchanged(
        result: RGBAImage,
        base: RGBAImage,
        mask: SelectionMask
    ) throws {
        guard result.width == base.width, result.height == base.height else {
            throw SelectionCompositeError.maskDimensionsMismatch(
                expected: "\(base.width)x\(base.height)",
                actual: "\(result.width)x\(result.height)"
            )
        }
        let coverage = try resolvedCoverage(mask, width: base.width, height: base.height)
        var changedOutside = 0
        for i in stride(from: 0, to: result.pixels.count, by: 4) {
            guard coverage[i / 4] == 0 else { continue }
            if result.pixels[i] != base.pixels[i]
                || result.pixels[i + 1] != base.pixels[i + 1]
                || result.pixels[i + 2] != base.pixels[i + 2]
                || result.pixels[i + 3] != base.pixels[i + 3] {
                changedOutside += 1
            }
        }
        guard changedOutside == 0 else {
            throw SelectionCompositeError.outsideSelectionChanged(count: changedOutside)
        }
    }

    /// Converts a mask into a flat coverage buffer, validating its bounds.
    public static func resolvedCoverage(_ mask: SelectionMask, width: Int, height: Int) throws -> [UInt8] {
        switch mask {
        case let .rectangle(rect):
            guard rect.isWithin(width: width, height: height) else {
                throw SelectionCompositeError.rectangleOutsideCanvas(rect, width: width, height: height)
            }
            var values = [UInt8](repeating: 0, count: width * height)
            for y in rect.y..<rect.maxY {
                for x in rect.x..<rect.maxX {
                    values[y * width + x] = 255
                }
            }
            return values
        case let .ellipse(rect):
            guard rect.isWithin(width: width, height: height) else {
                throw SelectionCompositeError.rectangleOutsideCanvas(rect, width: width, height: height)
            }
            var values = [UInt8](repeating: 0, count: width * height)
            let rx = Double(rect.width) / 2
            let ry = Double(rect.height) / 2
            // 4x4 supersampling gives a deterministic soft edge while the
            // bounding rectangle is the only possible changed area.
            let samples: [(Double, Double)] = (0..<4).flatMap { sy in
                (0..<4).map { sx in
                    ((Double(sx) + 0.5) / 4, (Double(sy) + 0.5) / 4)
                }
            }
            for y in rect.y..<rect.maxY {
                for x in rect.x..<rect.maxX {
                    var inside = 0
                    for (ox, oy) in samples {
                        let dx = (Double(x) - Double(rect.x) + ox - rx) / rx
                        let dy = (Double(y) - Double(rect.y) + oy - ry) / ry
                        if dx * dx + dy * dy <= 1 { inside += 1 }
                    }
                    values[y * width + x] = UInt8((inside * 255 + 8) / 16)
                }
            }
            return values
        case let .coverage(maskWidth, maskHeight, values):
            guard maskWidth == width, maskHeight == height else {
                throw SelectionCompositeError.maskDimensionsMismatch(
                    expected: "\(width)x\(height)",
                    actual: "\(maskWidth)x\(maskHeight)"
                )
            }
            guard values.count == width * height else {
                throw SelectionCompositeError.invalidCoverageCount(expected: width * height, actual: values.count)
            }
            return values
        }
    }
}

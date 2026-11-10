// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import CryptoKit

public enum MediaImageWarpError: Error, Sendable, Equatable {
    case invalidGeometry
    case emptyVisiblePixels
    case resourceLimit
    case cancelled
    case renderFailed
}
public struct MediaImageWarpPoint: Codable, Sendable, Hashable {
    /// Logical canvas coordinates, top-leading; 1 is one canvas dimension.
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct MediaImageWarpQuad: Codable, Sendable, Hashable {
    public var topLeft: MediaImageWarpPoint
    public var topRight: MediaImageWarpPoint
    public var bottomRight: MediaImageWarpPoint
    public var bottomLeft: MediaImageWarpPoint
    public init(topLeft: MediaImageWarpPoint, topRight: MediaImageWarpPoint, bottomRight: MediaImageWarpPoint, bottomLeft: MediaImageWarpPoint) {
        self.topLeft = topLeft; self.topRight = topRight; self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
    }
    public init(points: [MediaImageWarpPoint]) throws {
        guard points.count == 4 else { throw MediaImageWarpError.invalidGeometry }
        self.init(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
    }
    public var points: [MediaImageWarpPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
    public func validate() throws {
        let p = points
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 4 && abs($0.y) <= 4 }) else { throw MediaImageWarpError.invalidGeometry }
        let crosses = (0..<4).map { index -> Double in
            let a = p[index], b = p[(index + 1) % 4], c = p[(index + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        // Mirrored but convex mappings are valid. Folded/degenerate quads are
        // rejected instead of silently rendering holes or a different shape.
        guard crosses.allSatisfy({ $0 > 1e-10 }) || crosses.allSatisfy({ $0 < -1e-10 }) else { throw MediaImageWarpError.invalidGeometry }
    }
}
public struct MediaImageWarpPixelBounds: Codable, Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}
public struct MediaImageWarpGeometry: Codable, Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// Tight visible alpha intersected with the actual selection coverage.
    public let contentBounds: MediaImageWarpPixelBounds
    public let sourceQuad: MediaImageWarpQuad
    public let pixelSHA256: String
    public let coverageSHA256: String?
}
public enum MediaImageWarpMode: String, Codable, Sendable { case perspective, bilinear }
public struct MediaImageWarpWork: Sendable {
    public var isCancelled: @Sendable () -> Bool
    public init(isCancelled: @escaping @Sendable () -> Bool = { false }) { self.isCancelled = isCancelled }
    public func check() throws { if isCancelled() || Task.isCancelled { throw MediaImageWarpError.cancelled } }
}
public struct MediaImageWarpResult: Sendable {
    public let image: CGImage
    /// A moved coverage mask, not a crop applied back at the old coordinates.
    /// The App may adapt it to its existing bounded selection bitmap format.
    public let transformedCoverage: CGImage?
    public let source: MediaImageWarpGeometry
    public let destination: MediaImageWarpQuad
    public let mode: MediaImageWarpMode
}

/// Native raster processing over an already resolved layer. This adds no
/// project model, storage or execution authority. RGBA8 sRGB premultiplied
/// pixels are retained throughout interpolation; the original is never saved.
public enum MediaNativeImageWarp {
    public static let maximumPixels = 16_777_216
    public static let maximumEdge = 8_192
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    public static func geometry(_ image: CGImage, coverage: CGImage? = nil, work: MediaImageWarpWork = .init()) throws -> MediaImageWarpGeometry {
        let raster = try decode(image, coverage: coverage, work: work)
        return try geometry(raster, work: work)
    }
    public static func apply(_ image: CGImage, mode: MediaImageWarpMode, destination: MediaImageWarpQuad,
        coverage: CGImage? = nil, work: MediaImageWarpWork = .init()) throws -> MediaImageWarpResult {
        try work.check(); try destination.validate()
        let raster = try decode(image, coverage: coverage, work: work), source = try geometry(raster, work: work)
        if destination == source.sourceQuad {
            return .init(image: image, transformedCoverage: coverage, source: source, destination: destination, mode: mode)
        }
        let output: CGImage, movedMask: CGImage?
        switch mode {
        case .perspective: (output, movedMask) = try perspective(image: image, raster: raster, source: source, destination: destination, coverage: coverage, work: work)
        case .bilinear: (output, movedMask) = try bilinear(raster: raster, source: source, destination: destination, work: work)
        }
        try work.check()
        return .init(image: output, transformedCoverage: movedMask, source: source, destination: destination, mode: mode)
    }

    /// Same geometry for on-canvas preview grid/handles and AI observations.
    public static func mapUnitPoint(_ point: MediaImageWarpPoint, to quad: MediaImageWarpQuad, mode: MediaImageWarpMode) throws -> MediaImageWarpPoint {
        try quad.validate()
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { throw MediaImageWarpError.invalidGeometry }
        return try mapped(point.x, point.y, quad: quad, mode: mode)
    }
    private static func mapped(_ u: Double, _ v: Double, quad: MediaImageWarpQuad, mode: MediaImageWarpMode) throws -> MediaImageWarpPoint {
        let p = quad.points
        if mode == .bilinear {
            return .init(x: (1-u)*(1-v)*p[0].x + u*(1-v)*p[1].x + u*v*p[2].x + (1-u)*v*p[3].x,
                y: (1-u)*(1-v)*p[0].y + u*(1-v)*p[1].y + u*v*p[2].y + (1-u)*v*p[3].y)
        }
        let dx1 = p[1].x-p[2].x, dx2 = p[3].x-p[2].x, dx3 = p[0].x-p[1].x+p[2].x-p[3].x
        let dy1 = p[1].y-p[2].y, dy2 = p[3].y-p[2].y, dy3 = p[0].y-p[1].y+p[2].y-p[3].y
        var g = 0.0, h = 0.0
        if abs(dx3) + abs(dy3) > 1e-12 {
            let determinant = dx1*dy2-dx2*dy1
            guard abs(determinant) > 1e-12 else { throw MediaImageWarpError.invalidGeometry }
            g = (dx3*dy2-dx2*dy3)/determinant; h = (dx1*dy3-dx3*dy1)/determinant
        }
        let denominator = g*u+h*v+1
        guard abs(denominator) > 1e-12 else { throw MediaImageWarpError.invalidGeometry }
        return .init(x: ((p[1].x-p[0].x+g*p[1].x)*u+(p[3].x-p[0].x+h*p[3].x)*v+p[0].x)/denominator,
            y: ((p[1].y-p[0].y+g*p[1].y)*u+(p[3].y-p[0].y+h*p[3].y)*v+p[0].y)/denominator)
    }
    private struct Raster {
        let width: Int, height: Int
        let pixels: [UInt8]
        let coverage: [UInt8]?
    }
    private static func decode(_ image: CGImage, coverage: CGImage?, work: MediaImageWarpWork) throws -> Raster {
        try work.check()
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maximumEdge, h <= maximumEdge, w <= maximumPixels / h else { throw MediaImageWarpError.resourceLimit }
        let pixels = try rgba(image)
        var alpha: [UInt8]?
        if let coverage {
            guard coverage.width == w, coverage.height == h,
                  ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(coverage.alphaInfo) else { throw MediaImageWarpError.invalidGeometry }
            let mask = try rgba(coverage)
            alpha = stride(from: 3, to: mask.count, by: 4).map { mask[$0] }
        }
        try work.check(); return .init(width: w, height: h, pixels: pixels, coverage: alpha)
    }
    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width*4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard success else { throw MediaImageWarpError.renderFailed }; return bytes
    }
    private static func geometry(_ raster: Raster, work: MediaImageWarpWork) throws -> MediaImageWarpGeometry {
        let w = raster.width, h = raster.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            if y % 32 == 0 { try work.check() }
            for x in 0..<w {
                let i = y*w+x, value = Int(raster.pixels[i*4+3]) * Int(raster.coverage?[i] ?? 255)
                if (value+127)/255 > 0 { minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw MediaImageWarpError.emptyVisiblePixels }
        let bounds = MediaImageWarpPixelBounds(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)
        let quad = MediaImageWarpQuad(topLeft: .init(x: Double(minX)/Double(w), y: Double(minY)/Double(h)),
            topRight: .init(x: Double(maxX+1)/Double(w), y: Double(minY)/Double(h)),
            bottomRight: .init(x: Double(maxX+1)/Double(w), y: Double(maxY+1)/Double(h)),
            bottomLeft: .init(x: Double(minX)/Double(w), y: Double(maxY+1)/Double(h)))
        return .init(width: w, height: h, contentBounds: bounds, sourceQuad: quad, pixelSHA256: digest(raster.pixels), coverageSHA256: raster.coverage.map(digest))
    }
    private static func digest(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    private static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: colorSpace, bitmapInfo: .init(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw MediaImageWarpError.renderFailed }
        return image
    }
    private static func maskImage(_ alpha: [UInt8], width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: alpha.count*4)
        for i in alpha.indices { for c in 0..<4 { bytes[i*4+c] = alpha[i] } }
        return try image(bytes, width: width, height: height)
    }
    private static func perspective(image original: CGImage, raster: Raster, source: MediaImageWarpGeometry,
        destination: MediaImageWarpQuad, coverage: CGImage?, work: MediaImageWarpWork) throws -> (CGImage, CGImage?) {
        let w = raster.width, h = raster.height, extent = CGRect(x: 0, y: 0, width: w, height: h)
        let original = CIImage(cgImage: original), clear = CIImage(color: .clear).cropped(to: extent)
        let selected: CIImage, remainder: CIImage
        if let coverage {
            let mask = CIImage(cgImage: coverage, options: [.colorSpace: NSNull()])
            selected = original.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
            remainder = clear.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: original, kCIInputMaskImageKey: mask])
        } else { selected = original; remainder = clear }
        let bounds = source.contentBounds
        let sourceRect = CGRect(x: bounds.x, y: h-bounds.y-bounds.height, width: bounds.width, height: bounds.height)
        func warp(_ input: CIImage) throws -> CIImage {
            func vector(_ point: MediaImageWarpPoint) -> CIVector { .init(x: point.x*Double(w), y: (1-point.y)*Double(h)) }
            guard let filter = CIFilter(name: "CIPerspectiveTransform", parameters: [kCIInputImageKey: input.cropped(to: sourceRect),
                "inputTopLeft": vector(destination.topLeft), "inputTopRight": vector(destination.topRight),
                "inputBottomRight": vector(destination.bottomRight), "inputBottomLeft": vector(destination.bottomLeft)]), let output = filter.outputImage else { throw MediaImageWarpError.renderFailed }
            return output.cropped(to: extent)
        }
        let transformed = try warp(selected).composited(over: remainder)
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        try work.check()
        guard let result = context.createCGImage(transformed, from: extent, format: .RGBA8, colorSpace: colorSpace) else { throw MediaImageWarpError.renderFailed }
        var moved: CGImage?
        if let coverage {
            guard let transformedMask = try context.createCGImage(warp(CIImage(cgImage: coverage, options: [.colorSpace: NSNull()])), from: extent, format: .RGBA8, colorSpace: colorSpace) else {
                throw MediaImageWarpError.renderFailed
            }
            moved = transformedMask
        }
        try work.check(); return (result, moved)
    }
    private struct BilinearMap {
        let x0: Double, y0: Double, bx: Double, by: Double, cx: Double, cy: Double, dx: Double, dy: Double, determinant: Double
        init(_ quad: MediaImageWarpQuad) {
            let p = quad.points
            x0 = p[0].x; y0 = p[0].y
            bx = p[1].x-p[0].x; by = p[1].y-p[0].y; cx = p[3].x-p[0].x; cy = p[3].y-p[0].y
            dx = p[0].x-p[1].x+p[2].x-p[3].x; dy = p[0].y-p[1].y+p[2].y-p[3].y
            determinant = bx*cy-by*cx
        }
        func inverse(x: Double, y: Double) -> (Double, Double)? {
            guard abs(determinant) > 1e-12 else { return nil }
            var u = ((x-x0)*cy-(y-y0)*cx)/determinant, v = (bx*(y-y0)-by*(x-x0))/determinant
            for _ in 0..<10 {
                let ex = x0+bx*u+cx*v+dx*u*v-x, ey = y0+by*u+cy*v+dy*u*v-y
                if abs(ex)+abs(ey) < 1e-9 { return (u,v) }
                let ax = bx+dx*v, ay = by+dy*v, sx = cx+dx*u, sy = cy+dy*u, det = ax*sy-ay*sx
                guard abs(det) > 1e-12 else { return nil }
                u -= (ex*sy-ey*sx)/det; v -= (ax*ey-ay*ex)/det
                guard u.isFinite, v.isFinite, abs(u)<100, abs(v)<100 else { return nil }
            }
            return nil
        }
    }
    private static func bilinear(raster: Raster, source: MediaImageWarpGeometry, destination: MediaImageWarpQuad, work: MediaImageWarpWork) throws -> (CGImage, CGImage?) {
        let w = raster.width, h = raster.height, bounds = source.contentBounds, mask = raster.coverage
        var output = [UInt8](repeating: 0, count: raster.pixels.count), moved = mask.map { _ in [UInt8](repeating: 0, count: w*h) }
        if let mask {
            for i in mask.indices { for c in 0..<4 { output[i*4+c] = UInt8((Int(raster.pixels[i*4+c])*(255-Int(mask[i]))+127)/255) } }
        }
        let p = destination.points, inverse = BilinearMap(destination)
        let minX = max(0,Int(floor(p.map(\.x).min()!*Double(w)))-2), maxX = min(w-1,Int(ceil(p.map(\.x).max()!*Double(w)))+2)
        let minY = max(0,Int(floor(p.map(\.y).min()!*Double(h)))-2), maxY = min(h-1,Int(ceil(p.map(\.y).max()!*Double(h)))+2)
        if minX <= maxX, minY <= maxY {
            for y in minY...maxY {
                if y % 8 == 0 { try work.check() }
                for x in minX...maxX {
                    guard let (u,v) = inverse.inverse(x: (Double(x)+0.5)/Double(w), y: (Double(y)+0.5)/Double(h)),
                          u >= -1/Double(bounds.width), u <= 1+1/Double(bounds.width), v >= -1/Double(bounds.height), v <= 1+1/Double(bounds.height) else { continue }
                    let sx = Double(bounds.x)+u*Double(bounds.width)-0.5, sy = Double(bounds.y)+v*Double(bounds.height)-0.5
                    let x0 = Int(floor(sx)), y0 = Int(floor(sy)), fx = sx-Double(x0), fy = sy-Double(y0)
                    var red = 0.0, green = 0.0, blue = 0.0, alphaValue = 0.0, coverage = 0.0
                    for j in 0...1 { for i in 0...1 {
                        let px = x0+i, py = y0+j
                        guard px >= bounds.x, px < bounds.x+bounds.width, py >= bounds.y, py < bounds.y+bounds.height else { continue }
                        let index = py*w+px, weight = (i == 0 ? 1-fx : fx)*(j == 0 ? 1-fy : fy), alpha = Double(mask?[index] ?? 255)/255
                        let contribution = alpha*weight, i4 = index*4
                        red += Double(raster.pixels[i4])*contribution; green += Double(raster.pixels[i4+1])*contribution
                        blue += Double(raster.pixels[i4+2])*contribution; alphaValue += Double(raster.pixels[i4+3])*contribution
                        coverage += Double(mask?[index] ?? 255)*weight
                    } }
                    let index = y*w+x, foregroundAlpha = max(0,min(1,alphaValue/255)), i4 = index*4
                    func over(_ value: Double, _ channel: Int) -> UInt8 { UInt8(max(0,min(255,(value+Double(output[i4+channel])*(1-foregroundAlpha)).rounded()))) }
                    output[i4] = over(red,0); output[i4+1] = over(green,1); output[i4+2] = over(blue,2); output[i4+3] = over(alphaValue,3)
                    if moved != nil { moved![index] = UInt8(max(0,min(255,coverage.rounded()))) }
                }
            }
        }
        try work.check()
        return (try image(output, width: w, height: h), try moved.map { try maskImage($0, width: w, height: h) })
    }
}

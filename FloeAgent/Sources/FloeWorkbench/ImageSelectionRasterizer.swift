// FloeWorkbench — vector selection rasterization.
//
// Selections are stored as normalized vector shapes (rectangle / ellipse /
// lasso) with add/subtract/replace operations and a normalized feather, so the
// same selection renders identically at preview and export resolution and
// follows the canvas when it is scaled. The rasterizer only produces an alpha
// mask; it never touches source pixels.

import Foundation
import FloeCore
#if canImport(CoreImage)
import CoreImage
import CoreGraphics

public enum ImageSelectionRasterizer {
    /// Alpha mask where selected pixels are opaque white. Returns nil for an
    /// empty, non-inverted selection (caller keeps the layer untouched).
    public static func maskImage(for selection: ImageSelection, canvas: CGSize) -> CIImage? {
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        if selection.shapes.isEmpty {
            guard selection.inverted else { return nil }
            return fullMask(canvas: canvas, inverted: selection.inverted)
        }
        guard let union = unionImage(selection.shapes, canvas: canvas) else { return nil }
        var mask = selection.inverted ? invert(union, canvas: canvas) : union
        if selection.feather > 0.0001 {
            let radius = CGFloat(max(0, min(selection.feather, 0.5))) * min(canvas.width, canvas.height)
            if radius >= 0.5 {
                let blur = CIFilter(name: "CIGaussianBlur")!
                blur.setValue(mask, forKey: kCIInputImageKey)
                blur.setValue(radius, forKey: kCIInputRadiusKey)
                mask = (blur.outputImage ?? mask).cropped(to: CGRect(origin: .zero, size: canvas))
            }
        }
        return mask
    }

    static func path(for shape: ImageSelectionShape, canvas: CGSize) -> CGPath? {
        let points = shape.points.map { CGPoint(x: $0.x * canvas.width, y: (1 - $0.y) * canvas.height) }
        switch shape.kind {
        case .rectangle:
            guard points.count >= 2 else { return nil }
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard rect.width >= 0.5, rect.height >= 0.5 else { return nil }
            return CGPath(rect: rect, transform: nil)
        case .ellipse:
            guard points.count >= 2 else { return nil }
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard rect.width >= 0.5, rect.height >= 0.5 else { return nil }
            return CGPath(ellipseIn: rect, transform: nil)
        case .lasso:
            guard points.count >= 3 else { return nil }
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            return path
        }
    }

    private static func unionImage(_ shapes: [ImageSelectionShape], canvas: CGSize) -> CIImage? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        for shape in shapes {
            guard let path = path(for: shape, canvas: canvas) else { continue }
            switch shape.operation {
            case .replace:
                context.clear(full)
                context.setBlendMode(.normal)
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.addPath(path)
                context.fillPath()
            case .add:
                context.setBlendMode(.normal)
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.addPath(path)
                context.fillPath()
            case .subtract:
                context.setBlendMode(.clear)
                context.addPath(path)
                context.fillPath()
            }
        }
        context.setBlendMode(.normal)
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }

    private static func invert(_ image: CIImage, canvas: CGSize) -> CIImage {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = CIContext().createCGImage(image, from: CGRect(origin: .zero, size: canvas)) else {
            return image
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(full)
        context.setBlendMode(.destinationOut)
        context.draw(cg, in: full)
        context.setBlendMode(.normal)
        guard let inverted = context.makeImage() else { return image }
        return CIImage(cgImage: inverted)
    }

    private static func fullMask(canvas: CGSize, inverted: Bool) -> CIImage {
        // An empty non-inverted selection means "everything"; the caller only
        // reaches here when inverted, which is an empty selection.
        return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }
}
#endif

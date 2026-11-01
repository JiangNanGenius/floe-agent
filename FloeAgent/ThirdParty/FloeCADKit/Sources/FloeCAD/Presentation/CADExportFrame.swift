//
//  CADExportFrame.swift
//  FloeCADKit
//
//  X21 — deterministic export framing for a saved camera.
//
//  The saved frame aspect is a real output property: a still exported from a
//  4:3 shot is 4:3, not the device viewport's aspect. The live render is
//  CONTAINED (never cropped, never stretched) in that canvas, so the camera
//  composition the user saved is preserved even when the export canvas and the
//  viewport differ. This mirrors the MP4 pixel composer's fit-and-centre rule.
//
//  The size and fit math are pure and unit-tested; only `composited` touches
//  UIKit.
//

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum CADExportFrame {
    static let minimumDimension = 64
    static let maximumDimension = 4096

    /// Pixel size of a frame with `aspect` whose width starts at `targetWidth`.
    /// A portrait/very wide frame is bounded by `maximumDimension` on both
    /// edges; the aspect is preserved (rounded to whole pixels).
    static func pixelSize(forAspect aspect: Double,
                          targetWidth: Int,
                          maximumDimension: Int = 4096) -> (width: Int, height: Int)? {
        guard aspect.isFinite, aspect > 0,
              targetWidth >= minimumDimension,
              maximumDimension >= minimumDimension else { return nil }
        var width = min(targetWidth, maximumDimension)
        var height = Int((Double(width) / aspect).rounded())
        if height > maximumDimension {
            height = maximumDimension
            width = Int((Double(height) * aspect).rounded())
        }
        if height < minimumDimension {
            height = minimumDimension
            width = Int((Double(height) * aspect).rounded())
        }
        width = min(max(width, minimumDimension), maximumDimension)
        height = min(max(height, minimumDimension), maximumDimension)
        return (width, height)
    }

    /// Contain `content` in `canvas` and centre it. Never crops or stretches.
    static func fittedRect(content: CGSize, canvas: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / content.width,
                        canvas.height / content.height)
        let size = CGSize(width: content.width * scale,
                          height: content.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2,
                      y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    #if canImport(UIKit)
    /// Compose the actual live render into the saved frame aspect. The
    /// background is the presentation environment colour, so bars read as the
    /// presentation background rather than a fabricated image.
    static func composited(_ image: UIImage, aspect: Double,
                           background: UIColor) -> (image: UIImage,
                                                    width: Int, height: Int)? {
        guard let size = pixelSize(forAspect: aspect, targetWidth:
                                    Int((image.size.width * image.scale).rounded()))
        else { return nil }
        let canvas = CGSize(width: size.width, height: size.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let output = UIGraphicsImageRenderer(size: canvas, format: format)
            .image { context in
                background.setFill()
                context.fill(CGRect(origin: .zero, size: canvas))
                let content = CGSize(width: image.size.width * image.scale,
                                     height: image.size.height * image.scale)
                image.draw(in: fittedRect(content: content, canvas: canvas))
            }
        return (output, size.width, size.height)
    }
    #endif
}

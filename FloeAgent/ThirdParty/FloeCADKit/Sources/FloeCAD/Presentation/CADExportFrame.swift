//
//  CADExportFrame.swift
//  FloeCADKit
//
//  X21-R2 — saved-shot framing across viewport and export-container aspects.
//
//  A saved shot is a FRAME, not just a pose. Rendering that pose into whatever
//  REAL viewport currently exists clips the shot whenever the viewport is
//  narrower than the saved frame, and fitting the clipped image into the saved
//  aspect cannot restore geometry that was never drawn.
//
//  The correct rule is the opposite one:
//    1. widen the TRANSIENT projection just enough that the current viewport
//       contains the whole saved frustum (`CADExportFraming`),
//    2. snapshot the real RealityKit pixels,
//    3. centre-crop the saved frame out of that wider render, and
//    4. scale that crop to the exact output frame.
//
//  The camera distance is never changed: moving the eye changes perspective
//  and parallax. A perspective camera widens its vertical FOV; an
//  orthographic camera widens its half-height. The persisted camera (pose,
//  distance, FOV, frame aspect) is untouched; the widening is a transient
//  render value that is never written to a document.
//
//  High-FOV / very narrow combinations have a hard bound and refuse
//  explicitly instead of silently clipping the saved shot.
//
//  Size, fit and crop math are pure and unit-tested; only the image helpers
//  touch UIKit.
//

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Transient saved-shot render plan

/// One transient render plan for a saved frame inside a real viewport.
/// `savedAspect` and `viewportAspect` are width / height.
nonisolated struct CADExportFraming: Equatable, Sendable {
    /// A perspective camera above this vertical FOV is refused: the tangent
    /// explodes, the near plane dominates the image and the result is no
    /// longer a truthful wide-angle render. The persisted user FOV stays
    /// 10...150; this bound applies only to the internal transient lens.
    static let maximumTransientFovYDegrees = 165.0
    /// Bound for the transient half-height multiplier. A saved aspect is at
    /// most 5:1, so 64 covers every viewport the App can actually show and
    /// still refuses a nonsense geometry instead of allocating an absurd
    /// projection.
    static let maximumTransientScale = 64.0
    /// A hair of extra widening protects the crop from a viewport whose
    /// pixel aspect differs by a rounding step while the asynchronous
    /// snapshot flies.
    static let padding = 1.002

    let savedAspect: Double
    let viewportAspect: Double
    /// Multiplies the visible half-height while rendering. Always >= 1.
    let transientScale: Double
    /// Perspective vertical FOV that produces `transientScale`. For an
    /// orthographic camera this is the authored FOV; the half-height scale
    /// carries the widening instead.
    let transientFovYDegrees: Double
    let width: Int
    let height: Int

    var pixelSize: (width: Int, height: Int) { (width, height) }

    /// Plan the transient render, or nil when the saved frame cannot be
    /// contained without an unsupported lens.
    static func plan(savedAspect: Double,
                     viewportAspect: Double,
                     fovYDegrees: Double,
                     projection: CADCameraProjection,
                     targetWidth: Int) -> CADExportFraming? {
        guard savedAspect.isFinite, savedAspect > 0,
              viewportAspect.isFinite, viewportAspect > 0,
              fovYDegrees.isFinite, fovYDegrees >= 1, fovYDegrees < 179,
              let size = CADExportFrame.pixelSize(forAspect: savedAspect,
                                                  targetWidth: targetWidth)
        else { return nil }
        // Widen only when the viewport is narrower than the saved frame. A
        // wider viewport already contains the saved horizontal extent; it is
        // centre-cropped with the unchanged lens.
        let needed = savedAspect / viewportAspect
        let scale = needed > 1 ? needed * padding : 1
        guard scale.isFinite, scale >= 1, scale <= maximumTransientScale else {
            return nil
        }
        var transientFov = fovYDegrees
        if projection == .perspective && scale > 1 {
            let half = fovYDegrees * .pi / 360
            transientFov = 2 * atan(tan(half) * scale) * 180 / .pi
            guard transientFov.isFinite,
                  transientFov <= maximumTransientFovYDegrees else {
                return nil
            }
        }
        return CADExportFraming(savedAspect: savedAspect,
                                viewportAspect: viewportAspect,
                                transientScale: scale,
                                transientFovYDegrees: transientFov,
                                width: size.width, height: size.height)
    }

    /// The normalized centre crop of a rendered frame that is exactly the
    /// saved frame. `renderedAspect` must be the aspect of the PIXELS that
    /// were actually captured, not only the requested viewport: if a
    /// concurrent resize made the render narrower than the plan can cover,
    /// this returns nil so the caller discards the frame instead of
    /// returning a clipped shot.
    func cropRect(renderedAspect: Double) -> CGRect? {
        guard renderedAspect.isFinite, renderedAspect > 0,
              transientScale.isFinite, transientScale > 0 else { return nil }
        // Rendered half-height is h * scale; the saved half-height is h.
        let heightFraction = 1 / transientScale
        // Rendered half-width is h * scale * viewport; the saved half-width
        // is h * savedAspect.
        let widthFraction = savedAspect / (transientScale * renderedAspect)
        guard widthFraction.isFinite, heightFraction.isFinite,
              widthFraction > 0, heightFraction > 0,
              widthFraction <= 1 + 1e-6, heightFraction <= 1 + 1e-6 else {
            return nil
        }
        let width = min(widthFraction, 1)
        let height = min(heightFraction, 1)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2,
                      width: width, height: height)
    }
}

// MARK: - Pixel helpers

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
    /// Used by the video composer when a saved shot is placed inside the
    /// user's unchanged X28 container.
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
    /// Centre-crop the saved frame out of an already-rendered viewport. The
    /// crop is derived from the PIXELS the ARView actually produced, so a
    /// one-pixel viewport change cannot reintroduce a clipped edge. ARView
    /// snapshots are `.up`; any other orientation refuses rather than
    /// cropping the wrong axis.
    static func croppedSavedFrame(_ image: UIImage,
                                  plan: CADExportFraming) -> UIImage? {
        guard image.imageOrientation == .up else { return nil }
        let pixelWidth = Int((image.size.width * image.scale).rounded())
        let pixelHeight = Int((image.size.height * image.scale).rounded())
        guard pixelWidth >= minimumDimension, pixelHeight >= minimumDimension,
              let normalized = plan.cropRect(
                renderedAspect: Double(pixelWidth) / Double(pixelHeight))
        else { return nil }
        let originX = min(max(Int((normalized.minX * CGFloat(pixelWidth)).rounded()), 0),
                          pixelWidth - 1)
        let originY = min(max(Int((normalized.minY * CGFloat(pixelHeight)).rounded()), 0),
                          pixelHeight - 1)
        let width = min(max(Int((normalized.width * CGFloat(pixelWidth)).rounded()), 1),
                        pixelWidth - originX)
        let height = min(max(Int((normalized.height * CGFloat(pixelHeight)).rounded()), 1),
                         pixelHeight - originY)
        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        guard let cgImage = image.cgImage,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    /// The complete saved frame at the exact output pixel size. The crop is
    /// scaled 1:1 from real rendered pixels; no aspect is stretched.
    static func framedStill(_ image: UIImage,
                            plan: CADExportFraming)
    -> (image: UIImage, width: Int, height: Int)? {
        guard let cropped = croppedSavedFrame(image, plan: plan),
              let resized = resized(cropped, width: plan.width,
                                    height: plan.height) else { return nil }
        return (resized, plan.width, plan.height)
    }

    /// One exact-size redraw. `scale = 1` makes the returned image's `size`
    /// and pixel size agree, so the encoded PNG dimensions are the plan's.
    static func resized(_ image: UIImage, width: Int, height: Int) -> UIImage? {
        guard width >= minimumDimension, height >= minimumDimension,
              width <= maximumDimension, height <= maximumDimension else {
            return nil
        }
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif
}

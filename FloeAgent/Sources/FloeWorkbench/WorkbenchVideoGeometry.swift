// FloeWorkbench — Video frame geometry.
//
// One source of truth for how a clip's raw decoded frame maps onto the
// composition canvas. The SAME transforms drive:
//
//  * the in-app AVPlayer preview (standard AVVideoComposition instructions,
//    which AVFoundation serializes into the playback pipeline), and
//  * the export renderer (custom compositor over normalized intermediates,
//    which runs in-process where the instruction configuration survives).
//
// Keeping this math shared is what makes preview and export agree on
// orientation, crop, rotation and aspect-fit. Captions are burned in by the
// export compositor; the preview overlays the same segments in SwiftUI
// (AVVideoCompositionCoreAnimationTool is documented as export-only).

import Foundation
#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
#endif

/// Geometry for one clip on the composition canvas.
struct WorkbenchClipGeometry {
    /// Raw source buffer size as decoded (before `preferredTransform`).
    var naturalSize: CGSize
    /// Display transform of the source track (`preferredTransform`), mapping
    /// the raw buffer into display coordinates.
    var preferredTransform: CGAffineTransform
    /// Displayed size after `preferredTransform` (positive).
    var displaySize: CGSize
    /// Crop rectangle in the DISPLAY coordinate space, or nil for the full
    /// frame.
    var displayCrop: CGRect?
    /// Crop rectangle expressed in the RAW buffer space (for
    /// `AVVideoCompositionLayerInstruction.setCropRectangle`, which is defined
    /// in buffer coordinates). Axis-aligned for 0°/90°/180°/270° sources.
    var sourceCrop: CGRect?
    /// Full raw-buffer → canvas transform (orientation, crop rebase, user
    /// rotation, aspect-fit, centering). Does not clip; callers crop to the
    /// canvas afterwards.
    var canvasTransform: CGAffineTransform

    static func make(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                     crop: NormalizedRect?, rotationDegrees: Double,
                     canvas: CGSize) -> WorkbenchClipGeometry {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: max(1, abs(displayRect.width)),
                                 height: max(1, abs(displayRect.height)))
        // Map raw -> display with a normalized origin.
        let normalize = CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        let displayTransform = preferredTransform.concatenating(normalize)

        // Crop in display coordinates.
        var displayCrop: CGRect?
        if let crop {
            let rect = CGRect(x: crop.x * displaySize.width,
                              y: crop.y * displaySize.height,
                              width: crop.width * displaySize.width,
                              height: crop.height * displaySize.height)
            if rect.width > 1, rect.height > 1 {
                displayCrop = rect
            }
        }
        let cropRect = displayCrop ?? CGRect(origin: .zero, size: displaySize)
        let sourceCrop = displayCrop.map { $0.applying(displayTransform.inverted()) }

        // Rebase the crop origin to zero in the cropped image's coordinates.
        let rebase = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        // Content transform is expressed in the cropped image's local space
        // (origin top-left, size = crop size).
        var contentTransform = CGAffineTransform.identity

        // User rotation about the crop center.
        if rotationDegrees != 0 {
            let center = CGPoint(x: cropRect.width / 2, y: cropRect.height / 2)
            let rotate = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: rotationDegrees * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            contentTransform = contentTransform.concatenating(rotate)
        }

        // Aspect-fit the transformed content into the canvas and center it.
        let transformedBounds = CGRect(origin: .zero, size: cropRect.size).applying(contentTransform)
        let width = max(1, transformedBounds.width)
        let height = max(1, transformedBounds.height)
        let scale = min(canvas.width / width, canvas.height / height)
        let centerX = canvas.width / 2 - transformedBounds.midX * scale
        let centerY = canvas.height / 2 - transformedBounds.midY * scale
        contentTransform = contentTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centerX, y: centerY))

        // Full mapping: raw buffer -> display -> crop rebase -> content.
        let full = displayTransform.concatenating(rebase).concatenating(contentTransform)

        return WorkbenchClipGeometry(naturalSize: naturalSize,
                                     preferredTransform: preferredTransform,
                                     displaySize: displaySize,
                                     displayCrop: displayCrop,
                                     sourceCrop: sourceCrop,
                                     canvasTransform: full)
    }
}

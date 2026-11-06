// FloeWorkbench — PreparedVideo: selection-mask adapter.
//
// Video masks reuse the exact shared PreparedImage selection kernel rather
// than maintaining a second feather/inversion implementation. The kernel is
// source-pixel based; this adapter only translates the video plan's normalized
// rectangle/ellipse and feather fraction into that contract.
//
// The qualification package stages this adapter, PreparedVideo sources and the
// exact shared PreparedImage kernel sources (with hashes) so the host compiles
// the production implementation, not a stub.

import Foundation
import CoreGraphics

enum PreparedVideoMaskKernel {
    static func mask(_ mask: PreparedVideoMask, width: Int, height: Int,
                     cancellation: PreparedVideoCancellation) throws -> CGImage {
        try cancellation.check()
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              mask.width > 0, mask.height > 0 else {
            throw PreparedVideoError.renderFailed("mask dimensions are outside the supported bound")
        }
        let low = MediaPreparedBrushPoint(x: mask.centerX - mask.width / 2,
                                          y: mask.centerY - mask.height / 2)
        let high = MediaPreparedBrushPoint(x: mask.centerX + mask.width / 2,
                                           y: mask.centerY + mask.height / 2)
        let shape: MediaPreparedSelectionSpec.Shape = mask.shape == .rectangle ? .rectangle : .ellipse
        let featherPixels = mask.feather * Double(min(width, height))
        let spec = MediaPreparedSelectionSpec(shape: shape, points: [low, high],
                                              featherPixels: featherPixels,
                                              inverted: mask.isInverted)
        do {
            return try MediaPreparedImageKernel.selectionMask(
                spec, sourceWidth: width, sourceHeight: height,
                renderScale: 1,
                isCancelled: { cancellation.isCancelled })
        } catch MediaPreparedImageError.cancelled {
            throw PreparedVideoError.cancelled
        } catch let error as MediaPreparedImageError {
            switch error {
            case .resourceLimit:
                throw PreparedVideoError.renderFailed("mask exceeds the shared image kernel resource limit")
            case .invalidGeometry:
                throw PreparedVideoError.renderFailed("mask geometry is invalid for the shared image kernel")
            case .renderFailed, .cancelled:
                throw PreparedVideoError.renderFailed("the shared image kernel could not produce the mask")
            }
        } catch {
            throw PreparedVideoError.renderFailed("the shared image kernel failed")
        }
    }
}

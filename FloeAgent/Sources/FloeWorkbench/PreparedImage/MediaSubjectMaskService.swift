// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
#if canImport(Vision)
import Vision
#endif

public protocol MediaSubjectMasking: Sendable {
    func foregroundMask(_ image:CGImage) async throws -> ImageSelectionBitmap
}

public actor MediaSubjectMaskService: MediaSubjectMasking {
    public static let shared=MediaSubjectMaskService()
    public init() {}
    public func foregroundMask(_ image:CGImage) async throws -> ImageSelectionBitmap {
        try Task.checkCancellation()
        #if canImport(Vision)
        if #available(iOS 17,macOS 14,*) {
            let job=ForegroundMaskJob(),handler=VNImageRequestHandler(cgImage:image,options:[:])
            return try await withTaskCancellationHandler {
                try handler.perform([job.request]);try Task.checkCancellation()
                guard let observation=job.request.results?.first,!observation.allInstances.isEmpty else{
                    throw MediaPreparedCoreError.invalidOperation("no foreground subject was found; use a wand or lasso selection")
                }
                let pixel=try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
                let mask=CIImage(cvPixelBuffer:pixel).applyingFilter("CIMaskToAlpha")
                guard let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(mask,from:mask.extent) else{
                    throw MediaPreparedCoreError.invalidOperation("foreground mask could not be rendered")
                }
                try Task.checkCancellation();return try MediaNativeSelection.coverage(cg)
            } onCancel: { job.request.cancel() }
        }
        #endif
        throw MediaPreparedCoreError.invalidOperation("foreground selection requires a supported system Vision runtime")
    }
}
#if canImport(Vision)
@available(iOS 17,macOS 14,*)
private final class ForegroundMaskJob: @unchecked Sendable {
    // VNRequest.cancel is the only cross-task operation; request construction,
    // perform and result inspection stay in the owning service operation.
    let request=VNGenerateForegroundInstanceMaskRequest()
}
#endif

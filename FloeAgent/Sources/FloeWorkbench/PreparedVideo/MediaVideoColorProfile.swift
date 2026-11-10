// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import CoreMedia
import AVFoundation
import VideoToolbox
import ImageIO

/// Nil retains the existing sRGB/709 SDR path byte-for-byte. Explicit profiles
/// use managed conversion, not only a changed container tag.
public enum MediaVideoColorProfile: String, Sendable, Codable, Hashable, CaseIterable {
    case rec709
    case rec2020HLG
    case rec2020PQ
    public var isHDR: Bool { self != .rec709 }
    public var bitDepth: Int { isHDR ? 10 : 8 }
    public var pixelBufferFormat: OSType { isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA }
    public func colorSpace() throws -> CGColorSpace {
        let name: CFString
        switch self {
        case .rec709: name = CGColorSpace.itur_709
        case .rec2020HLG: name = CGColorSpace.itur_2100_HLG
        case .rec2020PQ: name = CGColorSpace.itur_2100_PQ
        }
        guard let space = CGColorSpace(name: name) else { throw PreparedVideoError.renderFailed("the selected video color space is unavailable") }
        return space
    }
    public static func videoProperties(_ profile: Self?) -> [String:Any] {
        let hdr = profile?.isHDR == true
        let transfer: String
        switch profile {
        case .rec709: transfer = AVVideoTransferFunction_ITU_R_709_2
        case .rec2020HLG: transfer = AVVideoTransferFunction_ITU_R_2100_HLG
        case .rec2020PQ: transfer = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case nil: transfer = AVVideoTransferFunction_IEC_sRGB
        }
        return [AVVideoColorPrimariesKey: hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]
    }
    public static func attach(_ profile: Self?,to buffer: CVPixelBuffer) throws {
        let hdr = profile?.isHDR == true
        let transfer: CFString
        switch profile {
        case .rec709: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        case .rec2020HLG: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .rec2020PQ: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case nil: transfer = kCVImageBufferTransferFunction_sRGB
        }
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,transfer,.shouldPropagate)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        if let profile { CVBufferSetAttachment(buffer,kCVImageBufferCGColorSpaceKey,try profile.colorSpace(),.shouldPropagate) }
    }
    public static func encodedBitDepth(_ description: CMFormatDescription) -> Int? {
        let fields = CMFormatDescriptionGetExtensions(description) as? [String:Any] ?? [:]
        if let bits = fields[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber { return bits.intValue }
        guard let atoms = fields[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String:Any],
              let data = atoms["hvcC"] as? Data, data.count >= 19, data[0] == 1 else { return nil }
        let luma = Int(data[17]&7)+8, chroma = Int(data[18]&7)+8
        return luma == chroma ? luma : nil
    }
    public static func validateEncoded(_ profile: Self,description: CMFormatDescription) throws {
        let fields = CMFormatDescriptionGetExtensions(description) as? [String:Any] ?? [:]
        let wanted = videoProperties(profile)
        guard fields[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String == wanted[AVVideoColorPrimariesKey] as? String,
              fields[kCMFormatDescriptionExtension_TransferFunction as String] as? String == wanted[AVVideoTransferFunctionKey] as? String,
              fields[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String == wanted[AVVideoYCbCrMatrixKey] as? String else {
            throw PreparedVideoError.renderFailed("the encoded video did not preserve its selected color properties")
        }
        if profile.isHDR {
            guard CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC, encodedBitDepth(description) == 10 else {
                throw PreparedVideoError.renderFailed("the encoded HDR video did not preserve 10-bit HEVC")
            }
        }
    }
}

public actor MediaVideoColorProfileDetector {
    public static let shared = MediaVideoColorProfileDetector()
    public init() {}
    public func detect(url: URL,kind: MediaAssetKind) async throws -> MediaVideoColorProfile? {
        guard url.isFileURL else { throw MediaPreparedCoreError.invalidOperation("color detection requires a local source") }
        try Task.checkCancellation()
        switch kind {
        case .video:
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let description = try await track.load(.formatDescriptions).first else {
                throw MediaPreparedCoreError.invalidOperation("the video color description is unavailable")
            }
            let fields = CMFormatDescriptionGetExtensions(description) as? [String:Any] ?? [:]
            let transfer = fields[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            try Task.checkCancellation()
            if transfer == AVVideoTransferFunction_ITU_R_2100_HLG { return .rec2020HLG }
            if transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ { return .rec2020PQ }
            if transfer == AVVideoTransferFunction_ITU_R_709_2 { return .rec709 }
            return nil
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceThumbnailMaxPixelSize:64,kCGImageSourceShouldAllowFloat:true,
                    kCGImageSourceDecodeRequest:kCGImageSourceDecodeToHDR] as CFDictionary),
                  let space = image.colorSpace else { throw MediaPreparedCoreError.invalidOperation("the image color profile is unavailable") }
            try Task.checkCancellation()
            if CGColorSpaceIsHLGBased(space) { return .rec2020HLG }
            if CGColorSpaceIsPQBased(space) { return .rec2020PQ }
            if image.contentHeadroom > 1 { return .rec2020HLG }
            return nil
        case .audio: throw MediaPreparedCoreError.invalidOperation("choose a video or image source")
        }
    }
}

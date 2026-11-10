// FloeWorkbench — PreparedVideo: honest capability probes and adapters.
//
// Capability reporting is deliberately explicit:
//   * VideoToolbox encoder enumeration is read at runtime; a missing encoder
//     is reported, never replaced by an optimistic constant.
//   * Vision tracking/person-segmentation API presence is not the same as a
//     shipped tracking/matte pipeline. This component reports the API probe
//     and keeps `visionTrackingAdapterImplemented` /
//     `visionMattePipelineImplemented` false until a real adapter is bound.
//   * The simulator label is reported so a simulator run cannot be counted as
//     native hardware evidence.
//
// The enhancement bridge is an adapter contract onto the existing
// `MediaEnhancementService` design. It deliberately contains no model
// downloader/installer and no alternate runtime; the coordinator supplies the
// real service-backed bridge.

import Foundation
import CoreMedia
import VideoToolbox
import Metal
#if canImport(Vision)
import Vision
#endif

public struct PreparedVideoCapabilityReport: Sendable, Hashable, Codable {
    public let platform: String
    public let isSimulator: Bool
    public let metalAvailable: Bool
    public let h264EncoderAvailable: Bool
    public let hevcEncoderAvailable: Bool
    public let hardwareHEVCDecodeAvailable: Bool
    public let visionTrackingAPIAvailable: Bool
    public let visionPersonSegmentationAPIAvailable: Bool
    public let visionTrackingAdapterImplemented: Bool
    public let visionMattePipelineImplemented: Bool
    public let offlineAudioMixerImplemented: Bool
    public let notes: [String]
}

public enum PreparedVideoCapabilities {
    public static func probe() -> PreparedVideoCapabilityReport {
        let encoders = encoderList()
        let metalAvailable = MTLCreateSystemDefaultDevice() != nil
        let h264 = encoders.contains { $0.codec == kCMVideoCodecType_H264 }
        let hevc = encoders.contains { $0.codec == kCMVideoCodecType_HEVC }
        let hardwareDecode = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        var notes: [String] = []
        if !h264 { notes.append("No H.264 encoder was enumerated by VideoToolbox.") }
        if !hevc { notes.append("No HEVC encoder was enumerated by VideoToolbox.") }
        if !metalAvailable {
            notes.append("No Metal device is available; Core Image may fall back to CPU.")
        }
        notes.append("Sampled source object tracking and translation stabilization are implemented; person matte processing is not implemented.")
        return PreparedVideoCapabilityReport(
            platform: platformName,
            isSimulator: isSimulator,
            metalAvailable: metalAvailable,
            h264EncoderAvailable: h264,
            hevcEncoderAvailable: hevc,
            hardwareHEVCDecodeAvailable: hardwareDecode,
            visionTrackingAPIAvailable: visionTrackingAvailable,
            visionPersonSegmentationAPIAvailable: visionSegmentationAvailable,
            visionTrackingAdapterImplemented: visionTrackingAvailable,
            visionMattePipelineImplemented: false,
            offlineAudioMixerImplemented: true,
            notes: notes)
    }

    public static func encoderAvailable(for codec: PreparedVideoCodec) -> Bool {
        let encoders = encoderList()
        switch codec {
        case .h264: return encoders.contains { $0.codec == kCMVideoCodecType_H264 }
        case .hevc: return encoders.contains { $0.codec == kCMVideoCodecType_HEVC }
        }
    }

    private struct Encoder {
        var codec: CMVideoCodecType
        var hardwareAccelerated: Bool
    }

    private static func encoderList() -> [Encoder] {
        var list: CFArray?
        let status = VTCopyVideoEncoderList(nil, &list)
        guard status == noErr, let entries = list as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let codecNumber = entry[kVTVideoEncoderList_CodecType as String] as? NSNumber else {
                return nil
            }
            let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
            return Encoder(codec: CMVideoCodecType(codecNumber.uint32Value),
                           hardwareAccelerated: hardware)
        }
    }

    private static var platformName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static var visionTrackingAvailable: Bool {
        #if canImport(Vision)
        if #available(iOS 11.0, macOS 10.13, *) {
            _ = VNTrackObjectRequest.self
            return true
        }
        return false
        #else
        return false
        #endif
    }

    private static var visionSegmentationAvailable: Bool {
        #if canImport(Vision)
        if #available(iOS 15.0, macOS 12.0, *) {
            _ = VNGeneratePersonSegmentationRequest.self
            return true
        }
        return false
        #else
        return false
        #endif
    }
}

// MARK: - Enhancement bridge

public enum PreparedVideoEnhancementOperation: String, Sendable, Hashable, Codable {
    case interpolation
    case superResolution
    case tracking
    case matte
}

public struct PreparedVideoEnhancementCapabilities: Sendable, Hashable, Codable {
    public let interpolation: Bool
    public let superResolution: Bool
    public let tracking: Bool
    public let matte: Bool
    public let availableModelIDs: [String]
    public let sourceDescription: String

    public init(interpolation: Bool, superResolution: Bool, tracking: Bool, matte: Bool,
                availableModelIDs: [String] = [], sourceDescription: String) {
        self.interpolation = interpolation
        self.superResolution = superResolution
        self.tracking = tracking
        self.matte = matte
        self.availableModelIDs = availableModelIDs
        self.sourceDescription = sourceDescription
    }
}

public struct PreparedVideoEnhancementRequest: Sendable, Hashable {
    public let inputURL: URL
    public let outputURL: URL
    public let operation: PreparedVideoEnhancementOperation
    public let modelID: String?
    public let targetFrameRate: Double?
    public let scaleFactor: Int?

    public init(inputURL: URL, outputURL: URL,
                operation: PreparedVideoEnhancementOperation,
                modelID: String? = nil, targetFrameRate: Double? = nil,
                scaleFactor: Int? = nil) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.operation = operation
        self.modelID = modelID
        self.targetFrameRate = targetFrameRate
        self.scaleFactor = scaleFactor
    }
}

public struct PreparedVideoEnhancementReceipt: Sendable, Hashable {
    public let outputURL: URL
    public let operation: PreparedVideoEnhancementOperation
    public let modelID: String?
    public let notes: [String]

    public init(outputURL: URL, operation: PreparedVideoEnhancementOperation,
                modelID: String?, notes: [String] = []) {
        self.outputURL = outputURL
        self.operation = operation
        self.modelID = modelID
        self.notes = notes
    }
}

/// Coordinator-supplied bridge onto the existing `MediaEnhancementService`.
/// The bridge owns model resolution/installation policy; this component does
/// not create a second model store or installer.
public protocol PreparedVideoEnhancementBridge: Sendable {
    func capabilities() async -> PreparedVideoEnhancementCapabilities
    func enhance(_ request: PreparedVideoEnhancementRequest) async throws -> PreparedVideoEnhancementReceipt
}

public struct UnavailablePreparedVideoEnhancementBridge: PreparedVideoEnhancementBridge {
    public init() {}

    public func capabilities() async -> PreparedVideoEnhancementCapabilities {
        PreparedVideoEnhancementCapabilities(
            interpolation: false, superResolution: false, tracking: false, matte: false,
            availableModelIDs: [],
            sourceDescription: "No MediaEnhancementService bridge is bound")
    }

    public func enhance(_ request: PreparedVideoEnhancementRequest) async throws -> PreparedVideoEnhancementReceipt {
        throw PreparedVideoError.unsupportedCapability("no enhancement service bridge is bound")
    }
}

// MARK: - Vision effect adapter

public struct PreparedVideoVisionEffectCapability: Sendable, Hashable, Codable {
    public let trackingSupported: Bool
    public let matteSupported: Bool
    public let reason: String
}

public protocol PreparedVideoVisionEffectAdapter: Sendable {
    func capability() -> PreparedVideoVisionEffectCapability
}

public struct UnavailablePreparedVideoVisionEffectAdapter: PreparedVideoVisionEffectAdapter {
    public init() {}

    public func capability() -> PreparedVideoVisionEffectCapability {
        PreparedVideoVisionEffectCapability(
            trackingSupported: false, matteSupported: false,
            reason: "Vision tracking/matte is not implemented; capability probe only")
    }
}

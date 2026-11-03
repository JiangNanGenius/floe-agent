// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — explicit input/output contract, limits, guards
// and measured result vocabulary (job-8e175eef3cea48d3).
//
// This is the Android execution contract for the planned ENH family
// (ENH-IN-OUT-CONTRACT, ENH-PROGRESS-ABORT, ENH-NO-FAKE-UPSCALE). It is a
// deliberate adaptation of the iOS `FloeMedia/MediaEnhancementContract.swift`
// fixed reference (36f63bf400dfaa3a127259eac006b38d72516390), NOT a port of the
// CoreML/VideoToolbox engine:
//
//  * Motion interpolation runs as a REAL deterministic ffmpeg
//    `minterpolate` job inside the task's resolved Linux environment through
//    the original `exec.shell` durable-job path. Availability is discovered,
//    never assumed: the generic ffmpeg/ffprobe tools are probed in the guest
//    (`command -v`) before any job is offered.
//  * True super-resolution NEVER falls back to plain scaling. It requires a
//    user-configured remote backend stored through the original settings and
//    credential services (`SettingsStore` key + `ProviderProfile` base URL +
//    keychain-referenced credential). An unconfigured or unreachable backend
//    is an explicit, configurable state — never a silent downgrade.
//  * Ordinary resize is not represented here at all; the media.project
//    export path remains the only resize surface and is labelled resize.
//
// The contract performs no IO: validation is pure over measured probe facts,
// so unsupported combinations are refused BEFORE any invocation.
import Foundation
import FloeCore

// MARK: - Operation

/// Which enhancement to run, with its explicit parameter. The associated
/// values are the contract: a caller cannot request "enhancement" without
/// naming the exact target frame rate or scale factor.
public enum G09R2EnhancementOperation: Sendable, Equatable {
    /// Real motion interpolation to the exact target constant frame rate.
    case interpolation(targetFPS: Double)
    /// True super-resolution through the configured cloud backend.
    case superResolution(scaleFactor: Int)

    public var isInterpolation: Bool {
        if case .interpolation = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .interpolation(let fps):
            return "interpolation targetFPS=\(fps)"
        case .superResolution(let scale):
            return "superResolution scaleFactor=\(scale)"
        }
    }
}

extension G09R2EnhancementOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, targetFPS, scaleFactor
    }

    private enum Kind: String, Codable {
        case interpolation, superResolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .interpolation:
            self = .interpolation(targetFPS: try container.decode(Double.self, forKey: .targetFPS))
        case .superResolution:
            self = .superResolution(scaleFactor: try container.decode(Int.self, forKey: .scaleFactor))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interpolation(let fps):
            try container.encode(Kind.interpolation, forKey: .kind)
            try container.encode(fps, forKey: .targetFPS)
        case .superResolution(let scale):
            try container.encode(Kind.superResolution, forKey: .kind)
            try container.encode(scale, forKey: .scaleFactor)
        }
    }
}

// MARK: - Request

/// One fully specified enhancement request. `inputRelativePath` is resolved
/// beneath the trusted project media root ONLY; the service never consults a
/// current selection, first project or global root. The workspace scope is
/// frozen at submission (snapshot of the task workspace) and both staging and
/// the guest-visible `/workspace` view are derived from that single snapshot.
///
/// Super-resolution currently supports VIDEO inputs only (real backend:
/// fal.ai `fal-ai/bytedance-upscaler/upscale/video`). Still images are
/// refused with an explicit supported-type boundary, never silently sent to
/// a video model.
public struct G09R2EnhancementRequestDTO: Codable, Sendable, Equatable {
    public var inputRelativePath: String
    public var operation: G09R2EnhancementOperation
    public var outputFileName: String
    /// Explicit overwrite consent. Default false: an existing destination is
    /// refused so a staged commit can never replace a previous artifact (or
    /// the source) by accident.
    public var overwrite: Bool
    /// Output bit depth: 8 (SDR, standard tier) or 10 (HDR, pro tier). A
    /// value above 8 requires the backend's pro tier and is sent verbatim;
    /// an HDR source refuses 8-bit output instead of silently squashing.
    public var bitDepth: Int

    public init(inputRelativePath: String,
                operation: G09R2EnhancementOperation,
                outputFileName: String,
                overwrite: Bool = false,
                bitDepth: Int = 8) {
        self.inputRelativePath = inputRelativePath
        self.operation = operation
        self.outputFileName = outputFileName
        self.overwrite = overwrite
        self.bitDepth = bitDepth
    }
}

// MARK: - Probe facts

/// Measured properties of a media file, obtained from the guest `ffprobe`
/// readback (or, for images, the byte-level probe). Every guard and every
/// result field uses these measured facts — never a success string.
public struct G09R2MediaProbeFacts: Codable, Sendable, Equatable {
    public var isImage: Bool
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
    public var frameRate: Double
    public var frameCount: Int
    public var hasAudio: Bool
    public var codec: String?
    /// HDR when the container advertises PQ or HLG transfer (or 10-bit+ HEVC
    /// without an explicit SDR tag). Drives the explicit bit-depth contract:
    /// HDR sources must opt into 10-bit output, never a silent 8-bit squash.
    public var isHDR: Bool
    public var byteCount: Int64
    public var sha256: String

    public init(isImage: Bool, width: Int, height: Int,
                durationSeconds: Double, frameRate: Double, frameCount: Int,
                hasAudio: Bool, codec: String?, isHDR: Bool = false,
                byteCount: Int64, sha256: String) {
        self.isImage = isImage
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.hasAudio = hasAudio
        self.codec = codec
        self.isHDR = isHDR
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

// MARK: - Limits

/// Hard bounds shared by both engines. Identical numbers to the iOS contract
/// so cross-platform projects behave the same way.
public struct G09R2EnhancementLimits: Sendable, Equatable {
    public var maximumSourceDimension: Int
    public var maximumOutputDimension: Int
    public var maximumDurationSeconds: Double
    public var maximumFrames: Int
    public var maximumTargetFPS: Double
    /// Interpolation accepts 2...8x the source frame rate.
    public var maximumUpscaleWhileInterpolating: Int
    /// The fal.ai bytedance-upscaler backend bound: output pixel count must
    /// not exceed 4k (3840x2160).
    public static let falMaximumPixels = 3840 * 2160

    public init(maximumSourceDimension: Int = 4096,
                maximumOutputDimension: Int = 8192,
                maximumDurationSeconds: Double = 3600,
                maximumFrames: Int = 200_000,
                maximumTargetFPS: Double = 240,
                maximumUpscaleWhileInterpolating: Int = 8) {
        self.maximumSourceDimension = maximumSourceDimension
        self.maximumOutputDimension = maximumOutputDimension
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumFrames = maximumFrames
        self.maximumTargetFPS = maximumTargetFPS
        self.maximumUpscaleWhileInterpolating = maximumUpscaleWhileInterpolating
    }

    public static let standard = G09R2EnhancementLimits()
}

// MARK: - Refusals

/// Typed, bounded refusal vocabulary for the enhancement surface. Codes are
/// alphanumeric/`._-` and <= 64 bytes so they can travel the R2 wire and the
/// App failure mapping unchanged.
public enum G09R2EnhancementRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedCombination(String)
    case sourceTooLarge(String)
    case outputTooLarge(String)
    case durationTooLong(String)
    case frameBoundExceeded(String)
    case targetFPSInvalid(String)
    case scaleInvalid(String)
    case sourceUnreadable(String)
    case backendUnavailable(String)
    case taskContextRequired
    case outputExists

    public var code: String {
        switch self {
        case .unsupportedCombination: return "unsupportedCombination"
        case .sourceTooLarge: return "sourceTooLarge"
        case .outputTooLarge: return "outputTooLarge"
        case .durationTooLong: return "durationTooLong"
        case .frameBoundExceeded: return "frameBoundExceeded"
        case .targetFPSInvalid: return "targetFPSInvalid"
        case .scaleInvalid: return "scaleInvalid"
        case .sourceUnreadable: return "sourceUnreadable"
        case .backendUnavailable: return "backendUnavailable"
        case .taskContextRequired: return "taskContextRequired"
        case .outputExists: return "outputExists"
        }
    }

    /// Exact actionable reason; safe for UI copy (no paths with separators,
    /// no secrets, bounded length).
    public var detail: String {
        switch self {
        case .unsupportedCombination(let d): return d
        case .sourceTooLarge(let d): return d
        case .outputTooLarge(let d): return d
        case .durationTooLong(let d): return d
        case .frameBoundExceeded(let d): return d
        case .targetFPSInvalid(let d): return d
        case .scaleInvalid(let d): return d
        case .sourceUnreadable(let d): return d
        case .backendUnavailable(let d): return d
        case .taskContextRequired:
            return "Enhancement runs in the owning task environment; open this project from its task or use Ask AI first."
        case .outputExists:
            return "The output file already exists; enable overwrite to replace it explicitly."
        }
    }

    public var description: String { "\(code): \(detail)" }
}

// MARK: - Guards

/// Explicit preflight guards. Every rejection names the exact unsupported
/// property; nothing here silently changes the requested operation. Pure
/// function over measured facts — safe to unit test and cheap to run before
/// any invocation.
public enum G09R2EnhancementGuards {
    /// Validates the request against measured source facts and limits, and
    /// returns the derived output geometry + the interpolation ratio
    /// (frames per source pair) for the caller's planning.
    public static func validate(
        source: G09R2MediaProbeFacts,
        request: G09R2EnhancementRequestDTO,
        limits: G09R2EnhancementLimits = .standard
    ) throws -> (outputWidth: Int, outputHeight: Int, framesPerPair: Int) {
        guard source.width > 1, source.height > 1,
              source.width <= limits.maximumSourceDimension,
              source.height <= limits.maximumSourceDimension else {
            throw G09R2EnhancementRefusal.sourceTooLarge(
                "Source \(source.width)x\(source.height) must be within 2...\(limits.maximumSourceDimension)")
        }
        guard source.width % 2 == 0, source.height % 2 == 0 else {
            throw G09R2EnhancementRefusal.unsupportedCombination(
                "Source dimensions must be even for encoding")
        }
        switch request.operation {
        case .interpolation(let targetFPS):
            guard !source.isImage else {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "Frame interpolation requires a video input; still images have no frames to interpolate")
            }
            guard targetFPS.isFinite, targetFPS > 0,
                  targetFPS <= limits.maximumTargetFPS else {
                throw G09R2EnhancementRefusal.targetFPSInvalid(
                    "targetFPS must be finite and within 0...\(Int(limits.maximumTargetFPS))")
            }
            guard source.frameRate.isFinite, source.frameRate > 0, source.frameRate < 1000 else {
                throw G09R2EnhancementRefusal.sourceUnreadable(
                    "Source has no usable constant frame rate (measured \(source.frameRate))")
            }
            let ratio = targetFPS / source.frameRate
            guard ratio >= 2, ratio <= Double(limits.maximumUpscaleWhileInterpolating) else {
                throw G09R2EnhancementRefusal.targetFPSInvalid(
                    "targetFPS must be a 2...\(limits.maximumUpscaleWhileInterpolating)x multiple of the measured source frame rate \(source.frameRate); got \(targetFPS)")
            }
            guard source.durationSeconds.isFinite, source.durationSeconds > 0 else {
                throw G09R2EnhancementRefusal.sourceUnreadable(
                    "Source duration must be positive and finite")
            }
            guard source.durationSeconds <= limits.maximumDurationSeconds else {
                throw G09R2EnhancementRefusal.durationTooLong(
                    "Source duration exceeds the \(Int(limits.maximumDurationSeconds)) second bound")
            }
            let estimate = (source.durationSeconds * targetFPS).rounded(.up)
            guard estimate.isFinite, estimate <= Double(limits.maximumFrames) else {
                throw G09R2EnhancementRefusal.frameBoundExceeded(
                    "Estimated output exceeds the \(limits.maximumFrames) frame bound")
            }
            let framesPerPair = Int((targetFPS / source.frameRate).rounded(.up))
            return (source.width, source.height, max(2, framesPerPair))
        case .superResolution(let scaleFactor):
            guard scaleFactor >= 2, scaleFactor <= 4 else {
                throw G09R2EnhancementRefusal.scaleInvalid(
                    "scaleFactor must be 2, 3 or 4")
            }
            // Supported-type boundary: the configured real backend is the
            // fal.ai video upscaler. Images need their own documented image
            // model before they are accepted, never a video URL in disguise.
            guard !source.isImage else {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "Super-resolution currently supports video inputs only")
            }
            let outputWidth = source.width * scaleFactor
            let outputHeight = source.height * scaleFactor
            guard outputWidth <= limits.maximumOutputDimension,
                  outputHeight <= limits.maximumOutputDimension else {
                throw G09R2EnhancementRefusal.outputTooLarge(
                    "Scaled dimensions \(outputWidth)x\(outputHeight) exceed the \(limits.maximumOutputDimension) pixel bound")
            }
            // The fal.ai bytedance-upscaler backend admits scale_ratio up to
            // 4k (3840x2160 pixels); refuse before any paid submission.
            guard outputWidth * outputHeight <= G09R2EnhancementLimits.falMaximumPixels else {
                throw G09R2EnhancementRefusal.outputTooLarge(
                    "Scaled output exceeds the backend 4k bound (3840x2160)")
            }
            guard request.bitDepth == 8 || request.bitDepth == 10 else {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "bitDepth must be 8 or 10")
            }
            guard source.durationSeconds.isFinite, source.durationSeconds > 0,
                  source.frameRate.isFinite, source.frameRate > 0 else {
                throw G09R2EnhancementRefusal.sourceUnreadable(
                    "Source duration and frame rate must be finite and positive")
            }
            // Explicit HDR contract: an HDR source must opt into 10-bit
            // output (pro tier); an 8-bit request on HDR refuses instead of
            // silently converting.
            if source.isHDR, request.bitDepth == 8 {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "The source is HDR; choose 10-bit output to preserve it")
            }
            let estimate = (source.durationSeconds * source.frameRate).rounded(.up)
            guard estimate.isFinite, estimate <= Double(limits.maximumFrames) else {
                throw G09R2EnhancementRefusal.frameBoundExceeded(
                    "Estimated source frames exceed the \(limits.maximumFrames) frame bound")
            }
            guard source.durationSeconds <= limits.maximumDurationSeconds else {
                throw G09R2EnhancementRefusal.durationTooLong(
                    "Source duration exceeds the \(Int(limits.maximumDurationSeconds)) second bound")
            }
            return (outputWidth, outputHeight, 1)
        }
    }

    /// Post-write verification of the committed output against the contract
    /// and the measured source facts. Throws a typed refusal when the measured
    /// output does not match what was requested — a returned success string is
    /// never accepted as evidence.
    public static func verifyOutput(
        measured: G09R2MediaProbeFacts,
        source: G09R2MediaProbeFacts,
        request: G09R2EnhancementRequestDTO
    ) throws {
        // Fidelity guards (both engines): a verified output must not silently
        // drop source traits. Lost audio or lost HDR when the source had
        // them is a typed refusal, never a quietly "valid" enhancement.
        guard !source.hasAudio || measured.hasAudio else {
            throw G09R2EnhancementRefusal.unsupportedCombination(
                "Output lost the source audio track")
        }
        guard !source.isHDR || measured.isHDR else {
            throw G09R2EnhancementRefusal.unsupportedCombination(
                "Output lost the source HDR characteristics")
        }
        switch request.operation {
        case .interpolation(let targetFPS):
            guard !measured.isImage else {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "Interpolation output must be a video")
            }
            guard measured.width == source.width, measured.height == source.height else {
                throw G09R2EnhancementRefusal.unsupportedCombination(
                    "Interpolation must preserve source dimensions; measured \(measured.width)x\(measured.height), expected \(source.width)x\(source.height)")
            }
            guard abs(measured.frameRate - targetFPS) <= max(0.5, targetFPS * 0.02) else {
                throw G09R2EnhancementRefusal.targetFPSInvalid(
                    "Output measured at \(measured.frameRate) fps, expected \(targetFPS)")
            }
            guard measured.durationSeconds > 0 else {
                throw G09R2EnhancementRefusal.sourceUnreadable(
                    "Output has no measurable duration")
            }
        case .superResolution(let scaleFactor):
            // The backend contract declares output geometry; require the
            // measured dimensions to match the requested scale exactly.
            guard measured.width == source.width * scaleFactor,
                  measured.height == source.height * scaleFactor else {
                throw G09R2EnhancementRefusal.outputTooLarge(
                    "Output measured \(measured.width)x\(measured.height), expected \(source.width * scaleFactor)x\(source.height * scaleFactor)")
            }
        }
    }
}

// MARK: - Progress

/// Structured progress for long-running enhancement work. Fractions come from
/// the real ffmpeg `frame=` counter (interpolation) or byte counts (cloud
/// backend); no invented percentages.
public struct G09R2EnhancementProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case preflight
        case processing
        case validating
        case committing
    }

    public var phase: Phase
    public var completedUnits: Int
    public var totalUnits: Int
    public var fraction: Double

    public init(phase: Phase, completedUnits: Int, totalUnits: Int) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.fraction = totalUnits > 0
            ? min(1, Double(completedUnits) / Double(totalUnits))
            : 0
    }
}

// MARK: - Result

/// Everything the caller needs to judge the result without trusting a success
/// string: the real engine/method, measured counters, and the committed
/// output identity (path, bytes, SHA-256). `remoteJobID` retains the cloud
/// backend's own job identifier for super-resolution outcomes that finished
/// remotely — including outcomes the backend never confirmed, which stay
/// `outcomeUnknown` rather than being replayed.
public struct G09R2EnhancementReceipt: Codable, Sendable, Equatable {
    public var outputRelativePath: String
    /// Truthful engine label, e.g. `ffmpeg-minterpolate` or the configured
    /// backend identifier. Never `super-resolution` for a plain resize.
    public var engine: String
    /// Wire method spelling: `interpolation` | `superResolution`.
    public var method: String
    public var inputKind: String
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var sourceFPS: Double
    public var sourceDurationSeconds: Double
    public var sourceFrameCount: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var outputFPS: Double
    public var outputDurationSeconds: Double
    public var outputFrameCount: Int
    public var outputBytes: Int64
    public var outputSHA256: String
    public var remoteJobID: String?
    public var warnings: [String]
    /// Set when the verified output re-entered the original media
    /// `importAsset` revision-CAS ownership: the imported asset identity and
    /// the project revision after the import. Nil with a nil importErrorCode
    /// means the import has not been attempted yet (the UI can retry through
    /// `media.enhancement.import`).
    public var importedAssetID: UUID?
    public var importRevision: Int64?
    /// Bounded failure code when the import of a verified output failed; the
    /// output file itself stays committed under `outputRelativePath`.
    public var importErrorCode: String?

    public init(outputRelativePath: String, engine: String, method: String,
                inputKind: String, sourceWidth: Int, sourceHeight: Int,
                sourceFPS: Double, sourceDurationSeconds: Double,
                sourceFrameCount: Int, outputWidth: Int, outputHeight: Int,
                outputFPS: Double, outputDurationSeconds: Double,
                outputFrameCount: Int, outputBytes: Int64,
                outputSHA256: String, remoteJobID: String? = nil,
                warnings: [String] = [], importedAssetID: UUID? = nil,
                importRevision: Int64? = nil, importErrorCode: String? = nil) {
        self.outputRelativePath = outputRelativePath
        self.engine = engine
        self.method = method
        self.inputKind = inputKind
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFPS = sourceFPS
        self.sourceDurationSeconds = sourceDurationSeconds
        self.sourceFrameCount = sourceFrameCount
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.outputFPS = outputFPS
        self.outputDurationSeconds = outputDurationSeconds
        self.outputFrameCount = outputFrameCount
        self.outputBytes = outputBytes
        self.outputSHA256 = outputSHA256
        self.remoteJobID = remoteJobID
        self.warnings = warnings
        self.importedAssetID = importedAssetID
        self.importRevision = importRevision
        self.importErrorCode = importErrorCode
    }
}

// MARK: - Capability

/// Honest capability descriptor. Each engine reports its own availability and
/// the exact reason when unavailable; nothing is advertised earlier than it is
/// wired.
public struct G09R2EnhancementCapabilityDTO: Codable, Sendable, Equatable {
    /// ffmpeg/ffprobe discovered in the task Linux image.
    public var interpolationReady: Bool
    /// Truthful engine label advertised when interpolationReady.
    public var interpolationEngine: String?
    public var interpolationUnavailableReason: String?
    /// A usable super-resolution backend is configured (settings key +
    /// provider profile + resolvable credential reference).
    public var superResolutionReady: Bool
    /// Public display name of the configured backend, never a secret.
    public var superResolutionBackendName: String?
    public var superResolutionUnavailableReason: String?

    public init(interpolationReady: Bool, interpolationEngine: String? = nil,
                interpolationUnavailableReason: String? = nil,
                superResolutionReady: Bool, superResolutionBackendName: String? = nil,
                superResolutionUnavailableReason: String? = nil) {
        self.interpolationReady = interpolationReady
        self.interpolationEngine = interpolationEngine
        self.interpolationUnavailableReason = interpolationUnavailableReason
        self.superResolutionReady = superResolutionReady
        self.superResolutionBackendName = superResolutionBackendName
        self.superResolutionUnavailableReason = superResolutionUnavailableReason
    }
}

// MARK: - Status

public enum G09R2EnhancementJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case cancelling
    case validating
    case completed
    case failed
    case cancelled
    /// The provider/backend outcome could not be confirmed (process loss,
    /// network failure after dispatch). The remote ID is retained when known
    /// and the job is NEVER silently replayed.
    case outcomeUnknown

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .outcomeUnknown: return true
        default: return false
        }
    }
}

public struct G09R2EnhancementStatusDTO: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: G09R2EnhancementJobState
    public var progress: G09R2EnhancementProgress?
    public var receipt: G09R2EnhancementReceipt?
    public var errorCode: String?
    public var errorDetail: String?
    public var retryable: Bool
    public var canCancel: Bool

    public init(jobID: String, state: G09R2EnhancementJobState,
                progress: G09R2EnhancementProgress? = nil,
                receipt: G09R2EnhancementReceipt? = nil,
                errorCode: String? = nil, errorDetail: String? = nil,
                retryable: Bool = false, canCancel: Bool = false) {
        self.jobID = jobID
        self.state = state
        self.progress = progress
        self.receipt = receipt
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.retryable = retryable
        self.canCancel = canCancel
    }
}

// MARK: - Wire requests

public struct G09R2EnhancementCapabilityRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public init(context: G09R2ProjectContextDTO) {
        self.context = context
    }
}

public struct G09R2EnhancementSubmitRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var enhancement: G09R2EnhancementRequestDTO
    public init(context: G09R2ProjectContextDTO,
                enhancement: G09R2EnhancementRequestDTO) {
        self.context = context
        self.enhancement = enhancement
    }
}

public struct G09R2EnhancementJobQuery: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var jobID: String
    public init(context: G09R2ProjectContextDTO, jobID: String) {
        self.context = context
        self.jobID = jobID
    }
}

public struct G09R2EnhancementHandleDTO: Encodable, Sendable {
    public var jobID: String
    public var state: String
    public var idempotent: Bool
    public init(jobID: String, state: String, idempotent: Bool) {
        self.jobID = jobID
        self.state = state
        self.idempotent = idempotent
    }
}

// MARK: - Backend configuration (settings store value)

/// Value stored under `media.enhancement.superResolutionBackend` in the
/// original `SettingsStore`. It references the ORIGINAL credential store
/// DIRECTLY through a keychain account (`SecretReference`-style identifier):
/// the API credential never enters this record, any log, or the wire, and NO
/// `ProviderProfile` is created — the enhancer backend must never appear as a
/// general `video.generate`-capable provider.
///
/// Decode is tolerant: the source-only predecessor schema
/// (`{"providerProfileID":...}`) decodes into `legacyProviderProfileID` so an
/// old row is reported as `backendProfileUnavailable` (reconfigure) instead
/// of a decode failure.
public struct G09R2EnhancerBackendConfiguration: Codable, Sendable, Equatable {
    /// User-facing name for the configured backend (e.g. "fal.ai").
    public var displayName: String?
    /// Documented fal model endpoint driving the transport.
    public var endpointID: String
    /// Keychain account holding the API credential in the ORIGINAL
    /// credential store. Opaque reference derived from it via
    /// `SecretGatewayNaming`; the secret bytes never touch this row.
    public var credentialAccount: String
    /// Documented remote contract revision implemented by this build.
    public var contractRevision: Int
    /// Present only for predecessor rows that referenced a ProviderProfile;
    /// those stay an explicit reconfigure state.
    public var legacyProviderProfileID: UUID?

    /// Fixed account for the built-in fal super-resolution backend. One
    /// enhancer service = one credential account; nothing is per-project.
    public static let defaultCredentialAccount = "media.enhancement.superResolution"
    /// The documented fal model this build implements.
    public static let defaultEndpointID = G09R2FalSuperResolutionBackend.defaultEndpointID

    public init(displayName: String? = nil,
                endpointID: String = G09R2EnhancerBackendConfiguration.defaultEndpointID,
                credentialAccount: String =
                    G09R2EnhancerBackendConfiguration.defaultCredentialAccount,
                contractRevision: Int = 1,
                legacyProviderProfileID: UUID? = nil) {
        self.displayName = displayName
        self.endpointID = endpointID
        self.credentialAccount = credentialAccount
        self.contractRevision = contractRevision
        self.legacyProviderProfileID = legacyProviderProfileID
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, endpointID, credentialAccount, contractRevision
        case legacyProviderProfileID = "providerProfileID"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.endpointID = try container.decodeIfPresent(String.self, forKey: .endpointID)
            ?? G09R2EnhancerBackendConfiguration.defaultEndpointID
        // Predecessor rows carry no credential account; keep the default so
        // the legacy provider reference is reported honestly below.
        self.credentialAccount = try container.decodeIfPresent(
            String.self, forKey: .credentialAccount)
            ?? G09R2EnhancerBackendConfiguration.defaultCredentialAccount
        self.contractRevision = try container.decodeIfPresent(Int.self, forKey: .contractRevision)
            ?? 1
        self.legacyProviderProfileID = try container.decodeIfPresent(
            UUID.self, forKey: .legacyProviderProfileID)
    }
}

// MARK: - Configuration wire (bridge actions)

/// Secret-free projection of the stored configuration for the settings UI.
public struct G09R2EnhancerConfigurationDTO: Codable, Sendable, Equatable {
    public var configured: Bool
    public var displayName: String?
    public var endpointID: String
    /// True when a non-empty credential exists in the original store for the
    /// configured account; the bytes never leave the vault.
    public var credentialConfigured: Bool
    /// True when a predecessor ProviderProfile row is present; the user must
    /// re-enter the key once through the new direct-credential flow.
    public var legacyProviderProfileReferenced: Bool

    public init(configured: Bool, displayName: String?, endpointID: String,
                credentialConfigured: Bool,
                legacyProviderProfileReferenced: Bool) {
        self.configured = configured
        self.displayName = displayName
        self.endpointID = endpointID
        self.credentialConfigured = credentialConfigured
        self.legacyProviderProfileReferenced = legacyProviderProfileReferenced
    }
}

/// Secret-free save request. The typed row is persisted only after the ONE
/// sealed native ingress established the credential: when
/// `saveIntentToken` is present it names the opaque one-shot `int:v1:`
/// handle whose bounded vault slot froze the secret-free candidate and the
/// key bytes together at save-tap (the key bytes NEVER cross this wire);
/// when absent the existing credential is kept and only the row is edited.
public struct G09R2EnhancerConfigurationSaveRequest: Decodable, Sendable {
    public var displayName: String?
    public var endpointID: String
    /// Advisory only; binding always comes from the sealed ingress /
    /// the current owned row, never from this raw value.
    public var credentialAccount: String
    /// Opaque one-shot sealed-ingress handle (`int:v1:…`) for a key Set;
    /// absent for a display-only edit.
    public var saveIntentToken: String?

    public init(displayName: String?, endpointID: String, credentialAccount: String,
                saveIntentToken: String? = nil) {
        self.displayName = displayName
        self.endpointID = endpointID
        self.credentialAccount = credentialAccount
        self.saveIntentToken = saveIntentToken
    }
}

/// Opaque credential reference for one account (secret-free; mirrors the
/// provider settings projection that already exposes opaque references).
public struct G09R2EnhancerCredentialReferenceDTO: Codable, Sendable, Equatable {
    public var credentialAccount: String
    public var opaqueReference: String

    public init(credentialAccount: String, opaqueReference: String) {
        self.credentialAccount = credentialAccount
        self.opaqueReference = opaqueReference
    }
}

public struct G09R2EnhancerCredentialReferenceRequest: Decodable, Sendable {
    public var credentialAccount: String?

    public init(credentialAccount: String? = nil) {
        self.credentialAccount = credentialAccount
    }
}

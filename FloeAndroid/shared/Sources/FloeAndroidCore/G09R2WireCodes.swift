// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — closed wire vocabulary for `floe.creative/6`.
//
// This file contains ONLY protocol values: version/schema, the closed BridgeV6
// action list, R2 limits, new typed error codes, state spellings and the exact
// video-command/design-action vocabularies. It performs no IO, starts no task
// and contains no provider or storage implementation. V1–V5 are untouched;
// this is the additive R2 layer consumed by a later native implementation.
import Foundation

public enum BridgeV6 {
    public static let version = 6
    public static let schema = "floe.creative/6"
    public static let maximumRequestBytes = G09R2CreativeLimits.requestBytes
    public static let maximumResponseBytes = G09R2CreativeLimits.responseBytes
    /// No model tool is registered by this bridge.
    public static let modelTools = false

    /// Closed action list. `handshake`, `status` and `bind` remain operations
    /// (like V5), not actions.
    ///
    /// CONTRACT FREEZE V2 (Main authorization 2026-11-01): the three
    /// `media.largeImport.*` actions are the ONLY additive change. Version,
    /// schema, limits and every other action name are unchanged.
    public static let actions: [String] = [
        "media.video.load",
        "media.video.apply",
        "media.largeImport.submit",
        "media.largeImport.status",
        "media.largeImport.cancel",
        "generation.models",
        "generation.image.submit",
        "generation.image.status",
        "generation.image.dismiss",
        "generation.video.submit",
        "generation.video.status",
        "generation.video.cancel",
        "generation.video.deliver",
        "generation.candidates.list",
        "generation.candidates.accept",
        "generation.candidates.reject",
        "design.canvas.snapshot",
        "design.canvas.mutate",
        "design.canvas.adopt",
        "design.canvas.compare",
        "design.canvas.restore",
        "design.canvas.export",
        "design.canvas.preview",
        "design.owner.state",
        "design.owner.brief",
        "design.owner.spec",
        "design.owner.freeze",
        "design.owner.propose",
        "design.owner.adopt",
        "design.owner.reject",
        "design.owner.compare",
        "design.owner.restore",
        "design.owner.export",
        "design.owner.preview",
    ]

    public static let actionSet = Set(actions)
}

public enum G09R2CreativeLimits {
    /// Bridge request/response and the frozen R1 project caps stay unchanged.
    public static let requestBytes = 65_536
    public static let responseBytes = 16 * 1024 * 1024
    public static let canvasProjectBytes = 15 * 1024 * 1024
    public static let mediaProjectBytes = 8 * 1024 * 1024

    /// Render tickets are IPC descriptors, not project JSON.
    public static let renderDescriptorBytes = 64 * 1024
    public static let renderReplyBytes = 1024 * 1024
    public static let maxLiveRenderTickets = 2

    public static let mediaCommands = 64

    /// Policy cap for an owned project image used as a generation source/edit/
    /// reference; bytes stay native and the request carries only an asset ID.
    public static let imageSourceBytes = 12 * 1024 * 1024

    /// Streamed large-import policy ceilings (not bridge buffers). The generic
    /// Canvas asset ceiling remains 64 MiB.
    public static let importImageBytes: Int64 = 128 * 1024 * 1024
    public static let importAudioBytes: Int64 = 1024 * 1024 * 1024
    public static let importVideoBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let canvasGenericAssetBytes: Int64 = 64 * 1024 * 1024
    public static let importDiskHeadroomBytes: Int64 = 512 * 1024 * 1024

    public static let designPreviewBytes = 8 * 1024 * 1024
    public static let designSourceBytes: Int64 = 64 * 1024 * 1024

    public static let jobListDefault = 50
    public static let jobListMax = 200
}

/// New R2 codes only. `invalidPayload`, `staleSession`, `staleGeneration`,
/// `revisionConflict`, `assetTooLarge`, `projectTooLarge`,
/// `storageUnavailable`, `writeFailed` and `outcomeUnknown` remain the R1
/// `G09CreativeError` codes and are reused verbatim.
public enum G09R2WireError: Error, Sendable, Equatable {
    case generationUnavailable
    case modelUnavailable
    case providerRejected
    case providerTimeout
    case jobNotFound
    case jobTerminal
    case candidateNotFound
    case candidateStale
    case renderUnsupported
    case rendererUnavailable
    case renderCancelled
    case renderTimeout
    case unsupportedCodec
    case unsupportedTransition
    case unsupportedSourceFormat
    case insufficientStorage
    case importTooLarge
    case renderTicketNotFound
    case renderTicketExpired
    case renderTicketAlreadySettled
    case designTargetUnavailable
    case designConflict
    case designPublicationPending
    case designPreviewTooLarge
    case designPayloadTooLarge
    case designPayloadMissing
    case designPublicationUnavailable

    public var code: String {
        switch self {
        case .generationUnavailable: "generationUnavailable"
        case .modelUnavailable: "modelUnavailable"
        case .providerRejected: "providerRejected"
        case .providerTimeout: "providerTimeout"
        case .jobNotFound: "jobNotFound"
        case .jobTerminal: "jobTerminal"
        case .candidateNotFound: "candidateNotFound"
        case .candidateStale: "candidateStale"
        case .renderUnsupported: "renderUnsupported"
        case .rendererUnavailable: "rendererUnavailable"
        case .renderCancelled: "renderCancelled"
        case .renderTimeout: "renderTimeout"
        case .unsupportedCodec: "unsupportedCodec"
        case .unsupportedTransition: "unsupportedTransition"
        case .unsupportedSourceFormat: "unsupportedSourceFormat"
        case .insufficientStorage: "insufficientStorage"
        case .importTooLarge: "importTooLarge"
        case .renderTicketNotFound: "renderTicketNotFound"
        case .renderTicketExpired: "renderTicketExpired"
        case .renderTicketAlreadySettled: "renderTicketAlreadySettled"
        case .designTargetUnavailable: "designTargetUnavailable"
        case .designConflict: "designConflict"
        case .designPublicationPending: "designPublicationPending"
        case .designPreviewTooLarge: "designPreviewTooLarge"
        case .designPayloadTooLarge: "designPayloadTooLarge"
        case .designPayloadMissing: "designPayloadMissing"
        case .designPublicationUnavailable: "designPublicationUnavailable"
        }
    }

    public var retryable: Bool {
        switch self {
        case .generationUnavailable, .modelUnavailable, .providerTimeout,
             .rendererUnavailable, .insufficientStorage, .designTargetUnavailable:
            true
        default:
            false
        }
    }
}

// MARK: - Closed state spellings

public enum G09R2GenerationKind: String, Codable, Sendable, CaseIterable {
    case image
    case video
}

public enum G09R2ImageRequestState: String, Codable, Sendable, CaseIterable {
    case submitted
    case running
    case completed
    case failed
    case interrupted
    case outcomeUnknown
    case dismissed
}

public enum G09R2MediaJobState: String, Codable, Sendable, CaseIterable {
    case submitted
    case running
    case waitingForProvider
    case downloading
    case completed
    case failed
    case cancelled
    case interrupted
    case outcomeUnknown
}

public enum G09R2CandidateState: String, Codable, Sendable, CaseIterable {
    case pending
    case accepted
    case rejected
    case stale
}

public enum G09R2CandidateDeliveryOutcome: String, Codable, Sendable, CaseIterable {
    case ready
    case notReady
    case outcomeUnknown
}

public enum G09R2MediaExportKind: String, Codable, Sendable, CaseIterable {
    case preview
    case image
    case video
}

public enum G09R2MediaExportState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case verifying
    case completed
    case cancelled
    case failed
    case interrupted
    case timeout
}

public enum G09R2RenderTicketReplyStatus: String, Codable, Sendable, CaseIterable {
    case completed
    case failed
    case cancelled
    case timeout
    case unsupported
}

public enum G09R2MediaExportRoute: String, Codable, Sendable, CaseIterable {
    /// A real renderer route through the bounded MediaRenderTicket transport.
    case renderTicket
    /// No real renderer is connected; export must be reported unavailable.
    case unavailable
}

/// Video command `type` names; each maps one-to-one to the shared Swift
/// `MediaEditCommand` transaction engine. The Kotlin R2 contract freezes the
/// same list.
public enum G09R2VideoCommandKind: String, Codable, Sendable, CaseIterable {
    case appendClip
    case updateClip
    case reorderClips
    case splitClip
    case duplicateClip
    case removeClip
    case setPrimaryAudio
    case setCover
    case shiftCaptions
    case addMusic
    case updateMusic
    case removeMusic
    case addCaption
    case updateCaption
    case removeCaption
    case setCaptionStyle
    case setCanvas
}

public enum G09R2DesignAction: String, Codable, Sendable, CaseIterable {
    case canvasSnapshot = "design.canvas.snapshot"
    case canvasMutate = "design.canvas.mutate"
    case canvasAdopt = "design.canvas.adopt"
    case canvasCompare = "design.canvas.compare"
    case canvasRestore = "design.canvas.restore"
    case canvasExport = "design.canvas.export"
    case canvasPreview = "design.canvas.preview"
    case ownerState = "design.owner.state"
    case ownerBrief = "design.owner.brief"
    case ownerSpec = "design.owner.spec"
    case ownerFreeze = "design.owner.freeze"
    case ownerPropose = "design.owner.propose"
    case ownerAdopt = "design.owner.adopt"
    case ownerReject = "design.owner.reject"
    case ownerCompare = "design.owner.compare"
    case ownerRestore = "design.owner.restore"
    case ownerExport = "design.owner.export"
    case ownerPreview = "design.owner.preview"
}

public enum G09R2LargeImportKind: String, Codable, Sendable, CaseIterable {
    case image
    case audio
    case video
}

/// Streamed large-import policy. The generic Canvas 64 MiB ceiling is
/// intentionally not raised; these are per-kind ceilings for the dedicated
/// streamed path.
public enum G09R2LargeImportPolicy {
    public static let duplicationFactor: Int64 = 2

    public static func maxBytes(for kind: G09R2LargeImportKind) -> Int64 {
        switch kind {
        case .image: G09R2CreativeLimits.importImageBytes
        case .audio: G09R2CreativeLimits.importAudioBytes
        case .video: G09R2CreativeLimits.importVideoBytes
        }
    }

    public static func accepts(_ kind: G09R2LargeImportKind, byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maxBytes(for: kind)
    }

    /// Two copies of the source (staging + final) plus bounded headroom.
    /// Saturates instead of overflowing.
    public static func requiredFreeBytes(sourceBytes: Int64) -> Int64 {
        guard sourceBytes > 0 else { return 0 }
        let headroom = G09R2CreativeLimits.importDiskHeadroomBytes
        guard sourceBytes <= (Int64.max - headroom) / duplicationFactor else {
            return Int64.max
        }
        return sourceBytes * duplicationFactor + headroom
    }
}

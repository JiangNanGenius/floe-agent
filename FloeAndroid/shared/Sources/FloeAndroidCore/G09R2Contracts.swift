// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — additive DTOs and closed wire projections shared by a later native
// implementation and the Kotlin R2 consumer contracts.
//
// This file contains NO service, actor, store, provider call, filesystem or
// bridge dispatch. It only freezes request/response shapes, the typed video
// command decoder (mapped to the EXISTING shared transaction engine), and the
// render-ticket/design value shapes. V1–V5 and every R1 file remain untouched.
import Foundation
import FloeCore
import FloeAndroidWorkbench

// MARK: - Explicit project context

/// The exact trusted project/editor identity every R2 media request carries.
/// The host re-resolves the accepted epoch separately. `storage` is explicit
/// and never inferred from a recorded project field. `origin` is provenance
/// only.
public struct G09R2ProjectContextDTO: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var sessionToken: String
    public var storage: G09StorageLayerDTO
    public var origin: G09CreativeOriginDTO?

    public init(projectID: UUID, sessionToken: String,
                storage: G09StorageLayerDTO, origin: G09CreativeOriginDTO? = nil) {
        self.projectID = projectID
        self.sessionToken = sessionToken
        self.storage = storage
        self.origin = origin
    }
}

// MARK: - Video

public struct G09R2VideoLoadRequest: Decodable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
}

public struct G09R2VideoApplyRequest: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var opID: String
    public var commands: [G09R2VideoCommandWire]
}

/// Trusted typed read envelope. `project` is the real native project;
/// `timeline` is its typed `videoTimeline` projection. `mediaRootPath` is
/// read-only and never accepted back as a write root.
public struct G09R2VideoEnvelopeDTO: Encodable, Sendable {
    public var project: MediaProject
    public var timeline: VideoTimeline
    public var mediaRootPath: String
    public var storage: G09StorageLayerDTO
    public var writable: Bool
    public var warnings: [String]
}

/// Closed R2 command vocabulary mapped one-to-one to the shared Swift
/// `MediaEditCommand` cases. Fields use the exact shared model keys. `crop`
/// keeps the explicit three-way state object.
public enum G09R2VideoCommandWire: Decodable, Sendable {
    case appendClip(VideoClip)
    case updateClip(
        id: UUID,
        trimStart: Double?,
        trimEnd: Double?,
        speed: Double?,
        volume: Double?,
        isMuted: Bool?,
        rotationDegrees: Double?,
        crop: G09OptionalUpdateWire<NormalizedRect>,
        leadingTransition: VideoTransitionKind?,
        transitionDuration: Double?)
    case reorderClips(orderedIDs: [UUID])
    case splitClip(id: UUID, atTimelineSeconds: Double)
    case duplicateClip(id: UUID)
    case removeClip(id: UUID)
    case setPrimaryAudio(volume: Double?, muted: Bool?)
    case setCover(time: Double?)
    case shiftCaptions(bySeconds: Double)
    case addMusic(MusicClip)
    case updateMusic(
        id: UUID,
        offsetSeconds: Double?,
        trimStart: Double?,
        lengthSeconds: Double?,
        volume: Double?,
        fadeInSeconds: Double?,
        fadeOutSeconds: Double?)
    case removeMusic(id: UUID)
    case addCaption(CaptionSegment)
    case updateCaption(id: UUID, start: Double?, end: Double?, text: String?)
    case removeCaption(id: UUID)
    case setCaptionStyle(CaptionStyle)
    case setCanvas(width: Int, height: Int, frameRate: Double?)

    private enum CodingKeys: String, CodingKey {
        case type
        case clip, id, trimStart, trimEnd, speed, volume, isMuted, rotationDegrees
        case crop, leadingTransition, transitionDuration
        case orderedIDs, atTimelineSeconds, muted, time, bySeconds
        case music, offsetSeconds, lengthSeconds, fadeInSeconds, fadeOutSeconds
        case caption, start, end, text, style
        case width, height, frameRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(G09R2VideoCommandKind.self, forKey: .type) {
        case .appendClip:
            self = .appendClip(try container.decode(VideoClip.self, forKey: .clip))
        case .updateClip:
            self = .updateClip(
                id: try container.decode(UUID.self, forKey: .id),
                trimStart: try container.decodeIfPresent(Double.self, forKey: .trimStart),
                trimEnd: try container.decodeIfPresent(Double.self, forKey: .trimEnd),
                speed: try container.decodeIfPresent(Double.self, forKey: .speed),
                volume: try container.decodeIfPresent(Double.self, forKey: .volume),
                isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted),
                rotationDegrees: try container.decodeIfPresent(Double.self, forKey: .rotationDegrees),
                crop: try container.decode(
                    G09OptionalUpdateWire<NormalizedRect>.self, forKey: .crop),
                leadingTransition: try container.decodeIfPresent(
                    VideoTransitionKind.self, forKey: .leadingTransition),
                transitionDuration: try container.decodeIfPresent(
                    Double.self, forKey: .transitionDuration))
        case .reorderClips:
            self = .reorderClips(orderedIDs: try container.decode([UUID].self, forKey: .orderedIDs))
        case .splitClip:
            self = .splitClip(
                id: try container.decode(UUID.self, forKey: .id),
                atTimelineSeconds: try container.decode(Double.self, forKey: .atTimelineSeconds))
        case .duplicateClip:
            self = .duplicateClip(id: try container.decode(UUID.self, forKey: .id))
        case .removeClip:
            self = .removeClip(id: try container.decode(UUID.self, forKey: .id))
        case .setPrimaryAudio:
            self = .setPrimaryAudio(
                volume: try container.decodeIfPresent(Double.self, forKey: .volume),
                muted: try container.decodeIfPresent(Bool.self, forKey: .muted))
        case .setCover:
            self = .setCover(time: try container.decodeIfPresent(Double.self, forKey: .time))
        case .shiftCaptions:
            self = .shiftCaptions(
                bySeconds: try container.decode(Double.self, forKey: .bySeconds))
        case .addMusic:
            self = .addMusic(try container.decode(MusicClip.self, forKey: .music))
        case .updateMusic:
            self = .updateMusic(
                id: try container.decode(UUID.self, forKey: .id),
                offsetSeconds: try container.decodeIfPresent(Double.self, forKey: .offsetSeconds),
                trimStart: try container.decodeIfPresent(Double.self, forKey: .trimStart),
                lengthSeconds: try container.decodeIfPresent(Double.self, forKey: .lengthSeconds),
                volume: try container.decodeIfPresent(Double.self, forKey: .volume),
                fadeInSeconds: try container.decodeIfPresent(Double.self, forKey: .fadeInSeconds),
                fadeOutSeconds: try container.decodeIfPresent(Double.self, forKey: .fadeOutSeconds))
        case .removeMusic:
            self = .removeMusic(id: try container.decode(UUID.self, forKey: .id))
        case .addCaption:
            self = .addCaption(try container.decode(CaptionSegment.self, forKey: .caption))
        case .updateCaption:
            self = .updateCaption(
                id: try container.decode(UUID.self, forKey: .id),
                start: try container.decodeIfPresent(Double.self, forKey: .start),
                end: try container.decodeIfPresent(Double.self, forKey: .end),
                text: try container.decodeIfPresent(String.self, forKey: .text))
        case .removeCaption:
            self = .removeCaption(id: try container.decode(UUID.self, forKey: .id))
        case .setCaptionStyle:
            self = .setCaptionStyle(try container.decode(CaptionStyle.self, forKey: .style))
        case .setCanvas:
            self = .setCanvas(
                width: try container.decode(Int.self, forKey: .width),
                height: try container.decode(Int.self, forKey: .height),
                frameRate: try container.decodeIfPresent(Double.self, forKey: .frameRate))
        }
    }

    /// Converts to the original shared command. No second edit engine exists.
    public func sharedCommand() -> MediaEditCommand {
        switch self {
        case .appendClip(let clip):
            return .appendClip(clip)
        case .updateClip(let id, let trimStart, let trimEnd, let speed, let volume,
                         let isMuted, let rotationDegrees, let crop,
                         let leadingTransition, let transitionDuration):
            return .updateClip(
                id: id, trimStart: trimStart, trimEnd: trimEnd, speed: speed,
                volume: volume, isMuted: isMuted, rotationDegrees: rotationDegrees,
                crop: crop.mapped { $0 },
                leadingTransition: leadingTransition,
                transitionDuration: transitionDuration)
        case .reorderClips(let orderedIDs):
            return .reorderClips(orderedIDs: orderedIDs)
        case .splitClip(let id, let atTimelineSeconds):
            return .splitClip(id: id, atTimelineSeconds: atTimelineSeconds)
        case .duplicateClip(let id):
            return .duplicateClip(id: id)
        case .removeClip(let id):
            return .removeClip(id: id)
        case .setPrimaryAudio(let volume, let muted):
            return .setPrimaryAudio(volume: volume, muted: muted)
        case .setCover(let time):
            return .setCover(time: time)
        case .shiftCaptions(let bySeconds):
            return .shiftCaptions(bySeconds: bySeconds)
        case .addMusic(let music):
            return .addMusic(music)
        case .updateMusic(let id, let offsetSeconds, let trimStart, let lengthSeconds,
                          let volume, let fadeInSeconds, let fadeOutSeconds):
            return .updateMusic(
                id: id, offsetSeconds: offsetSeconds, trimStart: trimStart,
                lengthSeconds: lengthSeconds, volume: volume,
                fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds)
        case .removeMusic(let id):
            return .removeMusic(id: id)
        case .addCaption(let caption):
            return .addCaption(caption)
        case .updateCaption(let id, let start, let end, let text):
            return .updateCaption(id: id, start: start, end: end, text: text)
        case .removeCaption(let id):
            return .removeCaption(id: id)
        case .setCaptionStyle(let style):
            return .setCaptionStyle(style)
        case .setCanvas(let width, let height, let frameRate):
            return .setCanvas(width: width, height: height, frameRate: frameRate)
        }
    }
}

// MARK: - Generation

public struct G09R2CodecContractDTO: Codable, Sendable, Equatable {
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
}

public struct G09R2GenerationParameterContractDTO: Codable, Sendable, Equatable {
    public var sizes: [String]?
    public var aspectRatios: [String]?
    public var resolutions: [String]?
    public var durationSeconds: [Double]?
    public var maxCount: Int
    public var maxReferenceImages: Int
    public var supportsImageToVideo: Bool
    public var supportsFirstFrame: Bool
    public var codecs: [G09R2CodecContractDTO]
}

/// Per-route reference bounds. The native host validates an owned project
/// asset; an arbitrary URL never enters this policy.
public struct G09R2ReferenceImagePolicyDTO: Codable, Sendable, Equatable {
    public var maxImages: Int
    public var maxBytesPerImage: Int64
    public var acceptedMimeTypes: [String]
    public var minWidth: Int?
    public var maxWidth: Int?
    public var minHeight: Int?
    public var maxHeight: Int?
}

public struct G09R2ModelRouteDTO: Codable, Sendable, Equatable {
    public var routeID: String
    public var remoteModelID: String
    public var providerID: String
    public var providerName: String
    public var kind: G09R2GenerationKind
    public var enabled: Bool
    public var available: Bool
    public var unavailableReason: String?
    public var parameters: G09R2GenerationParameterContractDTO
    public var referenceImagePolicy: G09R2ReferenceImagePolicyDTO
    /// Provider-reported note or the honest account-authoritative wording;
    /// never a hard-coded price.
    public var costNote: String
}

public struct G09R2ModelCatalogDTO: Codable, Sendable, Equatable {
    public var image: [G09R2ModelRouteDTO]
    public var video: [G09R2ModelRouteDTO]
}

public struct G09R2ImageGenerationRequestDTO: Codable, Sendable, Equatable {
    public var prompt: String
    public var modelRouteID: String
    public var size: String?
    public var count: Int
    public var sourceAssetID: UUID?
    public var referenceAssetIDs: [UUID]
    public var idempotencyKey: String
}

public struct G09R2VideoGenerationRequestDTO: Codable, Sendable, Equatable {
    public var prompt: String
    public var modelRouteID: String
    public var durationSeconds: Double?
    public var aspectRatio: String?
    public var resolution: String?
    public var sourceAssetID: UUID?
    public var referenceAssetIDs: [UUID]
    public var idempotencyKey: String
}

public struct G09R2ImageSubmitRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var opID: String
    public var request: G09R2ImageGenerationRequestDTO
}

public struct G09R2ImageStatusRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var requestID: String
}

public struct G09R2ImageDismissRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var requestID: String
    public var opID: String
}

public struct G09R2VideoSubmitRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var opID: String
    public var request: G09R2VideoGenerationRequestDTO
}

public struct G09R2JobStatusRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var jobID: String
}

public struct G09R2JobCancelRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var jobID: String
    public var opID: String
}

public struct G09R2JobDeliverRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var jobID: String
    public var opID: String
}

public struct G09R2CandidatesRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
}

public struct G09R2CandidateAcceptRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var candidateID: String
    public var opID: String
}

public struct G09R2CandidateRejectRequest: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var candidateID: String
    public var opID: String
}

public struct G09R2ImageRequestHandleDTO: Codable, Sendable, Equatable {
    public var requestID: String
    public var projectID: UUID
    public var acceptedAt: Date
    public var state: G09R2ImageRequestState
    public var idempotent: Bool
}

public struct G09R2VideoJobHandleDTO: Codable, Sendable, Equatable {
    public var jobID: String
    public var projectID: UUID
    public var acceptedAt: Date
    public var state: G09R2MediaJobState
    public var idempotent: Bool
}

/// UI-safe candidate. `relativePath` is a native-verified safe relative path;
/// no absolute path, provider task ID or credential is present.
public struct G09R2CandidateDTO: Codable, Sendable, Equatable {
    public var candidateID: String
    public var projectID: UUID
    public var kind: G09R2GenerationKind
    public var modelDisplayName: String?
    public var createdAt: Date
    public var byteCount: Int64
    public var sha256: String
    public var relativePath: String
    public var requestID: String?
    public var state: G09R2CandidateState
}

public struct G09R2ImageRequestStatusDTO: Codable, Sendable, Equatable {
    public var requestID: String
    public var projectID: UUID
    public var state: G09R2ImageRequestState
    public var submittedAt: Date
    public var updatedAt: Date
    public var candidate: G09R2CandidateDTO?
    public var errorCode: String?
    public var retryable: Bool
}

public struct G09R2JobStatusDTO: Codable, Sendable, Equatable {
    public var jobID: String
    public var projectID: UUID
    public var state: G09R2MediaJobState
    public var updatedAt: Date
    public var progressHint: Double?
    public var resultAvailable: Bool
    /// Presence only; the raw provider task ID never leaves the host.
    public var providerTaskReferencePresent: Bool
    public var lastErrorCode: String?
    public var retryable: Bool
    public var canCancel: Bool
}

public struct G09R2DeliveredCandidateDTO: Codable, Sendable, Equatable {
    public var outcome: G09R2CandidateDeliveryOutcome
    public var candidate: G09R2CandidateDTO?
    public var reason: String?
}

public struct G09R2CandidateMutationReceiptDTO: Codable, Sendable, Equatable {
    public var candidateID: String
    public var projectID: UUID
    public var state: G09R2CandidateState
    public var opID: String
    public var idempotent: Bool
}

// MARK: - Design

public struct G09R2DesignBindingDTO: Codable, Sendable, Equatable {
    public var target: DesignTarget
    public var storage: G09StorageLayerDTO
    public var origin: G09CreativeOriginDTO?
    public var sessionToken: String

    public init(target: DesignTarget, storage: G09StorageLayerDTO,
                origin: G09CreativeOriginDTO? = nil, sessionToken: String) {
        self.target = target
        self.storage = storage
        self.origin = origin
        self.sessionToken = sessionToken
    }
}

public struct G09R2DesignStatusDTO: Encodable, Sendable, Equatable {
    public var bound: Bool
    public var epoch: UInt64?
    public var rootFingerprint: String?
    public var availableTargetKinds: [String]
    public var targetKindReasons: [String: String]
    public var availableActions: [String]
    public var maxProposalBytes: Int64
    public var maxPreviewBytes: Int
}

/// Read projection of the REAL shared owner envelope. `project` is the
/// canonical shared `DesignProject`; no parallel design store exists.
public struct G09R2DesignStateDTO: Codable, Sendable, Equatable {
    public var envelope: DesignOwnerEnvelope
    public var writable: Bool
    public var warnings: [String]
    public var availableActions: [String]
}

public struct G09R2DesignStateRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
}

public struct G09R2DesignBindRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64?
    public var opID: String
}

public struct G09R2DesignBriefRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var brief: DesignBrief
}

public struct G09R2DesignSpecRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var spec: DesignSpec
}

public struct G09R2StagedDesignPayloadDTO: Codable, Sendable, Equatable {
    /// Opaque staging token; bytes never travel in bridge JSON.
    public var token: String
    public var format: String
    public var byteCount: Int64
    public var sha256: String
}

public struct G09R2DesignFreezeRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var inputRevisionID: String?
    public var specSHA256: String?
    public var targetRevisionID: String?
    public var desiredFormat: String?
    public var workMode: DesignWorkMode?
    public var preservationDigest: String?
}

public struct G09R2DesignFreezeReceiptDTO: Codable, Sendable, Equatable {
    public var target: DesignTarget
    public var ownerRevision: Int64
    public var frozenRun: DesignRunFrozen
    public var idempotent: Bool
}

public struct G09R2DesignProposeRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var artifactID: String
    public var baseRevisionID: String?
    public var payload: G09R2StagedDesignPayloadDTO
    public var summary: String
    public var diff: [String]
    public var feedbackIDs: [String]
    /// Frozen typed intent; a restructure still requires the trusted
    /// confirmation claim before any payload is staged.
    public var workIntent: DesignWorkIntent?
}

public struct G09R2DesignProposalResultDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignStateDTO
    public var candidate: DesignCandidate
    public var payloadRelativePath: String
    public var replayed: Bool
}

public struct G09R2DesignAdoptRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var candidateID: String
    public var mode: DesignAdoptMode
}

public struct G09R2DesignRejectRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var candidateID: String
    public var reason: String?
}

public struct G09R2DesignCompareRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var candidateID: String
}

public struct G09R2DesignComparisonDTO: Codable, Sendable, Equatable {
    public var candidateID: String
    public var baseSHA256: String
    public var proposedSHA256: String
    public var changed: Bool
    public var diff: [String]
    public var diffTruncated: Bool
    public var diffNote: String?
    public var status: DesignCandidateStatus
}

public struct G09R2DesignRestoreRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var expectedRevision: Int64
    public var opID: String
    public var revisionID: String
}

public enum G09R2DesignDeliveryState: String, Codable, Sendable, CaseIterable {
    case notRequired
    case delivered
    case pending
}

public struct G09R2DesignDeliveryDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignDeliveryState
    public var reason: String?
}

public enum G09R2DesignPublicationState: String, Codable, Sendable, CaseIterable {
    case notRequired
    case published
    case pending
}

/// True destination identity for an immutable owner; `pending` is never
/// presented as success.
public struct G09R2DesignPublicationDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignPublicationState
    public var identifier: String?
    public var destination: String?
    public var contentSHA256: String?
    public var reason: String?
}

public struct G09R2DesignDecisionResultDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignStateDTO
    public var candidateID: String
    public var operationID: String
    public var idempotent: Bool
    public var committedRevisionToken: String?
    public var delivery: G09R2DesignDeliveryDTO
    public var publication: G09R2DesignPublicationDTO
}

public struct G09R2DesignDecisionReceiptDTO: Codable, Sendable, Equatable {
    public var state: G09R2DesignStateDTO
    public var candidateID: String
    public var operationID: String
    public var idempotent: Bool
}

public struct G09R2DesignPreviewRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var candidateID: String?
    public var revisionID: String?
    public var maxBytes: Int
}

/// Verified preview file receipt; never inline bytes and never a bare success.
public struct G09R2DesignPreviewReceiptDTO: Codable, Sendable, Equatable {
    public var target: DesignTarget
    public var ownerRevision: Int64
    public var candidateID: String?
    public var revisionID: String?
    public var format: String
    /// Native-issued trusted root; never a recorded design/project path.
    public var rootPath: String
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    public var width: Int?
    public var height: Int?
    public var createdAt: Date
}

public struct G09R2DesignExportRequest: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var candidateID: String?
    public var revisionID: String?
    public var format: String
    public var suggestedFileName: String?
}

public struct G09R2DesignExportReceiptDTO: Codable, Sendable, Equatable {
    public var target: DesignTarget
    public var ownerRevision: Int64
    public var candidateID: String?
    public var revisionID: String?
    public var format: String
    /// Native-issued trusted root; never a recorded design/project path.
    public var rootPath: String
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    public var createdAt: Date
}

// MARK: - Render ticket / platform receipts

/// Native-issued immutable snapshot lease. The platform opens
/// `mediaRootPath + "/" + relativePath`; it never reopens a mutable latest
/// project and never derives a root from recorded project JSON.
public struct G09R2RenderSnapshotLeaseDTO: Codable, Sendable, Equatable {
    public var leaseID: String
    /// Native-issued trusted media root; never a recorded project path.
    public var mediaRootPath: String
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int64
    public var expiresAt: Date
}

public struct G09R2RenderSnapshotRequestDTO: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var expectedRevision: Int64
    public var expectedTimelineDigest: String
}

public struct G09R2MediaExportBindingDTO: Codable, Sendable, Equatable {
    public var context: G09R2ProjectContextDTO
    public var mediaRootPath: String
    public var projectRevision: Int64
    public var timelineDigest: String
    public var attemptID: String
    public var snapshot: G09R2RenderSnapshotLeaseDTO
}

public struct G09R2PreviewWindowDTO: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var durationSeconds: Double
}

public struct G09R2VideoExportSettingsDTO: Codable, Sendable, Equatable {
    public var codecMime: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var quality: Double
    public var fileName: String
}

public struct G09R2ImageExportSettingsDTO: Codable, Sendable, Equatable {
    public var format: String
    public var width: Int?
    public var height: Int?
    public var quality: Double
    public var preserveTransparency: Bool
    public var stripMetadata: Bool
    public var fileName: String
}

/// Closed typed render purpose for a C03 selection copy. The complete
/// selection itself comes from the verified project snapshot; this only names
/// the source layer so the native IMAGE renderer can apply the whole-canvas
/// adjustment first and the project selection last, exactly like the App UI
/// and fixed iOS. It is never inferred from a project name or attempt prefix.
public struct G09R2ImageCopySelectionDTO: Codable, Sendable, Equatable {
    public var sourceLayerID: UUID

    public init(sourceLayerID: UUID) {
        self.sourceLayerID = sourceLayerID
    }
}

public struct G09R2ExportVerificationDTO: Codable, Sendable, Equatable {
    public var playable: Bool
    public var decodedDurationSeconds: Double?
    public var width: Int
    public var height: Int
    public var audioTrackCount: Int
    public var container: String
    public var codec: String
}

/// Receipt identity only; it deliberately does not echo the editor session
/// token from `G09R2MediaExportBindingDTO`.
public struct G09R2MediaExportReceiptBindingDTO: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var mediaRootPath: String
    public var projectRevision: Int64
    public var timelineDigest: String
    public var attemptID: String
}

public struct G09R2MediaExportReceiptDTO: Codable, Sendable, Equatable {
    public var binding: G09R2MediaExportReceiptBindingDTO
    public var kind: G09R2MediaExportKind
    public var outputRelativePath: String
    public var mimeType: String
    public var byteCount: Int64
    public var sha256: String
    public var verification: G09R2ExportVerificationDTO
    public var completedAt: Date
}

/// Native-issued descriptor for the bounded render-ticket transport. It
/// carries a snapshot FILE lease/reference, not the project JSON.
public struct G09R2RenderTicketDescriptorDTO: Codable, Sendable, Equatable {
    public var ticketID: String
    public var descriptorVersion: Int
    public var kind: G09R2MediaExportKind
    public var projectID: UUID
    /// Attempt identity bound to the native export binding.
    public var attemptID: String
    /// Native-issued trusted media root; never a recorded project path.
    public var mediaRootPath: String
    /// Explicit storage layer bound to this ticket.
    public var storage: G09StorageLayerDTO
    /// Real route provenance when one exists; never storage authority.
    public var origin: G09CreativeOriginDTO?
    public var projectRevision: Int64
    public var timelineDigest: String
    public var leaseID: String
    public var ownerReference: String
    public var epoch: UInt64
    public var snapshotRelativePath: String
    public var snapshotSHA256: String
    public var snapshotByteCount: Int64
    /// Expiry of the native snapshot lease; an expired lease is refused.
    public var snapshotLeaseExpiresAt: Date
    public var outputRelativePath: String
    public var videoSettings: G09R2VideoExportSettingsDTO?
    public var imageSettings: G09R2ImageExportSettingsDTO?
    public var previewWindow: G09R2PreviewWindowDTO?
    public var expiresAt: Date
    public var descriptorByteCount: Int
    /// Optional C03 render purpose; nil on every pre-C03 caller, so their
    /// descriptor JSON and render behavior stay unchanged.
    public var copySelection: G09R2ImageCopySelectionDTO? = nil
}

public struct G09R2ClaimedRenderTicketDTO: Codable, Sendable, Equatable {
    public var descriptor: G09R2RenderTicketDescriptorDTO
    public var claimToken: String
    public var claimedAt: Date
    public var leaseExpiresAt: Date
}

public struct G09R2RenderTicketReplyDTO: Codable, Sendable, Equatable {
    public var ticketID: String
    public var status: G09R2RenderTicketReplyStatus
    public var receipt: G09R2MediaExportReceiptDTO?
    public var errorCode: String?
    public var completedAt: Date
    public var replyByteCount: Int
}

public struct G09R2RenderTicketStatsDTO: Codable, Sendable, Equatable {
    public var live: Int
    public var claimed: Int
    public var completed: Int
    public var cancelled: Int
    public var failed: Int
    public var maxLive: Int
    public var lastErrorCode: String?
}

public struct G09R2MediaProjectToolExportCapabilityDTO: Codable, Sendable, Equatable {
    public var route: G09R2MediaExportRoute
    public var registered: Bool
    public var reason: String?
    public var supportedActions: [String]
}

public struct G09R2MediaProjectToolExportSubmissionDTO: Codable, Sendable, Equatable {
    public var ticketID: String
    public var leaseID: String
    public var projectRevision: Int64
    public var acceptedAt: Date
}

public struct G09R2StagedImportMetadataDTO: Codable, Sendable, Equatable {
    public var token: String
    public var kind: G09R2LargeImportKind
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
}

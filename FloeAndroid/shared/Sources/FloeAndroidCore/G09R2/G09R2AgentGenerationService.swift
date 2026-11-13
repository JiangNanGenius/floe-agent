// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent (model-facing) generation — conversation-owned durable jobs
// (job-8e175eef3cea48d3 bindings; job-6b686caa5ffe4761 integration/correctness
// closure).
//
// The Android build had the real UI-driven generation backend
// (`G09R2GenerationService`, document-owned candidates) but NO model-facing
// bindings: `rg` found image.generate/video.generate only in discovery
// guidance. This service is the minimal original-tool backend reuse: the
// exact provider route resolution, adapters, credentials and durable job
// store the UI flow already uses, exposed for conversation-owned chat jobs
// that deliver readable artifacts into the task workspace.
//
// Lifecycle authority (6b686caa closure): workers, root-stop, cancellation
// and the bounded live-worker table are the SHARED `G09R2GenerationService`
// machinery — no second engine, no second job store, no untracked overflow
// tasks. `startWorker` returning false (root stopping / table full) is
// honored at every call site.
//
// Settlement + pinned-delivery authority (this closure):
//  * A generic provider/transport error AFTER the paid request was
//    dispatched is durable `outcomeUnknown` — never a definite failure —
//    unless a typed provider rejection proves non-acceptance. Local worker
//    stop, network interruption or poll-budget exhaustion never settles an
//    accepted remote job terminal: the retained provider handle stays
//    queryable through `video.status(refresh:)` / relaunch resume, and no
//    automatic resubmission ever happens.
//  * The provider task ID persisted at acceptance survives a cancel race: a
//    provider-confirmed cancel settles `cancelled`, a provider cancel failure
//    keeps the row truthful (non-terminal), and a completion that already
//    landed keeps its real terminal state.
//  * The ORIGINAL validated workspace target is pinned at submission from the
//    original conversation-ownership resolver and revalidated before any
//    delivered byte is committed; an explicit migration/revocation fences the
//    delivery (definite `targetChanged`) instead of publishing into a new
//    owner. The current workspace is never chosen, never reconstructed.
//
// Outcome-repair authority (preparing→expired device failure):
//  * The run-launch recovery pump (`resumeStaleJobs`) applies the SAME
//    `stalePreparingSeconds` freshness gate as `status(refresh:)`: a
//    handle-less preparing/submitted row younger than the bound is owned by
//    a starting worker and is never classified unknown. The pump is
//    fire-and-forget and can interleave between a submission's durable row
//    insert and its worker registration; without the gate it expired
//    brand-new jobs as `outcomeUnknown` before any dispatch.
//  * One-shot image delivery commits the artifact receipt with the poll
//    worker's CAS discipline: once verified bytes are durable in the pinned
//    workspace, a late local stop cannot strand them behind an
//    `outcomeUnknown` row; a cancel that raced the commit keeps its real
//    terminal state.
//
// Lifetime-repair authority (Full112 `expired/outcomeUnknown` evidence):
//  * Image outputs use deterministic job-identified names
//    (`image-<jobID>-<index>.<ext>`) AND an App-owned producer receipt
//    recorded from the REAL provider-returned bytes BEFORE workspace
//    publication (job/request/owner binding, count, MIME, size, SHA-256).
//    Bytes written before a process/worker death are recoverable; a refresh/
//    relaunch adopts them ONLY when every workspace byte matches that durable
//    receipt, with the FULL requested batch, in the ORIGINAL pinned
//    workspace. A filename, a valid PNG or a self-computed hash is never
//    delivery authority. No provider call is made; a partial batch, a
//    migrated/revoked owner, a missing/tampered receipt or an already-
//    terminal row is never claimed.
//  * A provider result that arrives before a local worker stop is still
//    written and receipted: cancelling a local waiter is not proof the
//    provider failed, and a paid result is never discarded.
//  * A replayed tool call (same submitting-operation identity AND exact
//    request) attaches to its ORIGINAL durable row even after that row is
//    terminal. A lost reply or a replayed unknown/finished call therefore
//    never triggers a second paid submission; a distinct request still
//    creates a new job.
//
// Unknown-outcome anti-retry authority (Full114 fifth-submission defect):
//  * A changed prompt/model/provider/tool call cannot buy a replacement in
//    the same trusted conversation+origin run while a handle-less paid
//    submission from that run is durable `outcomeUnknown`. The store checks
//    and inserts in ONE write transaction; the generation worker re-checks
//    before its first provider call so a retry inserted just BEFORE the
//    unknown settlement cannot still dispatch. The original unknown row is
//    preserved and returned; a new run or another conversation is unaffected,
//    and initial independent concurrent submissions still all dispatch.
//  * Source-confirmed provider/lifetime wiring repair: image requests and
//    provider-issued result downloads use the bound non-streaming session
//    (300 s request / 900 s resource, `StreamingTransport` on Android)
//    instead of the generic `.shared` session and a custom download session
//    that failed closed with `sessionNotStreamable` AFTER the provider had
//    already returned a paid URL. The 16:39-16:44 Full114 settlement times
//    alone do not prove which path failed on that run: actual provider
//    dispatch/billing was never observed. Every failed image attempt now
//    records a bounded non-secret stage trace (`requestStarted`,
//    `responseReceived`, `imagesDecoded`, `downloadStarted`,
//    `downloadCompleted`) plus a failure-class code in the durable payload,
//    so the next focused run distinguishes dispatch/response/download/commit
//    without logging prompts, keys, endpoints or provider bodies.
//
// Contract fidelity to the immutable iOS donors
// (36f63bf400dfaa3a127259eac006b38d72516390:
//  FloeApp/Files/RemoteImageTools.swift, FloeApp/Conversations/RemoteVideoTools.swift):
//  * `model` / `modelID` are a mutually exclusive one-of; the public `model`
//    is preferred and an internal UUID is never demanded from the user.
//  * An explicit selection is exact: 401/404/429 is returned, never remapped.
//  * Only when NO selection is given may the preferred route be used, and a
//    definite 401/404/429 may try one fallback on the SAME billing channel.
//  * No fallback after cancellation, timeout, policy refusal, server error or
//    an unknown result; a running/timed-out/outcome-unknown job is never
//    resubmitted.
//  * A replayed tool call (same runID + toolCallID idempotency key) attaches
//    to the SAME durable job instead of paying twice; when a context carries
//    no provider call id the key is a deterministic digest of the exact
//    request, never a random UUID.
//  * video.status separates "submitted/unknown" from a delivered readable
//    artifact: a submit string alone never marks a task complete.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore
import FloePersistence
import FloeProviders
import FloeTransport
import FloeWorkspace

// MARK: - Durable payload

/// One delivered generated artifact: the REAL workspace-relative path, the
/// sniffed MIME/format, the measured byte count and the individual SHA-256.
/// A multi-image result is a typed array of these, never a comma-joined
/// string that is neither a path nor a digest.
public struct G09R2AgentGenerationArtifact: Codable, Sendable, Equatable {
    public var relativePath: String     // "GeneratedMedia/image-<id>-1.png"
    public var mimeType: String         // sniffed facts, never a guess
    public var byteCount: Int64
    public var sha256: String

    public init(relativePath: String, mimeType: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// One image in the App-owned producer receipt: the exact output identity
/// the provider bytes had BEFORE any workspace publication. This record is
/// persisted in the durable job row (not the model-writable workspace) and is
/// the only authority a later recovery may verify workspace bytes against.
public struct G09R2AgentGenerationProducerImage: Codable, Sendable, Equatable {
    public var index: Int
    public var relativePath: String
    public var mimeType: String
    public var byteCount: Int64
    public var sha256: String

    public init(index: Int, relativePath: String, mimeType: String,
                byteCount: Int64, sha256: String) {
        self.index = index
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// App-owned proof that the provider returned this exact image batch for this
/// exact durable request, recorded from the REAL returned bytes BEFORE any
/// workspace publication. `requestDigest` binds the receipt to the immutable
/// request identity (prompt/route/options/count/reference); the job/owner
/// fields bind it to the durable row. A recovery may adopt a workspace file
/// ONLY when its bytes match this receipt exactly; a filename, a valid PNG or
/// a self-computed hash is never sufficient.
public struct G09R2AgentGenerationProducerReceipt: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var jobID: UUID
    public var ownerKind: String
    public var ownerID: UUID
    public var requestDigest: String
    public var providerID: UUID
    public var modelID: UUID
    public var remoteModelID: String
    public var count: Int
    public var images: [G09R2AgentGenerationProducerImage]
    public var recordedAt: Date

    public init(schemaVersion: Int = 1, jobID: UUID, ownerKind: String,
                ownerID: UUID, requestDigest: String, providerID: UUID,
                modelID: UUID, remoteModelID: String, count: Int,
                images: [G09R2AgentGenerationProducerImage],
                recordedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.requestDigest = requestDigest
        self.providerID = providerID
        self.modelID = modelID
        self.remoteModelID = remoteModelID
        self.count = count
        self.images = images
        self.recordedAt = recordedAt
    }

    /// Exact producer proof equality, excluding the recording timestamp (a
    /// JSON Date round-trip must never be the reason a durable receipt is
    /// considered missing).
    func bindsSameProducerProof(
        as other: G09R2AgentGenerationProducerReceipt
    ) -> Bool {
        schemaVersion == other.schemaVersion
            && jobID == other.jobID
            && ownerKind == other.ownerKind
            && ownerID == other.ownerID
            && requestDigest == other.requestDigest
            && providerID == other.providerID
            && modelID == other.modelID
            && remoteModelID == other.remoteModelID
            && count == other.count
            && images == other.images
    }
}

/// Bounded, non-secret wire/settlement trace written ONLY when an image
/// attempt fails or a changed submission is refused by the unknown guard. It closes the historic observability gap (`lastError` was a single
/// `outcomeUnknown` string) by distinguishing:
///  * `requestStarted` but no `responseReceived` — provider call/transport;
///  * `responseReceived` without `imagesDecoded` — provider reply rejected or
///    unusable;
///  * `downloadStarted` without `downloadCompleted` — the paid result existed
///    as a provider URL but the local image download failed;
///  * `imagesDecoded` then a commit failure — verified bytes/commit.
/// Stage names are fixed enum spellings; `failureCode` is a bounded class
/// (HTTP status / URL error code / typed local reason), never a prompt, key,
/// endpoint or provider body.
public struct G09R2AgentGenerationDiagnostic: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var stages: [String]
    public var failureCode: String?
    /// The earlier unknown job that blocked a replacement dispatch, when the
    /// worker (not the insert transaction) caught the race.
    public var relatedJobID: UUID?
    public var recordedAt: Date

    public init(schemaVersion: Int = 1, stages: [String],
                failureCode: String? = nil, relatedJobID: UUID? = nil,
                recordedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.stages = Array(stages.prefix(12))
        self.failureCode = failureCode
        self.relatedJobID = relatedJobID
        self.recordedAt = recordedAt
    }
}

/// Thread-safe ordered recorder for the bounded, non-secret adapter wire
/// milestones. The observer is called from the provider adapter (and from
/// the image download loop), so recording must be synchronous, lock-bounded
/// and never block an `await`. Consecutive duplicates are collapsed and the
/// list is hard-capped: a malformed/chatty adapter cannot amplify a durable
/// diagnostic row.
final class G09R2WirePhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [String] = []
    private static let maximumStages = 12

    func record(_ phase: RemoteImageWirePhase) {
        lock.g04Locked {
            guard stages.count < Self.maximumStages else { return }
            guard stages.last != phase.rawValue else { return }
            stages.append(phase.rawValue)
        }
    }

    func snapshot() -> [String] {
        lock.g04Locked { stages }
    }
}

/// Exact request identity persisted BEFORE any provider call. Carried in the
/// original `media_generation_jobs.request_json`; never contains secrets.
public struct G09R2AgentGenerationPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var surface: String              // "chat"
    public var prompt: String
    public var routeID: String              // public selection name (remote id)
    public var providerID: UUID
    public var modelID: UUID
    public var remoteModelID: String
    public var count: Int
    public var size: String?
    public var aspectRatio: String?
    public var resolution: String?
    public var quality: String?
    public var durationSeconds: Int?
    public var includeAudio: Bool?
    public var watermark: Bool?
    public var seed: Int?
    public var referenceRelativePath: String?
    /// ORIGINAL validated delivery target pinned at submission: the durable
    /// conversation→workspace binding's identity and its store-derived root
    /// path. Authority metadata from the ORIGINAL workspace resolver only —
    /// never a model-provided root. Revalidated through the same resolver
    /// before any delivered byte is committed; an explicit migration or
    /// revocation fences the delivery instead of following the current root.
    public var targetWorkspaceID: UUID?
    public var targetWorkspaceRootPath: String?
    /// App-owned producer receipt recorded from the REAL provider-returned
    /// bytes BEFORE workspace publication. Recovery verifies workspace bytes
    /// against this trusted record; it is never derived from the workspace.
    public var producerReceipt: G09R2AgentGenerationProducerReceipt?
    /// Typed per-artifact delivery receipt (worker-set after the provider
    /// call). The authoritative delivery record for one OR many outputs.
    public var artifacts: [G09R2AgentGenerationArtifact]?
    /// Legacy single-artifact view: set exactly when the result has ONE
    /// artifact (never comma-joined); nil for multi-artifact results, whose
    /// truth lives in `artifacts`.
    public var workspaceRelativePath: String?
    public var deliveredByteCount: Int64?
    public var deliveredSHA256: String?
    /// Local (never provider) failure trace; excluded from every replay and
    /// request identity so recording it can never turn a replay into a
    /// conflict or a second paid submission.
    public var diagnostics: G09R2AgentGenerationDiagnostic?

    public init(schemaVersion: Int = 1, surface: String = "chat",
                prompt: String, routeID: String, providerID: UUID,
                modelID: UUID, remoteModelID: String, count: Int,
                size: String? = nil, aspectRatio: String? = nil,
                resolution: String? = nil, quality: String? = nil,
                durationSeconds: Int? = nil, includeAudio: Bool? = nil,
                watermark: Bool? = nil, seed: Int? = nil,
                referenceRelativePath: String? = nil,
                targetWorkspaceID: UUID? = nil,
                targetWorkspaceRootPath: String? = nil,
                diagnostics: G09R2AgentGenerationDiagnostic? = nil) {
        self.schemaVersion = schemaVersion
        self.surface = surface
        self.prompt = prompt
        self.routeID = routeID
        self.providerID = providerID
        self.modelID = modelID
        self.remoteModelID = remoteModelID
        self.count = count
        self.size = size
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.quality = quality
        self.durationSeconds = durationSeconds
        self.includeAudio = includeAudio
        self.watermark = watermark
        self.seed = seed
        self.referenceRelativePath = referenceRelativePath
        self.targetWorkspaceID = targetWorkspaceID
        self.targetWorkspaceRootPath = targetWorkspaceRootPath
        self.producerReceipt = nil
        self.diagnostics = diagnostics
    }

    /// The durable replay identity: everything except the local delivery
    /// fields, which the worker fills in after the provider call.
    func replayIdentityEquals(_ other: G09R2AgentGenerationPayload) -> Bool {
        var left = self
        var right = other
        left.artifacts = nil
        right.artifacts = nil
        left.workspaceRelativePath = nil
        right.workspaceRelativePath = nil
        left.deliveredByteCount = nil
        right.deliveredByteCount = nil
        left.deliveredSHA256 = nil
        right.deliveredSHA256 = nil
        left.producerReceipt = nil
        right.producerReceipt = nil
        left.diagnostics = nil
        right.diagnostics = nil
        return left == right
    }

    /// The exact request identity used by the replay pre-check. The pinned
    /// delivery target is deliberately excluded: a task/project move must not
    /// turn a replayed tool call into a SECOND paid submission. The old
    /// job's own delivery fence still decides where (or whether) its result
    /// may be published.
    func requestIdentityEquals(_ other: G09R2AgentGenerationPayload) -> Bool {
        var left = self
        var right = other
        left.targetWorkspaceID = nil
        right.targetWorkspaceID = nil
        left.targetWorkspaceRootPath = nil
        right.targetWorkspaceRootPath = nil
        return left.replayIdentityEquals(right)
    }

    /// Deterministic digest of the immutable request identity, used by the
    /// App-owned producer receipt. Delivery target and local delivery fields
    /// are excluded exactly like `requestIdentityEquals`.
    func requestDigest() -> String {
        var copy = self
        copy.targetWorkspaceID = nil
        copy.targetWorkspaceRootPath = nil
        copy.artifacts = nil
        copy.workspaceRelativePath = nil
        copy.deliveredByteCount = nil
        copy.deliveredSHA256 = nil
        copy.producerReceipt = nil
        copy.diagnostics = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return "" }
        return FloeDigest.sha256Hex(data)
    }

    /// Whether this stored payload is the SAME image request as the new tool
    /// arguments. Used before route resolution so a replayed call attaches to
    /// the existing durable row even if the route was disabled/removed after
    /// the original submission.
    func matchesImageRequest(
        prompt: String, selection: String?, legacyModelID: UUID?, count: Int,
        size: String?, aspectRatio: String?, resolution: String?, quality: String?,
        referenceRelativePath: String?
    ) -> Bool {
        guard self.prompt == prompt, self.count == count, self.size == size,
              self.aspectRatio == aspectRatio, self.resolution == resolution,
              self.quality == quality,
              self.referenceRelativePath == referenceRelativePath else {
            return false
        }
        if let legacyModelID {
            return routeID == legacyModelID.uuidString.lowercased()
        }
        if let selection, !selection.isEmpty {
            return remoteModelID.caseInsensitiveCompare(selection) == .orderedSame
        }
        return true
    }

    /// Whether this stored payload is the SAME video request as the new tool
    /// arguments (see `matchesImageRequest`).
    func matchesVideoRequest(
        prompt: String, selection: String?, legacyModelID: UUID?,
        aspectRatio: String?, resolution: String?, durationSeconds: Int?,
        includeAudio: Bool?, watermark: Bool?, seed: Int?,
        referenceRelativePath: String?
    ) -> Bool {
        guard self.prompt == prompt, self.aspectRatio == aspectRatio,
              self.resolution == resolution,
              self.durationSeconds == durationSeconds,
              self.includeAudio == includeAudio, self.watermark == watermark,
              self.seed == seed,
              self.referenceRelativePath == referenceRelativePath else {
            return false
        }
        if let legacyModelID {
            return routeID == legacyModelID.uuidString.lowercased()
        }
        if let selection, !selection.isEmpty {
            return remoteModelID.caseInsensitiveCompare(selection) == .orderedSame
        }
        return true
    }
}

// MARK: - Submission summary

public struct G09R2AgentSubmissionSummary: Sendable, Equatable {
    public var jobID: UUID
    public var state: MediaGenerationJobState
    public var providerTaskID: String?
    public var providerName: String
    public var remoteModelID: String
    public var deduplicated: Bool
    public var estimatedCompletionAt: Date?
    public var lastError: String? = nil
    /// Set only when NO new job was created because the same trusted
    /// owner+run already has an unresolved outcome-unknown submission. The
    /// jobID above is that existing unknown row (truthful recovery target).
    public var blockedByUnresolvedUnknown: UUID? = nil
}

// MARK: - Status projection

public struct G09R2AgentJobStatus: Sendable, Equatable {
    public var jobID: UUID
    public var state: MediaGenerationJobState
    public var terminated: Bool
    public var canCancel: Bool
    public var ready: Bool
    /// Durable media kind spelling ("image" / "video") from the job row.
    /// Defaulted so existing memberwise call sites (fallback statuses in the
    /// concurrent-churn suites) keep compiling; the projection always sets
    /// the real value.
    public var mediaKind: String = ""
    public var providerTaskID: String?
    public var resultURL: URL?
    public var resultURLExpiresAt: Date?
    /// Typed per-artifact delivery receipt; the authoritative record for one
    /// or many outputs.
    public var artifacts: [G09R2AgentGenerationArtifact]?
    /// Legacy single-artifact view (non-nil only for one-artifact results).
    public var workspaceRelativePath: String?
    public var deliveredByteCount: Int64?
    public var deliveredSHA256: String?
    public var nextPollAt: Date?
    public var lastError: String?
    /// A valid pending query succeeds without claiming delivery. Only a
    /// terminated job without its verified artifact is a failed outcome.
    var toolExitStatus: Int32 { terminated && !ready ? 1 : 0 }

}

// MARK: - Service

/// Conversation-owned facade over the EXISTING G09R2 generation execution.
/// Workers, root-stop and environment gating are the shared
/// `G09R2GenerationService` machinery (no second engine, no second job
/// store); only the ownership surface (conversation jobs delivered into the
/// task workspace) and the model-facing lifecycle are new.
public final class G09R2AgentGenerationService: @unchecked Sendable {
    public static let shared = G09R2AgentGenerationService()

    static let videoPollIntervalSeconds: TimeInterval = 15
    static let maximumVideoPolls = 120
    static let maximumResultBytes: Int64 = 512 * 1024 * 1024
    /// One refresh response carries at most this many durable job projections
    /// (the wire bound the BridgeV28 host channel enforces as well).
    static let maximumRefreshedJobs = 50

    internal let platform: G09R2GenerationPlatform
    private let afterImageBytesWritten: (@Sendable () async -> Void)?
    /// Deterministic crash seam for the post-write/pre-CAS recovery tests.
    /// Production initialization leaves it false; when true the worker stops
    /// after verified bytes are durable WITHOUT settling the row, exactly the
    /// state a process death leaves behind.
    private let abandonAfterImageWrite: Bool
    internal let environmentProvider: @Sendable (UInt64) async -> G09R2GenerationEnvironment?

    public convenience init() {
        self.init(
            platform: G09R2GenerationPlatform(),
            environmentProvider: { epoch in
                guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
                    epoch: epoch) else { return nil }
                return G09R2GenerationEnvironment(
                    root: cluster.identity.root,
                    database: cluster.database,
                    configuration: cluster.modelConfigurationStore)
            })
    }

    init(platform: G09R2GenerationPlatform,
         environmentProvider: @escaping @Sendable (UInt64) async -> G09R2GenerationEnvironment?,
         afterImageBytesWritten: (@Sendable () async -> Void)? = nil,
         abandonAfterImageWrite: Bool = false) {
        self.platform = platform
        self.environmentProvider = environmentProvider
        self.afterImageBytesWritten = afterImageBytesWritten
        self.abandonAfterImageWrite = abandonAfterImageWrite
    }

    // MARK: - Operation identity

    /// Stable idempotency identity for one tool execution. The provider call
    /// id (`runID:toolCallID`) is the normal key; when a context carries no
    /// provider call id, a deterministic digest of the exact request keeps a
    /// replayed identical call attached to the SAME durable job instead of
    /// paying twice — never a random UUID that silently breaks replay safety.
    public static func idempotencyKey(
        runID: UUID, toolCallID: String?, requestDigest: String
    ) -> String {
        if let trimmed = toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return "\(runID.uuidString):\(trimmed)"
        }
        return "\(runID.uuidString):agent-generation:\(requestDigest)"
    }

    // MARK: - Route catalog (image.models / video.models)

    /// Configured, enabled, adapter-backed routes with the public selection
    /// contract. Same catalog builder the UI flow uses.
    public func catalog(epoch: UInt64) async throws -> G09R2ModelCatalogDTO {
        let env = try await requireEnvironment(epoch: epoch)
        let providers = try await env.configuration.providers()
        let models = try await env.configuration.models()
        let preferences = try? await env.configuration.preferences()
        return G09R2GenerationCatalog.build(
            models: models, providers: providers, preferences: preferences,
            imageAdapter: { [platform] in platform.imageAdapter($0) },
            videoAdapter: { [platform] in platform.videoAdapter($0) })
    }

    /// Resolves an exact public selection (or the preferred route when no
    /// selection is given). Never remaps an explicit selection; the public
    /// selection name is the route's remote model ID, matching the donor
    /// contract (`publicModelID == remoteModelID`).
    public func resolveRoute(
        epoch: UInt64, kind: G09R2GenerationKind,
        selection: String?, legacyModelID: UUID?
    ) async throws -> (route: G09R2ModelRouteDTO, provider: ProviderProfile, model: ModelProfile) {
        let env = try await requireEnvironment(epoch: epoch)
        let catalog = try await catalog(epoch: epoch)
        let routes = kind == .image ? catalog.image : catalog.video
        let chosen: G09R2ModelRouteDTO?
        if let selection, !selection.isEmpty {
            let normalized = selection.lowercased()
            chosen = routes.first(where: {
                $0.remoteModelID.lowercased() == normalized
            })
            guard let chosen else {
                throw FloeError.validationFailed(
                    "Unknown \(kind == .image ? "image" : "video") model \(selection). Read the public candidates first.")
            }
        } else if let legacyModelID {
            chosen = routes.first(where: { $0.routeID == legacyModelID.uuidString.lowercased() })
            guard let chosen else {
                throw FloeError.validationFailed("Unknown modelID \(legacyModelID.uuidString)")
            }
        } else {
            // No selection: the catalog's first enabled+available route is
            // the preferred one (catalog build order is the priority order).
            chosen = routes.first
            guard let chosen else {
                throw FloeError.invalidConfiguration(
                    "No configured \(kind == .image ? "image" : "video") generation route")
            }
        }
        guard let route = chosen, route.enabled, route.available else {
            throw FloeError.invalidConfiguration("modelUnavailable")
        }
        guard let modelUUID = UUID(uuidString: route.routeID),
              let providerUUID = UUID(uuidString: route.providerID),
              let model = try await env.configuration.models().first(where: { $0.id == modelUUID }),
              let provider = try await env.configuration.providers().first(where: { $0.id == providerUUID }),
              provider.isEnabled, model.isEnabled else {
            throw FloeError.invalidConfiguration("modelUnavailable")
        }
        return (route, provider, model)
    }

    // MARK: - Image submit (image.generate)

    public func submitImage(
        epoch: UInt64,
        conversationID: UUID,
        runID: UUID,
        idempotencyKey: String,
        workspaceRootURL: URL,
        prompt: String,
        selection: String?,
        legacyModelID: UUID?,
        count: Int,
        size: String?,
        aspectRatio: String?,
        resolution: String?,
        quality: String?,
        referenceRelativePath: String?
    ) async throws -> G09R2AgentSubmissionSummary {
        let env = try await requireEnvironment(epoch: epoch)
        let store = MediaGenerationJobStore(database: env.database)
        let owner = MediaJobOwner.conversation(conversationID)
        // Replay boundary BEFORE route resolution and target pinning: a
        // replayed tool call (same runID+toolCallID, or the same deterministic
        // request digest) must attach to its ORIGINAL durable row even when
        // that row is terminal, the route was later disabled, or the task
        // workspace moved. Never a second paid submission; the stored row's
        // own delivery fence still governs where its result may be published.
        if let existing = try await replayOwnedJob(
            store: store, owner: owner, idempotencyKey: idempotencyKey,
            kind: .image,
            matches: { payload in
                payload.matchesImageRequest(
                    prompt: prompt, selection: selection,
                    legacyModelID: legacyModelID, count: count, size: size,
                    aspectRatio: aspectRatio, resolution: resolution,
                    quality: quality,
                    referenceRelativePath: referenceRelativePath)
            }) {
            return await submissionSummary(
                owned: existing, deduplicated: true, env: env)
        }
        let (route, provider, model) = try await resolveRoute(
            epoch: epoch, kind: .image, selection: selection,
            legacyModelID: legacyModelID)
        if referenceRelativePath != nil {
            // The catalog's reference policy is the configured truth; an
            // explicit reference for a route that accepts none is a refusal,
            // never a silent drop.
            guard route.referenceImagePolicy.maxImages > 0 else {
                throw FloeError.validationFailed("modelUnsupportedReference")
            }
        }
        let referenceData: Data?
        if let referenceRelativePath {
            referenceData = try readWorkspaceImage(
                referenceRelativePath, root: workspaceRootURL,
                maximumBytes: Int(G09R2CreativeLimits.imageSourceBytes),
                requireImageFacts: true)
        } else {
            referenceData = nil
        }
        let operation: RemoteImageOperation = referenceData == nil ? .generate : .edit
        guard let adapter = platform.imageAdapter(provider) else {
            throw FloeError.invalidConfiguration("adapterUnavailable")
        }
        guard adapter.supports(operation, for: provider) else {
            throw FloeError.validationFailed("operationUnsupported")
        }
        // Pin the ORIGINAL validated delivery target BEFORE any provider call:
        // the durable conversation→workspace binding resolved through the
        // original store, cross-checked against the submitting context's root.
        let target = try await pinWorkspaceTarget(
            env: env, conversationID: conversationID,
            submittingRoot: workspaceRootURL)
        let payload = G09R2AgentGenerationPayload(
            prompt: prompt, routeID: route.routeID,
            providerID: provider.id, modelID: model.id,
            remoteModelID: model.remoteModelID, count: count, size: size,
            aspectRatio: aspectRatio, resolution: resolution, quality: quality,
            referenceRelativePath: referenceRelativePath,
            targetWorkspaceID: target.workspaceID,
            targetWorkspaceRootPath: target.rootPath)
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: provider.secretRef,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try encoder().encode(payload))
        let creation: MediaJobCreation
        do {
            creation = try await store.createJob(
                job, owner: owner, originRunID: runID,
                idempotencyKey: idempotencyKey,
                blockOnUnresolvedUnknownInRun: true)
        } catch MediaGenerationJobStoreError.idempotencyConflict {
            // The same submitting operation identity was reused for a
            // DIFFERENT request. Refuse; never attach wrong data and never
            // create a second paying job.
            throw FloeError.validationFailed("idempotencyConflict")
        } catch MediaGenerationJobStoreError.unresolvedUnknownOutcome(
            let existingJobID) {
            // A changed prompt/model/provider/tool call is NOT a new user
            // intent: the same trusted owner+run already paid for an
            // outcome-unknown submission. Return that original row (no new
            // row, no paid call) so the model must report the unknown truth
            // instead of retrying around it.
            guard let existing = try await store.ownedJob(id: existingJobID) else {
                throw FloeError.validationFailed("unresolvedUnknownOutcome")
            }
            return await submissionSummary(
                owned: existing, deduplicated: true, env: env,
                blockedByUnresolvedUnknown: existingJobID)
        }
        if !creation.deduplicated {
            // The SAME bounded shared worker table as the UI flow: a full or
            // stopping table refuses; the durable row fails honestly instead
            // of overflowing into an untracked task.
            guard startWorker(epoch: epoch,
                              jobID: creation.job.id.uuidString.lowercased(),
                              kind: .image, body: { [weak self] token in
                guard let self else { return }
                await self.runImageJob(
                    token: token, epoch: epoch, jobID: creation.job.id,
                    referenceData: referenceData)
            }) else {
                _ = try? await store.transition(id: creation.job.id, to: .failed) {
                    $0.lastError = "generationQueueFull"
                    $0.nextPollAt = nil
                }
                throw FloeError.invalidConfiguration("generationQueueFull")
            }
        }
        return G09R2AgentSubmissionSummary(
            jobID: creation.job.id, state: creation.job.state,
            providerTaskID: creation.job.providerTaskID,
            providerName: provider.displayName ?? provider.kind.rawValue,
            remoteModelID: model.remoteModelID,
            deduplicated: creation.deduplicated,
            estimatedCompletionAt: creation.job.estimatedCompletionAt,
            lastError: creation.job.lastError)
    }

    private func runImageJob(
        token: String, epoch: UInt64, jobID: UUID,
        referenceData: Data?
        ) async {
        var dispatched = false
        let wireRecorder = G09R2WirePhaseRecorder()
        do {
            try throwIfCancelled(token: token)
            let env = try await requireEnvironment(epoch: epoch)
            let store = MediaGenerationJobStore(database: env.database)
            guard let owned = try await store.ownedJob(id: jobID),
                  !owned.job.state.isTerminal else { return }
            // Second line of the anti-resubmission guard: the insert
            // transaction already refuses a changed request once the unknown
            // is durable, but a retry inserted just BEFORE that settlement
            // can still reach its worker. It must not spend a paid call.
            if let unknown = try await store.unresolvedUnknownJob(
                owner: owned.owner, originRunID: owned.originRunID,
                mediaKind: .image, excluding: jobID) {
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: "unresolvedUnknownOutcome", definite: true,
                    diagnostic: G09R2AgentGenerationDiagnostic(
                        stages: [], failureCode: "unresolvedUnknownOutcome",
                        relatedJobID: unknown.job.id))
                return
            }
            let payload = try decodePayload(owned.job)
            // The durable payload carries the resolved internal route id; it
            // is re-resolved exactly, never re-interpreted as a public
            // selection string.
            guard let routeUUID = UUID(uuidString: payload.routeID) else {
                throw G09CreativeError.invalidPayload("corruptPayload")
            }
            let (_, provider, model) = try await resolveRoute(
                epoch: epoch, kind: .image, selection: nil,
                legacyModelID: routeUUID)
            guard let adapter = platform.imageAdapter(provider) else {
                throw FloeError.invalidConfiguration("adapterUnavailable")
            }
            let operation: RemoteImageOperation = referenceData == nil ? .generate : .edit
            try adapter.validateSourceImageCount(
                RemoteImageRequest(
                    operation: operation, prompt: payload.prompt,
                    sourceImages: referenceData.map { [$0] } ?? []),
                providerName: provider.displayName ?? provider.kind.rawValue)
            let selection = ImageGenerationSelection(
                aspectRatio: payload.aspectRatio, resolution: payload.resolution,
                quality: payload.quality, nativeSizeOverride: payload.size)
            try ImageGenerationPresetResolver.validateSelection(
                selection, provider: provider, model: model, operation: operation,
                count: payload.count, referenceCount: referenceData == nil ? 0 : 1)
            let credentials = try await platform.credentials(provider)
            try throwIfCancelled(token: token)
            // Persist dispatch intent before yielding to a paid request. A
            // concurrent local stop must not claim remote cancellation while
            // the provider may already be accepting it.
            try await store.transition(id: jobID, to: .submitted)
            try throwIfCancelled(token: token)
            dispatched = true
            let result = try await adapter.perform(
                RemoteImageRequest(
                    operation: operation, prompt: payload.prompt,
                    sourceImages: referenceData.map { [$0] } ?? [],
                    selection: selection, count: payload.count,
                    modelRemoteID: model.remoteModelID,
                    wirePhaseObserver: { phase in
                        wireRecorder.record(phase)
                    }),
                provider: provider, credentials: credentials)
            guard result.images.count == payload.count else {
                throw FloeError.validationFailed("imageCountMismatch")
            }
            // The provider ALREADY returned the paid result. Record the
            // App-owned producer proof from THOSE REAL BYTES before any
            // workspace publication; a later recovery may only verify
            // workspace files against this durable receipt (filename or a
            // self-computed workspace hash is not trusted). Then write and
            // commit in the non-cancelled hop; a local stop after the
            // provider returned must not discard a paid result. The pinned
            // ORIGINAL target is still revalidated; a task/project move
            // fences delivery instead of choosing a new root.
            let prepared = try prepareImageBatch(result.images, jobID: jobID)
            let receipt = G09R2AgentGenerationProducerReceipt(
                jobID: jobID,
                ownerKind: owned.owner.kind.rawValue,
                ownerID: owned.owner.id,
                requestDigest: payload.requestDigest(),
                providerID: payload.providerID,
                modelID: payload.modelID,
                remoteModelID: payload.remoteModelID,
                count: payload.count,
                images: prepared.map { image in
                    G09R2AgentGenerationProducerImage(
                        index: image.index,
                        relativePath: image.relativePath,
                        mimeType: image.mimeType,
                        byteCount: image.byteCount,
                        sha256: image.sha256)
                })
            var payloadWithReceipt = payload
            payloadWithReceipt.producerReceipt = receipt
            let receiptPayload = payloadWithReceipt
            try await persistProducerReceipt(
                store: store, jobID: jobID,
                payload: receiptPayload, receipt: receipt)
            let conversationID = owned.owner.id
            let artifacts = try await finalizeDespiteCancellation { [self] in
                let deliveryRoot = try await resolvePinnedWorkspaceRoot(
                    env: env, payload: receiptPayload,
                    conversationID: conversationID)
                return try writePreparedImages(
                    prepared, workspaceRootURL: deliveryRoot)
            }
            // Internal fixture seam after durable bytes, before the receipt CAS.
            // Production initialization leaves it nil.
            await afterImageBytesWritten?()
            if abandonAfterImageWrite {
                // Test-only faithful crash window: the verified files and the
                // App-owned producer receipt are durable, the row is still
                // non-terminal. A later refresh must adopt them.
                return
            }
            // The verified bytes are already durable in the pinned workspace;
            // the receipt commit is the publish boundary. A local stop that
            // arrived after the write must NOT strand real delivered bytes
            // behind an `outcomeUnknown` row with no artifact (the poll
            // worker's ready commit uses the same CAS discipline): commit the
            // receipt even when the local stop already cancelled this worker
            // task, and let a cancel that raced the commit keep its real
            // terminal state via the store's transition guard.
            do {
                try await commitImageReceipt(
                    store: store, jobID: jobID, payload: receiptPayload,
                    artifacts: artifacts)
            } catch MediaGenerationJobStoreError.invalidStateTransition {
                // A cancel raced the receipt commit and already settled the
                // real terminal state; keep it (ready-vs-cancel truth) and
                // leave the delivered bytes at their pinned paths.
                return
            }
        } catch let error as CancellationError {
            // A one-shot image carries no provider handle: before dispatch a
            // local stop is a definite `cancelled`; after dispatch the request
            // may have been accepted, so the durable state is ambiguous
            // `outcomeUnknown` — never a definite remote cancel.
            await finishJob(
                epoch: epoch, jobID: jobID,
                code: dispatched ? "outcomeUnknown" : "cancelled",
                definite: !dispatched,
                diagnostic: Self.imageFailureDiagnostic(
                    wireRecorder, error: error,
                    code: dispatched ? nil : "cancelled"))
        } catch AgentDeliveryFence.targetChanged {
            // The original output owner was migrated or revoked while the
            // provider worked: fail the delivery honestly, publish nothing.
            await finishJob(
                epoch: epoch, jobID: jobID,
                code: "targetChanged", definite: true,
                diagnostic: G09R2AgentGenerationDiagnostic(
                    stages: wireRecorder.snapshot(),
                    failureCode: "delivery.targetChanged"))
        } catch let remote as RemoteImageError {
            switch remote {
            case .providerRejected, .requestFailed:
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: "providerRejected", definite: true,
                    diagnostic: Self.imageFailureDiagnostic(
                        wireRecorder, error: remote))
            case .unsupportedOperation:
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: "modelUnavailable", definite: true,
                    diagnostic: Self.imageFailureDiagnostic(
                        wireRecorder, error: remote))
            case .invalidResponse:
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: "outcomeUnknown", definite: false,
                    diagnostic: Self.imageFailureDiagnostic(
                        wireRecorder, error: remote))
            }
        } catch let typed as G09CreativeError {
            switch typed.code {
            case "assetTooLarge", "assetDigestMismatch", "assetReferenceInvalid",
                 "assetMissing":
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: typed.code, definite: true,
                    diagnostic: Self.imageFailureDiagnostic(
                        wireRecorder, error: typed))
            default:
                // Root-stop/stale-generation after dispatch is ambiguous —
                // the paid request may have been accepted.
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: dispatched ? "outcomeUnknown" : typed.code,
                    definite: !dispatched,
                    diagnostic: Self.imageFailureDiagnostic(
                        wireRecorder, error: typed,
                        code: dispatched ? nil : typed.code))
            }
        } catch {
            // Only an explicit transport refusal before task creation proves
            // that this attempt was not sent. Connection error names alone
            // cannot rule out acceptance or a failure after a redirect.
            let definitelyNotDispatched = dispatched
                && Self.isDefinitePreDispatchTransportFailure(
                    error, stages: wireRecorder.snapshot())
            let code: String
            if !dispatched {
                code = Self.boundedCode(error)
            } else if definitelyNotDispatched {
                code = "requestNotDispatched"
            } else {
                code = "outcomeUnknown"
            }
            await finishJob(
                epoch: epoch, jobID: jobID, code: code,
                definite: !dispatched || definitelyNotDispatched,
                // The durable `lastError` stays the settlement class above;
                // the diagnostic records the underlying failure cause
                // (e.g. `urlError.timedOut`), never an opaque "unknown".
                diagnostic: Self.imageFailureDiagnostic(
                    wireRecorder, error: error))
        }
    }

    // MARK: - Video submit (video.generate)

    public func submitVideo(
        epoch: UInt64,
        conversationID: UUID,
        runID: UUID,
        idempotencyKey: String,
        workspaceRootURL: URL,
        prompt: String,
        selection: String?,
        legacyModelID: UUID?,
        aspectRatio: String?,
        resolution: String?,
        durationSeconds: Int?,
        includeAudio: Bool?,
        watermark: Bool?,
        seed: Int?,
        referenceRelativePath: String?
    ) async throws -> G09R2AgentSubmissionSummary {
        let env = try await requireEnvironment(epoch: epoch)
        let store = MediaGenerationJobStore(database: env.database)
        let owner = MediaJobOwner.conversation(conversationID)
        // First replay check BEFORE route resolution: an exact replayed call
        // still attaches when the original route was disabled/removed after
        // submission. The post-validation check below also covers provider
        // defaults/normalisation.
        if let existing = try await replayOwnedJob(
            store: store, owner: owner, idempotencyKey: idempotencyKey,
            kind: .video,
            matches: { payload in
                payload.matchesVideoRequest(
                    prompt: prompt, selection: selection,
                    legacyModelID: legacyModelID,
                    aspectRatio: aspectRatio, resolution: resolution,
                    durationSeconds: durationSeconds,
                    includeAudio: includeAudio, watermark: watermark,
                    seed: seed, referenceRelativePath: referenceRelativePath)
            }) {
            return await submissionSummary(
                owned: existing, deduplicated: true, env: env)
        }
        let (route, provider, model) = try await resolveRoute(
            epoch: epoch, kind: .video, selection: selection,
            legacyModelID: legacyModelID)
        guard let adapter = platform.videoAdapter(provider) else {
            throw FloeError.invalidConfiguration("adapterUnavailable")
        }
        // Validate options against the REAL route contract from the SAME
        // source the catalog uses. The catalog DTO is a lossy projection
        // (its `codecs` list is always empty), so the contract is rebuilt
        // here from the model/provider pair, never guessed back from the DTO.
        let contract = VideoModelRegistry.contract(model: model, provider: provider)
        let options = try VideoRequestValidator.validate(
            VideoGenerationOptions(
                aspectRatio: aspectRatio, resolution: resolution,
                durationSeconds: durationSeconds, includeAudio: includeAudio,
                seed: seed, watermark: watermark),
            contract: contract, modelRemoteID: model.remoteModelID)
        // Replay boundary BEFORE target pinning and job insertion: a replayed
        // tool call attaches to its ORIGINAL durable row even when terminal,
        // so a lost reply or an already-settled job never pays twice. The
        // validated options are compared because the request validator may
        // materialise provider defaults.
        if let existing = try await replayOwnedJob(
            store: store, owner: owner, idempotencyKey: idempotencyKey,
            kind: .video,
            matches: { payload in
                payload.matchesVideoRequest(
                    prompt: prompt, selection: selection,
                    legacyModelID: legacyModelID,
                    aspectRatio: options.aspectRatio,
                    resolution: options.resolution,
                    durationSeconds: options.durationSeconds,
                    includeAudio: options.includeAudio,
                    watermark: options.watermark, seed: options.seed,
                    referenceRelativePath: referenceRelativePath)
            }) {
            return await submissionSummary(
                owned: existing, deduplicated: true, env: env)
        }
        var referenceURLs: [URL] = []
        if let referenceRelativePath {
            // Refuse a reference for a route that accepts none (the catalog
            // policy is the configured truth), then read it through the
            // rooted guard and inline it as the documented data: URL.
            guard route.referenceImagePolicy.maxImages > 0 else {
                throw FloeError.validationFailed("modelUnsupportedReference")
            }
            let data = try readWorkspaceImage(
                referenceRelativePath, root: workspaceRootURL,
                maximumBytes: VideoReferenceImagePolicy.maximumBytes,
                requireImageFacts: false)
            referenceURLs = [try VideoReferenceImagePolicy.inlineDataURL(data: data)]
        }
        // Pin the ORIGINAL validated delivery target BEFORE any provider call:
        // the durable conversation→workspace binding resolved through the
        // original store, cross-checked against the submitting context's root.
        let target = try await pinWorkspaceTarget(
            env: env, conversationID: conversationID,
            submittingRoot: workspaceRootURL)
        let payload = G09R2AgentGenerationPayload(
            prompt: prompt, routeID: route.routeID,
            providerID: provider.id, modelID: model.id,
            remoteModelID: model.remoteModelID, count: 1,
            aspectRatio: options.aspectRatio, resolution: options.resolution,
            durationSeconds: options.durationSeconds,
            includeAudio: options.includeAudio, watermark: options.watermark,
            seed: options.seed, referenceRelativePath: referenceRelativePath,
            targetWorkspaceID: target.workspaceID,
            targetWorkspaceRootPath: target.rootPath)
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .video,
            credentialReference: provider.secretRef,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try encoder().encode(payload))
        let creation: MediaJobCreation
        do {
            creation = try await store.createJob(
                job, owner: owner, originRunID: runID,
                idempotencyKey: idempotencyKey,
                blockOnUnresolvedUnknownInRun: true)
        } catch MediaGenerationJobStoreError.idempotencyConflict {
            throw FloeError.validationFailed("idempotencyConflict")
        } catch MediaGenerationJobStoreError.unresolvedUnknownOutcome(
            let existingJobID) {
            guard let existing = try await store.ownedJob(id: existingJobID) else {
                throw FloeError.validationFailed("unresolvedUnknownOutcome")
            }
            return await submissionSummary(
                owned: existing, deduplicated: true, env: env,
                blockedByUnresolvedUnknown: existingJobID)
        }
        if !creation.deduplicated {
            guard startWorker(epoch: epoch,
                              jobID: creation.job.id.uuidString.lowercased(),
                              kind: .video, body: { [weak self, referenceURLs] token in
                guard let self else { return }
                await self.runVideoSubmit(
                    token: token, epoch: epoch, jobID: creation.job.id,
                    referenceURLs: referenceURLs)
            }) else {
                _ = try? await store.transition(id: creation.job.id, to: .failed) {
                    $0.lastError = "generationQueueFull"
                    $0.nextPollAt = nil
                }
                throw FloeError.invalidConfiguration("generationQueueFull")
            }
        }
        return G09R2AgentSubmissionSummary(
            jobID: creation.job.id, state: creation.job.state,
            providerTaskID: creation.job.providerTaskID,
            providerName: provider.displayName ?? provider.kind.rawValue,
            remoteModelID: model.remoteModelID,
            deduplicated: creation.deduplicated,
            estimatedCompletionAt: creation.job.estimatedCompletionAt,
            lastError: creation.job.lastError)
    }

    private func runVideoSubmit(
        token: String, epoch: UInt64, jobID: UUID,
        referenceURLs: [URL]
    ) async {
        var dispatched = false
        do {
            try throwIfCancelled(token: token)
            let env = try await requireEnvironment(epoch: epoch)
            let store = MediaGenerationJobStore(database: env.database)
            guard let owned = try await store.ownedJob(id: jobID),
                  !owned.job.state.isTerminal else { return }
            // Second line of the anti-resubmission guard (same contract as
            // the image worker): a changed-prompt/model/provider submission
            // inserted just BEFORE an outcome-unknown settlement became
            // durable must not spend a paid submit call.
            if let unknown = try await store.unresolvedUnknownJob(
                owner: owned.owner, originRunID: owned.originRunID,
                mediaKind: .video, excluding: jobID) {
                await finishJob(
                    epoch: epoch, jobID: jobID,
                    code: "unresolvedUnknownOutcome", definite: true,
                    diagnostic: G09R2AgentGenerationDiagnostic(
                        stages: [], failureCode: "unresolvedUnknownOutcome",
                        relatedJobID: unknown.job.id))
                return
            }
            let payload = try decodePayload(owned.job)
            guard let routeUUID = UUID(uuidString: payload.routeID) else {
                throw G09CreativeError.invalidPayload("corruptPayload")
            }
            let (_, provider, model) = try await resolveRoute(
                epoch: epoch, kind: .video, selection: nil,
                legacyModelID: routeUUID)
            guard let adapter = platform.videoAdapter(provider) else {
                throw FloeError.invalidConfiguration("adapterUnavailable")
            }
            let credentials = try await platform.credentials(provider)
            try throwIfCancelled(token: token)
            let request = RemoteVideoRequest(
                prompt: payload.prompt, modelRemoteID: model.remoteModelID,
                options: VideoGenerationOptions(
                    aspectRatio: payload.aspectRatio, resolution: payload.resolution,
                    durationSeconds: payload.durationSeconds,
                    includeAudio: payload.includeAudio, seed: payload.seed,
                    watermark: payload.watermark),
                referenceAssetURLs: referenceURLs)
            try await store.transition(id: jobID, to: .submitted)
            try throwIfCancelled(token: token)
            dispatched = true
            let submission = try await adapter.submit(
                request, provider: provider, credentials: credentials)
            guard !submission.providerTaskID.isEmpty else {
                throw RemoteVideoError.invalidResponse("emptyTaskID")
            }
            // The accepted provider task identity is persisted BEFORE any
            // subsequent await so a crash after acceptance never loses the
            // handle and never triggers a duplicate paid submission.
            if isWorkerCancelled(token: token) {
                // The provider ALREADY accepted the paid request. Local stop
                // can never claim provider cancellation: persist the accepted
                // handle, keep the durable row non-terminal, and let the
                // poll/resume path (or an explicit provider-confirmed cancel)
                // settle the real outcome — exactly the shared UI flow.
                await persistAcceptedVideoHandle(
                    store: store, jobID: jobID, submission: submission)
                return
            }
            // The accepted provider task identity is persisted BEFORE any
            // poll await so a crash after acceptance never loses the
            // handle and never triggers a duplicate paid submission. The
            // write must survive a cancel that races it (the accepted
            // handle is must-persist; see `finalizeDespiteCancellation`).
            try await finalizeDespiteCancellation { [store, submission] in
                try await store.transition(id: jobID, to: .submitted) {
                    $0.providerTaskID = submission.providerTaskID
                    $0.estimatedCompletionAt = submission.estimatedCompletionAt
                    $0.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
                    $0.resultURL = submission.resultURL
                    $0.resultURLExpiresAt = submission.resultURLExpiresAt
                    $0.nextPollAt = Date().addingTimeInterval(Self.videoPollIntervalSeconds)
                    $0.lastPolledAt = Date()
                    $0.lastError = nil
                }
            }
            // Hand off to the poll worker (same bounded table). A full table
            // leaves the durable submitted row for resumeStaleJobs or the
            // next status refresh — never an untracked overflow task.
            _ = startWorker(epoch: epoch,
                            jobID: jobID.uuidString.lowercased(),
                            kind: .video) { [weak self] pollToken in
                guard let self else { return }
                await self.runVideoPoll(token: pollToken, epoch: epoch, jobID: jobID)
            }
        } catch is CancellationError {
            // Pre-dispatch a local stop is a definite `cancelled`; after
            // dispatch the paid request may have been accepted — durable
            // `outcomeUnknown`, never a definite failure.
            await finishJob(epoch: epoch, jobID: jobID,
                            code: dispatched ? "outcomeUnknown" : "cancelled",
                            definite: !dispatched)
        } catch AgentDeliveryFence.targetChanged {
            await finishJob(epoch: epoch, jobID: jobID,
                            code: "targetChanged", definite: true)
        } catch let remote as RemoteVideoError {
            switch remote {
            case .unsupportedProvider:
                await finishJob(epoch: epoch, jobID: jobID,
                                code: "renderUnsupported", definite: true)
            case .invalidRequest:
                await finishJob(epoch: epoch, jobID: jobID,
                                code: "invalidPayload", definite: true)
            case .requestFailed:
                // A typed provider refusal proves the request was NOT accepted.
                await finishJob(epoch: epoch, jobID: jobID,
                                code: "providerRejected", definite: true)
            case .invalidResponse:
                await finishJob(epoch: epoch, jobID: jobID,
                                code: "outcomeUnknown", definite: false)
            }
        } catch let typed as G09CreativeError {
            await finishJob(epoch: epoch, jobID: jobID,
                            code: typed.code, definite: !dispatched)
        } catch {
            // Transport timeout, connection loss or adapter cancellation AFTER
            // dispatch is ambiguous: the provider may hold the paid request.
            // Durable `outcomeUnknown`; only pre-dispatch failures are
            // definite. No automatic retry, no billing fallback.
            await finishJob(epoch: epoch, jobID: jobID,
                            code: dispatched ? "outcomeUnknown"
                                : Self.boundedCode(error),
                            definite: !dispatched)
        }
    }

    /// Runs one bounded, awaited must-complete operation outside the current
    /// task's cancellation. Local worker cancellation must never silently
    /// drop a paid result or a must-persist settlement — an accepted provider
    /// handle, verified delivered bytes and their receipt, or an honest
    /// terminal state: GRDB refuses cancelled readers/writers
    /// (`SerializedDatabase` checks task cancellation before the block). The
    /// hop is awaited before returning, so no untracked work survives the
    /// caller, and the store's write transaction keeps its exact CAS/owner
    /// semantics.
    private func finalizeDespiteCancellation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try await operation()
        }.value
    }

    /// Persists an accepted provider handle on behalf of a worker task that
    /// already received a local cancellation request (see
    /// `finalizeDespiteCancellation`): the provider accepted the paid request
    /// before the local stop, so the durable row keeps the handle and stays
    /// non-terminal — exactly the shared UI flow's contract.
    private func persistAcceptedVideoHandle(
        store: MediaGenerationJobStore,
        jobID: UUID,
        submission: RemoteVideoSubmission
    ) async {
        _ = try? await finalizeDespiteCancellation {
            try await store.transition(id: jobID, to: .submitted) {
                $0.providerTaskID = submission.providerTaskID
                $0.estimatedCompletionAt = submission.estimatedCompletionAt
                $0.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
                $0.resultURL = submission.resultURL
                $0.resultURLExpiresAt = submission.resultURLExpiresAt
                $0.nextPollAt = Date().addingTimeInterval(Self.videoPollIntervalSeconds)
                $0.lastPolledAt = Date()
            }
        }
    }

    private func runVideoPoll(token: String, epoch: UInt64, jobID: UUID) async {
        var polls = 0
        while polls < Self.maximumVideoPolls {
            if isWorkerCancelled(token: token) { break }
            polls += 1
            do {
                try throwIfCancelled(token: token)
                let env = try await requireEnvironment(epoch: epoch)
                let store = MediaGenerationJobStore(database: env.database)
                guard let owned = try await store.ownedJob(id: jobID),
                      !owned.job.state.isTerminal else { return }
                let payload = try decodePayload(owned.job)
                guard let routeUUID = UUID(uuidString: payload.routeID) else {
                    throw G09CreativeError.invalidPayload("corruptPayload")
                }
                let (_, provider, model) = try await resolveRoute(
                    epoch: epoch, kind: .video, selection: nil,
                    legacyModelID: routeUUID)
                guard let adapter = platform.videoAdapter(provider),
                      let taskID = owned.job.providerTaskID else { return }
                let credentials = try await platform.credentials(provider)
                let status = try await adapter.status(
                    taskID: taskID, modelRemoteID: model.remoteModelID,
                    provider: provider, credentials: credentials)
                // Every configured adapter reports a provider-succeeded video
                // as `.completed` (Volcengine/Ark `succeeded`, DashScope
                // `SUCCEEDED`, Google Omni `ACTIVE`) carrying the result URL —
                // the shared UI worker handles `.completed` and `.ready`
                // identically (`G09R2GenerationWorkers`). Matching that here:
                // before this case existed, a succeeded task fell into
                // `default`, kept rewriting the row to `.running` with a fresh
                // `nextPollAt`, and the accepted paid result was never
                // delivered — the row spun non-terminal forever even though
                // the provider had long finished.
                switch status.state {
                case .completed, .ready:
                    guard let url = status.resultURL ?? owned.job.resultURL else {
                        throw RemoteVideoError.invalidResponse("missingResultURL")
                    }
                    try throwIfCancelled(token: token)
                    try await store.transition(id: jobID, to: .downloading) {
                        $0.resultURL = url
                        $0.lastError = nil
                        $0.nextPollAt = nil
                    }
                    let destination = env.root.artifactStoreURL.appendingPathComponent(
                        ".agent-video-\(jobID.uuidString).part")
                    defer { try? FileManager.default.removeItem(at: destination) }
                    let receipt = try await platform.download(
                        url, destination, Self.maximumResultBytes)
                    // Stop / epoch / target fence BEFORE committing any byte:
                    // a local cancel, a root stop, or a task/project target
                    // move during the provider callback must never publish
                    // into a (new) owner.
                    try throwIfCancelled(token: token)
                    let commitEnv = try await requireEnvironment(epoch: epoch)
                    let commitStore = MediaGenerationJobStore(database: commitEnv.database)
                    guard let current = try await commitStore.ownedJob(id: jobID),
                          !current.job.state.isTerminal else { return }
                    let deliveryRoot = try await resolvePinnedWorkspaceRoot(
                        env: commitEnv, payload: payload,
                        conversationID: current.owner.id)
                    try throwIfCancelled(token: token)
                    let artifact = try moveDeliveredVideo(
                        receipt, workspaceRoot: deliveryRoot, jobID: jobID)
                    try throwIfCancelled(token: token)
                    do {
                        try await commitStore.transition(id: jobID, to: .ready) {
                            var updated = payload
                            updated.artifacts = [artifact]
                            updated.workspaceRelativePath = artifact.relativePath
                            updated.deliveredByteCount = artifact.byteCount
                            updated.deliveredSHA256 = artifact.sha256
                            $0.requestJSON = (try? self.encoder().encode(updated)) ?? $0.requestJSON
                            $0.lastError = nil
                            $0.nextPollAt = nil
                            $0.resultURL = nil
                            $0.resultURLExpiresAt = nil
                        }
                    } catch MediaGenerationJobStoreError.invalidStateTransition {
                        // A cancel raced the commit and already settled the
                        // real terminal state; keep it (ready-vs-cancel truth).
                        return
                    }
                    return
                case .failed:
                    try await store.transition(id: jobID, to: .failed) {
                        $0.lastError = Self.boundedCodeText(status.error) ?? "providerFailed"
                        $0.nextPollAt = nil
                    }
                    return
                case .expired:
                    try await store.transition(id: jobID, to: .expired) {
                        $0.lastError = "expired"
                        $0.nextPollAt = nil
                    }
                    return
                case .cancelled:
                    try await store.transition(id: jobID, to: .cancelled) {
                        $0.lastError = nil
                        $0.nextPollAt = nil
                    }
                    return
                default:
                    try await store.transition(id: jobID, to: .running) {
                        $0.lastPolledAt = Date()
                        $0.nextPollAt = Date().addingTimeInterval(Self.videoPollIntervalSeconds)
                        $0.lastError = nil
                    }
                }
            } catch is CancellationError {
                break
            } catch AgentDeliveryFence.targetChanged {
                // The original output owner was migrated or revoked while the
                // provider worked: fail the delivery honestly and publish
                // nothing into any owner.
                await finishJob(epoch: epoch, jobID: jobID,
                                code: "targetChanged", definite: true)
                return
            } catch {
                // A poll failure keeps the durable job alive with bounded
                // backoff; the retained provider task ID is never replayed
                // as a new submission. The retry marker must survive on ANY
                // non-terminal state: `.downloading -> .running` is rejected
                // by the durable state machine (backward rank), so persist it
                // as a self-transition on the CURRENT state. The store
                // re-reads and re-validates inside one write transaction, so
                // a terminal settlement that races this retry can never be
                // overwritten. A cancelled worker task persists the marker
                // through the same non-cancelled hop as every finalization.
                if let env = try? await requireEnvironment(epoch: epoch) {
                    let retryStore = MediaGenerationJobStore(database: env.database)
                    if let current = try? await retryStore.ownedJob(id: jobID),
                       !current.job.state.isTerminal {
                        let retryState = current.job.state
                        _ = try? await finalizeDespiteCancellation {
                            try await retryStore.transition(id: jobID, to: retryState) {
                                $0.lastPolledAt = Date()
                                $0.nextPollAt = Date().addingTimeInterval(Self.videoPollIntervalSeconds)
                                $0.lastError = "pollRetry"
                                $0.retryCount += 1
                            }
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.videoPollIntervalSeconds * 1_000_000_000))
        }
        // Local worker stop, network interruption or poll-budget exhaustion:
        // an accepted remote job is retained non-terminal with its handle —
        // queryable and resumable, never resubmitted, never falsely terminal.
        await retainAcceptedJob(epoch: epoch, jobID: jobID)
    }

    // MARK: - Status / cancel (video.status / video.cover image+video jobs)

    public func status(
        epoch: UInt64, conversationID: UUID, jobID: UUID, refresh: Bool
    ) async throws -> G09R2AgentJobStatus {
        let env = try await requireEnvironment(epoch: epoch)
        let store = MediaGenerationJobStore(database: env.database)
        let owned = try await requireOwnedJob(
            store: store, jobID: jobID, conversationID: conversationID)
        let engine = G09R2GenerationService.shared
        if refresh, !owned.job.state.isTerminal,
           owned.job.mediaKind == .video, owned.job.providerTaskID != nil,
           !engine.hasActiveWorker(jobID: jobID.uuidString.lowercased()) {
            // Restart the bounded poll worker for this retained job; a full
            // or stopping table simply keeps the durable state as-is.
            _ = startWorker(epoch: epoch,
                            jobID: jobID.uuidString.lowercased(),
                            kind: .video) { [weak self] token in
                guard let self else { return }
                await self.runVideoPoll(token: token, epoch: epoch, jobID: jobID)
            }
        }
        var current = try await requireOwnedJob(
            store: store, jobID: jobID, conversationID: conversationID)
        // Background/foreground or relaunch reconciliation: a one-shot image
        // whose worker died AFTER the verified bytes reached the pinned
        // workspace can be adopted from its deterministic job-identified
        // files — no provider call, no resubmission. This runs BEFORE the
        // stale classification so real delivered bytes are never expired.
        if refresh, current.job.mediaKind == .image,
           current.job.providerTaskID == nil,
           !current.job.state.isTerminal,
           !engine.hasActiveWorker(jobID: jobID.uuidString.lowercased()),
           let payload = try? decodePayload(current.job),
           await reconcileImageDelivery(
                env: env, conversationID: conversationID,
                owner: current.owner, jobID: jobID, payload: payload) {
            current = try await requireOwnedJob(
                store: store, jobID: jobID, conversationID: conversationID)
        }
        if refresh, current.job.providerTaskID == nil,
           current.job.state == .preparing || current.job.state == .submitted,
           !engine.hasActiveWorker(jobID: jobID.uuidString.lowercased()),
           Date().timeIntervalSince(current.job.createdAt)
                > G09R2GenerationService.stalePreparingSeconds {
            // A request whose process died before persisting a handle has no
            // recoverable handle: classify unknown, never resubmit.
            _ = try? await store.transition(id: jobID, to: .expired) {
                $0.lastError = "outcomeUnknown"
                $0.nextPollAt = nil
            }
            current = try await requireOwnedJob(
                store: store, jobID: jobID, conversationID: conversationID)
        }
        return projection(current)
    }

    @discardableResult
    public func cancel(
        epoch: UInt64, conversationID: UUID, jobID: UUID
    ) async throws -> G09R2AgentJobStatus {
        let env = try await requireEnvironment(epoch: epoch)
        let store = MediaGenerationJobStore(database: env.database)
        let owned = try await requireOwnedJob(
            store: store, jobID: jobID, conversationID: conversationID)
        guard !owned.job.state.isTerminal else {
            throw FloeError.validationFailed("video.cancel on a finished job is an error")
        }
        // Cooperative cancellation of the exact owned local worker first.
        G09R2GenerationService.shared.requestCancel(
            jobID: jobID.uuidString.lowercased(), epoch: epoch)
        if let providerTaskID = owned.job.providerTaskID {
            // The provider must confirm; a failed provider cancel keeps the
            // job truthful (possibly running) and this call reports the
            // failure instead of claiming success.
            let payload = try decodePayload(owned.job)
            guard let routeUUID = UUID(uuidString: payload.routeID) else {
                throw G09CreativeError.invalidPayload("corruptPayload")
            }
            let (_, provider, _) = try await resolveRoute(
                epoch: epoch, kind: owned.job.mediaKind == .video ? .video : .image,
                selection: nil, legacyModelID: routeUUID)
            guard owned.job.mediaKind == .video,
                  let adapter = platform.videoAdapter(provider) else {
                throw FloeError.validationFailed("providerCancelUnsupported")
            }
            let credentials = try await platform.credentials(provider)
            do {
                try await adapter.cancel(
                    taskID: providerTaskID, provider: provider,
                    credentials: credentials)
            } catch {
                throw FloeError.validationFailed("providerCancelUnsupported")
            }
            // Provider confirmed. Re-read before settling: a completion that
            // raced with this cancel keeps the real terminal state.
            let settled = try await requireOwnedJob(
                store: store, jobID: jobID, conversationID: conversationID)
            guard !settled.job.state.isTerminal else { return projection(settled) }
            try await store.transition(id: jobID, to: .cancelled) {
                $0.lastError = nil
                $0.nextPollAt = nil
                $0.lastPolledAt = Date()
            }
        } else {
            // No handle does not prove that a dispatched request was refused.
            // Keep an in-flight video queryable so its late accepted handle
            // can still be persisted. One-shot image outcomes stay unknown.
            let settled = try await requireOwnedJob(
                store: store, jobID: jobID, conversationID: conversationID)
            guard !settled.job.state.isTerminal else { return projection(settled) }
            let dispatched = settled.job.state != .preparing
            let target: MediaGenerationJobState = dispatched
                ? (settled.job.mediaKind == .video ? settled.job.state : .expired)
                : .cancelled
            try await store.transition(id: jobID, to: target) {
                $0.lastError = dispatched ? "outcomeUnknown" : nil
                $0.nextPollAt = nil
            }
        }
        let settled = try await requireOwnedJob(
            store: store, jobID: jobID, conversationID: conversationID)
        return projection(settled)
    }

    /// Relaunch resume: restart poll workers for conversation-owned
    /// non-terminal video jobs that lost their process. Called from the App's
    /// conversation run launch pump (the same relaunch moment that re-attaches
    /// a task to the runtime), so retained video jobs keep polling after a
    /// process restart. Image jobs are single-shot: a non-terminal row is
    /// first checked for a FULL verified deterministic output batch in its
    /// ORIGINAL pinned workspace and adopted; only a handle-less row without
    /// recoverable verified outputs is classified unknown — never resubmitted.
    ///
    /// Freshness gate (device repair): the launch pump is a fire-and-forget
    /// task that can be scheduled while a brand-new submission is between its
    /// durable row insert and its worker registration. A handle-less
    /// preparing/submitted row younger than `stalePreparingSeconds` is NOT
    /// stale — its worker may be starting right now — so this pump must apply
    /// the exact same age gate `status(refresh:)` uses; only rows older than
    /// the bound (e.g. the submitter process really died) classify unknown.
    public func resumeStaleJobs(epoch: UInt64, conversationID: UUID) async {
        guard !G09R2GenerationService.shared.isRootStopping(epoch: epoch),
              let env = try? await requireEnvironment(epoch: epoch) else { return }
        let store = MediaGenerationJobStore(database: env.database)
        guard let jobs = try? await store.jobs(owner: .conversation(conversationID)) else {
            return
        }
        let engine = G09R2GenerationService.shared
        let now = Date()
        for job in jobs where !job.state.isTerminal {
            let key = job.id.uuidString.lowercased()
            guard !engine.hasActiveWorker(jobID: key) else { continue }
            // A lost one-shot image worker may have died after committing
            // verified bytes but before the receipt CAS. Adopt only the
            // deterministic files in the ORIGINAL pinned workspace; a still
            // incomplete batch is never claimed as delivered.
            if job.mediaKind == .image, job.providerTaskID == nil,
               job.state == .preparing || job.state == .submitted,
               let payload = try? decodePayload(job),
               await reconcileImageDelivery(
                    env: env, conversationID: conversationID,
                    owner: .conversation(conversationID), jobID: job.id,
                    payload: payload) {
                continue
            }
            if job.mediaKind == .video, job.providerTaskID != nil {
                // Same bounded shared table; a full/stopping table refuses and
                // the next refresh/resume retries against the durable row.
                _ = startWorker(epoch: epoch, jobID: key, kind: .video) { [weak self] token in
                    guard let self else { return }
                    await self.runVideoPoll(token: token, epoch: epoch, jobID: job.id)
                }
            } else if job.providerTaskID == nil,
                      job.state == .preparing || job.state == .submitted,
                      now.timeIntervalSince(job.createdAt)
                          > G09R2GenerationService.stalePreparingSeconds {
                try? await store.transition(id: job.id, to: .expired) {
                    $0.lastError = "outcomeUnknown"
                    $0.nextPollAt = nil
                }
            }
        }
    }

    /// Host refresh entry (the App's "refresh media jobs" action, BridgeV28):
    /// reconcile THIS conversation's durable media jobs through the exact
    /// resume/stale authorities above and return their bounded projections.
    /// This NEVER submits: the pump only restarts poll workers for retained
    /// accepted rows and classifies lost single-shot rows unknown — the same
    /// relaunch-resume semantics, on demand. A stopping or unavailable root
    /// refuses typed before any work; projections retain conversation ownership.
    public func refreshConversationJobs(
        epoch: UInt64, conversationID: UUID
    ) async throws -> [G09R2AgentJobStatus] {
        // Fence the exact accepted root BEFORE the pump (the pump itself also
        // re-checks; a stopping root must report the typed refusal, not run).
        _ = try await requireEnvironment(epoch: epoch)
        await resumeStaleJobs(epoch: epoch, conversationID: conversationID)
        let env = try await requireEnvironment(epoch: epoch)
        let store = MediaGenerationJobStore(database: env.database)
        let owned = try await store.jobs(owner: .conversation(conversationID))
        var statuses: [G09R2AgentJobStatus] = []
        for job in owned.prefix(Self.maximumRefreshedJobs) {
            let checked = try await requireOwnedJob(
                store: store, jobID: job.id, conversationID: conversationID)
            statuses.append(projection(checked))
        }
        return statuses
    }

    // MARK: - Private helpers (shared G09R2 execution)

    /// The exact durable job a replayed tool call already owns. The key is
    /// the submitting operation identity (`runID:toolCallID`, or the
    /// deterministic digest of the exact request), so a replay after a lost
    /// reply, a crash or a terminal settlement attaches to the ORIGINAL row
    /// instead of paying for a second provider request. Ownership and request
    /// identity are both re-checked; a mismatched key never attaches.
    private func replayOwnedJob(
        store: MediaGenerationJobStore,
        owner: MediaJobOwner,
        idempotencyKey: String,
        kind: MediaKind,
        matches: (G09R2AgentGenerationPayload) -> Bool
    ) async throws -> OwnedMediaGenerationJob? {
        guard let existing = try await store.ownedJob(
                idempotencyKey: idempotencyKey),
              existing.owner == owner,
              existing.job.mediaKind == kind,
              let payload = try? decodePayload(existing.job),
              matches(payload) else {
            return nil
        }
        return existing
    }

    /// Replayed-request summary over the EXISTING durable row (including a
    /// terminal one). It reports the stored truth; it never claims a new
    /// submission or a delivered artifact.
    private func submissionSummary(
        owned: OwnedMediaGenerationJob, deduplicated: Bool,
        env: G09R2GenerationEnvironment,
        blockedByUnresolvedUnknown: UUID? = nil
    ) async -> G09R2AgentSubmissionSummary {
        let payload = try? decodePayload(owned.job)
        let providers = (try? await env.configuration.providers()) ?? []
        let provider = providers.first { $0.id == owned.job.providerID }
        let providerName = provider?.displayName
            ?? provider?.kind.rawValue ?? "provider"
        return G09R2AgentSubmissionSummary(
            jobID: owned.job.id, state: owned.job.state,
            providerTaskID: owned.job.providerTaskID,
            providerName: providerName,
            remoteModelID: payload?.remoteModelID ?? "",
            deduplicated: deduplicated,
            estimatedCompletionAt: owned.job.estimatedCompletionAt,
            lastError: owned.job.lastError,
            blockedByUnresolvedUnknown: blockedByUnresolvedUnknown)
    }

    /// Registers work on the ONE bounded shared generation worker table. The
    /// boolean is returned to the caller: a stopping/full table never falls
    /// back to an untracked task here. Every registration and lookup uses the
    /// LOWERCASED job key — the shared table's `requestCancel`/`hasActiveWorker`
    /// normalize to lowercase, so any other spelling would make a cancel or
    /// refresh miss its exact live worker (the UI flow already uses lowercase
    /// keys end to end).
    private func startWorker(
        epoch: UInt64, jobID: String, kind: G09R2GenerationKind,
        body: @escaping @Sendable (String) async -> Void
    ) -> Bool {
        G09R2GenerationService.shared.startWorker(
            epoch: epoch, jobID: jobID, kind: kind, body: body)
    }

    private func isWorkerCancelled(token: String) -> Bool {
        G09R2GenerationService.shared.isWorkerCancelled(token)
    }

    private func throwIfCancelled(token: String) throws {
        if isWorkerCancelled(token: token) { throw CancellationError() }
    }

    private func requireEnvironment(epoch: UInt64) async throws
        -> G09R2GenerationEnvironment {
        guard !G09R2GenerationService.shared.isRootStopping(epoch: epoch),
              let env = await environmentProvider(epoch) else {
            throw G09CreativeError.staleGeneration
        }
        return env
    }

    private func projection(_ owned: OwnedMediaGenerationJob) -> G09R2AgentJobStatus {
        let job = owned.job
        let payload = try? decodePayload(job)
        // Historical ready rows may predate the receipt upsert repair. A state
        // label alone cannot claim delivery; preserve legacy single-file receipts.
        let artifacts = payload?.artifacts ?? []
        let hasTypedReceipt = !artifacts.isEmpty && artifacts.allSatisfy {
            !$0.relativePath.isEmpty && $0.byteCount > 0 && $0.sha256.count == 64
        }
        let hasLegacyReceipt = payload?.workspaceRelativePath?.isEmpty == false
            && (payload?.deliveredByteCount ?? 0) > 0
            && payload?.deliveredSHA256?.count == 64
        let missingReceipt = job.state == .ready && !hasTypedReceipt && !hasLegacyReceipt
        return G09R2AgentJobStatus(
            jobID: job.id, state: job.state, terminated: job.state.isTerminal,
            canCancel: !job.state.isTerminal,
            ready: job.state == .ready && !missingReceipt,
            mediaKind: job.mediaKind.rawValue,
            providerTaskID: job.providerTaskID,
            resultURL: job.resultURL,
            resultURLExpiresAt: job.resultURLExpiresAt,
            artifacts: payload?.artifacts,
            workspaceRelativePath: payload?.workspaceRelativePath,
            deliveredByteCount: payload?.deliveredByteCount,
            deliveredSHA256: payload?.deliveredSHA256,
            nextPollAt: job.nextPollAt,
            lastError: missingReceipt ? "missingArtifactReceipt" : job.lastError)
    }

    private func requireOwnedJob(
        store: MediaGenerationJobStore, jobID: UUID, conversationID: UUID
    ) async throws -> OwnedMediaGenerationJob {
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw FloeError.notFound("generation job \(jobID.uuidString)")
        }
        guard owned.owner.kind == .conversation, owned.owner.id == conversationID else {
            throw FloeError.validationFailed(
                "This generation job is not owned by the current conversation")
        }
        return owned
    }

    /// One fully validated provider image, still in memory and not yet
    /// published. The producer receipt is built from exactly these values.
    private struct PreparedImage: Sendable {
        var index: Int
        var data: Data
        var relativePath: String
        var mimeType: String
        var byteCount: Int64
        var sha256: String
    }

    /// Validates and names the provider-returned image batch BEFORE any
    /// workspace publication. The names are deterministic and
    /// job-identifiable (`GeneratedMedia/image-<jobID>-<index>.<ext>`), but
    /// the name alone is never delivery authority: the App-owned producer
    /// receipt below carries the exact MIME/count/size/hash of these bytes.
    private func prepareImageBatch(
        _ images: [Data], jobID: UUID
    ) throws -> [PreparedImage] {
        var total: Int64 = 0
        let jobKey = jobID.uuidString.lowercased()
        return try images.enumerated().map { index, data in
            guard Int64(data.count) <= G09R2MediaProbe.maximumGeneratedImageBytes,
                  let facts = G09R2MediaProbe.imageFacts(data) else {
                throw FloeError.validationFailed("generatedImageInvalid")
            }
            total += Int64(data.count)
            guard total <= G09R2MediaProbe.maximumGeneratedImageBatchBytes else {
                throw FloeError.validationFailed("generatedImageBatchTooLarge")
            }
            let ext = G09R2MediaProbe.imageExtension(mimeType: facts.mimeType)
            return PreparedImage(
                index: index + 1, data: data,
                relativePath: "GeneratedMedia/image-\(jobKey)-\(index + 1).\(ext)",
                mimeType: facts.mimeType,
                byteCount: Int64(data.count),
                sha256: FloeDigest.sha256Hex(data))
        }
    }

    /// Publishes the prepared batch into the pinned task workspace. The
    /// previous verified file is kept until its atomic replacement is in
    /// place, and the committed file is read back against the prepared
    /// digest before it can be receipted.
    private func writePreparedImages(
        _ images: [PreparedImage], workspaceRootURL: URL
    ) throws -> [G09R2AgentGenerationArtifact] {
        let resolvedRoot = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = resolvedRoot.appendingPathComponent(
            "GeneratedMedia", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/") else {
            throw FloeError.invalidConfiguration("workspaceUnavailable")
        }
        var written: [G09R2AgentGenerationArtifact] = []
        for image in images.sorted(by: { $0.index < $1.index }) {
            let name = URL(fileURLWithPath: image.relativePath).lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let url = resolvedDirectory.appendingPathComponent(name)
            let temporary = resolvedDirectory.appendingPathComponent(
                ".\(base).\(UUID().uuidString.lowercased()).part")
            do {
                try image.data.write(to: temporary, options: [])
                try G09R2CandidateStore.flushFile(temporary)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(
                        url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
                try G09R2CandidateStore.flushFile(url)
                guard G09R2CandidateStore.verifyCandidateFile(
                    url, byteCount: image.byteCount, sha256: image.sha256) else {
                    throw FloeError.validationFailed("generatedImageWriteMismatch")
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            // A prior attempt may have produced another sniffed format for
            // this same index. Keep exactly the receipted replacement.
            if let names = try? FileManager.default.contentsOfDirectory(
                atPath: resolvedDirectory.path) {
                for other in names where other.hasPrefix("\(base).") && other != name {
                    try? FileManager.default.removeItem(
                        at: resolvedDirectory.appendingPathComponent(other))
                }
            }
            written.append(G09R2AgentGenerationArtifact(
                relativePath: image.relativePath,
                mimeType: image.mimeType,
                byteCount: image.byteCount,
                sha256: image.sha256))
        }
        try G09R2CandidateStore.flushDirectory(resolvedDirectory)
        return written
    }

    /// Persists the App-owned producer receipt in the durable job row BEFORE
    /// any workspace byte is published. The row re-read is the proof that the
    /// receipt is actually durable; a terminal/cancelled row or a failed
    /// write refuses publication instead of leaving unverifiable files.
    private func persistProducerReceipt(
        store: MediaGenerationJobStore, jobID: UUID,
        payload: G09R2AgentGenerationPayload,
        receipt: G09R2AgentGenerationProducerReceipt
    ) async throws {
        var updated = payload
        updated.producerReceipt = receipt
        let updatedPayload = updated
        let persisted: Bool = try await finalizeDespiteCancellation {
            [self, store, updatedPayload, receipt] in
            try await store.transition(id: jobID, to: .submitted) {
                var current = (try? JSONDecoder().decode(
                    G09R2AgentGenerationPayload.self,
                    from: $0.requestJSON)) ?? updatedPayload
                guard current.requestIdentityEquals(updatedPayload) else { return }
                current.producerReceipt = receipt
                $0.requestJSON = (try? self.encoder().encode(current))
                    ?? $0.requestJSON
            }
            guard let row = try await store.ownedJob(id: jobID),
                  let stored = try? JSONDecoder().decode(
                    G09R2AgentGenerationPayload.self,
                    from: row.job.requestJSON),
                  stored.producerReceipt?.bindsSameProducerProof(as: receipt)
                    == true else {
                return false
            }
            return true
        }
        guard persisted else {
            throw FloeError.invalidConfiguration("producerReceiptNotPersisted")
        }
    }

    /// Commits the typed delivery receipt for a verified image batch. The
    /// whole CAS runs in a non-cancelled hop: a local stop that arrived after
    /// the provider returned must not strand real bytes behind an
    /// `outcomeUnknown` row. A cancel/terminal settlement that won the race
    /// keeps its state (`invalidStateTransition`), and this method rethrows it
    /// so the caller can stop without claiming delivery.
    private func commitImageReceipt(
        store: MediaGenerationJobStore, jobID: UUID,
        payload: G09R2AgentGenerationPayload,
        artifacts: [G09R2AgentGenerationArtifact]
    ) async throws {
        try await finalizeDespiteCancellation { [self, store, payload, artifacts] in
            try await store.transition(id: jobID, to: .ready) {
                // A late worker or another recovery already published this
                // exact job; keep its existing receipt. (`ready -> ready` is
                // a legal self-transition in the durable state machine.)
                if $0.state == .ready { return }
                var updated = payload
                updated.artifacts = artifacts
                // The legacy scalar view is honest: populated exactly for a
                // single-artifact result, nil for a multi-image batch.
                if artifacts.count == 1, let first = artifacts.first {
                    updated.workspaceRelativePath = first.relativePath
                    updated.deliveredByteCount = first.byteCount
                    updated.deliveredSHA256 = first.sha256
                } else {
                    updated.workspaceRelativePath = nil
                    updated.deliveredByteCount = nil
                    updated.deliveredSHA256 = nil
                }
                $0.requestJSON = (try? self.encoder().encode(updated)) ?? $0.requestJSON
                $0.lastError = nil
                $0.nextPollAt = nil
            }
        }
    }

    /// Re-adopts an image batch ONLY when the durable App-owned producer
    /// receipt proves the exact provider bytes for this exact job/request/
    /// owner. The workspace is model-writable, so a deterministic filename, a
    /// valid PNG or a hash computed from the workspace file is NOT delivery
    /// authority. Every receipted output must exist with the receipted MIME,
    /// byte count and SHA-256; the full requested count is required. No
    /// provider call is ever made here, and a terminal row is never
    /// resurrected.
    private func reconcileImageDelivery(
        env: G09R2GenerationEnvironment, conversationID: UUID,
        owner: MediaJobOwner, jobID: UUID, payload: G09R2AgentGenerationPayload
    ) async -> Bool {
        guard payload.count > 0, payload.count <= 4,
              let receipt = payload.producerReceipt,
              receipt.schemaVersion == 1,
              receipt.jobID == jobID,
              receipt.ownerKind == owner.kind.rawValue,
              receipt.ownerID == owner.id,
              receipt.requestDigest.count == 64,
              receipt.requestDigest == payload.requestDigest(),
              receipt.providerID == payload.providerID,
              receipt.modelID == payload.modelID,
              receipt.remoteModelID == payload.remoteModelID,
              receipt.count == payload.count,
              receipt.images.count == payload.count else {
            return false
        }
        let root: URL
        do {
            root = try await resolvePinnedWorkspaceRoot(
                env: env, payload: payload, conversationID: conversationID)
        } catch {
            // A migrated/revoked owner or corrupt pinned target must never be
            // repaired by choosing a current/guessed root.
            return false
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let generated = resolvedRoot.appendingPathComponent(
            "GeneratedMedia", isDirectory: true)
        let resolvedGenerated = generated.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedGenerated.path.hasPrefix(resolvedRoot.path + "/") else {
            return false
        }
        let jobKey = jobID.uuidString.lowercased()
        var artifacts: [G09R2AgentGenerationArtifact] = []
        var total: Int64 = 0
        var seenIndices = Set<Int>()
        for image in receipt.images.sorted(by: { $0.index < $1.index }) {
            guard (1...payload.count).contains(image.index),
                  seenIndices.insert(image.index).inserted,
                  image.mimeType == "image/png" || image.mimeType == "image/jpeg",
                  image.byteCount > 0,
                  image.byteCount <= G09R2MediaProbe.maximumGeneratedImageBytes,
                  image.sha256.count == 64 else {
                return false
            }
            let ext = G09R2MediaProbe.imageExtension(mimeType: image.mimeType)
            let expectedPath =
                "GeneratedMedia/image-\(jobKey)-\(image.index).\(ext)"
            guard image.relativePath == expectedPath else { return false }
            let url = resolvedRoot.appendingPathComponent(image.relativePath)
            guard url.standardizedFileURL.resolvingSymlinksInPath()
                    .deletingLastPathComponent().path == resolvedGenerated.path,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size == image.byteCount else {
                return false
            }
            total += image.byteCount
            guard total <= G09R2MediaProbe.maximumGeneratedImageBatchBytes else {
                return false
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let facts = G09R2MediaProbe.imageFacts(data),
                  facts.mimeType == image.mimeType,
                  FloeDigest.sha256Hex(data) == image.sha256 else {
                return false
            }
            // The delivery receipt is the TRUSTED values, not values
            // recomputed from the workspace.
            artifacts.append(G09R2AgentGenerationArtifact(
                relativePath: image.relativePath,
                mimeType: image.mimeType,
                byteCount: image.byteCount,
                sha256: image.sha256))
        }
        guard seenIndices.count == payload.count else { return false }
        let store = MediaGenerationJobStore(database: env.database)
        do {
            try await commitImageReceipt(
                store: store, jobID: jobID, payload: payload,
                artifacts: artifacts)
            return true
        } catch {
            return false
        }
    }

    /// Commits one fully received provider video into the task workspace
    /// without loading it into memory. The staged bytes are verified against
    /// the streaming download receipt FIRST; the existing delivered output
    /// (when a re-delivery replaces it) is retained until the verified
    /// replacement is atomically in place; the extension comes from sniffed
    /// container facts, never a hard-coded mp4.
    private func moveDeliveredVideo(
        _ receipt: G09R2DownloadReceipt, workspaceRoot: URL, jobID: UUID
    ) throws -> G09R2AgentGenerationArtifact {
        let staged = receipt.fileURL
        guard G09R2CandidateStore.verifyCandidateFile(
            staged, byteCount: receipt.byteCount, sha256: receipt.sha256) else {
            throw FloeError.validationFailed("deliveredVideoDigestMismatch")
        }
        guard let facts = G09R2MediaProbe.videoFacts(fileURL: staged) else {
            throw FloeError.validationFailed("deliveredVideoFormatUnsupported")
        }
        let directory = workspaceRoot.appendingPathComponent("GeneratedMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "video-\(jobID.uuidString.lowercased()).\(G09R2MediaProbe.videoExtension(mimeType: facts.mimeType))"
        let destination = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(
            ".\(name).\(UUID().uuidString.lowercased()).part")
        do {
            try FileManager.default.copyItem(at: staged, to: temporary)
            try G09R2CandidateStore.flushFile(temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Verified replacement: the previous output stays until the
                // new bytes are durable in the same directory.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try G09R2CandidateStore.flushDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FloeError.invalidConfiguration("deliveredVideoCommitFailed")
        }
        guard G09R2CandidateStore.verifyCandidateFile(
            destination, byteCount: receipt.byteCount, sha256: receipt.sha256) else {
            // Never publish a mismatched commit; the row stays non-terminal
            // and a later poll re-delivers the verified bytes.
            throw FloeError.validationFailed("deliveredVideoCommitMismatch")
        }
        return G09R2AgentGenerationArtifact(
            relativePath: "GeneratedMedia/\(name)",
            mimeType: facts.mimeType,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256)
    }

    /// Delivery fence: the original validated output owner was explicitly
    /// migrated or revoked while provider work was in flight. Delivery must
    /// fail honestly; nothing may be published into the current or guessed
    /// owner.
    private enum AgentDeliveryFence: Error {
        case targetChanged
    }

    /// Pins the ORIGINAL validated delivery target at submission. Resolves the
    /// durable conversation→workspace ownership through the ORIGINAL
    /// `SQLiteWorkspaceStore` (the same binding the run's workspace root came
    /// from) and cross-checks the derived root against the submitting tool
    /// context's root. Only store-derived authority metadata is persisted —
    /// never a model-provided root.
    private func pinWorkspaceTarget(
        env: G09R2GenerationEnvironment, conversationID: UUID,
        submittingRoot: URL
    ) async throws -> (workspaceID: UUID, rootPath: String) {
        let resolved = try await resolveOwnedWorkspaceRoot(
            env: env, conversationID: conversationID)
        guard Self.sameWorkspaceRoot(resolved.root, submittingRoot) else {
            throw FloeError.invalidConfiguration("workspaceUnavailable")
        }
        return (resolved.workspaceID, resolved.root.path)
    }

    /// Revalidates the pinned ORIGINAL target before any delivered byte is
    /// committed (delayed callback, restart or resume). The conversation must
    /// still own the pinned workspace, the pinned row must still exist with
    /// its original relative path, and the re-derived root must equal the
    /// pinned root. Any explicit migration/revocation throws the fence.
    private func resolvePinnedWorkspaceRoot(
        env: G09R2GenerationEnvironment,
        payload: G09R2AgentGenerationPayload, conversationID: UUID
    ) async throws -> URL {
        guard let pinnedID = payload.targetWorkspaceID,
              let pinnedRoot = payload.targetWorkspaceRootPath,
              !pinnedRoot.isEmpty else {
            // Rows without a pinned target predate this closure; the current
            // workspace is never chosen and a root is never reconstructed.
            throw G09CreativeError.invalidPayload("corruptPayload")
        }
        let workspaceStore = SQLiteWorkspaceStore(database: env.database)
        guard let currentID = try? await workspaceStore.workspaceID(
                conversationID: conversationID),
              currentID == pinnedID,
              let record = try? await workspaceStore.workspace(id: pinnedID),
              let relative = record.internalRelativePath, !relative.isEmpty else {
            throw AgentDeliveryFence.targetChanged
        }
        let resolved = try await resolveOwnedWorkspaceRoot(
            env: env, conversationID: conversationID)
        guard resolved.workspaceID == pinnedID, resolved.root.path == pinnedRoot else {
            throw AgentDeliveryFence.targetChanged
        }
        return resolved.root
    }

    /// The original resolver discipline for ONE owned conversation workspace:
    /// the durable ownership row plus the store record's exact relative path,
    /// symlink-resolved and re-contained under the accepted root's Workspace
    /// directory. No lexical-only authority, no guessed directory.
    private func resolveOwnedWorkspaceRoot(
        env: G09R2GenerationEnvironment, conversationID: UUID
    ) async throws -> (workspaceID: UUID, root: URL) {
        let workspaceStore = SQLiteWorkspaceStore(database: env.database)
        guard let workspaceID = try? await workspaceStore.workspaceID(
                conversationID: conversationID),
              let record = try? await workspaceStore.workspace(id: workspaceID),
              let relative = record.internalRelativePath, !relative.isEmpty else {
            throw FloeError.invalidConfiguration("workspaceUnavailable")
        }
        let base = URL(fileURLWithPath: env.root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard root.path.hasPrefix(base.path + "/") else {
            throw FloeError.invalidConfiguration("workspaceUnavailable")
        }
        return (workspaceID, root)
    }

    private static func sameWorkspaceRoot(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Local worker stop, network interruption or poll-budget exhaustion
    /// never settles an ACCEPTED remote job terminal: the retained provider
    /// handle stays queryable/resumable through `video.status(refresh:)` and
    /// relaunch resume. Only a handle-less row falls back to the durable
    /// unknown terminal state.
    private func retainAcceptedJob(epoch: UInt64, jobID: UUID) async {
        // The whole read+write runs in the non-cancelled hop: this is called
        // from worker tasks that already received a local stop, and a
        // cancelled writer would silently drop the retention marker. Root
        // drain is still honored — a stopping root skips the write exactly
        // as before.
        _ = try? await finalizeDespiteCancellation { [self] in
            guard let env = try? await self.requireEnvironment(epoch: epoch) else { return }
            let store = MediaGenerationJobStore(database: env.database)
            guard let owned = try? await store.ownedJob(id: jobID),
                  !owned.job.state.isTerminal else { return }
            guard owned.job.providerTaskID != nil else {
                // A handle-less row falls back to the durable unknown
                // terminal state (same fields `finishJob` would write).
                _ = try await store.transition(id: jobID, to: .expired) {
                    $0.lastError = "outcomeUnknown"
                    $0.nextPollAt = nil
                }
                return
            }
            // Keep the exact durable state (self-transition) with an explicit
            // unknown marker and no scheduled poll: the retained handle is
            // re-queried only by an explicit refresh/resume — never resubmitted.
            _ = try await store.transition(id: jobID, to: owned.job.state) {
                $0.lastError = "outcomeUnknown"
                $0.nextPollAt = nil
            }
        }
    }

    /// Reads one workspace-relative reference image through the ORIGINAL
    /// rooted path guard: symlinks are resolved and cannot escape the
    /// workspace, secret-file exclusions apply, and the size bound is
    /// enforced BEFORE any byte is read. The bytes are read exactly once.
    private func readWorkspaceImage(
        _ relative: String, root: URL, maximumBytes: Int,
        requireImageFacts: Bool
    ) throws -> Data {
        let pathGuard = WorkspacePathGuard(
            rootURL: root, maxReadBytes: maximumBytes)
        let url: URL
        do {
            url = try pathGuard.resolve(relative)
            try pathGuard.assertReadableSize(url)
        } catch let error as WorkspaceToolError {
            throw FloeError.validationFailed(Self.boundedWorkspaceError(error))
        }
        let data: Data
        do {
            data = try Data(floeContentsOf: url)
        } catch {
            throw FloeError.validationFailed("reference image is not readable")
        }
        guard data.count <= maximumBytes else {
            throw FloeError.validationFailed("reference image exceeds the byte bound")
        }
        guard VideoReferenceImagePolicy.detectedMIMEType(data) != nil else {
            throw FloeError.validationFailed("reference image is not a readable PNG/JPEG/WebP")
        }
        if requireImageFacts {
            // Image edit/generate sources must be provable PNG/JPEG with
            // real dimensions (same rule as the UI-owned read path).
            guard let facts = G09R2MediaProbe.imageFacts(data),
                  facts.mimeType == "image/png" || facts.mimeType == "image/jpeg" else {
                throw FloeError.validationFailed("reference image is not a readable PNG/JPEG")
            }
        }
        return data
    }

    static func boundedWorkspaceError(_ error: WorkspaceToolError) -> String {
        switch error {
        case .invalidArguments(let message):
            return Self.boundedCodeText(message) ?? "invalidReferencePath"
        case .escapesRoot:
            return "reference image escapes the workspace"
        case .secretFile:
            return "reference image is an excluded secret file"
        case .tooLarge:
            return "reference image exceeds the byte bound"
        default:
            return "invalidReferencePath"
        }
    }

    private func finishJob(
        epoch: UInt64, jobID: UUID, code: String, definite: Bool,
        diagnostic: G09R2AgentGenerationDiagnostic? = nil
    ) async {
        // Runs in the non-cancelled hop: this is the honest terminal
        // settlement for transport/stop failures and is frequently reached
        // from a worker task that already received a local stop — a
        // cancelled writer must not silently drop it. Root drain is still
        // honored exactly as before.
        _ = try? await finalizeDespiteCancellation { [self] in
            guard let env = try? await self.requireEnvironment(epoch: epoch) else { return }
            let store = MediaGenerationJobStore(database: env.database)
            guard let owned = try? await store.ownedJob(id: jobID),
                  !owned.job.state.isTerminal else { return }
            // A trusted producer receipt means the provider already returned
            // real bytes. Never terminalize a recoverable image result on a
            // local delivery error: adopt the fully verified batch now, or
            // leave the row non-terminal so a later refresh can verify it.
            // The explicit target fence remains a definite failure (the
            // original owner is gone; the result must not move).
            if owned.job.mediaKind == .image,
               let payload = try? self.decodePayload(owned.job),
               payload.producerReceipt != nil {
                if await self.reconcileImageDelivery(
                    env: env, conversationID: owned.owner.id,
                    owner: owned.owner, jobID: jobID, payload: payload) {
                    return
                }
                if code != "targetChanged" { return }
            }
            let state: MediaGenerationJobState = definite
                ? (code == "cancelled" ? .cancelled : .failed)
                : .expired
            // The bounded wire/settlement trace is part of the SAME durable
            // terminal CAS: a failed job always carries its own local,
            // non-secret evidence of how far the request got. It is excluded
            // from the request/replay identity, so it can never turn a
            // replay into a conflict or a paid second submission.
            _ = try await store.transition(id: jobID, to: state) {
                $0.lastError = code
                $0.nextPollAt = nil
                if let diagnostic,
                   let decoded = try? JSONDecoder().decode(
                        G09R2AgentGenerationPayload.self, from: $0.requestJSON) {
                    var current = decoded
                    current.diagnostics = diagnostic
                    if let encoded = try? self.encoder().encode(current) {
                        $0.requestJSON = encoded
                    }
                }
            }
        }
    }

    /// Bounded failure class for the durable diagnostic. Never contains a
    /// prompt, key, endpoint or provider body: fixed class names, an HTTP
    /// status code or a platform error-code identifier only.
    static func imageFailureCode(for error: Error) -> String {
        if let remote = error as? RemoteImageError {
            switch remote {
            case .unsupportedOperation: return "unsupportedOperation"
            case .requestFailed: return "requestFailed"
            case .providerRejected(let statusCode, _): return "http\(statusCode)"
            case .invalidResponse: return "invalidResponse"
            }
        }
        if error is CancellationError { return "cancelled" }
        if let transport = error as? IncrementalTransportError {
            switch transport {
            case .responseTooLarge: return "transport.responseTooLarge"
            case .pendingBufferSaturated:
                return "transport.pendingBufferSaturated"
            case .sessionNotStreamable:
                return "transport.sessionNotStreamable"
            case .noHTTPResponse: return "transport.noHTTPResponse"
            }
        }
        if let code = urlErrorCode(error) {
            return boundedCodeText("urlError.\(urlErrorCodeName(code))")
                ?? "urlError.other"
        }
        if let typed = error as? G09CreativeError {
            return boundedCodeText(typed.code) ?? "generationFailed"
        }
        return boundedCode(error)
    }

    /// Distinguishes a DEFINITE pre-dispatch failure (no HTTP request could
    /// have been accepted, so no paid result can exist) from every ambiguous
    /// post-dispatch failure. Once the adapter observed any response — or a
    /// provider-issued image download started, which proves the paid
    /// generation already returned a URL — nothing is definite: the local
    /// download/commit failure must stay `outcomeUnknown`, never be reported
    /// as a non-billed provider failure.
    static func isDefinitePreDispatchTransportFailure(
        _ error: Error, stages: [String]
    ) -> Bool {
        guard !stages.contains(RemoteImageWirePhase.responseReceived.rawValue),
              !stages.contains(RemoteImageWirePhase.downloadStarted.rawValue),
              !stages.contains(RemoteImageWirePhase.downloadCompleted.rawValue),
              !stages.contains(RemoteImageWirePhase.imagesDecoded.rawValue)
        else { return false }
        if let transport = error as? IncrementalTransportError {
            if case .sessionNotStreamable = transport { return true }
            return false
        }
        // URL error names do not attest that no paid request was sent:
        // a redirect or a later connection failure can follow acceptance,
        // and a missing observer is not negative dispatch evidence. Retain
        // the unknown result unless the transport itself proved refusal
        // before creating a request task (sessionNotStreamable above).
        return false
    }

    /// Provider-typed bound on the failure diagnostic for one image attempt.
    static func imageFailureDiagnostic(
        _ recorder: G09R2WirePhaseRecorder,
        error: Error,
        code: String? = nil
    ) -> G09R2AgentGenerationDiagnostic {
        let stages = recorder.snapshot()
        let failureCode = code.map { boundedCodeText($0) ?? "generationFailed" }
            ?? imageFailureCode(for: error)
        return G09R2AgentGenerationDiagnostic(
            stages: stages, failureCode: failureCode)
    }

    /// The platform URL error code, or nil when the error is not a URL
    /// loading error. Handles both the Swift `URLError` value and a bridged
    /// `NSError` without exposing any message text.
    static func urlErrorCode(_ error: Error) -> URLError.Code? {
        if let urlError = error as? URLError { return urlError.code }
        let bridged = error as NSError
        guard bridged.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: bridged.code)
    }

    private static func urlErrorCodeName(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .cannotFindHost: return "cannotFindHost"
        case .cannotConnectToHost: return "cannotConnectToHost"
        case .dnsLookupFailed: return "dnsLookupFailed"
        case .networkConnectionLost: return "networkConnectionLost"
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .secureConnectionFailed: return "secureConnectionFailed"
        case .badURL: return "badURL"
        case .unsupportedURL: return "unsupportedURL"
        case .userAuthenticationRequired: return "userAuthenticationRequired"
        case .resourceUnavailable: return "resourceUnavailable"
        default: return "other"
        }
    }

    private func decodePayload(_ job: MediaGenerationJob) throws
        -> G09R2AgentGenerationPayload {
        do {
            return try JSONDecoder().decode(
                G09R2AgentGenerationPayload.self, from: job.requestJSON)
        } catch {
            throw G09CreativeError.invalidPayload("corruptPayload")
        }
    }

    func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func boundedCode(_ error: Error) -> String {
        boundedCodeText(error.localizedDescription) ?? "generationFailed"
    }

    static func boundedCodeText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let allowed = text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "." || $0 == "_" || $0 == "-"
        }
        guard allowed, text.utf8.count <= 64 else { return "generationFailed" }
        return text
    }
}

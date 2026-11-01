// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — streamed large-import foundation (job-b72b2978320e484e).
//
// Reuses the EXISTING R1 staging token (`FloeAgent/CreativeIncoming`), the
// durable media intent/CAS/receipt path and the atomic `createFromSource`
// publication. It adds only the R2 per-kind policy ceilings, a streamed
// digest/progress/cancel pass over the App-staged bytes, a bounded
// service-owned job table and a truthful terminal outcome:
//
//  * pre-commit cancellation publishes NO project (no empty pre-create);
//  * the source file is never modified — the service only reads it;
//  * post-commit truth is completed/unknown, never a blind retry or rollback;
//  * jobs are not a second project DB; the media host remains the truth.
//
// Missing wire action (reported to Main, not invented here): the frozen V6
// action list has no large-import action. The exact minimal pre-staging point
// this service requires from a later reviewed wire action is documented in
// the handoff: a command carrying this metadata (token, kind, fileName,
// mimeType, byteCount, sha256, host-measured mediaMetadata) plus an explicit
// storage/origin/session/opID for new-project import.
import Foundation
import FloeCore
import FloeAndroidWorkbench

/// Additive native-side staged metadata. It is the frozen
/// `G09R2StagedImportMetadataDTO` PLUS the host-measured media metadata the
/// atomic new-project path needs (a later wire action must carry both).
public struct G09R2LargeImportMetadata: Sendable, Equatable {
    public var token: String
    public var kind: G09R2LargeImportKind
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var mediaMetadata: MediaAssetMetadata?

    public init(token: String, kind: G09R2LargeImportKind, fileName: String,
                mimeType: String? = nil, byteCount: Int64, sha256: String,
                mediaMetadata: MediaAssetMetadata? = nil) {
        self.token = token
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mediaMetadata = mediaMetadata
    }

    public init(_ dto: G09R2StagedImportMetadataDTO,
                mediaMetadata: MediaAssetMetadata? = nil) {
        self.init(token: dto.token, kind: dto.kind, fileName: dto.fileName,
                  mimeType: dto.mimeType, byteCount: dto.byteCount,
                  sha256: dto.sha256, mediaMetadata: mediaMetadata)
    }

    public var dto: G09R2StagedImportMetadataDTO {
        G09R2StagedImportMetadataDTO(
            token: token, kind: kind, fileName: fileName,
            mimeType: mimeType, byteCount: byteCount, sha256: sha256)
    }
}

public struct G09R2StagedImportValidationDTO: Sendable, Equatable {
    public var accepted: Bool
    public var requiredFreeBytes: Int64
    public var maxBytes: Int64
    public var refusalCode: String?

    public init(accepted: Bool, requiredFreeBytes: Int64, maxBytes: Int64,
                refusalCode: String?) {
        self.accepted = accepted
        self.requiredFreeBytes = requiredFreeBytes
        self.maxBytes = maxBytes
        self.refusalCode = refusalCode
    }
}

public enum G09R2LargeImportState: String, Codable, Sendable, CaseIterable {
    case queued
    case staging
    case verifying
    case importing
    case committing
    case completed
    case cancelled
    case failed
    case interrupted
}

public struct G09R2LargeImportJobHandleDTO: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: G09R2LargeImportState
    public var acceptedAt: Date

    public init(jobID: String, state: G09R2LargeImportState, acceptedAt: Date) {
        self.jobID = jobID
        self.state = state
        self.acceptedAt = acceptedAt
    }
}

public struct G09R2LargeImportStatusDTO: Encodable, Sendable {
    public var jobID: String
    public var state: G09R2LargeImportState
    public var updatedAt: Date
    public var progress: Double?
    public var createdProjectID: UUID?
    public var createdRevision: Int64?
    public var asset: G09MediaAssetReceiptDTO?
    public var errorCode: String?
    public var retryable: Bool

    public init(jobID: String, state: G09R2LargeImportState, updatedAt: Date,
                progress: Double?, createdProjectID: UUID?,
                createdRevision: Int64?, asset: G09MediaAssetReceiptDTO?,
                errorCode: String?, retryable: Bool) {
        self.jobID = jobID
        self.state = state
        self.updatedAt = updatedAt
        self.progress = progress
        self.createdProjectID = createdProjectID
        self.createdRevision = createdRevision
        self.asset = asset
        self.errorCode = errorCode
        self.retryable = retryable
    }
}

public struct G09R2LargeImportStatusRequest: Codable, Sendable, Equatable {
    public var jobID: String
    public var sessionToken: String
}

public struct G09R2LargeImportCancelRequest: Codable, Sendable, Equatable {
    public var jobID: String
    public var sessionToken: String
    public var opID: String
}

/// CONTRACT FREEZE V2 wire metadata. It is the frozen
/// `G09R2StagedImportMetadataDTO` plus the host-measured media metadata the
/// atomic new-project path requires. The staged BYTES never cross the wire.
public struct G09R2LargeImportWireMetadata: Codable, Sendable, Equatable {
    public var token: String
    public var kind: G09R2LargeImportKind
    public var fileName: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var mediaMetadata: MediaAssetMetadata?

    public init(token: String, kind: G09R2LargeImportKind, fileName: String,
                mimeType: String? = nil, byteCount: Int64, sha256: String,
                mediaMetadata: MediaAssetMetadata? = nil) {
        self.token = token
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mediaMetadata = mediaMetadata
    }

    public var domain: G09R2LargeImportMetadata {
        G09R2LargeImportMetadata(
            token: token, kind: kind, fileName: fileName,
            mimeType: mimeType, byteCount: byteCount, sha256: sha256,
            mediaMetadata: mediaMetadata)
    }
}

/// Exact frozen V6 payload for `media.largeImport.submit`:
/// `{context?|storage,origin,name,kind,sessionToken,expectedRevision?,opID,
///   metadata:{token,kind,fileName,mimeType,byteCount,sha256,mediaMetadata}}`.
public struct G09R2LargeImportSubmitWire: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO?
    public var storage: G09StorageLayerDTO?
    public var origin: G09CreativeOriginDTO?
    public var name: String?
    public var kind: G09R2LargeImportKind?
    public var sessionToken: String?
    public var expectedRevision: Int64?
    public var opID: String
    public var metadata: G09R2LargeImportWireMetadata
    public var preparedIntentToken: String?

    public var domain: G09R2LargeImportRequest {
        get throws {
            if let context {
                guard storage == nil, name == nil, kind == nil,
                      sessionToken == nil else {
                    throw G09CreativeError.invalidPayload("mixedImportTargets")
                }
                guard let expectedRevision else {
                    throw G09CreativeError.invalidPayload("missingExpectedRevision")
                }
                return .existingProject(
                    context: context, expectedRevision: expectedRevision,
                    opID: opID, metadata: metadata.domain)
            }
            guard let storage, let origin, let name, let kind,
                  let sessionToken else {
                throw G09CreativeError.invalidPayload("missingImportTarget")
            }
            guard expectedRevision == nil else {
                throw G09CreativeError.invalidPayload("mixedImportTargets")
            }
            return .newProject(
                storage: storage, origin: origin, name: name, kind: kind,
                sessionToken: sessionToken, opID: opID,
                metadata: metadata.domain,
                preparedIntentToken: preparedIntentToken)
        }
    }
}

/// Exactly the frozen Kotlin `LargeImportRequest` split, with the additive
/// host-measured media metadata required by atomic new-project creation.
public enum G09R2LargeImportRequest: Sendable {
    case existingProject(context: G09R2ProjectContextDTO,
                         expectedRevision: Int64,
                         opID: String,
                         metadata: G09R2LargeImportMetadata)
    case newProject(storage: G09StorageLayerDTO,
                    origin: G09CreativeOriginDTO,
                    name: String,
                    kind: G09R2LargeImportKind,
                    sessionToken: String,
                    opID: String,
                    metadata: G09R2LargeImportMetadata,
                    preparedIntentToken: String?)
}

public final class G09R2LargeImportService: @unchecked Sendable {
    public static let shared = G09R2LargeImportService()

    public static let maximumJobs = 8
    public static let maximumTerminalJobsKept = 32

    private struct Job {
        let id: String
        let epoch: UInt64
        let opID: String
        let createdAt: Date
        var updatedAt: Date
        var state: G09R2LargeImportState
        var progress: Double?
        var sessionDigest: String
        var request: G09R2LargeImportRequest
        var createdProjectID: UUID?
        var createdRevision: Int64?
        var asset: G09MediaAssetReceiptDTO?
        var errorCode: String?
        var retryable: Bool
        var cancelRequested: Bool
        /// TRUE from acceptance until `run` actually settles. Root drain must
        /// wait for this flag, never for a cancel request alone.
        var workerActive: Bool
        /// TRUE once the commit boundary was crossed; a later failure is
        /// `interrupted/outcomeUnknown`, never a blind retry.
        var commitStarted: Bool
    }

    private let condition = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    /// ONE bound generation at a time. Once set, new work and commits for
    /// this exact epoch are refused until the owner rebinds.
    private var stoppingEpoch: UInt64?

    /// Deterministic test seam: awaited after the streamed digest matches and
    /// immediately BEFORE the commit fence. Production leaves it nil. It is
    /// never consulted for a decision and cannot publish anything.
    internal var testingBeforeCommit: (@Sendable (String) async -> Void)?

    public init() {}

    // MARK: - Validation (pure preflight; no stream is opened)

    public func validate(metadata: G09R2LargeImportMetadata,
                         rootPath: String?) -> G09R2StagedImportValidationDTO {
        let maxBytes = G09R2LargeImportPolicy.maxBytes(for: metadata.kind)
        let required = G09R2LargeImportPolicy.requiredFreeBytes(
            sourceBytes: metadata.byteCount)
        var refusal: String?
        if !G09R2LargeImportPolicy.accepts(metadata.kind, byteCount: metadata.byteCount) {
            refusal = metadata.byteCount > maxBytes ? "importTooLarge" : "assetEmpty"
        } else if !G09CreativeAssetHost.validDigest(metadata.sha256) {
            refusal = "assetStagingInvalid"
        } else if !Self.safeToken(metadata.token) {
            refusal = "assetStagingInvalid"
        } else if G09CreativeAssetHost.safeDisplayName(metadata.fileName).isEmpty {
            refusal = "assetStagingInvalid"
        }
        if refusal == nil, let rootPath,
           let free = Self.availableBytes(path: rootPath), free < required {
            refusal = "insufficientStorage"
        }
        return G09R2StagedImportValidationDTO(
            accepted: refusal == nil, requiredFreeBytes: required,
            maxBytes: maxBytes, refusalCode: refusal)
    }

    // MARK: - Submit

    public func submit(service: G09CreativeDomainService, epoch: UInt64,
                       request: G09R2LargeImportRequest) async throws
        -> G09R2LargeImportJobHandleDTO {
        guard let cluster = await service.r2BoundCluster(), cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard !(await service.r2IsRootStopping(epoch: epoch)),
              !G09R2MediaRenderHostMailbox.shared.isRootStopping(epoch: epoch),
              !isRootStopping(epoch: epoch) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
        let metadata: G09R2LargeImportMetadata
        let sessionToken: String
        let opID: String
        switch request {
        case .existingProject(let context, _, let requestOpID, let stored):
            try await service.r2RequireMediaSession(
                projectID: context.projectID, token: context.sessionToken)
            metadata = stored
            sessionToken = context.sessionToken
            opID = requestOpID
        case .newProject(_, _, let name, let kind, let token, let requestOpID,
                         let stored, let preparedIntentToken):
            guard kind != .audio else {
                throw G09CreativeError.invalidPayload("audioNewProjectUnsupported")
            }
            guard G09CreativeWire.sanitizedName(name) != nil else {
                throw G09CreativeError.invalidPayload("invalidName")
            }
            if let preparedIntentToken, !Self.safeToken(preparedIntentToken) {
                throw G09CreativeError.invalidPayload("invalidPreparedIntent")
            }
            metadata = stored
            sessionToken = token
            opID = requestOpID
        }
        guard G09CreativeWire.validSessionToken(sessionToken),
              metadata.token.hasPrefix(sessionToken + ".") else {
            throw G09CreativeError.assetStagingInvalid
        }
        guard G09CreativeWire.safeOperationID(opID),
              opID.utf8.count <= G09SourceCreateIdentity.maximumOperationBytes else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let preflight = validate(metadata: metadata,
                                 rootPath: cluster.root.path)
        guard preflight.accepted else {
            throw Self.validationError(preflight)
        }
        switch request {
        case .newProject(_, _, _, let kind, _, _, _, _):
            guard let media = metadata.mediaMetadata,
                  let width = media.width, let height = media.height,
                  (2...8192).contains(width), (2...8192).contains(height) else {
                throw G09CreativeError.invalidPayload("missingSourceMetadata")
            }
            if kind == .video {
                guard let duration = media.durationSeconds,
                      duration.isFinite, duration > 0, duration <= 86_400 else {
                    throw G09CreativeError.invalidPayload("invalidSourceDuration")
                }
            }
        case .existingProject:
            break
        }

        let jobID = UUID().uuidString.lowercased()
        let now = Date()
        let job = Job(
            id: jobID, epoch: epoch, opID: opID, createdAt: now, updatedAt: now,
            state: .queued, progress: 0,
            sessionDigest: G09CreativeAssetHost.sessionDigest(sessionToken),
            request: request, createdProjectID: nil, createdRevision: nil,
            asset: nil, errorCode: nil, retryable: false, cancelRequested: false,
            workerActive: true, commitStarted: false)
        switch insert(job) {
        case .inserted:
            break
        case .queueFull:
            throw G09R2Error(.rendererUnavailable, detail: "importQueueFull")
        case .stopping:
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }

        Task.detached { [weak self] in
            guard let self else { return }
            await self.run(jobID: jobID, service: service, epoch: epoch)
        }
        return G09R2LargeImportJobHandleDTO(
            jobID: jobID, state: .queued, acceptedAt: now)
    }

    // MARK: - Status / cancel

    private enum StatusLookup {
        case immediate(G09R2LargeImportStatusDTO)
        case job(Job)
    }

    private enum CancelLookup {
        case immediate(G09R2LargeImportJobHandleDTO)
        case job(Job)
    }

    private func lookupStatus(_ request: G09R2LargeImportStatusRequest,
                              epoch: UInt64) throws -> StatusLookup {
        condition.lock()
        defer { condition.unlock() }
        guard let job = jobs[request.jobID] else {
            return .immediate(G09R2LargeImportStatusDTO(
                jobID: request.jobID, state: .interrupted, updatedAt: Date(),
                progress: nil, createdProjectID: nil, createdRevision: nil,
                asset: nil, errorCode: "jobNotFound", retryable: false))
        }
        guard job.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard job.sessionDigest == G09CreativeAssetHost.sessionDigest(
            request.sessionToken) else {
            return .immediate(G09R2LargeImportStatusDTO(
                jobID: request.jobID, state: job.state, updatedAt: job.updatedAt,
                progress: job.progress, createdProjectID: nil,
                createdRevision: nil, asset: nil,
                errorCode: "staleSession", retryable: false))
        }
        if !Self.isTerminal(job.state), !job.workerActive {
            var interrupted = job
            interrupted.state = .interrupted
            interrupted.errorCode = "workerSettledWithoutTerminal"
            interrupted.retryable = false
            interrupted.updatedAt = Date()
            jobs[job.id] = interrupted
            return .immediate(Self.status(interrupted))
        }
        return .job(job)
    }

    private func lookupCancel(_ request: G09R2LargeImportCancelRequest,
                              epoch: UInt64) throws -> CancelLookup {
        condition.lock()
        defer { condition.unlock() }
        guard let existing = jobs[request.jobID] else {
            return .immediate(G09R2LargeImportJobHandleDTO(
                jobID: request.jobID, state: .failed, acceptedAt: Date()))
        }
        guard existing.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        guard existing.sessionDigest == G09CreativeAssetHost.sessionDigest(
            request.sessionToken) else {
            return .immediate(G09R2LargeImportJobHandleDTO(
                jobID: request.jobID, state: existing.state,
                acceptedAt: existing.createdAt))
        }
        guard existing.opID == request.opID else {
            throw G09CreativeError.invalidPayload("operationIDMismatch")
        }
        var job = existing
        if !Self.isTerminal(job.state) {
            job.cancelRequested = true
            job.updatedAt = Date()
        }
        jobs[job.id] = job
        return .job(job)
    }

    public func status(_ request: G09R2LargeImportStatusRequest,
                       service: G09CreativeDomainService,
                       epoch: UInt64) async throws -> G09R2LargeImportStatusDTO {
        switch try lookupStatus(request, epoch: epoch) {
        case .immediate(let status):
            return status
        case .job(let job):
            // Root stop / rebind may unbound the cluster only after every
            // worker settled, so a nonterminal job always has its exact
            // generation. A terminal outcome stays readable.
            if !Self.isTerminal(job.state),
               await service.r2BoundCluster()?.epoch != epoch {
                throw G09CreativeError.staleGeneration
            }
            return Self.status(job)
        }
    }

    /// Cancellation is a request. The owner worker settles the truthful
    /// terminal state; a pre-commit job publishes nothing, while a commit
    /// already in flight is never rolled back or blindly retried.
    public func cancel(_ request: G09R2LargeImportCancelRequest,
                       service: G09CreativeDomainService,
                       epoch: UInt64) async throws -> G09R2LargeImportJobHandleDTO {
        switch try lookupCancel(request, epoch: epoch) {
        case .immediate(let handle):
            return handle
        case .job(let job):
            if !Self.isTerminal(job.state),
               await service.r2BoundCluster()?.epoch != epoch {
                throw G09CreativeError.staleGeneration
            }
            return G09R2LargeImportJobHandleDTO(
                jobID: job.id, state: job.state, acceptedAt: job.createdAt)
        }
    }

    /// Bounded wait helper for tests/tool integration. Never invents success.
    public func waitForCompletion(jobID: String, timeoutMillis: Int) async
        -> G09R2LargeImportStatusDTO? {
        let deadline = Date().addingTimeInterval(
            Double(max(1, timeoutMillis)) / 1000)
        while Date() < deadline {
            if let job = currentJob(jobID), Self.isTerminal(job.state) {
                return Self.status(job)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: - Execution

    private func run(jobID: String, service: G09CreativeDomainService,
                     epoch: UInt64) async {
        guard let snapshot = currentJob(jobID) else {
            workerFinished(jobID)
            return
        }
        // The worker stays owned until this defer runs, even if the cluster
        // was already retired/rebound: root drain must never observe a
        // half-settled import table.
        guard let cluster = await service.r2BoundCluster(), cluster.epoch == epoch else {
            finish(jobID, state: .interrupted, errorCode: "staleGeneration",
                   retryable: true)
            workerFinished(jobID)
            return
        }
        defer {
            // Staged bytes stay native-owned until the worker is done. A
            // verified success or an explicit pre-commit cancel may release
            // them; failure/unknown keeps them for an explicit same-opID
            // retry and never a blind replay.
            self.releaseStagingIfSettled(jobID: jobID, cluster: cluster)
            self.workerFinished(jobID)
        }
        let job = snapshot
        let metadata = Self.metadata(job.request)
        let sessionToken = Self.sessionToken(job.request)
        if isCancelled(jobID) || isRootStopping(epoch: epoch) {
            finish(jobID, state: .cancelled, errorCode: nil, retryable: false)
            return
        }
        guard let staging = cluster.assets.incomingURL(token: metadata.token),
              FileManager.default.fileExists(atPath: staging.path) else {
            finish(jobID, state: .failed, errorCode: "assetStagingInvalid",
                   retryable: false)
            return
        }
        update(jobID) { job in
            job.state = .verifying
            job.progress = 0
            job.updatedAt = Date()
        }
        do {
            let digest = try FloeDigest.sha256Hex(
                ofFileAt: staging, chunkSize: 1 << 20,
                progress: { hashed, total in
                    guard total > 0 else { return }
                    let fraction = min(0.6, 0.6 * Double(hashed) / Double(total))
                    self.update(jobID) { job in
                        job.progress = fraction
                        job.updatedAt = Date()
                    }
                },
                isCancelled: { self.isCancelled(jobID) })
            let size = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) }
            guard size == metadata.byteCount,
                  digest.caseInsensitiveCompare(metadata.sha256) == .orderedSame else {
                throw G09CreativeError.assetDigestMismatch
            }
            if let hook = testingBeforeCommit {
                await hook(jobID)
            }
            guard beginCommit(jobID, epoch: epoch) else {
                finish(jobID, state: .cancelled, errorCode: nil, retryable: false)
                return
            }
            switch job.request {
            case .existingProject(let context, let expectedRevision,
                                  let opID, _):
                let request = G09MediaAssetImportRequest(
                    token: metadata.token, opID: opID,
                    projectID: context.projectID,
                    expectedRevision: expectedRevision,
                    storage: context.storage, origin: context.origin,
                    sessionToken: sessionToken,
                    fileName: metadata.fileName, mimeType: metadata.mimeType,
                    byteCount: metadata.byteCount, sha256: metadata.sha256)
                let receipt = try await cluster.media.importAssetLarge(
                    request, staging: staging,
                    maximumBytes: G09R2LargeImportPolicy.maxBytes(
                        for: metadata.kind))
                complete(jobID, asset: receipt)
            case .newProject(let storage, let origin, let name, let kind,
                             _, let opID, _, _):
                let media = metadata.mediaMetadata ?? MediaAssetMetadata()
                let request = G09MediaSourceCreateRequest(
                    token: metadata.token, opID: opID, name: name,
                    kind: kind == .image ? "image" : "video",
                    storage: storage, origin: origin,
                    sessionToken: sessionToken,
                    fileName: metadata.fileName, mimeType: metadata.mimeType,
                    byteCount: metadata.byteCount, sha256: metadata.sha256,
                    sourceKind: kind.rawValue,
                    width: media.width ?? 0, height: media.height ?? 0,
                    durationSeconds: media.durationSeconds,
                    frameRate: media.frameRate,
                    rotationDegrees: media.rotationDegrees)
                let projectID = G09SourceCreateIdentity.projectID(
                    domain: "media", opID: opID)
                let loaded = try await cluster.media.createFromSource(
                    request, staging: staging, projectID: projectID)
                complete(jobID, loaded: loaded)
            }
        } catch {
            let commitStarted = hasCommitStarted(jobID)
            if isCancelled(jobID) && !commitStarted {
                finish(jobID, state: .cancelled, errorCode: nil, retryable: false)
                return
            }
            if commitStarted {
                if let typed = error as? G09CreativeError,
                   Self.definitePreCommitCode(typed.code) {
                    // CAS/session/payload/digest refusals happen before any
                    // publication and stay truthfully failed.
                    finish(jobID, state: .failed,
                           errorCode: typed.code, retryable: typed.retryable)
                } else {
                    // The commit boundary was crossed and the outcome is not
                    // provably pre-publication. The durable intent/receipt is
                    // the truth; bytes stay for an explicit same-opID replay.
                    finish(jobID, state: .interrupted,
                           errorCode: "outcomeUnknown", retryable: false)
                }
                return
            }
            if let typed = error as? G09CreativeError {
                switch typed {
                case .outcomeUnknown:
                    finish(jobID, state: .interrupted,
                           errorCode: "outcomeUnknown", retryable: false)
                default:
                    finish(jobID, state: .failed,
                           errorCode: typed.code, retryable: typed.retryable)
                }
                return
            }
            finish(jobID, state: .failed,
                   errorCode: G09CreativeError.map(error).code, retryable: false)
        }
    }

    // MARK: - Job table helpers

    private func complete(_ jobID: String, asset: G09MediaAssetReceiptDTO) {
        condition.lock()
        guard var job = jobs[jobID] else { condition.unlock(); return }
        job.state = .completed
        job.progress = 1
        job.createdProjectID = asset.projectID
        job.createdRevision = asset.revision
        job.asset = asset
        job.errorCode = nil
        job.retryable = false
        job.cancelRequested = false
        job.updatedAt = Date()
        jobs[jobID] = job
        condition.unlock()
    }

    private func complete(_ jobID: String,
                          loaded: G09MediaProjectHost.Loaded) {
        condition.lock()
        guard var job = jobs[jobID] else { condition.unlock(); return }
        job.state = .completed
        job.progress = 1
        job.createdProjectID = loaded.project.id
        job.createdRevision = loaded.project.revision
        job.asset = nil
        job.errorCode = nil
        job.retryable = false
        job.cancelRequested = false
        job.updatedAt = Date()
        jobs[jobID] = job
        condition.unlock()
    }

    private func finish(_ jobID: String, state: G09R2LargeImportState,
                        errorCode: String?, retryable: Bool) {
        condition.lock()
        guard var job = jobs[jobID] else { condition.unlock(); return }
        job.state = state
        job.progress = state == .cancelled ? nil : job.progress
        job.errorCode = errorCode
        job.retryable = retryable
        job.updatedAt = Date()
        jobs[jobID] = job
        condition.unlock()
    }

    private func update(_ jobID: String, _ body: (inout Job) -> Void) {
        condition.lock()
        guard var job = jobs[jobID] else { condition.unlock(); return }
        body(&job)
        jobs[jobID] = job
        condition.unlock()
    }

    private func isCancelled(_ jobID: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return jobs[jobID]?.cancelRequested ?? true
    }

    private enum InsertResult { case inserted, queueFull, stopping }

    private func insert(_ job: Job) -> InsertResult {
        condition.lock(); defer { condition.unlock() }
        pruneLocked()
        guard stoppingEpoch != job.epoch else { return .stopping }
        let live = jobs.values.filter { !Self.isTerminal($0.state) }.count
        guard live < Self.maximumJobs else { return .queueFull }
        guard jobs.count < Self.maximumJobs + Self.maximumTerminalJobsKept else {
            return .queueFull
        }
        jobs[job.id] = job
        order.append(job.id)
        return .inserted
    }

    private func currentJob(_ jobID: String) -> Job? {
        condition.lock(); defer { condition.unlock() }
        return jobs[jobID]
    }

    // MARK: - Root drain / commit fence

    /// Phase-1 root stop for THIS exact generation: refuse new work, request
    /// cancellation and report TRUE only when every accepted job's worker has
    /// actually settled. A cancel request alone is never proof of drain.
    public func requestRootStop(epoch: UInt64) -> Bool {
        condition.lock()
        // Root stop is serialized by the single bound generation; the most
        // recent exact-epoch request is the active fence. A stale request can
        // only arrive after the owner already refused/rebound.
        stoppingEpoch = epoch
        for id in order {
            guard var job = jobs[id], job.epoch == epoch,
                  !Self.isTerminal(job.state) else { continue }
            job.cancelRequested = true
            job.updatedAt = Date()
            jobs[id] = job
        }
        let pending = jobs.values.contains { job in
            job.epoch == epoch &&
                (job.workerActive || !Self.isTerminal(job.state))
        }
        condition.unlock()
        return !pending
    }

    public func isRootStopping(epoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return stoppingEpoch == epoch
    }

    /// Bounded owned-work count for an exact generation (worker active or a
    /// nonterminal record). Used by the App's drain diagnostic only; the
    /// phase-1 stop is the gate.
    public func pendingCount(epoch: UInt64) -> Int {
        condition.lock(); defer { condition.unlock() }
        return jobs.values.filter { job in
            job.epoch == epoch &&
                (job.workerActive || !Self.isTerminal(job.state))
        }.count
    }

    private func beginCommit(_ jobID: String, epoch: UInt64) -> Bool {
        condition.lock()
        guard var job = jobs[jobID] else { condition.unlock(); return false }
        guard stoppingEpoch != epoch, !job.cancelRequested else {
            job.cancelRequested = true
            job.updatedAt = Date()
            jobs[jobID] = job
            condition.unlock()
            return false
        }
        job.state = .committing
        job.progress = 0.85
        job.updatedAt = Date()
        job.commitStarted = true
        jobs[jobID] = job
        condition.unlock()
        return true
    }

    private func hasCommitStarted(_ jobID: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return jobs[jobID]?.commitStarted ?? true
    }

    private func workerFinished(_ jobID: String) {
        condition.lock()
        if var job = jobs[jobID] { job.workerActive = false; jobs[jobID] = job }
        condition.unlock()
    }

    /// Deletes ONLY this service's exact staged token, and only when the
    /// terminal outcome makes the bytes disposable (published success or an
    /// explicit pre-commit cancel). A failed/interrupted job keeps the bytes
    /// for an explicit same-opID retry; the project store is never touched.
    private func releaseStagingIfSettled(
        jobID: String, cluster: G09R2BoundCluster
    ) {
        guard let job = currentJob(jobID) else { return }
        switch job.state {
        case .completed, .cancelled:
            let metadata = Self.metadata(job.request)
            // `incomingURL` is nonisolated and bounded to the exact token
            // path under CreativeIncoming; this sync worker-settle step must
            // not hop back into the asset actor.
            if let staging = cluster.assets.incomingURL(token: metadata.token) {
                try? FileManager.default.removeItem(at: staging)
            }
        default:
            break
        }
    }

    private func pruneLocked() {
        let terminal = order.filter { id in
            guard let job = jobs[id] else { return true }
            return Self.isTerminal(job.state) && !job.workerActive
        }
        let excess = terminal.count - Self.maximumTerminalJobsKept
        if excess > 0 {
            for id in terminal.prefix(excess) {
                jobs.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
        }
    }

    private static func status(_ job: Job) -> G09R2LargeImportStatusDTO {
        G09R2LargeImportStatusDTO(
            jobID: job.id, state: job.state, updatedAt: job.updatedAt,
            progress: job.progress,
            createdProjectID: job.state == .completed ? job.createdProjectID : nil,
            createdRevision: job.state == .completed ? job.createdRevision : nil,
            asset: job.state == .completed ? job.asset : nil,
            errorCode: job.errorCode, retryable: job.retryable)
    }

    /// Errors a commit path raises BEFORE publishing anything (CAS/session/
    /// payload/digest/preflight refusals) stay truthfully `failed`; every
    /// other error after the fence is `interrupted/outcomeUnknown`.
    private static func definitePreCommitCode(_ code: String) -> Bool {
        switch code {
        case "revisionConflict", "staleSession", "sessionRequired",
             "invalidPayload", "assetDigestMismatch", "assetMissing",
             "assetReferenceInvalid", "insufficientStorage", "importTooLarge":
            return true
        default:
            return false
        }
    }

    private static func isTerminal(_ state: G09R2LargeImportState) -> Bool {
        switch state {
        case .completed, .cancelled, .failed, .interrupted: return true
        default: return false
        }
    }

    private static func metadata(_ request: G09R2LargeImportRequest)
        -> G09R2LargeImportMetadata {
        switch request {
        case .existingProject(_, _, _, let metadata): return metadata
        case .newProject(_, _, _, _, _, _, let metadata, _): return metadata
        }
    }

    private static func sessionToken(_ request: G09R2LargeImportRequest) -> String {
        switch request {
        case .existingProject(let context, _, _, _): return context.sessionToken
        case .newProject(_, _, _, _, let token, _, _, _): return token
        }
    }

    private static func validationError(_ validation: G09R2StagedImportValidationDTO)
        -> Error {
        switch validation.refusalCode {
        case "importTooLarge": return G09R2Error(.importTooLarge)
        case "insufficientStorage": return G09R2Error(.insufficientStorage)
        case "assetEmpty": return G09CreativeError.assetEmpty
        default: return G09CreativeError.assetStagingInvalid
        }
    }

    nonisolated static func safeToken(_ value: String) -> Bool {
        G09CreativeAssetHost.safeStagingToken(value)
    }

    /// Real filesystem preflight when the platform reports free space. A nil
    /// result means "not measurable here" and must not be turned into a fake
    /// refusal or a fake success.
    nonisolated static func availableBytes(path: String) -> Int64? {
        var best: Int64?
        if let values = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            best = capacity
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            let value = free.int64Value
            best = max(best ?? value, value)
        }
        return best
    }
}

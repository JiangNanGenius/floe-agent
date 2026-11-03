// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — BridgeV6 (`floe.creative/6`) on the EXISTING `floe_bridge_exchange`
// C ABI (job-b72b2978320e484e).
//
// Append-only protocol branch: V1–V5 bytes and behavior are untouched. V6
// exposes the closed frozen action vocabulary. This package implements the
// typed video read/apply foundation, the real generation service and the real
// design service. `status`/`bind` expose the real closed action set and a
// native `design` availability object; per-target refusal is returned by the
// action rather than a false global unavailability map. No model tool and no
// new C ABI entry is added here (the render-ticket C ABI is its own bounded
// host lane).
import Foundation
import FloeCore
import FloeAndroidWorkbench

public struct G09R2CreativeStatusDTO: Encodable, Sendable {
    public var bound: Bool
    public var epoch: UInt64?
    public var rootFingerprint: String?
    public var bridgeVersion: Int
    public var schema: String
    public var actions: [String]
    public var availableActions: [String]
    public var unavailableActions: [String: String]
    public var canvasSchemaVersion: Int
    public var mediaSchemaVersion: Int
    public var requestMaxBytes: Int
    public var responseMaxBytes: Int
    public var mediaProjectMaxBytes: Int
    public var renderDescriptorMaxBytes: Int
    public var renderReplyMaxBytes: Int
    public var maxLiveRenderTickets: Int
    public var modelTools: Bool
    /// Additive R2 generation availability, backed by the real configured
    /// provider/model routes. False only while the creative domain is unbound
    /// or generation has no usable route at all; per-route availability is in
    /// `generation.models`.
    public var generationAvailable: Bool
    public var generationActions: [String]
}

public enum BridgeV6Handler {
    public static let version = BridgeV6.version
    public static let schema = BridgeV6.schema
    public static let maximumRequestBytes = BridgeV6.maximumRequestBytes
    public static let maximumResponseBytes = BridgeV6.maximumResponseBytes

    /// The SAME process-wide creative domain authority as V5: one bound root,
    /// one media host, no second project store.
    static let service = BridgeV5.service

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[String: Any], Error>?
        func set(_ result: Result<[String: Any], Error>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<[String: Any], Error>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private static func blocking(
        _ body: @escaping @Sendable () async throws -> [String: Any]
    ) -> Result<[String: Any], Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? .failure(G09CreativeError.storageUnavailable)
    }

    public static func handle(requestData: Data,
                              fallbackRequestID: String?) -> [String: Any] {
        handle(requestData: requestData, fallbackRequestID: fallbackRequestID,
               service: service)
    }

    /// Test/host-injection seam (same closed handler, isolated service).
    static func handle(requestData: Data, fallbackRequestID: String?,
                       service: G09CreativeDomainService) -> [String: Any] {
        guard requestData.count <= maximumRequestBytes else {
            return G09CreativeWire.failure(.requestTooLarge)
        }
        let request: G09CreativeRequest
        do {
            request = try G09CreativeWire.decoder().decode(
                G09CreativeRequest.self, from: requestData)
        } catch {
            return G09CreativeWire.failure(.invalidRequest("invalidJSON"))
        }
        guard request.version == version else {
            return G09CreativeWire.failure(.unsupportedVersion)
        }
        switch request.operation {
        case "handshake":
            return handshake()
        case "status":
            return status(service: service)
        case "bind":
            guard let epoch = request.epoch, epoch > 0 else {
                return G09CreativeWire.failure(.invalidRequest("missingEpoch"))
            }
            return bind(epoch: epoch, service: service)
        case "command":
            guard let epoch = request.epoch, epoch > 0 else {
                return G09CreativeWire.failure(.invalidRequest("missingEpoch"))
            }
            guard let action = request.action, !action.isEmpty else {
                return G09CreativeWire.failure(.invalidRequest("missingAction"))
            }
            guard BridgeV6.actionSet.contains(action) else {
                return G09CreativeWire.failure(
                    .unsupportedAction(G09CreativeWire.bounded(action, limit: 80)))
            }
            let correlation = request.requestID ?? fallbackRequestID
            guard let correlation, !correlation.isEmpty,
                  correlation.utf8.count <= G09CreativeLimits.requestIDBytes else {
                return G09CreativeWire.failure(.invalidRequest("missingRequestID"))
            }
            let result = blocking {
                try await dispatch(service: service, epoch: epoch,
                                   requestID: correlation, action: action,
                                   payload: request.payload)
            }
            return decode(result)
        default:
            return G09CreativeWire.failure(.unsupportedOperation)
        }
    }

    // MARK: - Protocol values

    public static func handshake() -> [String: Any] {
        [
            "ok": true,
            "version": version,
            "schema": schema,
            "engine": "FloeCreativeR2",
            "actions": BridgeV6.actions,
            "availableActions": availableActions,
            "unavailableActions": unavailableActions,
            "requestMaxBytes": maximumRequestBytes,
            "responseMaxBytes": maximumResponseBytes,
            "canvasProjectMaxBytes": G09R2CreativeLimits.canvasProjectBytes,
            "mediaProjectMaxBytes": G09R2CreativeLimits.mediaProjectBytes,
            "renderDescriptorMaxBytes": G09R2CreativeLimits.renderDescriptorBytes,
            "renderReplyMaxBytes": G09R2CreativeLimits.renderReplyBytes,
            "maxLiveRenderTickets": G09R2CreativeLimits.maxLiveRenderTickets,
            "canvasSchemaVersion": CanvasProject.currentSchemaVersion,
            "mediaSchemaVersion": MediaProject.currentSchemaVersion,
            "persistence": "canvas-file-cas+media-json-cas+creative-asset-store",
            "videoPlayback": false,
            "rendererConnected": false,
            "generationAvailable": true,
            "generationActions": generationActions,
            "largeImport": [
                "available": true,
                "actions": ["media.largeImport.submit",
                            "media.largeImport.status",
                            "media.largeImport.cancel"],
                "imageMaxBytes": G09R2CreativeLimits.importImageBytes,
                "audioMaxBytes": G09R2CreativeLimits.importAudioBytes,
                "videoMaxBytes": G09R2CreativeLimits.importVideoBytes,
                "canvasGenericMaxBytes": G09R2CreativeLimits.canvasGenericAssetBytes,
            ],
            "modelTools": false,
            "enhancement": [
                "available": true,
                "actions": ["media.enhancement.capability",
                            "media.enhancement.submit",
                            "media.enhancement.status",
                            "media.enhancement.cancel",
                            "media.enhancement.configuration.get",
                            "media.enhancement.configuration.save",
                            "media.enhancement.configuration.clear",
                            "media.enhancement.configuration.reference",
                            "media.enhancement.import"],
                "interpolationEngine": "ffmpeg-minterpolate",
                "limits": [
                    "maximumSourceDimension": 4096,
                    "maximumOutputDimension": 8192,
                    "maximumDurationSeconds": 3600,
                    "maximumFrames": 200000,
                    "maximumTargetFPS": 240,
                    "scaleFactor": [2, 3, 4],
                ],
            ],
            "design": designCapabilityDictionary(),
        ]
    }

    public static let generationActions: [String] = [
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
    ]

    /// Every closed V6 action has a real dispatch path. Availability is
    /// capability-level (a specific target/project can still be unavailable),
    /// so `unavailableActions` no longer carries the stale design refusal that
    /// contradicted the real design service. The schema stays `[String]` /
    /// `[String: String]` for existing consumers; the values are now truthful.
    public static let availableActions: [String] = BridgeV6.actions

    /// No action is globally unavailable in this build. Per-target/per-resource
    /// refusal is returned by the action itself (for example an unsupported
    /// creativeDocument target or a CAD Canvas node).
    public static let unavailableActions: [String: String] = [:]

    // MARK: - Operations

    private static func status(service: G09CreativeDomainService) -> [String: Any] {
        let result = blocking {
            let status = await service.status()
            let dto = G09R2CreativeStatusDTO(
                bound: status.bound,
                epoch: status.epoch,
                rootFingerprint: status.rootFingerprint,
                bridgeVersion: version,
                schema: schema,
                actions: BridgeV6.actions,
                availableActions: availableActions,
                unavailableActions: unavailableActions,
                canvasSchemaVersion: status.canvasSchemaVersion,
                mediaSchemaVersion: status.mediaSchemaVersion,
                requestMaxBytes: maximumRequestBytes,
                responseMaxBytes: maximumResponseBytes,
                mediaProjectMaxBytes: G09R2CreativeLimits.mediaProjectBytes,
                renderDescriptorMaxBytes: G09R2CreativeLimits.renderDescriptorBytes,
                renderReplyMaxBytes: G09R2CreativeLimits.renderReplyBytes,
                maxLiveRenderTickets: G09R2CreativeLimits.maxLiveRenderTickets,
                modelTools: false,
                 generationAvailable: true,
                 generationActions: generationActions)
            var object = try successObject(dto)
            object["design"] = try await designStatusObject(service)
            object["enhancement"] = [
                "available": true,
                "actions": ["media.enhancement.capability",
                            "media.enhancement.submit",
                            "media.enhancement.status",
                            "media.enhancement.cancel",
                            "media.enhancement.configuration.get",
                            "media.enhancement.configuration.save",
                            "media.enhancement.configuration.clear",
                            "media.enhancement.configuration.reference",
                            "media.enhancement.import"],
            ]
            return object
        }
        return decode(result)
    }

    private static func bind(epoch: UInt64,
                             service: G09CreativeDomainService) -> [String: Any] {
        let result = blocking {
            // Preflight the render transport BEFORE the creative domain
            // switches cluster: a live/claimed old-generation ticket keeps
            // the old Root bound; an old claim token never retargets a new one.
            let alreadyBound = G09R2MediaRenderHostMailbox.shared.isBound(to: epoch)
            guard alreadyBound ||
                G09R2MediaRenderHostMailbox.shared.canBind(epoch: epoch) else {
                throw G09R2Error(.rendererUnavailable, detail: "ticketDrainPending")
            }
            guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(epoch: epoch) else {
                throw G09CreativeError.acceptedRootNotLive
            }
            let storage = G09CreativeStorageContext(
                root: cluster.identity.root,
                database: cluster.database,
                workspaceStore: cluster.workspaceStore,
                conversationStore: cluster.conversationStore)
            _ = try await service.bind(epoch: epoch, storage: storage)
            // The bounded render transport is bound to the SAME exact
            // generation. A generation that still owns claimed/queued tickets
            // cannot be rebound underneath the platform.
            if !alreadyBound,
               !G09R2MediaRenderHostMailbox.shared.bind(epoch: epoch) {
                throw G09R2Error(.rendererUnavailable, detail: "ticketDrainPending")
            }
            G09R2SnapshotLeases.shared.purgeExpired()
            let status = await service.status()
            let dto = G09R2CreativeStatusDTO(
                bound: status.bound,
                epoch: status.epoch,
                rootFingerprint: status.rootFingerprint,
                bridgeVersion: version,
                schema: schema,
                actions: BridgeV6.actions,
                availableActions: availableActions,
                unavailableActions: unavailableActions,
                canvasSchemaVersion: status.canvasSchemaVersion,
                mediaSchemaVersion: status.mediaSchemaVersion,
                requestMaxBytes: maximumRequestBytes,
                responseMaxBytes: maximumResponseBytes,
                mediaProjectMaxBytes: G09R2CreativeLimits.mediaProjectBytes,
                renderDescriptorMaxBytes: G09R2CreativeLimits.renderDescriptorBytes,
                renderReplyMaxBytes: G09R2CreativeLimits.renderReplyBytes,
                maxLiveRenderTickets: G09R2CreativeLimits.maxLiveRenderTickets,
                modelTools: false,
                 generationAvailable: true,
                 generationActions: generationActions)
            var object = try successObject(dto)
            object["design"] = try await designStatusObject(service)
            object["enhancement"] = [
                "available": true,
                "actions": ["media.enhancement.capability",
                            "media.enhancement.submit",
                            "media.enhancement.status",
                            "media.enhancement.cancel",
                            "media.enhancement.configuration.get",
                            "media.enhancement.configuration.save",
                            "media.enhancement.configuration.clear",
                            "media.enhancement.configuration.reference",
                            "media.enhancement.import"],
            ]
            return object
        }
        return decode(result)
    }

    private static func dispatch(
        service: G09CreativeDomainService, epoch: UInt64,
        requestID: String, action: String, payload: G09CreativeJSON?
    ) async throws -> [String: Any] {
        _ = requestID
        switch action {
        case "media.video.load":
            let request: G09R2VideoLoadRequest = try G09CreativeWire.decode(
                G09R2VideoLoadRequest.self, payload: payload)
            let loaded = try await G09R2MediaFoundation.shared.loadVideo(
                service: service, epoch: epoch, request: request)
            var object = try G09CreativeWire.object(loaded.envelope)
            object["timelineDigest"] = loaded.timelineDigest
            object["projectRevision"] = loaded.envelope.project.revision
            object["ok"] = true
            return object
        case "media.video.apply":
            let request: G09R2VideoApplyRequest = try G09CreativeWire.decode(
                G09R2VideoApplyRequest.self, payload: payload)
            let receipt = try await G09R2MediaFoundation.shared.applyVideo(
                service: service, epoch: epoch, request: request)
            return try successObject(receipt)
        case "media.largeImport.submit":
            let wire: G09R2LargeImportSubmitWire = try G09CreativeWire.decode(
                G09R2LargeImportSubmitWire.self, payload: payload)
            let handle = try await G09R2LargeImportService.shared.submit(
                service: service, epoch: epoch, request: try wire.domain)
            return try successObject(handle)
        case "media.largeImport.status":
            let request: G09R2LargeImportStatusRequest = try G09CreativeWire.decode(
                G09R2LargeImportStatusRequest.self, payload: payload)
            let status = try await G09R2LargeImportService.shared.status(
                request, service: service, epoch: epoch)
            return try successObject(status)
        case "media.largeImport.cancel":
            let request: G09R2LargeImportCancelRequest = try G09CreativeWire.decode(
                G09R2LargeImportCancelRequest.self, payload: payload)
            let handle = try await G09R2LargeImportService.shared.cancel(
                request, service: service, epoch: epoch)
            return try successObject(handle)
        case "media.enhancement.capability":
            let request: G09R2EnhancementCapabilityRequest = try G09CreativeWire.decode(
                G09R2EnhancementCapabilityRequest.self, payload: payload)
            let capability = try await G09R2MediaEnhancementService.shared.capability(
                service: service, epoch: epoch, context: request.context)
            return try successObject(capability)
        case "media.enhancement.submit":
            let request: G09R2EnhancementSubmitRequest = try G09CreativeWire.decode(
                G09R2EnhancementSubmitRequest.self, payload: payload)
            let handle = try await G09R2MediaEnhancementService.shared.submit(
                service: service, epoch: epoch, context: request.context,
                request: request.enhancement)
            return try successObject(G09R2EnhancementHandleDTO(
                jobID: handle.jobID, state: handle.state.rawValue,
                idempotent: handle.idempotent))
        case "media.enhancement.status":
            let request: G09R2EnhancementJobQuery = try G09CreativeWire.decode(
                G09R2EnhancementJobQuery.self, payload: payload)
            let status = try await G09R2MediaEnhancementService.shared.status(
                service: service, epoch: epoch, context: request.context,
                jobID: request.jobID)
            return try successObject(status)
        case "media.enhancement.cancel":
            let request: G09R2EnhancementJobQuery = try G09CreativeWire.decode(
                G09R2EnhancementJobQuery.self, payload: payload)
            let status = try await G09R2MediaEnhancementService.shared.cancel(
                service: service, epoch: epoch, context: request.context,
                jobID: request.jobID)
            return try successObject(status)
        case "media.enhancement.configuration.get":
            let dto = try await G09R2MediaEnhancementService.shared.configuration(
                service: service, epoch: epoch)
            return try successObject(dto)
        case "media.enhancement.configuration.save":
            let request: G09R2EnhancerConfigurationSaveRequest = try G09CreativeWire.decode(
                G09R2EnhancerConfigurationSaveRequest.self, payload: payload)
            let dto = try await G09R2MediaEnhancementService.shared.saveConfiguration(
                service: service, epoch: epoch, request: request)
            return try successObject(dto)
        case "media.enhancement.configuration.clear":
            let dto = try await G09R2MediaEnhancementService.shared.clearConfiguration(
                service: service, epoch: epoch)
            return try successObject(dto)
        case "media.enhancement.configuration.reference":
            let referenceRequest: G09R2EnhancerCredentialReferenceRequest =
                try G09CreativeWire.decode(
                    G09R2EnhancerCredentialReferenceRequest.self, payload: payload)
            guard let account = referenceRequest.credentialAccount else {
                // The nil-account staging mint is REMOVED with the two-call
                // staging flow (job-e5e786c723244725): a key Set now travels
                // ONLY through the ONE sealed secure ingress (the App host
                // submits the closed `enhancerSave` intent core + key bytes
                // to the existing one-shot vault slot and the save consumes
                // that lease). This action remains ONLY as the explicit
                // secret-free derivation compatibility/read helper.
                throw G09CreativeError.invalidPayload(
                    "enhancerReferenceAccountRequired")
            }
            // Explicit account: pure derivation (secret-free), unchanged
            // from the predecessor contract. This derives an opaque
            // reference shape only — it grants NO ownership and performs no
            // effect; every read/send/mutation path still proves the record
            // from this root's ORIGINAL metadata authority first.
            return try successObject(G09R2EnhancerCredentialReferenceDTO(
                credentialAccount: account,
                opaqueReference: G09R2EnhancerBackendConfigurationStore
                    .opaqueReference(for: account)))
        case "media.enhancement.import":
            let request: G09R2EnhancementJobQuery = try G09CreativeWire.decode(
                G09R2EnhancementJobQuery.self, payload: payload)
            let status = try await G09R2MediaEnhancementService.shared.importOutput(
                service: service, epoch: epoch, context: request.context,
                jobID: request.jobID)
            return try successObject(status)
        case "generation.models":
            let catalog = try await G09R2GenerationService.shared.models(
                service: service, epoch: epoch)
            return try successObject(catalog)
        case "generation.image.submit":
            let request: G09R2ImageSubmitRequest = try G09CreativeWire.decode(
                G09R2ImageSubmitRequest.self, payload: payload)
            let handle = try await G09R2GenerationService.shared.submitImage(
                service: service, epoch: epoch, request: request)
            return try successObject(handle)
        case "generation.image.status":
            let request: G09R2ImageStatusRequest = try G09CreativeWire.decode(
                G09R2ImageStatusRequest.self, payload: payload)
            let status = try await G09R2GenerationService.shared.imageStatus(
                service: service, epoch: epoch, request: request)
            return try successObject(status)
        case "generation.image.dismiss":
            let request: G09R2ImageDismissRequest = try G09CreativeWire.decode(
                G09R2ImageDismissRequest.self, payload: payload)
            let receipt = try await G09R2GenerationService.shared.dismissImage(
                service: service, epoch: epoch, request: request)
            return try successObject(receipt)
        case "generation.video.submit":
            let request: G09R2VideoSubmitRequest = try G09CreativeWire.decode(
                G09R2VideoSubmitRequest.self, payload: payload)
            let handle = try await G09R2GenerationService.shared.submitVideo(
                service: service, epoch: epoch, request: request)
            return try successObject(handle)
        case "generation.video.status":
            let request: G09R2JobQueryWire = try G09CreativeWire.decode(
                G09R2JobQueryWire.self, payload: payload)
            if let jobID = request.jobID, !jobID.isEmpty {
                let status = try await G09R2GenerationService.shared.refreshJob(
                    service: service, epoch: epoch, context: request.context,
                    jobID: jobID)
                return try successObject(status)
            }
            let jobs = try await G09R2GenerationService.shared.jobs(
                service: service, epoch: epoch, context: request.context,
                limit: request.limit ?? G09R2CreativeLimits.jobListDefault)
            return try successObject(G09R2JobListDTO(jobs: jobs))
        case "generation.video.cancel":
            let request: G09R2JobCancelRequest = try G09CreativeWire.decode(
                G09R2JobCancelRequest.self, payload: payload)
            let status = try await G09R2GenerationService.shared.cancelJob(
                service: service, epoch: epoch, request: request)
            return try successObject(status)
        case "generation.video.deliver":
            let request: G09R2JobDeliverRequest = try G09CreativeWire.decode(
                G09R2JobDeliverRequest.self, payload: payload)
            let delivered = try await G09R2GenerationService.shared.deliverResult(
                service: service, epoch: epoch, request: request)
            return try successObject(delivered)
        case "generation.candidates.list":
            let request: G09R2CandidatesRequest = try G09CreativeWire.decode(
                G09R2CandidatesRequest.self, payload: payload)
            let candidates = try await G09R2GenerationService.shared.candidates(
                service: service, epoch: epoch, context: request.context)
            return try successObject(G09R2CandidateListDTO(candidates: candidates))
        case "generation.candidates.accept":
            let request: G09R2CandidateAcceptRequest = try G09CreativeWire.decode(
                G09R2CandidateAcceptRequest.self, payload: payload)
            let receipt = try await G09R2GenerationService.shared.acceptCandidate(
                service: service, epoch: epoch, request: request)
            return try successObject(receipt)
        case "generation.candidates.reject":
            let request: G09R2CandidateRejectRequest = try G09CreativeWire.decode(
                G09R2CandidateRejectRequest.self, payload: payload)
            let receipt = try await G09R2GenerationService.shared.rejectCandidate(
                service: service, epoch: epoch, request: request)
            return try successObject(receipt)
        case "design.canvas.snapshot", "design.owner.state":
            let envelope: G09R2DesignStateEnvelope = try G09CreativeWire.decode(
                G09R2DesignStateEnvelope.self, payload: payload)
            // Two bounded read-only inventory routes deliberately carry no
            // target binding: they are scoped to the bound service/root and are
            // reachable only through this trusted App bridge (no model tool).
            if action == "design.owner.state",
               let creative = envelope.creative,
               creative.kind == .assets || creative.kind == .pending {
                let design = try await designService(service, epoch: epoch)
                switch creative.kind {
                case .assets:
                    let query = creative.assets
                        ?? G09R2DesignCreativePageQueryDTO()
                    let page = try await design.creativeAssets(
                        limit: query.limit ?? 24,
                        cursor: query.cursor,
                        trustedUI: true)
                    return try successObject(page)
                case .pending:
                    let query = creative.pending
                        ?? G09R2DesignCreativePageQueryDTO()
                    let page = try await design.creativePendingRequests(
                        limit: query.limit ?? 24,
                        cursor: query.cursor,
                        trustedUI: true)
                    return try successObject(page)
                default:
                    break
                }
            }
            guard let binding = envelope.binding else {
                throw G09CreativeError.invalidPayload("missingDesignBinding")
            }
            try requireDesignKind(
                binding, canvas: action == "design.canvas.snapshot")
            let design = try await designService(service, epoch: epoch)
            if let creative = envelope.creative {
                guard action == "design.owner.state",
                      binding.target.kind == .creativeDocument else {
                    throw G09R2Error(
                        .designTargetUnavailable,
                        detail: "creativeRouteRequiresCreativeOwnerState")
                }
                guard let opID = envelope.opID, !opID.isEmpty else {
                    throw G09CreativeError.invalidPayload("missingOperationID")
                }
                switch creative.kind {
                case .begin:
                    let request = G09R2DesignCreativeBeginRequest(
                        binding: binding,
                        expectedRevision: envelope.expectedRevision,
                        opID: opID,
                        brief: creative.begin?.brief,
                        spec: creative.begin?.spec)
                    let result = try await design.beginCreativeRequest(
                        request, trustedUI: true)
                    return try successObject(result)
                case .bind:
                    guard let expectedRevision = envelope.expectedRevision,
                          let bound = creative.bind else {
                        throw G09CreativeError.invalidPayload(
                            "missingCreativeBind")
                    }
                    let request = G09R2DesignCreativeBindRequest(
                        binding: binding,
                        expectedRevision: expectedRevision,
                        opID: opID,
                        boundResultID: bound.boundResultID,
                        payload: bound.payload,
                        displayName: bound.displayName)
                    let result = try await design.bindCreativeFirstResult(
                        request, trustedUI: true)
                    return try successObject(result)
                case .bindRetained:
                    guard let expectedRevision = envelope.expectedRevision,
                          let retained = creative.bindRetained else {
                        throw G09CreativeError.invalidPayload(
                            "missingCreativeRetainedBind")
                    }
                    let request = G09R2DesignCreativeRetainedBindRequest(
                        binding: binding,
                        expectedRevision: expectedRevision,
                        opID: opID,
                        boundResultID: retained.boundResultID,
                        displayName: retained.displayName)
                    let result = try await design
                        .bindCreativeRetainedFirstResult(
                            request, trustedUI: true)
                    return try successObject(result)
                case .importBind:
                    guard let expectedRevision = envelope.expectedRevision,
                          let imported = creative.importBind else {
                        throw G09CreativeError.invalidPayload(
                            "missingCreativeImportBind")
                    }
                    let request = G09R2DesignCreativeImportBindRequest(
                        binding: binding,
                        expectedRevision: expectedRevision,
                        opID: opID,
                        payload: imported.payload,
                        displayName: imported.displayName)
                    let result = try await design.importCreativeFirstResult(
                        request, trustedUI: true)
                    return try successObject(result)
                case .assets, .pending:
                    throw G09R2Error(
                        .designTargetUnavailable,
                        detail: "creativeInventoryRequiresOwnerState")
                }
            }
            if envelope.expectedRevision != nil || envelope.opID != nil {
                guard let opID = envelope.opID, !opID.isEmpty else {
                    throw G09CreativeError.invalidPayload("missingOperationID")
                }
                let request = G09R2DesignBindRequest(
                    binding: binding,
                    expectedRevision: envelope.expectedRevision,
                    opID: opID)
                let result = try await design.bind(request)
                return try successObject(result)
            }
            let result = try await design.state(binding)
            return try successObject(result)
        case "design.owner.brief":
            let request: G09R2DesignBriefRequest = try G09CreativeWire.decode(
                G09R2DesignBriefRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.setBrief(
                request,
                trustedUI: request.binding.target.kind == .creativeDocument)
            return try successObject(result)
        case "design.owner.spec":
            let request: G09R2DesignSpecRequest = try G09CreativeWire.decode(
                G09R2DesignSpecRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.setSpec(
                request,
                trustedUI: request.binding.target.kind == .creativeDocument)
            return try successObject(result)
        case "design.owner.freeze":
            let request: G09R2DesignFreezeRequest = try G09CreativeWire.decode(
                G09R2DesignFreezeRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let receipt = try await design.freeze(
                request,
                trustedUI: request.binding.target.kind == .creativeDocument)
            var receiptObject = try successObject(receipt)
            receiptObject["operationID"] = request.opID
            return receiptObject
        case "design.owner.propose":
            let request: G09R2DesignProposeRequest = try G09CreativeWire.decode(
                G09R2DesignProposeRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.propose(
                request,
                trustedUI: request.binding.target.kind == .creativeDocument)
            return try successObject(result)
        case "design.owner.adopt":
            let request: G09R2DesignAdoptRequest = try G09CreativeWire.decode(
                G09R2DesignAdoptRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.adopt(
                request,
                trustedUI: request.binding.target.kind == .creativeDocument)
            return try successObject(result)
        case "design.owner.reject":
            let request: G09R2DesignRejectRequest = try G09CreativeWire.decode(
                G09R2DesignRejectRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.reject(request)
            return try successObject(result)
        case "design.owner.compare":
            let request: G09R2DesignCompareRequest = try G09CreativeWire.decode(
                G09R2DesignCompareRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.compare(request)
            return try successObject(result)
        case "design.owner.restore":
            let request: G09R2DesignRestoreRequest = try G09CreativeWire.decode(
                G09R2DesignRestoreRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.restore(request)
            return try successObject(result)
        case "design.owner.export":
            let request: G09R2DesignExportRequest = try G09CreativeWire.decode(
                G09R2DesignExportRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.export(request)
            return try successObject(result)
        case "design.owner.preview":
            let request: G09R2DesignPreviewRequest = try G09CreativeWire.decode(
                G09R2DesignPreviewRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: false)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.preview(request)
            return try successObject(result)
        case "design.canvas.mutate":
            let envelope: G09R2DesignCanvasMutationEnvelope = try G09CreativeWire.decode(
                G09R2DesignCanvasMutationEnvelope.self, payload: payload)
            let design = try await designService(service, epoch: epoch)
            switch envelope.kind {
            case .brief:
                guard let request = envelope.brief else {
                    throw G09CreativeError.invalidPayload("missingBrief")
                }
                try requireDesignKind(request.binding, canvas: true)
                let result = try await design.setBrief(request)
                return try successObject(result)
            case .spec:
                guard let request = envelope.spec else {
                    throw G09CreativeError.invalidPayload("missingSpec")
                }
                try requireDesignKind(request.binding, canvas: true)
                let result = try await design.setSpec(request)
                return try successObject(result)
            case .freeze:
                guard let request = envelope.freeze else {
                    throw G09CreativeError.invalidPayload("missingFreeze")
                }
                try requireDesignKind(request.binding, canvas: true)
                let receipt = try await design.freeze(request)
                var freezeObject = try successObject(receipt)
                freezeObject["operationID"] = request.opID
                return freezeObject
            case .propose:
                guard let request = envelope.propose else {
                    throw G09CreativeError.invalidPayload("missingProposal")
                }
                try requireDesignKind(request.binding, canvas: true)
                let result = try await design.propose(request)
                return try successObject(result)
            case .reject:
                guard let request = envelope.reject else {
                    throw G09CreativeError.invalidPayload("missingReject")
                }
                try requireDesignKind(request.binding, canvas: true)
                let result = try await design.reject(request)
                return try successObject(result)
            }
        case "design.canvas.adopt":
            let request: G09R2DesignAdoptRequest = try G09CreativeWire.decode(
                G09R2DesignAdoptRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: true)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.adopt(request)
            return try successObject(result)
        case "design.canvas.compare":
            let request: G09R2DesignCompareRequest = try G09CreativeWire.decode(
                G09R2DesignCompareRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: true)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.compare(request)
            return try successObject(result)
        case "design.canvas.restore":
            let request: G09R2DesignRestoreRequest = try G09CreativeWire.decode(
                G09R2DesignRestoreRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: true)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.restore(request)
            return try successObject(result)
        case "design.canvas.export":
            let request: G09R2DesignExportRequest = try G09CreativeWire.decode(
                G09R2DesignExportRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: true)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.export(request)
            return try successObject(result)
        case "design.canvas.preview":
            let request: G09R2DesignPreviewRequest = try G09CreativeWire.decode(
                G09R2DesignPreviewRequest.self, payload: payload)
            try requireDesignKind(request.binding, canvas: true)
            let design = try await designService(service, epoch: epoch)
            let result = try await design.preview(request)
            return try successObject(result)
        default:
            throw G09CreativeError.unsupportedAction(
                G09CreativeWire.bounded(action, limit: 80))
        }
    }

    // MARK: - Design helpers

    private static func designService(
        _ service: G09CreativeDomainService,
        epoch: UInt64
    ) async throws -> G09R2DesignService {
        guard let design = await service.r2DesignService(for: epoch) else {
            throw G09CreativeError.staleGeneration
        }
        return design
    }

    private static func requireDesignKind(
        _ binding: G09R2DesignBindingDTO,
        canvas: Bool
    ) throws {
        let isCanvas = binding.target.kind == .canvasNode
        guard isCanvas == canvas else {
            throw G09R2Error(
                .designTargetUnavailable,
                detail: canvas
                    ? "canvasActionRequiresCanvasTarget"
                    : "ownerActionRequiresOwnerTarget")
        }
    }

    private static func designStatusObject(
        _ service: G09CreativeDomainService
    ) async throws -> [String: Any] {
        let status = await service.r2DesignStatus()
        return try G09CreativeWire.object(status)
    }

    /// Handshake is synchronous; this advertises the closed capability set
    /// without claiming a bound generation. The authoritative bound/epoch
    /// status (and any per-generation restriction) is the `status` operation,
    /// which is already async behind the bridge's bounded wait.
    private static func designCapabilityDictionary() -> [String: Any] {
        [
            "bound": false,
            "availableTargetKinds": [
                "canvasNode", "fileDocument", "chatAttachment",
                "creativeDocument",
            ],
            "targetKindReasons": [String: String](),
            "availableActions": G09R2DesignAction.allCases.map(\.rawValue),
            "maxProposalBytes": G09R2CreativeLimits.designSourceBytes,
            "maxPreviewBytes": G09R2CreativeLimits.designPreviewBytes,
        ] as [String: Any]
    }

    // MARK: - Encoding

    private static func successObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        var object = try G09CreativeWire.object(value)
        object["ok"] = true
        return object
    }

    private static func decode(
        _ result: Result<[String: Any], Error>
    ) -> [String: Any] {
        switch result {
        case .success(let object):
            return object
        case .failure(let error):
            if let typed = error as? G09R2Error { return failure(typed) }
            return G09CreativeWire.failure(G09CreativeError.map(error))
        }
    }

    public static func failure(_ error: G09R2Error) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "error": error.code,
            "retryable": error.retryable,
        ]
        if let detail = error.detail {
            value["reason"] = G09CreativeWire.bounded(detail, limit: 96)
        }
        return value
    }
}

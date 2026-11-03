// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — production execution service (job-8e175eef3cea48d3).
//
// This service closes the three confirmed ENH operation gaps on the original
// Android ownership/runtime stack:
//
//  * ENH-IN-OUT-CONTRACT — every request is validated against MEASURED source
//    facts (guest ffprobe readback or the on-device byte probe) before any
//    invocation; the contract (operation, target frame rate / scale, limits,
//    declared output artifact) is explicit and typed.
//  * ENH-PROGRESS-ABORT — interpolation runs as an original `exec.shell`
//    durable BackgroundJob in the task's resolved Linux environment; live
//    progress is parsed from ffmpeg's own `-progress` file, cancellation is
//    the original cooperative job cancellation, and the original input is
//    never touched (staged copy in, staged `.part` out, verified atomic
//    commit). Super-resolution runs as a bounded service-owned worker with
//    real byte progress and the same truthful cancel/unknown semantics.
//  * ENH-NO-FAKE-UPSCALE — plain resize does not exist on this surface; the
//    only super-resolution path is a user-configured remote backend reached
//    through the original settings/credential services. An unconfigured or
//    unreachable backend stays an explicit, configurable state.
//
// Reused, never duplicated: the creative domain cluster/epoch/session
// authority, the media task binding (task/workspace/pinned environment), the
// durable BackgroundJobService + LocalShellService exec.shell path, the
// RunStore workspace/run resolution, the original SettingsStore for the
// typed enhancer configuration, the original SecretGatewayRegistry
// credential store (no ProviderProfile: the enhancer backend never appears
// as a general video-generation provider), the original media
// importAsset/revision-CAS/receipt ownership for verified outputs, the
// generation download shape, and the workbench staged-write/atomic-commit +
// SHA-256 verification discipline.
import Foundation
#if canImport(Android)
import Android
#endif
import FloeCore
import FloeModels
import FloeWorkspace
import FloePersistence
import FloeAndroidJobTools
import FloeAndroidShellTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Platform seams (injected in focused tests)

public struct G09R2MediaEnhancementPlatform: Sendable {
    /// Submits one original durable exec.shell job. Production routes through
    /// `RuntimeFacadeJobBindings.shared.service`.
    public var submitShellJob: @Sendable (
        _ runID: UUID, _ payloadJSON: Data, _ workspaceRootURL: URL,
        _ environmentID: String?, _ waitForCompletion: Bool
    ) async throws -> BackgroundJob
    public var readJob: @Sendable (UUID) async throws -> BackgroundJob?
    public var cancelJob: @Sendable (UUID) async throws -> BackgroundJob
    /// Digest of a file on the accepted storage root (streaming, bounded).
    public var digestFile: @Sendable (URL) async throws -> (byteCount: Int64, sha256: String)
    /// The configured super-resolution backend transport.
    public var backend: any G09R2SuperResolutionBackendTransport

    public init(
        submitShellJob: @escaping @Sendable (
            UUID, Data, URL, String?, Bool
        ) async throws -> BackgroundJob = { runID, payloadJSON, root, environmentID, wait in
            guard let service = RuntimeFacadeJobBindings.shared.service else {
                throw FloeError.invalidConfiguration("backgroundJobServiceUnavailable")
            }
            // shellPayload already encodes the original exec.shell argument object.
            let payload = payloadJSON
            return try await service.submit(
                runID: runID,
                toolCallID: nil,
                targetTool: LocalShellTool.name,
                payloadJSON: payload,
                scope: .local,
                workspaceRootURL: root,
                allowedWorkspacePaths: [],
                environmentID: environmentID,
                submissionSource: .nativeService,
                waitForCompletion: wait)
        },
        readJob: @escaping @Sendable (UUID) async throws -> BackgroundJob? = { id in
            guard let service = RuntimeFacadeJobBindings.shared.service else { return nil }
            return try await service.job(id: id)
        },
        cancelJob: @escaping @Sendable (UUID) async throws -> BackgroundJob = { id in
            guard let service = RuntimeFacadeJobBindings.shared.service else {
                throw FloeError.invalidConfiguration("backgroundJobServiceUnavailable")
            }
            return try await service.cancel(id: id)
        },
        digestFile: @escaping @Sendable (URL) async throws -> (byteCount: Int64, sha256: String) = { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? Int64) ?? Int64((attributes[.size] as? Int) ?? 0)
            let sha = try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: { Task.isCancelled })
            return (byteCount, sha)
        },
        backend: any G09R2SuperResolutionBackendTransport =
            G09R2FalSuperResolutionBackend()
    ) {
        self.submitShellJob = submitShellJob
        self.readJob = readJob
        self.cancelJob = cancelJob
        self.digestFile = digestFile
        self.backend = backend
    }
}

// MARK: - Service

public final class G09R2MediaEnhancementService: @unchecked Sendable {
    public static let shared = G09R2MediaEnhancementService()

    /// Bounded live enhancement workers (super-resolution HTTP and the
    /// interpolation monitor). Durable state lives in the on-disk journal, so
    /// waiting jobs do not occupy a worker slot.
    public static let maximumLiveWorkers = 4

    private let lock = NSLock()
    private var workers: [String: Worker] = [:]
    private var stoppingEpoch: UInt64?

    internal let platform: G09R2MediaEnhancementPlatform
    internal let environmentProvider: @Sendable (UInt64) async -> G09R2GenerationEnvironment?

    private struct Worker {
        var token: String
        var epoch: UInt64
        var jobKey: String
        var cancelRequested: Bool
        var task: Task<Void, Never>?
    }

    public convenience init() {
        self.init(
            platform: G09R2MediaEnhancementPlatform(),
            environmentProvider: { epoch in
                guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
                    epoch: epoch) else { return nil }
                return G09R2GenerationEnvironment(
                    root: cluster.identity.root,
                    database: cluster.database,
                    configuration: cluster.modelConfigurationStore)
            })
    }

    init(platform: G09R2MediaEnhancementPlatform,
         environmentProvider: @escaping @Sendable (UInt64) async -> G09R2GenerationEnvironment?) {
        self.platform = platform
        self.environmentProvider = environmentProvider
    }

    // MARK: - Capability

    /// Honest capability for one project. Interpolation additionally requires
    /// an active media task binding (the pinned task workspace + environment
    /// the guest job will run in); super-resolution requires the user to have
    /// configured a backend through the original provider settings.
    public func capability(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO
    ) async throws -> G09R2EnhancementCapabilityDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let env = try await requireEnvironment(cluster, epoch: epoch)

        // Interpolation: bound + pinned task context + shell readiness.
        let binding = try? await service.r2TaskBindingStore()?
            .active(projectID: context.projectID)
        let interpolationReady: Bool
        let interpolationReason: String?
        let engine = "ffmpeg-minterpolate"
        if binding?.state != .pinned {
            interpolationReady = false
            interpolationReason = "taskBindingRequired"
        } else if !RuntimeFacadeLinuxBindings.shared.isCapabilityQualified {
            interpolationReady = false
            interpolationReason = "linuxUnavailable"
        } else {
            interpolationReady = true
            interpolationReason = nil
        }

        // Super-resolution: the typed enhancer configuration row (original
        // SettingsStore) + the credential in the ORIGINAL credential store.
        // No ProviderProfile is involved: the enhancer backend must never
        // appear as a general video-generation provider.
        let configurationStore = G09R2EnhancerBackendConfigurationStore(
            database: env.database)
        let configuration = try? await configurationStore.load()
        var srReady = false
        var srName: String?
        var srReason: String?
        if binding?.state != .pinned {
            srReady = false
            srReason = "taskBindingRequired"
        } else if let configuration {
            if configuration.legacyProviderProfileID != nil {
                srReason = "backendProfileUnavailable"
            } else if await configurationStore.credentialConfigured(configuration) {
                srReady = true
                srName = configuration.displayName
                    ?? G09R2FalSuperResolutionBackend.defaultEndpointID
            } else {
                srReason = "backendProfileUnavailable"
            }
        } else {
            srReason = "backendNotConfigured"
        }

        return G09R2EnhancementCapabilityDTO(
            interpolationReady: interpolationReady,
            interpolationEngine: interpolationReady ? engine : nil,
            interpolationUnavailableReason: interpolationReason,
            superResolutionReady: srReady,
            superResolutionBackendName: srName,
            superResolutionUnavailableReason: srReason)
    }

    // MARK: - Backend configuration

    /// Secret-free projection of the typed enhancer configuration for the
    /// settings UI. Resolving the credential only checks presence: the bytes
    /// never enter the reply.
    public func configuration(
        service: G09CreativeDomainService, epoch: UInt64
    ) async throws -> G09R2EnhancerConfigurationDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = G09R2EnhancerBackendConfigurationStore(database: env.database)
        guard let configuration = try await store.load() else {
            return G09R2EnhancerConfigurationDTO(
                configured: false, displayName: nil,
                endpointID: G09R2EnhancerBackendConfiguration.defaultEndpointID,
                credentialConfigured: false,
                legacyProviderProfileReferenced: false)
        }
        return G09R2EnhancerConfigurationDTO(
            configured: true,
            displayName: configuration.displayName,
            endpointID: configuration.endpointID,
            credentialConfigured: await store.credentialConfigured(configuration),
            legacyProviderProfileReferenced: configuration.legacyProviderProfileID != nil)
    }

    /// Persists the typed row through ONE original sealed secure ingress.
    /// When the request carries a `saveIntentToken` (a key Set), the service
    /// consumes the one-shot vault lease with the EXACT closed `enhancerSave`
    /// subject, resolving the route ONLY from the trusted host route
    /// registry (never the command wire), and the store performs the single
    /// original vault capture + immutable rotation inside the
    /// runtime-owned mutation lifetime: new owned reference committed,
    /// accepted-root fence revalidated at the commit point, row persisted
    /// LAST, previous credential retired through the original vault delete.
    /// A failed save therefore leaves the previous configuration AND
    /// credential byte-identical; a lost reply after a successful commit
    /// leaves the new key intact (the UI re-reads the configuration; it
    /// never resubmits key writes). A root switch mid-save refuses typed
    /// before any durable effect. The request's `credentialAccount` is
    /// advisory only: binding always comes from the sealed ingress / the
    /// current owned row.
    public func saveConfiguration(
        service: G09CreativeDomainService, epoch: UInt64,
        request: G09R2EnhancerConfigurationSaveRequest
    ) async throws -> G09R2EnhancerConfigurationDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = G09R2EnhancerBackendConfigurationStore(database: env.database)
        let configuration = G09R2EnhancerBackendConfiguration(
            displayName: request.displayName,
            endpointID: request.endpointID,
            credentialAccount: request.credentialAccount)
        // The whole exchange is pinned to the request epoch; the commit
        // revalidates the fence right before the row becomes durable.
        let commitFence: @Sendable () async throws -> Void = { [self] in
            try await self.requireNoRootStop(service, epoch: epoch)
        }
        var intentLease: SaveIntentLease?
        if let token = request.saveIntentToken {
            // Consume the ONE sealed enhancer ingress. The route comes ONLY
            // from the trusted host route registry (never the command
            // envelope); without a live enhancer route the lease is NOT
            // consumed and nothing is ever written.
            guard let route = G02HostSecureIngress.registry.currentRoute() else {
                throw G09CreativeError.runtimeUnavailable
            }
            do {
                intentLease = try SecretSaveIntentVault.shared.consume(
                    token: token, route: route, expectedSubject: .enhancerSave)
            } catch {
                throw Self.mapIngressRejection(error)
            }
        }
        do {
            try await store.save(
                configuration,
                intentLease: intentLease,
                epoch: epoch,
                commitValidation: commitFence)
        } catch let error as G09R2EnhancerBackendConfigurationStore.ConfigurationError {
            throw G09CreativeError.invalidPayload(error.wireCode)
        } catch let refusal as G09R2EnhancerRuntimeRefusal {
            throw Self.mapRuntimeRefusal(refusal)
        }
        return G09R2EnhancerConfigurationDTO(
            configured: true,
            displayName: configuration.displayName,
            endpointID: configuration.endpointID,
            credentialConfigured: true,
            legacyProviderProfileReferenced: false)
    }

    /// Maps a sealed-ingress consume refusal onto the closed creative
    /// vocabulary. The mapping is secret-free: no token, candidate or route
    /// detail ever travels the reply. A replayed/consumed/expired one-shot
    /// slot, a route mismatch (the host route closed or was replaced) and a
    /// subject mismatch (a providerSave/mcpSave/webSearchSave token can
    /// never drive an enhancer save) all refuse BEFORE any effect.
    private static func mapIngressRejection(_ error: Error) -> G09CreativeError {
        guard let backend = error as? SecretBackendError,
              case .intentRejected(let rejection) = backend else {
            return .invalidPayload("saveIntentUnavailable")
        }
        switch rejection {
        case .unknownToken:
            return .invalidPayload("saveIntentUnknown")
        case .consumed:
            return .invalidPayload("saveIntentConsumed")
        case .expired:
            return .invalidPayload("saveIntentExpired")
        case .routeMismatch:
            return .invalidPayload("saveIntentRouteMismatch")
        case .subjectMismatch:
            return .invalidPayload("saveIntentSubjectMismatch")
        case .intentSaturated:
            return .invalidPayload("saveIntentLeasesSaturated")
        default:
            return .invalidPayload("saveIntentUnavailable")
        }
    }

    /// Revokes the configuration: the credential is retired through the
    /// original vault delete (durable deletion-queue semantics) and the row
    /// is removed only afterwards, with the ownership fence held for the
    /// whole exchange.
    @discardableResult
    public func clearConfiguration(
        service: G09CreativeDomainService, epoch: UInt64
    ) async throws -> G09R2EnhancerConfigurationDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = G09R2EnhancerBackendConfigurationStore(database: env.database)
        do {
            try await store.clear(epoch: epoch)
        } catch let error as G09R2EnhancerBackendConfigurationStore.ConfigurationError {
            throw G09CreativeError.invalidPayload(error.wireCode)
        } catch let refusal as G09R2EnhancerRuntimeRefusal {
            throw Self.mapRuntimeRefusal(refusal)
        }
        return G09R2EnhancerConfigurationDTO(
            configured: false, displayName: nil,
            endpointID: G09R2EnhancerBackendConfiguration.defaultEndpointID,
            credentialConfigured: false,
            legacyProviderProfileReferenced: false)
    }

    /// Maps a trusted-runtime ownership refusal onto the closed creative
    /// error vocabulary: a stale generation is the ordinary stale-generation
    /// refusal; an admission rejection (owner mismatch, rebind while owned,
    /// epoch not newer, …) is a typed payload refusal with the dedicated
    /// `enhancerRuntimeOwnership` wire code (feature copy is primary's
    /// lane; until then the labelled fallback shows the code).
    private static func mapRuntimeRefusal(
        _ refusal: G09R2EnhancerRuntimeRefusal
    ) -> G09CreativeError {
        switch refusal {
        case .staleGeneration:
            return G09CreativeError.staleGeneration
        case .ownershipRejected:
            return G09CreativeError.invalidPayload("enhancerRuntimeOwnership")
        }
    }

    // MARK: - Submit

    public struct SubmissionHandle: Sendable, Equatable {
        public var jobID: String
        public var state: G09R2EnhancementJobState
        public var idempotent: Bool
    }

    /// Validates the contract, stages the durable journal and starts the real
    /// backend. Returns the durable enhancement jobID immediately; progress,
    /// cancel and delivery are observed through `status`/`cancel`.
    public func submit(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, request: G09R2EnhancementRequestDTO,
        limits: G09R2EnhancementLimits = .standard
    ) async throws -> SubmissionHandle {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireContext(context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let loaded = try await loadProject(cluster, context: context)
        guard loaded.writable else { throw G09CreativeError.provenanceMismatch }
        let mediaRoot = loaded.storage.rootURL

        // 1. Resolve the input file beneath the trusted media root only.
        let inputURL = try resolveUnderRoot(
            relative: request.inputRelativePath, root: mediaRoot)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw G09R2EnhancementRefusal.sourceUnreadable("input not found")
        }

        // 2. Resolve the frozen execution context for guest jobs.
        let execution = try await resolveExecutionContext(
            service: service, env: env, projectID: context.projectID)

        // 3. Measured source facts BEFORE invocation.
        let sourceFacts = try await probeSource(
            inputURL: inputURL, context: context, execution: execution)

        // 4. Explicit guards — unsupported combinations refuse here.
        _ = try G09R2EnhancementGuards.validate(
            source: sourceFacts, request: request, limits: limits)

        // 5. Destination contract under the Enhancements directory.
        let destinationRelative = "Enhancements/\(request.outputFileName)"
        let destinationURL = try resolveUnderRoot(
            relative: destinationRelative, root: mediaRoot)
        if FileManager.default.fileExists(atPath: destinationURL.path),
           !request.overwrite {
            throw G09R2EnhancementRefusal.outputExists
        }

        // 6. Durable journal first (prepared) — a relaunch can always settle.
        let jobID = UUID().uuidString.lowercased()
        let journal = G09R2EnhancementJournal(root: mediaRoot)
        try await journal.write(record: .init(
            jobID: jobID, projectID: context.projectID,
            state: .queued, request: request,
            sourceFacts: sourceFacts,
            createdAt: Date(), updatedAt: Date()))

        // 7. Start the real engine.
        switch request.operation {
        case .interpolation:
            try await startInterpolation(
                service: service, epoch: epoch, cluster: cluster, context: context,
                execution: execution, jobID: jobID, inputURL: inputURL,
                mediaRoot: mediaRoot, request: request,
                sourceFacts: sourceFacts, journal: journal)
        case .superResolution:
            try await startSuperResolution(
                service: service, epoch: epoch, cluster: cluster, context: context,
                env: env, execution: execution, jobID: jobID,
                inputURL: inputURL, mediaRoot: mediaRoot, request: request,
                sourceFacts: sourceFacts, journal: journal)
        }
        return SubmissionHandle(jobID: jobID, state: .running, idempotent: false)
    }

    // MARK: - Status

    public func status(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, jobID: String
    ) async throws -> G09R2EnhancementStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let loaded = try await loadProject(cluster, context: context)
        let journal = G09R2EnhancementJournal(root: loaded.storage.rootURL)
        guard let record = try await journal.read(jobID: jobID) else {
            throw G09CreativeError.invalidPayload("unknownEnhancementJob")
        }
        // The durable shell job, when present, is the live truth for progress.
        var liveProgress: G09R2EnhancementProgress?
        var liveState = record.state
        var liveError: String?
        if let shellJobID = record.shellJobID {
            if let job = try? await platform.readJob(shellJobID) {
                (liveState, liveProgress, liveError) = try await interpolationLiveState(
                    record: record, job: job, mediaRoot: loaded.storage.rootURL)
            } else {
                liveState = .outcomeUnknown
                liveError = "jobRecordUnavailable"
            }
        } else if let remoteID = record.remoteRequestID,
                  !record.state.isTerminal,
                  record.state == .running || record.state == .queued {
            // Cloud job with a retained handle and no live worker (relaunch):
            // resume through the exact handle — never resubmit.
            liveState = .running
            liveProgress = record.lastProgress
            try await kickSuperResolutionResume(
                service: service, epoch: epoch, context: context,
                cluster: cluster, record: record, remoteID: remoteID,
                mediaRoot: loaded.storage.rootURL)
        } else if record.state == .running || record.state == .queued {
            liveProgress = record.lastProgress
        }
        return G09R2EnhancementStatusDTO(
            jobID: jobID,
            state: liveState,
            progress: liveProgress ?? record.lastProgress,
            receipt: record.receipt,
            errorCode: liveError ?? record.errorCode,
            errorDetail: record.errorDetail,
            retryable: (liveError ?? record.errorCode).map {
                Self.retryableCodes.contains($0)
            } ?? false,
            canCancel: !liveState.isTerminal)
    }

    // MARK: - Cancel

    @discardableResult
    public func cancel(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, jobID: String
    ) async throws -> G09R2EnhancementStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let loaded = try await loadProject(cluster, context: context)
        let journal = G09R2EnhancementJournal(root: loaded.storage.rootURL)
        guard let record = try await journal.read(jobID: jobID),
              !record.state.isTerminal else {
            throw G09CreativeError.invalidPayload("unknownOrTerminalJob")
        }
        // Cooperative cancellation of the exact owned processor first.
        requestWorkerCancel(jobKey: jobID)
        if let shellJobID = record.shellJobID {
            _ = try? await platform.cancelJob(shellJobID)
        } else if record.remoteRequestID != nil,
                  let env = try? await requireEnvironment(cluster, epoch: epoch),
                  let configuration = try? await G09R2EnhancerBackendConfigurationStore(
                      database: env.database).load(),
                  configuration.legacyProviderProfileID == nil,
                  let apiKey = await G09R2EnhancerBackendConfigurationStore(
                      database: env.database).credential(for: configuration) {
            // Best-effort provider cancellation through the retained handle;
            // legacy records derive the canonical owner/alias URLs per the
            // official fal-js parser — never the full submission subpath.
            let handle = record.remoteHandle
                ?? G09R2FalSuperResolutionBackend.canonicalHandle(
                    queueBase: G09R2EnhancerBackendConfigurationStore.queueBaseURL,
                    endpointID: configuration.endpointID,
                    requestID: record.remoteRequestID!)
            try? await platform.backend.cancel(
                baseURL: G09R2EnhancerBackendConfigurationStore.queueBaseURL,
                apiKey: apiKey, handle: handle)
        }
        var updated = record
        updated.state = .cancelled
        updated.errorCode = "cancelled"
        updated.errorDetail = "Cancelled by the user; the source file is unchanged."
        updated.updatedAt = Date()
        try await journal.write(record: updated)
        return G09R2EnhancementStatusDTO(
            jobID: jobID, state: .cancelled,
            progress: updated.lastProgress, receipt: updated.receipt,
            errorCode: updated.errorCode, errorDetail: updated.errorDetail,
            retryable: false, canCancel: false)
    }

    // MARK: - Import retry

    /// Retries the original importAsset ownership for one COMPLETED job whose
    /// verified output has not (or not yet) become a project asset. Idempotent
    /// through the original durable import intent/receipt (`opID` derives
    /// from the job ID), so a retry after a successful import replays the
    /// committed receipt instead of adding a second asset.
    public func importOutput(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, jobID: String
    ) async throws -> G09R2EnhancementStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        let loaded = try await loadProject(cluster, context: context)
        let journal = G09R2EnhancementJournal(root: loaded.storage.rootURL)
        guard let record = try await journal.read(jobID: jobID),
              record.state == .completed,
              let receipt = record.receipt,
              receipt.importedAssetID == nil else {
            // Already imported (or not completed): report the live truth.
            return try await status(
                service: service, epoch: epoch, context: context, jobID: jobID)
        }
        let opID = "enhance.\(jobID).import"
        guard G09CreativeWire.safeOperationID(opID) else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        let result = await performImport(
            cluster: cluster, context: context, opID: opID,
            fileName: (receipt.outputRelativePath as NSString).lastPathComponent,
            byteCount: receipt.outputBytes, sha256: receipt.outputSHA256)
        var updated = record
        switch result {
        case .success(let imported):
            updated.receipt?.importedAssetID = imported.assetID
            updated.receipt?.importRevision = imported.revision
            updated.receipt?.importErrorCode = nil
        case .failure(let code):
            updated.receipt?.importErrorCode = code
        }
        updated.updatedAt = Date()
        try? await journal.write(record: updated)
        return G09R2EnhancementStatusDTO(
            jobID: jobID,
            state: updated.state,
            progress: updated.lastProgress,
            receipt: updated.receipt,
            errorCode: updated.errorCode,
            errorDetail: updated.errorDetail,
            retryable: updated.errorCode.map { Self.retryableCodes.contains($0) } ?? false,
            canCancel: false)
    }

    // MARK: - Root stop

    /// Phase-1 root stop: refuse new workers for this epoch, request
    /// cancellation of the exact owned tasks, and report TRUE only after every
    /// worker actually settled.
    public func requestRootStop(epoch: UInt64) -> Bool {
        lock.lock()
        stoppingEpoch = epoch
        var tasks: [Task<Void, Never>] = []
        for token in Array(workers.keys) {
            guard var worker = workers[token], worker.epoch == epoch else { continue }
            worker.cancelRequested = true
            if let task = worker.task { tasks.append(task) }
            workers[token] = worker
        }
        let pending = workers.values.contains { $0.epoch == epoch }
        lock.unlock()
        for task in tasks { task.cancel() }
        return !pending
    }

    public func pendingWorkerCount(epoch: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        return workers.values.filter { $0.epoch == epoch }.count
    }

    // MARK: - Private: execution context

    struct ExecutionContext: Sendable, Equatable {
        var taskID: UUID
        var workspaceID: UUID
        var workspaceRootURL: URL
        var runID: UUID
        var environmentID: String?
    }

    private func resolveExecutionContext(
        service: G09CreativeDomainService,
        env: G09R2GenerationEnvironment,
        projectID: UUID
    ) async throws -> ExecutionContext {
        guard let binding = try await service.r2TaskBindingStore()?
            .active(projectID: projectID),
              binding.state == .pinned else {
            throw G09R2EnhancementRefusal.taskContextRequired
        }
        let taskID = binding.taskID
        guard let workspaceStore = await service.r2WorkspaceStore(),
              let workspaceID = try? await workspaceStore.workspaceID(
                conversationID: taskID),
              let record = try? await workspaceStore.workspace(id: workspaceID),
              let relative = record.internalRelativePath,
              !relative.isEmpty else {
            throw G09R2EnhancementRefusal.taskContextRequired
        }
        let base = URL(fileURLWithPath: env.root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
        let root = base.appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
        guard root.path.hasPrefix(base.path + "/") else {
            throw G09R2EnhancementRefusal.taskContextRequired
        }
        let runs = try? await SQLiteRunStore(database: env.database)
            .runs(conversationID: taskID)
        guard let runID = runs?.sorted(by: {
            $0.startedAt > $1.startedAt
        }).first?.id else {
            throw G09R2EnhancementRefusal.taskContextRequired
        }
        return ExecutionContext(
            taskID: taskID, workspaceID: workspaceID, workspaceRootURL: root,
            runID: runID, environmentID: binding.environmentID)
    }

    // MARK: - Private: probing

    /// Measured source facts. Images use the on-device byte probe; video uses
    /// the guest ffprobe readback so frame rate and duration are measured, not
    /// guessed.
    private func probeSource(
        inputURL: URL, context: G09R2ProjectContextDTO,
        execution: ExecutionContext
    ) async throws -> G09R2MediaProbeFacts {
        let ext = inputURL.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "bmp", "gif"]
        let digest = try await platform.digestFile(inputURL)
        if imageExtensions.contains(ext) {
            guard let image = G09R2MediaProbe.imageFacts(
                try Data(floeContentsOf: inputURL)) else {
                throw G09R2EnhancementRefusal.sourceUnreadable("image probe failed")
            }
            return G09R2MediaProbeFacts(
                isImage: true, width: image.width, height: image.height,
                durationSeconds: 0, frameRate: 0, frameCount: 0,
                hasAudio: false, codec: image.mimeType,
                byteCount: digest.byteCount, sha256: digest.sha256)
        }
        // Video: stage a copy into the task workspace and run the guest probe.
        return try await runGuestProbe(
            inputURL: inputURL, execution: execution)
    }

    /// Copies the input into the task workspace staging area (the guest sees
    /// it at `/workspace/...`) and reads measured facts back through one
    /// bounded exec.shell ffprobe job.
    private func runGuestProbe(
        inputURL: URL, execution: ExecutionContext
    ) async throws -> G09R2MediaProbeFacts {
        let probeJobID = UUID().uuidString.lowercased()
        let layout = G09R2EnhancementGuestLayout(
            jobID: "probe-\(probeJobID)",
            inputRelativePath: inputURL.lastPathComponent,
            outputFileName: "probe")
        let stagingRoot = execution.workspaceRootURL
            .appendingPathComponent(layout.stagingRelativeDir, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true)
        let stagedInput = stagingRoot
            .appendingPathComponent((layout.inputRelativePath as NSString).lastPathComponent)
        if !FileManager.default.fileExists(atPath: stagedInput.path) {
            try FileManager.default.copyItem(at: inputURL, to: stagedInput)
        }
        let relativeInput = "\(layout.stagingRelativeDir)/\((layout.inputRelativePath as NSString).lastPathComponent)"
        let script = G09R2EnhancementFFmpegPlan.probeScript(
            inputRelativePath: relativeInput)
        let payload = try shellPayload(script: script)
        let job = try await platform.submitShellJob(
            execution.runID, payload, execution.workspaceRootURL,
            execution.environmentID, true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        guard job.state == .completed else {
            let error = job.lastError ?? "probeFailed"
            if error.contains("toolsMissing") {
                throw G09R2EnhancementRefusal.backendUnavailable(
                    "ffprobe is not installed in the task Linux environment")
            }
            throw G09R2EnhancementRefusal.sourceUnreadable(error)
        }
        let outputText = job.outputPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        } ?? (job.resultSummary ?? "")
        let digest = try await platform.digestFile(stagedInput)
        let blocks = G09R2EnhancementProbeParser.blocks(fromJobOutput: outputText)
        if let errorToken = blocks.error {
            throw G09R2EnhancementRefusal.sourceUnreadable(errorToken)
        }
        guard let json = blocks.input else {
            throw G09R2EnhancementRefusal.sourceUnreadable("probe produced no facts")
        }
        return try G09R2EnhancementProbeParser.parseVideoFacts(
            json, byteCount: digest.byteCount, sha256: digest.sha256)
    }

    /// Probes a backend-delivered file by staging one copy into the task
    /// workspace and reading measured facts back through the guest ffprobe.
    private func probeDownloadedVideo(
        _ file: URL, stagedDigest: (byteCount: Int64, sha256: String),
        execution: ExecutionContext
    ) async throws -> G09R2MediaProbeFacts {
        var facts = try await runGuestProbe(inputURL: file, execution: execution)
        facts.byteCount = stagedDigest.byteCount
        facts.sha256 = stagedDigest.sha256
        return facts
    }

    // MARK: - Private: interpolation engine

    private func startInterpolation(
        service: G09CreativeDomainService, epoch: UInt64, cluster: G09R2BoundCluster,
        context: G09R2ProjectContextDTO,
        execution: ExecutionContext,
        jobID: String, inputURL: URL, mediaRoot: URL,
        request: G09R2EnhancementRequestDTO,
        sourceFacts: G09R2MediaProbeFacts,
        journal: G09R2EnhancementJournal
    ) async throws {
        guard case .interpolation(let targetFPS) = request.operation else {
            throw G09R2EnhancementRefusal.unsupportedCombination("not interpolation")
        }
        let layout = G09R2EnhancementGuestLayout(
            jobID: jobID,
            inputRelativePath: request.inputRelativePath,
            outputFileName: request.outputFileName)
        // Stage the input into the task workspace (guest-readable copy; the
        // original media asset is never opened for write).
        let stagingRoot = execution.workspaceRootURL
            .appendingPathComponent(layout.stagingRelativeDir, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true)
        let stagedInput = execution.workspaceRootURL
            .appendingPathComponent(layout.inputRelativePath)
        try? FileManager.default.removeItem(at: stagedInput)
        try FileManager.default.copyItem(at: inputURL, to: stagedInput)
        let script = G09R2EnhancementFFmpegPlan.interpolationScript(
            layout: layout, targetFPS: targetFPS,
            sourceHasAudio: sourceFacts.hasAudio)
        let payload = try shellPayload(script: script.script)
        do {
            try startWorker(epoch: epoch, jobKey: jobID) { [weak self] token in
                guard let self else { return }
                var submittedJobID: UUID?
                do {
                    try self.throwIfCancelled(token: token)
                    let shellJob = try await self.platform.submitShellJob(
                        execution.runID, payload, execution.workspaceRootURL,
                        execution.environmentID, false)
                    submittedJobID = shellJob.id
                    try await journal.update(jobID: jobID) {
                        $0.state = .running
                        $0.shellJobID = shellJob.id
                        $0.updatedAt = Date()
                    }
                    await self.monitorInterpolation(
                        token: token, epoch: epoch, jobID: jobID,
                        shellJobID: shellJob.id, cluster: cluster, mediaRoot: mediaRoot,
                        workspaceRoot: execution.workspaceRootURL,
                        layout: layout, request: request, sourceFacts: sourceFacts,
                        context: context, journal: journal)
                } catch {
                    if let submittedJobID {
                        _ = try? await self.platform.cancelJob(submittedJobID)
                        // Keep staging while the real job may still be settling.
                    } else {
                        try? FileManager.default.removeItem(at: stagedInput)
                    }
                    let retainedID = submittedJobID
                    try? await journal.update(jobID: jobID) {
                        $0.shellJobID = retainedID
                        $0.state = retainedID == nil ? .failed : .outcomeUnknown
                        $0.errorCode = retainedID == nil ? "interpolationSubmitFailed" : "outcomeUnknown"
                        $0.updatedAt = Date()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedInput)
            throw error
        }
    }

    private func monitorInterpolation(
        token: String, epoch: UInt64, jobID: String, shellJobID: UUID,
        cluster: G09R2BoundCluster, mediaRoot: URL, workspaceRoot: URL,
        layout: G09R2EnhancementGuestLayout,
        request: G09R2EnhancementRequestDTO,
        sourceFacts: G09R2MediaProbeFacts,
        context: G09R2ProjectContextDTO,
        journal: G09R2EnhancementJournal
    ) async {
        let progressURL = workspaceRoot.appendingPathComponent(layout.progressRelativePath)
        let stagedOutput = workspaceRoot.appendingPathComponent(layout.outputRelativePath)
        var terminal: BackgroundJob?
        while !isWorkerCancelled(token: token) {
            do {
                if let job = try await platform.readJob(shellJobID),
                   job.state.isTerminal {
                    terminal = job
                    break
                }
            } catch { /* keep polling; the durable store is the truth */ }
            if let text = try? String(contentsOfFile: progressURL.path, encoding: .utf8),
               let frame = G09R2EnhancementProbeParser.latestFrame(fromProgressText: text),
               var record = try? await journal.read(jobID: jobID) {
                let estimated = max(1, Int((sourceFacts.durationSeconds * ({
                    if case .interpolation(let fps) = request.operation { return fps }
                    return sourceFacts.frameRate
                }())).rounded()))
                record.lastProgress = G09R2EnhancementProgress(
                    phase: .processing, completedUnits: frame, totalUnits: estimated)
                record.updatedAt = Date()
                try? await journal.write(record: record)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !isWorkerCancelled(token: token), let job = terminal else {
            // Cancellation is settled by `cancel`; on root stop the durable
            // shell job cancellation is requested and we exit without
            // inventing a terminal state.
            return
        }
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot.appendingPathComponent(layout.inputRelativePath))
        }
        await settleInterpolation(
            shellJob: job, jobID: jobID, cluster: cluster, mediaRoot: mediaRoot,
            stagedOutput: stagedOutput, request: request,
            sourceFacts: sourceFacts, context: context, journal: journal,
            isCancelled: { self.isWorkerCancelled(token: token) })
    }

    private func settleInterpolation(
        shellJob: BackgroundJob, jobID: String,
        cluster: G09R2BoundCluster, mediaRoot: URL,
        stagedOutput: URL, request: G09R2EnhancementRequestDTO,
        sourceFacts: G09R2MediaProbeFacts,
        context: G09R2ProjectContextDTO,
        journal: G09R2EnhancementJournal,
        isCancelled: @escaping @Sendable () -> Bool
    ) async {
        var record = (try? await journal.read(jobID: jobID))
            ?? G09R2EnhancementRecord(
                jobID: jobID, projectID: UUID(), state: .running,
                request: request, sourceFacts: sourceFacts,
                createdAt: Date(), updatedAt: Date())
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        do {
            guard shellJob.state == .completed else {
                switch shellJob.state {
                case .cancelled:
                    record.state = .cancelled
                    record.errorCode = "cancelled"
                case .interrupted:
                    record.state = .outcomeUnknown
                    record.errorCode = "outcomeUnknown"
                    record.errorDetail = "The job was interrupted before its outcome was confirmed; the staged output was discarded and the source is unchanged."
                default:
                    record.state = .failed
                    record.errorCode = "ffmpegFailed"
                    record.errorDetail = bounded(shellJob.lastError ?? "exit \(shellJob.id)")
                }
                record.updatedAt = Date()
                try? await journal.write(record: record)
                return
            }
            // Verify: measured output facts must satisfy the contract.
            let outputText = shellJob.outputPath.flatMap {
                try? String(contentsOfFile: $0, encoding: .utf8)
            } ?? ""
            let blocks = G09R2EnhancementProbeParser.blocks(fromJobOutput: outputText)
            guard let json = blocks.output else {
                throw G09R2EnhancementRefusal.sourceUnreadable(
                    "output probe missing")
            }
            let stagedDigest = try await platform.digestFile(stagedOutput)
            let measured = try G09R2EnhancementProbeParser.parseVideoFacts(
                json, byteCount: stagedDigest.byteCount, sha256: stagedDigest.sha256)
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: sourceFacts, request: request)

            // Commit: staged `.part` -> verified destination, atomic replace.
            record.state = .validating
            try? await journal.write(record: record)
            let destination = try resolveUnderRoot(
                relative: "Enhancements/\(request.outputFileName)", root: mediaRoot)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let committedDigest = try await commitVerified(
                from: stagedOutput, to: destination, overwrite: request.overwrite,
                isCancelled: isCancelled)
            record.receipt = G09R2EnhancementReceipt(
                outputRelativePath: "Enhancements/\(request.outputFileName)",
                engine: "ffmpeg-minterpolate",
                method: "interpolation",
                inputKind: "video",
                sourceWidth: sourceFacts.width,
                sourceHeight: sourceFacts.height,
                sourceFPS: sourceFacts.frameRate,
                sourceDurationSeconds: sourceFacts.durationSeconds,
                sourceFrameCount: sourceFacts.frameCount,
                outputWidth: measured.width,
                outputHeight: measured.height,
                outputFPS: measured.frameRate,
                outputDurationSeconds: measured.durationSeconds,
                outputFrameCount: measured.frameCount,
                outputBytes: committedDigest.byteCount,
                outputSHA256: committedDigest.sha256,
                warnings: sourceFacts.hasAudio
                    ? [] : ["the source has no audio track"])
            record.state = .completed
            record.errorCode = nil
            record.errorDetail = nil
            record.updatedAt = Date()
            try await journal.write(record: record)
            // The verified output re-enters the original importAsset /
            // revision-CAS ownership so it is previewable/saveable through
            // the existing media pipeline.
            await importVerifiedOutput(
                cluster: cluster, jobID: jobID, context: context,
                journal: journal,
                fileName: request.outputFileName,
                byteCount: committedDigest.byteCount,
                sha256: committedDigest.sha256)
        } catch {
            record.state = .failed
            record.errorCode = (error as? G09R2EnhancementRefusal)?.code
                ?? "verificationFailed"
            record.errorDetail = bounded(
                (error as? G09R2EnhancementRefusal)?.detail
                    ?? (error as? G09R2EnhancementParsingError).map { "\($0)" }
                    ?? "verification failed")
            record.updatedAt = Date()
            try? await journal.write(record: record)
        }
    }

    // MARK: - Verified output import (original importAsset ownership)

    /// Imports one committed enhancement output into its media project
    /// through the ORIGINAL `G09MediaProjectHost.importAsset` durable
    /// intent/CAS/receipt path, using the measured bytes + SHA-256 already
    /// captured in the receipt. The project revision is re-read first and a
    /// single revision-conflict retry uses the fresh revision, so an ordinary
    /// concurrent project edit cannot wedge the import. Failures stay honest:
    /// the output file remains committed and the receipt carries a bounded
    /// `importErrorCode` the UI can retry with `media.enhancement.import`.
    private func importVerifiedOutput(
        cluster: G09R2BoundCluster, jobID: String,
        context: G09R2ProjectContextDTO,
        journal: G09R2EnhancementJournal, fileName: String,
        byteCount: Int64, sha256: String
    ) async {
        guard var record = try? await journal.read(jobID: jobID),
              record.state == .completed, record.receipt != nil,
              record.receipt?.importedAssetID == nil,
              record.receipt?.importErrorCode == nil else { return }
        let opID = "enhance.\(jobID).import"
        guard G09CreativeWire.safeOperationID(opID) else { return }
        let result = await performImport(
            cluster: cluster, context: context, opID: opID, fileName: fileName,
            byteCount: byteCount, sha256: sha256)
        switch result {
        case .success(let imported):
            record.receipt?.importedAssetID = imported.assetID
            record.receipt?.importRevision = imported.revision
        case .failure(let code):
            record.receipt?.importErrorCode = code
        }
        record.updatedAt = Date()
        try? await journal.write(record: record)
    }

    private enum ImportOutcome {
        case success(assetID: UUID, revision: Int64)
        case failure(code: String)
    }

    private func performImport(
        cluster: G09R2BoundCluster, context: G09R2ProjectContextDTO,
        opID: String, fileName: String,
        byteCount: Int64, sha256: String
    ) async -> ImportOutcome {
        // One retry with a freshly read revision covers an ordinary
        // concurrent project edit between submission and settle.
        for attempt in 0..<2 {
            do {
                let loaded = try await cluster.media.load(
                    id: context.projectID, requested: context.storage,
                    origin: context.origin)
                guard loaded.writable else { return .failure(code: "provenanceMismatch") }
                let mediaRoot = loaded.storage.rootURL
                let staging = try resolveUnderRoot(
                    relative: "Enhancements/\(fileName)", root: mediaRoot)
                guard FileManager.default.fileExists(atPath: staging.path) else {
                    return .failure(code: "outputMissing")
                }
                let request = G09MediaAssetImportRequest(
                    token: context.sessionToken, opID: opID,
                    projectID: context.projectID,
                    expectedRevision: loaded.project.revision,
                    storage: context.storage, origin: context.origin,
                    sessionToken: context.sessionToken,
                    fileName: fileName, mimeType: "video/mp4",
                    byteCount: byteCount, sha256: sha256)
                let receipt = try await cluster.media.importAsset(
                    request, staging: staging)
                return .success(
                    assetID: receipt.asset.id, revision: receipt.revision)
            } catch let error as G09CreativeError {
                if error == .revisionConflict, attempt == 0 { continue }
                return .failure(code: error.code)
            } catch {
                return .failure(code: "importFailed")
            }
        }
        return .failure(code: "revisionConflict")
    }

    // MARK: - Private: super-resolution engine

    private func startSuperResolution(
        service: G09CreativeDomainService, epoch: UInt64, cluster: G09R2BoundCluster,
        context: G09R2ProjectContextDTO,
        env: G09R2GenerationEnvironment,
        execution: ExecutionContext,
        jobID: String, inputURL: URL, mediaRoot: URL,
        request: G09R2EnhancementRequestDTO,
        sourceFacts: G09R2MediaProbeFacts,
        journal: G09R2EnhancementJournal
    ) async throws {
        guard case .superResolution(let scaleFactor) = request.operation else {
            throw G09R2EnhancementRefusal.unsupportedCombination("not superResolution")
        }
        let configurationStore = G09R2EnhancerBackendConfigurationStore(
            database: env.database)
        guard let configuration = try await configurationStore.load(),
              configuration.legacyProviderProfileID == nil else {
            throw G09R2EnhancementRefusal.backendUnavailable(
                "super-resolution backend is not configured")
        }
        guard let apiKey = await configurationStore.credential(for: configuration) else {
            throw G09R2EnhancementRefusal.backendUnavailable(
                "the configured backend has no usable credential")
        }
        var record = try await journal.read(jobID: jobID)
            ?? G09R2EnhancementRecord(
                jobID: jobID, projectID: context.projectID, state: .running,
                request: request, sourceFacts: sourceFacts,
                createdAt: Date(), updatedAt: Date())
        record.state = .running
        record.updatedAt = Date()
        try await journal.write(record: record)

        try startWorker(epoch: epoch, jobKey: jobID) { [weak self] token in
            guard let self else { return }
            await self.runSuperResolution(
                token: token, epoch: epoch, jobID: jobID, cluster: cluster,
                configuration: configuration, apiKey: apiKey,
                inputURL: inputURL, mediaRoot: mediaRoot,
                outputFileName: request.outputFileName,
                scaleFactor: scaleFactor, request: request,
                sourceFacts: sourceFacts, context: context, execution: execution,
                journal: journal, resumeHandle: nil)
        }
    }

    /// Relaunch recovery: a cloud job with a retained handle but no live
    /// worker resumes through the exact handle (poll + download + verify +
    /// commit). Never resubmits.
    private func kickSuperResolutionResume(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO,
        cluster: G09R2BoundCluster,
        record: G09R2EnhancementRecord,
        remoteID: String,
        mediaRoot: URL
    ) async throws {
        guard !hasActiveWorker(jobKey: record.jobID),
              let env = try? await requireEnvironment(cluster, epoch: epoch),
              let configuration = try? await G09R2EnhancerBackendConfigurationStore(
                  database: env.database).load(),
              configuration.legacyProviderProfileID == nil,
              let apiKey = await G09R2EnhancerBackendConfigurationStore(
                  database: env.database).credential(for: configuration),
              case .superResolution(let scaleFactor) = record.request.operation,
              let inputURL = try? resolveUnderRoot(
                  relative: record.request.inputRelativePath, root: mediaRoot),
              let execution = try? await resolveExecutionContext(
                  service: service, env: env, projectID: context.projectID)
        else { return }
        // Prefer the retained validated handle; legacy records carry only the
        // request ID and derive the canonical owner/alias URLs exactly per
        // the official fal-js parser (never the full submission subpath).
        let handle: G09R2SuperResolutionAcceptedHandle
        if let retained = record.remoteHandle {
            handle = retained
        } else {
            handle = G09R2FalSuperResolutionBackend.canonicalHandle(
                queueBase: G09R2EnhancerBackendConfigurationStore.queueBaseURL,
                endpointID: configuration.endpointID,
                requestID: remoteID)
        }
        let journal = G09R2EnhancementJournal(root: mediaRoot)
        try startWorker(epoch: epoch, jobKey: record.jobID) { [weak self] token in
            guard let self else { return }
            await self.runSuperResolution(
                token: token, epoch: epoch, jobID: record.jobID, cluster: cluster,
                configuration: configuration, apiKey: apiKey,
                inputURL: inputURL, mediaRoot: mediaRoot,
                outputFileName: record.request.outputFileName,
                scaleFactor: scaleFactor, request: record.request,
                sourceFacts: record.sourceFacts, context: context,
                execution: execution,
                journal: journal, resumeHandle: handle)
        }
    }

    private func hasActiveWorker(jobKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return workers.values.contains { $0.jobKey == jobKey }
    }

    private func runSuperResolution(
        token: String, epoch: UInt64, jobID: String,
        cluster: G09R2BoundCluster,
        configuration: G09R2EnhancerBackendConfiguration,
        apiKey: String,
        inputURL: URL, mediaRoot: URL,
        outputFileName: String,
        scaleFactor: Int,
        request: G09R2EnhancementRequestDTO,
        sourceFacts: G09R2MediaProbeFacts,
        context: G09R2ProjectContextDTO,
        execution: ExecutionContext,
        journal: G09R2EnhancementJournal,
        resumeHandle: G09R2SuperResolutionAcceptedHandle?
    ) async {
        var record = (try? await journal.read(jobID: jobID))
            ?? G09R2EnhancementRecord(
                jobID: jobID, projectID: UUID(), state: .running,
                request: request, sourceFacts: sourceFacts,
                createdAt: Date(), updatedAt: Date())
        do {
            try throwIfCancelled(token: token)
            let staged = mediaRoot.appendingPathComponent(
                "Enhancements/.\(jobID).\(scaleFactor)x.part")
            try FileManager.default.createDirectory(
                at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staged) }

            record.lastProgress = G09R2EnhancementProgress(
                phase: .processing, completedUnits: 0, totalUnits: 3)
            try? await journal.write(record: record)

            let queueBase = G09R2EnhancerBackendConfigurationStore.queueBaseURL
            let handle: G09R2SuperResolutionAcceptedHandle
            if let resumeHandle {
                // Relaunch recovery through the retained handle.
                handle = try await platform.backend.resume(
                    baseURL: queueBase,
                    apiKey: apiKey,
                    handle: resumeHandle,
                    destination: staged,
                    progress: { fraction in
                        guard !self.isWorkerCancelled(token: token) else { return }
                        try? await journal.update(jobID: jobID) { snapshot in
                        guard !snapshot.state.isTerminal else { return }
                        snapshot.lastProgress = G09R2EnhancementProgress(
                            phase: .processing,
                            completedUnits: Int((fraction * 3).rounded()),
                            totalUnits: 3)
                        snapshot.updatedAt = Date()
                        }
                    },
                    isCancelled: { self.isWorkerCancelled(token: token) })
            } else {
                handle = try await platform.backend.enhance(
                    baseURL: queueBase,
                    apiKey: apiKey,
                    input: inputURL,
                    scaleFactor: scaleFactor,
                    targetFPS: sourceFacts.frameRate,
                    bitDepth: request.bitDepth,
                    destination: staged,
                    onAccepted: { accepted in
                        // Crash-durable ownership: the accepted handle lands
                        // in the per-job journal BEFORE the first poll await.
                        try await journal.update(jobID: jobID) { snapshot in
                        snapshot.remoteRequestID = accepted.requestID
                        snapshot.remoteHandle = accepted
                        snapshot.updatedAt = Date()
                        }
                    },
                    progress: { fraction in
                        guard !self.isWorkerCancelled(token: token) else { return }
                        try? await journal.update(jobID: jobID) { snapshot in
                        guard !snapshot.state.isTerminal else { return }
                        snapshot.lastProgress = G09R2EnhancementProgress(
                            phase: .processing,
                            completedUnits: Int((fraction * 3).rounded()),
                            totalUnits: 3)
                        snapshot.updatedAt = Date()
                        }
                    },
                    isCancelled: { self.isWorkerCancelled(token: token) })
            }
            record.remoteRequestID = handle.requestID
            record.remoteHandle = handle
            try? await journal.write(record: record)

            try throwIfCancelled(token: token)
            let stagedDigest = try await platform.digestFile(staged)
            // The SR surface is video-only (explicit supported-type boundary),
            // so the enhanced output is always a video here; measured facts
            // come from the guest ffprobe readback of the downloaded file —
            // a returned success string is never accepted as evidence.
            let measured = try await probeDownloadedVideo(
                staged, stagedDigest: stagedDigest, execution: execution)
            try G09R2EnhancementGuards.verifyOutput(
                measured: measured, source: sourceFacts, request: request)

            record.state = .validating
            try? await journal.write(record: record)
            let destination = try resolveUnderRoot(
                relative: "Enhancements/\(outputFileName)", root: mediaRoot)
            let committed = try await commitVerified(
                from: staged, to: destination, overwrite: request.overwrite,
                isCancelled: { self.isWorkerCancelled(token: token) })
            let committedDigest = try await platform.digestFile(destination)
            record.receipt = G09R2EnhancementReceipt(
                outputRelativePath: "Enhancements/\(outputFileName)",
                engine: configuration.displayName ?? configuration.endpointID,
                method: "superResolution",
                inputKind: sourceFacts.isImage ? "image" : "video",
                sourceWidth: sourceFacts.width,
                sourceHeight: sourceFacts.height,
                sourceFPS: sourceFacts.frameRate,
                sourceDurationSeconds: sourceFacts.durationSeconds,
                sourceFrameCount: sourceFacts.frameCount,
                outputWidth: measured.width,
                outputHeight: measured.height,
                outputFPS: measured.frameRate,
                outputDurationSeconds: measured.durationSeconds,
                outputFrameCount: measured.frameCount,
                outputBytes: committed.byteCount,
                outputSHA256: committed.sha256,
                remoteJobID: handle.requestID,
                warnings: [])
            record.state = .completed
            record.errorCode = nil
            record.errorDetail = nil
            record.updatedAt = Date()
            try await journal.write(record: record)
            // The verified output re-enters the original importAsset /
            // revision-CAS ownership so it is previewable/saveable through
            // the existing media pipeline (the committed file under
            // Enhancements/ stays untouched as the durable receipt artifact).
            await importVerifiedOutput(
                cluster: cluster, jobID: jobID, context: context,
                journal: journal,
                fileName: outputFileName, byteCount: committedDigest.byteCount,
                sha256: committedDigest.sha256)
        } catch is CancellationError {
            record = (try? await journal.read(jobID: jobID)) ?? record
            record.state = .cancelled
            record.errorCode = "cancelled"
            record.errorDetail = "Cancelled by the user; the source file is unchanged."
            record.updatedAt = Date()
            try? await journal.write(record: record)
        } catch {
            record = (try? await journal.read(jobID: jobID)) ?? record
            if let accepted = (error as? G09R2SuperResolutionBackendUnknownError)?.acceptedHandle {
                record.remoteRequestID = accepted.requestID
                record.remoteHandle = accepted
            }
            let refusal = error as? G09R2EnhancementRefusal
            let unknown = error is G09R2SuperResolutionBackendUnknownError
            record.state = unknown ? .outcomeUnknown : .failed
            record.errorCode = unknown
                ? "outcomeUnknown"
                : (refusal?.code ?? "superResolutionFailed")
            record.errorDetail = bounded(
                refusal?.detail
                    ?? (unknown
                        ? "The backend outcome could not be confirmed; the remote job ID is retained and the job was not replayed."
                        : "Super-resolution failed: \(error.localizedDescription)"))
            record.updatedAt = Date()
            try? await journal.write(record: record)
        }
    }

    // MARK: - Private: workers

    private func startWorker(
        epoch: UInt64, jobKey: String,
        body: @escaping @Sendable (String) async -> Void
    ) throws {
        let token = UUID().uuidString.lowercased()
        lock.lock()
        guard stoppingEpoch != epoch,
              workers.count < Self.maximumLiveWorkers,
              !workers.values.contains(where: { $0.jobKey == jobKey }) else {
            lock.unlock()
            throw G09R2EnhancementRefusal.backendUnavailable("enhancementWorkersBusy")
        }
        workers[token] = Worker(
            token: token, epoch: epoch, jobKey: jobKey,
            cancelRequested: false, task: nil)
        lock.unlock()
        let task = Task.detached { [weak self] in
            await body(token)
            self?.finishWorker(token)
        }
        lock.lock()
        if var worker = workers[token] {
            worker.task = task
            if worker.cancelRequested { task.cancel() }
            workers[token] = worker
        }
        lock.unlock()
    }

    private func finishWorker(_ token: String) {
        lock.lock()
        workers.removeValue(forKey: token)
        lock.unlock()
    }

    private func isWorkerCancelled(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return workers[token]?.cancelRequested ?? true
    }

    private func requestWorkerCancel(jobKey: String) {
        lock.lock()
        var tasks: [Task<Void, Never>] = []
        for token in Array(workers.keys) {
            guard var worker = workers[token], worker.jobKey == jobKey else { continue }
            worker.cancelRequested = true
            if let task = worker.task { tasks.append(task) }
            workers[token] = worker
        }
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    private func throwIfCancelled(token: String) throws {
        if isWorkerCancelled(token: token) { throw CancellationError() }
    }

    // MARK: - Private: helpers

    private func interpolationLiveState(
        record: G09R2EnhancementRecord, job: BackgroundJob,
        mediaRoot: URL
    ) async throws -> (G09R2EnhancementJobState, G09R2EnhancementProgress?, String?) {
        switch job.state {
        case .queued:
            return (.queued, record.lastProgress, nil)
        case .running:
            return (.running, record.lastProgress, nil)
        case .completed:
            // The monitor settles the journal; until then report validating.
            return (record.state == .completed ? .completed : .validating,
                    record.lastProgress, record.errorCode)
        case .cancelled:
            return (.cancelled, record.lastProgress, record.errorCode ?? "cancelled")
        case .failed:
            return (record.state == .completed ? .completed : .failed,
                    record.lastProgress,
                    record.errorCode ?? bounded(job.lastError ?? "failed"))
        case .interrupted:
            return (.outcomeUnknown, record.lastProgress,
                    record.errorCode ?? "outcomeUnknown")
        }
    }

    /// Staged write -> fsync -> digest -> atomic replace; returns the
    /// committed identity. Mirrors the workbench export commit discipline.
    private func commitVerified(
        from staged: URL, to destination: URL, overwrite: Bool,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> (byteCount: Int64, sha256: String) {
        let digest = try await platform.digestFile(staged)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The guest workspace can live on a different filesystem. Copy into
        // the destination directory before its atomic publish, preserving any old file.
        let prepared = directory.appendingPathComponent(".enhance-commit-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: prepared) }
        try FileManager.default.copyItem(at: staged, to: prepared)
        let copied = try await platform.digestFile(prepared)
        guard copied.byteCount == digest.byteCount, copied.sha256 == digest.sha256 else {
            throw G09CreativeError.writeFailed
        }
        let fd = open(prepared.path, O_RDONLY)
        guard fd >= 0 else { throw G09CreativeError.writeFailed }
        let flushed = fsync(fd)
        _ = close(fd)
        guard flushed == 0 else { throw G09CreativeError.writeFailed }
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        // link refuses an existing destination atomically when overwrite is off.
        let result = overwrite
            ? rename(prepared.path, destination.path)
            : link(prepared.path, destination.path)
        guard result == 0 else {
            if !overwrite && errno == EEXIST { throw G09R2EnhancementRefusal.outputExists }
            throw G09CreativeError.writeFailed
        }
        let directoryFD = open(directory.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = close(directoryFD) }
        return digest
    }

    private func shellPayload(script: String) throws -> Data {
        let arguments: [String: Any] = [
            "command": script,
            "cwd": ".",
            "timeout": 600,
            "maxOutputBytes": 262_144,
        ]
        return try JSONSerialization.data(withJSONObject: arguments)
    }

    private func resolveUnderRoot(relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.contains("\0"),
              !relative.hasPrefix("/"), !relative.contains("..") else {
            throw G09CreativeError.invalidPayload("invalidRelativePath")
        }
        return try WorkspacePathGuard(rootURL: root).resolve(relative)
    }

    private func bounded(_ text: String) -> String {
        text.unicodeScalars.count > 300
            ? String(String(text.prefix(300))) + "…"
            : text
    }

    private func requireCluster(
        _ service: G09CreativeDomainService, epoch: UInt64
    ) async throws -> G09R2BoundCluster {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch else {
            throw G09CreativeError.staleGeneration
        }
        return cluster
    }

    private func requireNoRootStop(
        _ service: G09CreativeDomainService, epoch: UInt64
    ) async throws {
        guard stoppingEpoch != epoch,
              !(await service.r2IsRootStopping(epoch: epoch)) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
    }

    private func requireEnvironment(
        _ cluster: G09R2BoundCluster, epoch: UInt64
    ) async throws -> G09R2GenerationEnvironment {
        guard let env = await environmentProvider(epoch),
              env.root.path == cluster.root.path else {
            throw G09CreativeError.staleGeneration
        }
        return env
    }

    private func requireContext(_ context: G09R2ProjectContextDTO) throws {
        guard G09CreativeWire.validSessionToken(context.sessionToken) else {
            throw G09CreativeError.invalidPayload("invalidSessionToken")
        }
        _ = try context.storage.validatedWorkspaceID()
    }

    private func loadProject(
        _ cluster: G09R2BoundCluster, context: G09R2ProjectContextDTO
    ) async throws -> G09MediaProjectHost.Loaded {
        do {
            return try await cluster.media.load(
                id: context.projectID, requested: context.storage,
                origin: context.origin)
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.map(error)
        }
    }

    static let retryableCodes: Set<String> = [
        "backendUnavailable", "linuxUnavailable", "outcomeUnknown",
        "taskBindingRequired", "sourceTooLarge", "outputTooLarge",
        "durationTooLong", "frameBoundExceeded", "targetFPSInvalid",
        "scaleInvalid", "sourceUnreadable", "unsupportedCombination",
        "outputExists",
    ]
}

// MARK: - Unknown backend outcome

// (G09R2SuperResolutionBackendUnknownError is defined alongside the backend
// transport in G09R2SuperResolutionBackend.swift.)

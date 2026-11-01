// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — generation submit/status/deliver and candidate adoption.
import Foundation
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWorkbench

extension G09R2GenerationService {
    // MARK: - Image submit

    public func submitImage(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2ImageSubmitRequest
    ) async throws -> G09R2ImageRequestHandleDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireContext(wire.context)
        try await requireMediaSession(service, context: wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard G09CreativeWire.safeOperationID(wire.request.idempotencyKey),
              wire.request.idempotencyKey.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidIdempotencyKey")
        }
        let prompt = wire.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf8.count <= 8_000 else {
            throw G09CreativeError.invalidPayload("invalidPrompt")
        }
        guard (1...4).contains(wire.request.count) else {
            throw G09CreativeError.invalidPayload("invalidImageCount")
        }
        guard wire.request.referenceAssetIDs.count <= 8 else {
            throw G09CreativeError.invalidPayload("tooManyReferences")
        }

        let env = try await requireEnvironment(cluster, epoch: epoch)
        let loaded = try await requireProject(
            cluster, context: wire.context,
            expectedRevision: wire.expectedRevision)
        let (route, provider, model) = try await resolveRoute(
            env: env, kind: .image, routeID: wire.request.modelRouteID,
            operation: (wire.request.sourceAssetID != nil
                || !wire.request.referenceAssetIDs.isEmpty) ? .edit : .generate)
        guard let adapter = platform.imageAdapter(provider) else {
            throw G09R2Error(.modelUnavailable, detail: "adapterUnavailable")
        }
        let operation: RemoteImageOperation =
            (wire.request.sourceAssetID != nil
                || !wire.request.referenceAssetIDs.isEmpty) ? .edit : .generate
        guard adapter.supports(operation, for: provider) else {
            throw G09R2Error(.modelUnavailable, detail: "operationUnsupported")
        }

        let sourceCount = (wire.request.sourceAssetID == nil ? 0 : 1)
            + wire.request.referenceAssetIDs.count
        _ = try await readOwnedImages(
            cluster: cluster, loaded: loaded,
            sourceID: wire.request.sourceAssetID,
            referenceIDs: wire.request.referenceAssetIDs,
            maximum: Int64(G09R2CreativeLimits.imageSourceBytes),
            maximumCount: route.referenceImagePolicy.maxImages)
        let selection = ImageGenerationSelection(
            nativeSizeOverride: wire.request.size)
        do {
            try ImageGenerationPresetResolver.validateSelection(
                selection, provider: provider, model: model,
                operation: operation, count: wire.request.count,
                referenceCount: sourceCount)
        } catch {
            // Rejected user options are a payload error, never a route claim.
            throw G09CreativeError.invalidPayload("invalidImageOptions")
        }
        let maximumOutput = max(1, adapter.maximumOutputImages(
            modelRemoteID: model.remoteModelID))
        guard wire.request.count <= maximumOutput else {
            throw G09R2Error(.modelUnavailable, detail: "imageCountUnsupported")
        }
        // Resolve the credential BEFORE persisting a job: a missing key is a
        // definite local precondition failure and must not create a job that
        // looks like a submitted provider call.
        _ = try await requireCredentials(provider)

        let payload = G09R2GenerationJobPayload(
            kind: .image, context: wire.context, epoch: epoch, route: route,
            request: wire.request)
            .withOperation(wire.opID, expectedRevision: wire.expectedRevision)
        let key = payload.namespacedIdempotencyKey
        let store = jobStore(env)
        if let existing = try await store.ownedJob(idempotencyKey: key) {
            _ = try verifyReplay(existing, payload: payload)
            return imageHandle(existing, idempotent: true)
        }
        guard beginInflight(key) else {
            if let existing = try await store.ownedJob(idempotencyKey: key) {
                _ = try verifyReplay(existing, payload: payload)
                return imageHandle(existing, idempotent: true)
            }
            throw G09R2Error(.generationUnavailable, detail: "submitInFlight")
        }
        defer { endInflight(key) }
        guard let encoded = try? G09CreativeWire.encoder().encode(payload) else {
            throw G09CreativeError.writeFailed
        }
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: provider.secretRef,
            canvasID: nil, documentID: nil,
            sourceNodeIDs: [wire.request.sourceAssetID].compactMap { $0 }
                + wire.request.referenceAssetIDs,
            resultNodeID: UUID(), requestJSON: encoded,
            state: .preparing)
        let creation = try await store.createJob(
            job, owner: .document(wire.context.projectID),
            originRunID: nil, idempotencyKey: key)
        if creation.deduplicated {
            _ = try verifyReplay(creation.owned, payload: payload)
            return imageHandle(creation.owned, idempotent: true)
        }
        guard startWorker(
            epoch: epoch, jobID: job.id.uuidString.lowercased(), kind: .image,
            body: { [weak self] token in
                guard let self else { return }
                await self.runImageJob(
                    token: token, service: service, epoch: epoch,
                    jobID: job.id, context: wire.context, payload: payload)
            }) else {
            _ = try? await store.transition(id: job.id, to: .failed) {
                $0.lastError = "generationQueueFull"
                $0.nextPollAt = nil
            }
            throw G09R2Error(.rendererUnavailable, detail: "generationQueueFull")
        }
        return G09R2ImageRequestHandleDTO(
            requestID: job.id.uuidString.lowercased(),
            projectID: wire.context.projectID,
            acceptedAt: creation.job.createdAt,
            state: .submitted,
            idempotent: false)
    }

    private func imageHandle(
        _ owned: OwnedMediaGenerationJob, idempotent: Bool
    ) -> G09R2ImageRequestHandleDTO {
        G09R2ImageRequestHandleDTO(
            requestID: owned.job.id.uuidString.lowercased(),
            projectID: owned.owner.id,
            acceptedAt: owned.job.createdAt,
            state: imageState(owned.job),
            idempotent: idempotent)
    }

    // MARK: - Image status / dismiss

    public func imageStatus(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2ImageStatusRequest
    ) async throws -> G09R2ImageRequestStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(wire.context)
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = jobStore(env)
        guard let jobID = UUID(uuidString: wire.requestID),
              let owned = try await store.ownedJob(id: jobID) else {
            throw G09R2Error(.jobNotFound)
        }
        let payload = try verifyReplay(
            owned,
            payload: try replayPayload(owned, context: wire.context,
                                       expectedKind: .image))
        _ = payload
        let candidateStore = candidateStore(root: env.artifactRoot)
        let dismissed = (try await candidateStore.dismissal(
            projectID: wire.context.projectID, requestID: wire.requestID)) != nil
        if !dismissed, !owned.job.state.isTerminal {
            await withLocalWork(
                epoch: epoch, kind: .image, id: wire.requestID
            ) { [weak self] in
                guard let self else { return }
                await self.finalizeImageIfPossible(
                    env: env, cluster: cluster, owned: owned,
                    payload: payload, store: store,
                    candidateStore: candidateStore)
            }
        }
        if !dismissed, owned.job.state == .preparing,
           !hasActiveWorker(jobID: wire.requestID),
           Date().timeIntervalSince(owned.job.createdAt) > Self.stalePreparingSeconds,
           (try await candidateStore.candidateForRequest(
                projectID: wire.context.projectID,
                requestID: wire.requestID)) == nil {
            _ = try? await store.transition(id: jobID, to: .expired) {
                $0.lastError = "outcomeUnknown"
                $0.nextPollAt = nil
            }
        }
        let refreshed = try await store.ownedJob(id: jobID) ?? owned
        var candidate = try await candidateStore.candidateForRequest(
            projectID: wire.context.projectID, requestID: wire.requestID)
        if candidate == nil, refreshed.job.state == .ready {
            candidate = try await rebuildImageCandidate(
                env: env, owned: refreshed, payload: payload,
                candidateStore: candidateStore)
        }
        return imageStatusDTO(
            refreshed.job, projectID: wire.context.projectID,
            candidate: candidate, dismissed: dismissed)
    }

    public func dismissImage(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2ImageDismissRequest
    ) async throws -> G09R2ImageDismissReceiptDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = jobStore(env)
        guard let jobID = UUID(uuidString: wire.requestID),
              let owned = try await store.ownedJob(id: jobID) else {
            throw G09R2Error(.jobNotFound)
        }
        _ = try verifyReplay(
            owned,
            payload: try replayPayload(owned, context: wire.context,
                                       expectedKind: .image))
        let candidateStore = candidateStore(root: env.artifactRoot)
        let receipt = G09R2CandidateReceipt(
            opID: wire.opID, kind: "dismiss",
            subjectID: wire.requestID,
            payloadHash: FloeDigest.sha256Hex(Data(
                "dismiss|\(wire.context.projectID.uuidString.lowercased())|\(wire.requestID)".utf8)))
        try await candidateStore.recordDismissal(
            receipt, projectID: wire.context.projectID,
            requestID: wire.requestID)
        if !owned.job.state.isTerminal {
            _ = try? await store.transition(id: jobID, to: .cancelled) {
                $0.lastError = "dismissed"
                $0.nextPollAt = nil
            }
        }
        let refreshed = try await store.ownedJob(id: jobID) ?? owned
        return G09R2ImageDismissReceiptDTO(
            requestID: wire.requestID,
            projectID: wire.context.projectID,
            state: .dismissed,
            opID: wire.opID,
            idempotent: refreshed.job.state == .cancelled || owned.job.state.isTerminal)
    }

    // MARK: - Video submit

    public func submitVideo(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2VideoSubmitRequest
    ) async throws -> G09R2VideoJobHandleDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireContext(wire.context)
        try await requireMediaSession(service, context: wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        guard G09CreativeWire.safeOperationID(wire.request.idempotencyKey),
              wire.request.idempotencyKey.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidIdempotencyKey")
        }
        let prompt = wire.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf8.count <= 8_000 else {
            throw G09CreativeError.invalidPayload("invalidPrompt")
        }
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let loaded = try await requireProject(
            cluster, context: wire.context,
            expectedRevision: wire.expectedRevision)
        let (route, provider, model) = try await resolveRoute(
            env: env, kind: .video, routeID: wire.request.modelRouteID)
        guard platform.videoAdapter(provider) != nil else {
            throw G09R2Error(.modelUnavailable, detail: "adapterUnavailable")
        }
        let providers = try await env.configuration.providers()
        let models = try await env.configuration.models()
        let preferences = try? await env.configuration.preferences()
        let videoRoutes = VideoModelRegistry.routes(
            models: models, providers: providers,
            preferredModelID: preferences?.defaultVideoModelID)
        guard let videoRoute = videoRoutes.first(where: { $0.modelID == model.id }) else {
            throw G09R2Error(.modelUnavailable, detail: "routeRemoved")
        }
        var options = VideoGenerationOptions(
            aspectRatio: wire.request.aspectRatio,
            resolution: wire.request.resolution,
            durationSeconds: wire.request.durationSeconds.map { Int($0.rounded()) })
        if let duration = wire.request.durationSeconds,
           abs(Double(Int(duration.rounded())) - duration) > 0.001 {
            throw G09CreativeError.invalidPayload("nonIntegralDuration")
        }
        do {
            options = try VideoRequestValidator.validate(options, route: videoRoute)
        } catch {
            throw G09CreativeError.invalidPayload("invalidVideoOptions")
        }
        let referenceIDs = wire.request.referenceAssetIDs
            + [wire.request.sourceAssetID].compactMap { $0 }
        guard referenceIDs.count <= route.parameters.maxReferenceImages,
              referenceIDs.count <= VideoReferenceImagePolicy.maximumAssets else {
            throw G09CreativeError.invalidPayload("referenceCountUnsupported")
        }
        _ = try await readOwnedImages(
            cluster: cluster, loaded: loaded, sourceID: nil,
            referenceIDs: referenceIDs,
            maximum: Int64(VideoReferenceImagePolicy.maximumBytes),
            maximumCount: route.parameters.maxReferenceImages,
            videoPolicy: true)
        _ = try await requireCredentials(provider)

        let payload = G09R2GenerationJobPayload(
            kind: .video, context: wire.context, epoch: epoch, route: route,
            request: wire.request)
            .withOperation(wire.opID, expectedRevision: wire.expectedRevision)
        let key = payload.namespacedIdempotencyKey
        let store = jobStore(env)
        if let existing = try await store.ownedJob(idempotencyKey: key) {
            _ = try verifyReplay(existing, payload: payload)
            return videoHandle(existing, idempotent: true)
        }
        guard beginInflight(key) else {
            if let existing = try await store.ownedJob(idempotencyKey: key) {
                _ = try verifyReplay(existing, payload: payload)
                return videoHandle(existing, idempotent: true)
            }
            throw G09R2Error(.generationUnavailable, detail: "submitInFlight")
        }
        defer { endInflight(key) }
        guard let encoded = try? G09CreativeWire.encoder().encode(payload) else {
            throw G09CreativeError.writeFailed
        }
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .video,
            credentialReference: provider.secretRef,
            canvasID: nil, documentID: nil,
            sourceNodeIDs: referenceIDs, resultNodeID: UUID(),
            requestJSON: encoded, state: .preparing)
        let creation = try await store.createJob(
            job, owner: .document(wire.context.projectID),
            originRunID: nil, idempotencyKey: key)
        if creation.deduplicated {
            _ = try verifyReplay(creation.owned, payload: payload)
            return videoHandle(creation.owned, idempotent: true)
        }
        let validatedOptions = options
        guard startWorker(
            epoch: epoch, jobID: job.id.uuidString.lowercased(), kind: .video,
            body: { [weak self] token in
                guard let self else { return }
                await self.runVideoSubmit(
                    token: token, service: service, epoch: epoch,
                    jobID: job.id, context: wire.context, payload: payload,
                    options: validatedOptions, videoRoute: videoRoute)
            }) else {
            _ = try? await store.transition(id: job.id, to: .failed) {
                $0.lastError = "generationQueueFull"
                $0.nextPollAt = nil
            }
            throw G09R2Error(.rendererUnavailable, detail: "generationQueueFull")
        }
        return G09R2VideoJobHandleDTO(
            jobID: job.id.uuidString.lowercased(),
            projectID: wire.context.projectID,
            acceptedAt: creation.job.createdAt,
            state: .submitted,
            idempotent: false)
    }

    internal func videoHandle(
        _ owned: OwnedMediaGenerationJob, idempotent: Bool
    ) -> G09R2VideoJobHandleDTO {
        G09R2VideoJobHandleDTO(
            jobID: owned.job.id.uuidString.lowercased(),
            projectID: owned.owner.id,
            acceptedAt: owned.job.createdAt,
            state: mediaJobState(owned.job),
            idempotent: idempotent)
    }

    // MARK: - Jobs / status / cancel / deliver

    public func jobs(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, limit: Int
    ) async throws -> [G09R2JobStatusDTO] {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(context)
        try await requireMediaSession(service, context: context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        _ = try await requireProject(cluster, context: context)
        let store = jobStore(env)
        await startDueVideoPolls(
            service: service, epoch: epoch, context: context, env: env,
            store: store)
        let bounded = max(1, min(limit, G09R2CreativeLimits.jobListMax))
        let owned = try await store.jobs(
            owner: .document(context.projectID))
        let candidateStore = candidateStore(root: env.artifactRoot)
        var result: [G09R2JobStatusDTO] = []
        for job in owned where job.mediaKind == .video {
            let candidate = try await candidateStore.candidateForJob(
                projectID: context.projectID,
                jobID: job.id.uuidString.lowercased())
            result.append(jobStatus(
                OwnedMediaGenerationJob(
                    job: job, owner: .document(context.projectID),
                    canvasID: nil, documentID: context.projectID),
                candidate: candidate))
            if result.count >= bounded { break }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Uses the EXISTING durable `dueOwnedJobs` backoff query. Polls are
    /// started (not awaited) so the bridge stays responsive; each worker is
    /// bounded and root-drained. No second scheduler/queue exists.
    internal func startDueVideoPolls(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO,
        env: G09R2GenerationEnvironment,
        store: MediaGenerationJobStore
    ) async {
        guard !isRootStopping(epoch: epoch) else { return }
        let due = (try? await store.dueOwnedJobs(at: Date(), limit: 8)) ?? []
        for owned in due {
            guard owned.owner == .document(context.projectID),
                  owned.job.mediaKind == .video,
                  owned.job.state != .preparing,
                  let taskID = owned.job.providerTaskID, !taskID.isEmpty else {
                continue
            }
            let jobID = owned.job.id.uuidString.lowercased()
            guard G09R2ForegroundCoordinator.shared.hasLease(
                    jobID: jobID, epoch: epoch) else { continue }
            guard !hasActiveWorker(jobID: jobID),
                  let payload = try? decodePayload(owned.job) else { continue }
            _ = startWorker(
                epoch: epoch, jobID: jobID, kind: .video,
                body: { [weak self] token in
                    guard let self else { return }
                    await self.runVideoPoll(
                        token: token, service: service, epoch: epoch,
                        jobID: owned.job.id, payload: payload)
                })
        }
    }

    public func refreshJob(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO, jobID: String
    ) async throws -> G09R2JobStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(context)
        try await requireMediaSession(service, context: context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        _ = try await requireProject(cluster, context: context)
        let store = jobStore(env)
        guard let uuid = UUID(uuidString: jobID),
              let owned = try await store.ownedJob(id: uuid) else {
            throw G09R2Error(.jobNotFound)
        }
        let payload = try verifyReplay(
            owned, payload: try replayPayload(
                owned, context: context, expectedKind: .video))
        let candidateStore = candidateStore(root: env.artifactRoot)
        if !owned.job.state.isTerminal {
            await withLocalWork(
                epoch: epoch, kind: .video, id: jobID
            ) { [weak self] in
                guard let self else { return }
                await self.finalizeVideoIfPossible(
                    env: env, cluster: cluster, owned: owned,
                    payload: payload, store: store,
                    candidateStore: candidateStore, epoch: epoch)
            }
        }
        let current = try await store.ownedJob(id: uuid) ?? owned
        if current.job.state == .preparing,
           !hasActiveWorker(jobID: jobID),
           Date().timeIntervalSince(current.job.createdAt) > Self.stalePreparingSeconds,
           (await videoStagingManifest(
                env: env, jobID: jobID, candidateStore: candidateStore)) == nil {
            _ = try? await store.transition(id: uuid, to: .expired) {
                $0.lastError = "outcomeUnknown"
                $0.nextPollAt = nil
            }
        }
        let shouldPoll = (current.job.state == .submitted
            || current.job.state == .running
            || current.job.state == .downloading)
            && current.job.providerTaskID != nil
            && !hasActiveWorker(jobID: jobID)
        if shouldPoll {
            if startWorker(
                epoch: epoch, jobID: jobID, kind: .video,
                body: { [weak self] token in
                    guard let self else { return }
                    await self.runVideoPoll(
                        token: token, service: service, epoch: epoch,
                        jobID: uuid, payload: payload)
                }) {
                await waitForWorker(jobID: jobID,
                                    seconds: Self.refreshWaitSeconds)
            }
        }
        let refreshed = try await store.ownedJob(id: uuid) ?? current
        let candidate = try await candidateStore.candidateForJob(
            projectID: context.projectID, jobID: jobID)
        return jobStatus(refreshed, candidate: candidate)
    }

    public func cancelJob(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2JobCancelRequest
    ) async throws -> G09R2JobStatusDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = jobStore(env)
        guard let uuid = UUID(uuidString: wire.jobID),
              let owned = try await store.ownedJob(id: uuid) else {
            throw G09R2Error(.jobNotFound)
        }
        let payload = try verifyReplay(
            owned, payload: try replayPayload(
                owned, context: wire.context, expectedKind: .video))
        if owned.job.state.isTerminal {
            let candidateStyle = try await candidateStore(root: env.artifactRoot)
                .candidateForJob(projectID: wire.context.projectID,
                                 jobID: wire.jobID)
            return jobStatus(owned, candidate: candidateStyle)
        }
        guard let taskID = owned.job.providerTaskID else {
            throw G09R2Error(.renderUnsupported, detail: "providerCancelUnsupported")
        }
        let providers = try await env.configuration.providers()
        let models = try await env.configuration.models()
        let preferences = try? await env.configuration.preferences()
        let catalog = G09R2GenerationCatalog.build(
            models: models, providers: providers, preferences: preferences,
            imageAdapter: { self.platform.imageAdapter($0) },
            videoAdapter: { self.platform.videoAdapter($0) })
        guard let route = catalog.video.first(where: {
            $0.routeID == payload.routeID
        }), let provider = providers.first(where: {
            $0.id.uuidString.lowercased() == route.providerID
        }), let adapter = platform.videoAdapter(provider) else {
            throw G09R2Error(.modelUnavailable, detail: "routeRemoved")
        }
        let credentials = try await requireCredentials(provider)
        do {
            try await adapter.cancel(
                taskID: taskID, provider: provider, credentials: credentials)
        } catch {
            // Backend cancellation is not universally supported. The job is
            // NOT marked cancelled and remains truthful (possibly running).
            throw G09R2Error(.renderUnsupported,
                             detail: "providerCancelUnsupported")
        }
        _ = try? await store.transition(id: uuid, to: .cancelled) {
            $0.lastError = nil
            $0.nextPollAt = nil
            $0.lastPolledAt = Date()
        }
        let refreshed = try await store.ownedJob(id: uuid) ?? owned
        let candidate = try await candidateStore(root: env.artifactRoot)
            .candidateForJob(projectID: wire.context.projectID,
                             jobID: wire.jobID)
        return jobStatus(refreshed, candidate: candidate)
    }

    public func deliverResult(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2JobDeliverRequest
    ) async throws -> G09R2DeliveredCandidateDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let store = jobStore(env)
        guard let uuid = UUID(uuidString: wire.jobID),
              let owned = try await store.ownedJob(id: uuid) else {
            throw G09R2Error(.jobNotFound)
        }
        let payload = try verifyReplay(
            owned, payload: try replayPayload(
                owned, context: wire.context, expectedKind: .video))
        let candidateStore = candidateStore(root: env.artifactRoot)
        let receipt = G09R2CandidateReceipt(
            opID: wire.opID, kind: "deliver", subjectID: wire.jobID,
            payloadHash: FloeDigest.sha256Hex(Data(
                "deliver|\(wire.context.projectID.uuidString.lowercased())|\(wire.jobID)".utf8)))
        if let existing = try await candidateStore.receipt(
            projectID: wire.context.projectID, opID: wire.opID) {
            guard existing == receipt else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
        }
        switch owned.job.state {
        case .completed, .downloading:
            await withLocalWork(
                epoch: epoch, kind: .video, id: wire.jobID
            ) { [weak self] in
                guard let self else { return }
                await self.finalizeVideoIfPossible(
                    env: env, cluster: cluster, owned: owned,
                    payload: payload, store: store,
                    candidateStore: candidateStore, epoch: epoch)
            }
        case .ready:
            break
        case .failed, .cancelled:
            return G09R2DeliveredCandidateDTO(
                outcome: .notReady, candidate: nil,
                reason: boundedErrorCode(owned.job.lastError) ?? "jobTerminal")
        case .expired:
            return G09R2DeliveredCandidateDTO(
                outcome: owned.job.lastError == "outcomeUnknown"
                    ? .outcomeUnknown : .notReady,
                candidate: nil,
                reason: boundedErrorCode(owned.job.lastError))
        default:
            return G09R2DeliveredCandidateDTO(
                outcome: .notReady, candidate: nil, reason: "jobActive")
        }
        let refreshed = try await store.ownedJob(id: uuid) ?? owned
        guard refreshed.job.state == .ready,
              let localAssetID = refreshed.job.localAssetID,
              let asset = try await assetStore(env).asset(id: localAssetID),
              let relative = asset.localRelativePath,
              let fileURL = candidateStore.containedURL(relativePath: relative),
              G09R2CandidateStore.verifyCandidateFile(
                fileURL, byteCount: asset.byteCount,
                sha256: asset.contentHash) else {
            return G09R2DeliveredCandidateDTO(
                outcome: .notReady, candidate: nil,
                reason: "resultAssetMissing")
        }
        var candidate = try await candidateStore.candidateForJob(
            projectID: wire.context.projectID, jobID: wire.jobID)
        if candidate == nil {
            let facts = G09R2MediaProbe.videoFacts(fileURL: fileURL)
            let record = G09R2CandidateRecord(
                candidateID: wire.jobID,
                projectID: wire.context.projectID,
                kind: .video,
                modelDisplayName: payload.remoteModelID,
                createdAt: refreshed.job.updatedAt,
                byteCount: asset.byteCount,
                sha256: asset.contentHash,
                relativePath: relative,
                assetID: asset.id,
                mimeType: asset.mimeType ?? "video/mp4",
                metadata: facts?.metadata,
                requestID: nil,
                jobID: wire.jobID,
                state: .pending)
            try await candidateStore.upsert(record)
            candidate = record
        }
        if let candidate, candidate.state == .rejected || candidate.state == .stale {
            return G09R2DeliveredCandidateDTO(
                outcome: .notReady, candidate: nil,
                reason: "candidateRejected")
        }
        if let candidate {
            try await candidateStore.recordReceipt(
                receipt, projectID: wire.context.projectID)
            try await candidateStore.recordDelivery(
                projectID: wire.context.projectID, jobID: wire.jobID,
                candidateID: candidate.candidateID)
            return G09R2DeliveredCandidateDTO(
                outcome: .ready, candidate: candidate.dto, reason: nil)
        }
        return G09R2DeliveredCandidateDTO(
            outcome: .notReady, candidate: nil, reason: "resultAssetMissing")
    }

    // MARK: - Candidates

    public func candidates(
        service: G09CreativeDomainService, epoch: UInt64,
        context: G09R2ProjectContextDTO
    ) async throws -> [G09R2CandidateDTO] {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(context)
        try await requireMediaSession(service, context: context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        _ = try await requireProject(cluster, context: context)
        return try await candidateStore(root: env.artifactRoot)
            .candidates(projectID: context.projectID)
    }

    public func acceptCandidate(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2CandidateAcceptRequest
    ) async throws -> G09MediaProjectReceiptDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try await requireNoRootStop(service, epoch: epoch)
        try requireContext(wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        let loaded = try await requireProject(
            cluster, context: wire.context,
            expectedRevision: wire.expectedRevision)
        let candidateStore = candidateStore(root: env.artifactRoot)
        guard let candidate = try await candidateStore.record(
            projectID: wire.context.projectID,
            candidateID: wire.candidateID) else {
            throw G09R2Error(.candidateNotFound)
        }
        // The receipt identity is the stable operation, not the caller's
        // current CAS expectation: replaying the same accept after its own
        // commit advanced the revision must return the same receipt.
        let receiptHash = FloeDigest.sha256Hex(Data(
            "accept|\(wire.context.projectID.uuidString.lowercased())|\(wire.candidateID)".utf8))
        let adoptOpID = "g09r2-adopt-\(wire.opID)"
        if let receipt = try await candidateStore.receipt(
            projectID: wire.context.projectID, opID: wire.opID) {
            guard receipt.kind == "accept",
                  receipt.payloadHash == receiptHash,
                  receipt.subjectID == wire.candidateID else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            if let witness = try await mediaReceipt(cluster, opID: adoptOpID) {
                let adoptedID = G09SourceCreateIdentity.assetID(
                    domain: "generation", opID: wire.candidateID)
                let adopted = loaded.project.assets.first(where: {
                    $0.id == adoptedID
                })
                try await candidateStore.setState(
                    projectID: wire.context.projectID,
                    candidateID: wire.candidateID, state: .accepted,
                    acceptOpID: wire.opID,
                    acceptRevision: witness.revision,
                    acceptedAssetID: adoptedID,
                    acceptedRelativePath: adopted?.relativePath
                        ?? candidate.relativePath)
                return G09MediaProjectReceiptDTO(
                    projectID: witness.projectID, revision: witness.revision,
                    canUndo: witness.canUndo, canRedo: witness.canRedo,
                    opID: wire.opID, idempotent: true)
            }
        }
        if candidate.state == .rejected || candidate.state == .stale {
            throw G09R2Error(.candidateStale)
        }
        if candidate.state == .accepted {
            if let witness = try await mediaReceipt(cluster, opID: adoptOpID) {
                return G09MediaProjectReceiptDTO(
                    projectID: witness.projectID, revision: witness.revision,
                    canUndo: witness.canUndo, canRedo: witness.canRedo,
                    opID: wire.opID, idempotent: true)
            }
            throw G09R2Error(.candidateStale)
        }
        guard candidate.acceptOpID == nil || candidate.acceptOpID == wire.opID else {
            throw G09R2Error(.candidateStale)
        }
        let adoptKey = "adopt:\(wire.context.projectID.uuidString.lowercased()):\(wire.candidateID)"
        guard beginInflight(adoptKey) else {
            throw G09R2Error(.candidateStale, detail: "adoptInFlight")
        }
        defer { endInflight(adoptKey) }
        guard let workToken = beginLocalWork(
            epoch: epoch, kind: candidate.kind, id: wire.candidateID) else {
            throw G09R2Error(.renderCancelled, detail: "rootStopping")
        }
        defer { finishWorker(workToken) }
        // A commit that landed before a crash is discovered from the durable
        // media receipt instead of copying the asset twice.
        if let witness = try await mediaReceipt(cluster, opID: adoptOpID) {
            let adoptedID = G09SourceCreateIdentity.assetID(
                domain: "generation", opID: wire.candidateID)
            let adopted = loaded.project.assets.first(where: {
                $0.id == adoptedID
            })
            try await candidateStore.setState(
                projectID: wire.context.projectID,
                candidateID: wire.candidateID, state: .accepted,
                acceptOpID: wire.opID, acceptRevision: witness.revision,
                acceptedAssetID: adoptedID,
                acceptedRelativePath: adopted?.relativePath
                    ?? candidate.relativePath)
            try await candidateStore.recordReceipt(
                G09R2CandidateReceipt(
                    opID: wire.opID, kind: "accept",
                    subjectID: wire.candidateID, payloadHash: receiptHash,
                    revision: witness.revision),
                projectID: wire.context.projectID)
            return G09MediaProjectReceiptDTO(
                projectID: witness.projectID, revision: witness.revision,
                canUndo: witness.canUndo, canRedo: witness.canRedo,
                opID: wire.opID, idempotent: true)
        }

        let assetID = G09SourceCreateIdentity.assetID(
            domain: "generation", opID: wire.candidateID)
        let displayName = candidate.mimeType.hasPrefix("image/")
            ? "Generated Image.\(G09R2MediaProbe.imageExtension(mimeType: candidate.mimeType))"
            : "Generated Video.\(G09R2MediaProbe.videoExtension(mimeType: candidate.mimeType))"
        guard let source = candidateStore.containedURL(
                relativePath: candidate.relativePath),
              G09R2CandidateStore.verifyCandidateFile(
                source, byteCount: candidate.byteCount,
                sha256: candidate.sha256) else {
            throw G09R2Error(.candidateStale, detail: "candidateBytesMissing")
        }
        var factsMetadata = candidate.metadata
        switch candidate.kind {
        case .image:
            guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]),
                  data.count <= Int(G09R2MediaProbe.maximumGeneratedImageBytes),
                  let facts = G09R2MediaProbe.imageFacts(data),
                  facts.mimeType == candidate.mimeType else {
                throw G09R2Error(.candidateStale, detail: "candidateFormatChanged")
            }
            factsMetadata = MediaAssetMetadata(
                width: facts.width, height: facts.height,
                hasAlpha: facts.hasAlpha)
        case .video:
            guard let facts = G09R2MediaProbe.videoFacts(fileURL: source),
                  facts.mimeType == candidate.mimeType else {
                throw G09R2Error(.candidateStale, detail: "candidateFormatChanged")
            }
            factsMetadata = facts.metadata
        }
        guard let target = G09R2CandidateStore.projectMediaTarget(
            rootURL: loaded.storage.rootURL, assetID: assetID,
            displayName: displayName) else {
            throw G09CreativeError.storageUnavailable
        }
        var createdTarget = false
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                guard G09R2CandidateStore.verifyCandidateFile(
                    target, byteCount: candidate.byteCount,
                    sha256: candidate.sha256) else {
                    throw G09CreativeError.assetDigestMismatch
                }
            } else {
                if isWorkerCancelled(workToken) {
                    throw G09R2Error(.renderCancelled, detail: "rootStopping")
                }
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".adopt-\(UUID().uuidString).tmp")
                try FileManager.default.copyItem(at: source, to: temporary)
                try G09R2CandidateStore.flushFile(temporary)
                try FileManager.default.moveItem(at: temporary, to: target)
                try G09R2CandidateStore.flushDirectory(
                    target.deletingLastPathComponent())
                createdTarget = true
            }
            if isWorkerCancelled(workToken) {
                throw G09R2Error(.renderCancelled, detail: "rootStopping")
            }
            guard let relative = Self.projectRelativePath(
                target: target, root: loaded.storage.rootURL) else {
                throw G09CreativeError.storageUnavailable
            }
            var commands: [MediaEditCommand] = []
            let reference = MediaAssetReference(
                id: assetID, kind: candidate.kind == .image ? .image : .video,
                relativePath: relative, originalName: displayName,
                byteCount: candidate.byteCount,
                contentHash: candidate.sha256, metadata: factsMetadata)
            commands.append(.addAsset(reference))
            switch candidate.kind {
            case .image:
                let layer = ImageLayer(
                    id: G09SourceCreateIdentity.childID(
                        domain: "generation", opID: wire.candidateID,
                        tag: "layer"),
                    kind: .image, name: displayName, assetID: assetID)
                commands.append(.addImageLayer(layer))
            case .video:
                guard let duration = factsMetadata?.durationSeconds,
                      duration.isFinite, duration > 0 else {
                    throw G09R2Error(.unsupportedSourceFormat,
                                     detail: "videoDurationUnavailable")
                }
                let clip = VideoClip(
                    id: G09SourceCreateIdentity.childID(
                        domain: "generation", opID: wire.candidateID,
                        tag: "clip"),
                    assetID: assetID, trimStart: 0, trimEnd: duration)
                commands.append(.appendClip(clip))
            }
            if isWorkerCancelled(workToken) || isRootStopping(epoch: epoch) {
                throw G09R2Error(.renderCancelled, detail: "rootStopping")
            }
            let committed = try await cluster.media.applyShared(
                projectID: wire.context.projectID,
                expectedRevision: wire.expectedRevision,
                sessionToken: wire.context.sessionToken,
                storage: wire.context.storage, origin: wire.context.origin,
                opID: adoptOpID, commands: commands)
            try await candidateStore.setState(
                projectID: wire.context.projectID,
                candidateID: wire.candidateID, state: .accepted,
                acceptOpID: wire.opID,
                acceptRevision: committed.project.revision,
                acceptedAssetID: assetID, acceptedRelativePath: relative)
            try await candidateStore.recordReceipt(
                G09R2CandidateReceipt(
                    opID: wire.opID, kind: "accept",
                    subjectID: wire.candidateID, payloadHash: receiptHash,
                    revision: committed.project.revision),
                projectID: wire.context.projectID)
            await releaseCandidateReservation(
                env: env, candidateID: wire.candidateID,
                assetID: candidate.assetID)
            return G09MediaProjectReceiptDTO(
                projectID: committed.project.id,
                revision: committed.project.revision,
                canUndo: MediaTransactions.canUndo(committed.project),
                canRedo: MediaTransactions.canRedo(committed.project),
                opID: wire.opID, idempotent: false)
        } catch let typed as G09R2Error {
            if createdTarget {
                try? FileManager.default.removeItem(at: target)
            }
            throw typed
        } catch {
            if createdTarget {
                try? FileManager.default.removeItem(at: target)
            }
            throw G09CreativeError.map(error)
        }
    }

    public func rejectCandidate(
        service: G09CreativeDomainService, epoch: UInt64,
        request wire: G09R2CandidateRejectRequest
    ) async throws -> G09R2CandidateMutationReceiptDTO {
        let cluster = try await requireCluster(service, epoch: epoch)
        try requireContext(wire.context)
        guard G09CreativeWire.safeOperationID(wire.opID),
              wire.opID.utf8.count <= 100 else {
            throw G09CreativeError.invalidPayload("invalidOperationID")
        }
        try await requireMediaSession(service, context: wire.context)
        let env = try await requireEnvironment(cluster, epoch: epoch)
        _ = try await requireProject(cluster, context: wire.context)
        let candidateStore = candidateStore(root: env.artifactRoot)
        guard let candidate = try await candidateStore.record(
            projectID: wire.context.projectID,
            candidateID: wire.candidateID) else {
            throw G09R2Error(.candidateNotFound)
        }
        let receiptHash = FloeDigest.sha256Hex(Data(
            "reject|\(wire.context.projectID.uuidString.lowercased())|\(wire.candidateID)".utf8))
        if let receipt = try await candidateStore.receipt(
            projectID: wire.context.projectID, opID: wire.opID) {
            guard receipt.kind == "reject",
                  receipt.payloadHash == receiptHash,
                  receipt.subjectID == wire.candidateID else {
                throw G09CreativeError.invalidPayload("intentMismatch")
            }
            return G09R2CandidateMutationReceiptDTO(
                candidateID: wire.candidateID,
                projectID: wire.context.projectID,
                state: .rejected, opID: wire.opID, idempotent: true)
        }
        switch candidate.state {
        case .accepted:
            throw G09R2Error(.candidateStale, detail: "candidateAlreadyAccepted")
        case .rejected:
            if let existing = try await candidateStore.receipt(
                projectID: wire.context.projectID, opID: wire.opID) {
                return G09R2CandidateMutationReceiptDTO(
                    candidateID: wire.candidateID,
                    projectID: wire.context.projectID,
                    state: .rejected, opID: wire.opID, idempotent: true)
            }
            throw G09R2Error(.candidateStale)
        case .stale:
            throw G09R2Error(.candidateStale)
        case .pending:
            break
        }
        let rejectKey = "reject:\(wire.context.projectID.uuidString.lowercased()):\(wire.candidateID)"
        guard beginInflight(rejectKey) else {
            throw G09R2Error(.candidateStale, detail: "rejectInFlight")
        }
        defer { endInflight(rejectKey) }
        try await candidateStore.setState(
            projectID: wire.context.projectID,
            candidateID: wire.candidateID, state: .rejected,
            rejectOpID: wire.opID)
        try await candidateStore.recordReceipt(
            G09R2CandidateReceipt(
                opID: wire.opID, kind: "reject",
                subjectID: wire.candidateID, payloadHash: receiptHash),
            projectID: wire.context.projectID)
        await releaseCandidateReservation(
            env: env, candidateID: wire.candidateID,
            assetID: candidate.assetID)
        return G09R2CandidateMutationReceiptDTO(
            candidateID: wire.candidateID,
            projectID: wire.context.projectID,
            state: .rejected, opID: wire.opID, idempotent: false)
    }

    // MARK: - Shared request helpers

    internal func replayPayload(
        _ owned: OwnedMediaGenerationJob,
        context: G09R2ProjectContextDTO, expectedKind: G09R2GenerationKind
    ) throws -> G09R2GenerationJobPayload {
        guard owned.owner == .document(context.projectID) else {
            throw G09CreativeError.crossOwnerRefused
        }
        let payload = try decodePayload(owned.job)
        guard payload.kind == expectedKind,
              payload.projectID == context.projectID else {
            throw G09CreativeError.invalidPayload("intentMismatch")
        }
        guard payload.writeLayer == Self.writeLayer(context.storage),
              payload.originKind == context.origin?.kind.rawValue,
              payload.originOwnerID == context.origin?.ownerID else {
            throw G09CreativeError.invalidPayload("contextMismatch")
        }
        return payload
    }

    internal static func writeLayer(_ storage: G09StorageLayerDTO) -> String {
        switch storage.kind {
        case .appOwned: "appOwned"
        case .workspace: "workspace:\(storage.workspaceID?.uuidString.lowercased() ?? "")"
        }
    }

    internal func requireCredentials(_ provider: ProviderProfile) async throws
        -> ProviderCredentials {
        do {
            return try await platform.credentials(provider)
        } catch {
            throw G09R2Error(.generationUnavailable,
                             detail: "credentialUnavailable")
        }
    }

    internal struct OwnedImage {
        var assetID: UUID
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
    }

    internal func readOwnedImages(
        cluster: G09R2BoundCluster, loaded: G09MediaProjectHost.Loaded,
        sourceID: UUID?, referenceIDs: [UUID],
        maximum: Int64, maximumCount: Int,
        videoPolicy: Bool = false
    ) async throws -> [OwnedImage] {
        var ids: [UUID] = []
        if let sourceID { ids.append(sourceID) }
        ids.append(contentsOf: referenceIDs)
        guard ids.count <= maximumCount, ids.count <= 8 else {
            throw G09CreativeError.invalidPayload("referenceCountUnsupported")
        }
        let root = loaded.storage.rootURL.standardizedFileURL
        var result: [OwnedImage] = []
        for id in ids {
            guard let asset = loaded.project.assets.first(where: { $0.id == id }),
                  asset.kind == .image,
                  G09CreativeAssetHost.safeRelativePath(asset.relativePath) else {
                throw G09CreativeError.assetReferenceInvalid
            }
            let target = root.appendingPathComponent(asset.relativePath)
                .standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw G09CreativeError.assetReferenceInvalid
            }
            guard let size = try? target.resourceValues(
                forKeys: [.fileSizeKey]).fileSize,
                size > 0, Int64(size) <= maximum else {
                throw G09CreativeError.assetTooLarge
            }
            guard let data = try? Data(contentsOf: target) else {
                throw G09CreativeError.assetMissing
            }
            if let declared = asset.contentHash,
               G09CreativeAssetHost.validDigest(declared) {
                let actual = FloeDigest.sha256Hex(data)
                guard actual.caseInsensitiveCompare(declared) == .orderedSame else {
                    throw G09CreativeError.assetDigestMismatch
                }
            }
            if videoPolicy {
                guard let mime = VideoReferenceImagePolicy.detectedMIMEType(data),
                      VideoReferenceImagePolicy.acceptedMIMETypes.contains(mime) else {
                    throw G09R2Error(.unsupportedSourceFormat,
                                     detail: "referenceFormatUnsupported")
                }
                result.append(OwnedImage(
                    assetID: id, data: data, mimeType: mime,
                    width: 0, height: 0))
            } else {
                guard let facts = G09R2MediaProbe.imageFacts(data) else {
                    throw G09R2Error(.unsupportedSourceFormat,
                                     detail: "sourceFormatUnsupported")
                }
                guard facts.mimeType == "image/png"
                        || facts.mimeType == "image/jpeg" else {
                    throw G09R2Error(.unsupportedSourceFormat,
                                     detail: "sourceFormatUnsupported")
                }
                result.append(OwnedImage(
                    assetID: id, data: data, mimeType: facts.mimeType,
                    width: facts.width, height: facts.height))
            }
        }
        return result
    }

    internal func mediaReceipt(
        _ cluster: G09R2BoundCluster, opID: String
    ) async throws -> G09MediaWriteReceipt? {
        do {
            return try await cluster.media.readReceipt(opID)
        } catch {
            return nil
        }
    }

    internal func releaseCandidateReservation(
        env: G09R2GenerationEnvironment, candidateID: String, assetID: UUID
    ) async {
        // One provisional reference belongs to the pending candidate. Release
        // exactly once; the store's durable op receipt makes a replay a no-op.
        try? await assetStore(env).applyReferenceOp(
            opID: "g09r2.candidate.release.\(candidateID)",
            assetID: assetID, delta: -1)
    }

    internal static func projectRelativePath(
        target: URL, root: URL
    ) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = target.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    internal func waitForWorker(jobID: String, seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !hasActiveWorker(jobID: jobID) { return }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

public struct G09R2ImageDismissReceiptDTO: Codable, Sendable, Equatable {
    public var requestID: String
    public var projectID: UUID
    public var state: G09R2ImageRequestState
    public var opID: String
    public var idempotent: Bool

    public init(requestID: String, projectID: UUID,
                state: G09R2ImageRequestState, opID: String,
                idempotent: Bool) {
        self.requestID = requestID
        self.projectID = projectID
        self.state = state
        self.opID = opID
        self.idempotent = idempotent
    }
}


public struct G09R2CandidateListDTO: Codable, Sendable, Equatable {
    public var candidates: [G09R2CandidateDTO]

    public init(candidates: [G09R2CandidateDTO]) {
        self.candidates = candidates
    }
}


/// The frozen action list has no separate `jobs` verb. The bounded list rides
/// the existing `generation.video.status` action when `jobID` is absent; the
/// same native owner and durable store answer both shapes (no local cache).
public struct G09R2JobQueryWire: Decodable, Sendable {
    public var context: G09R2ProjectContextDTO
    public var jobID: String?
    public var limit: Int?
}

public struct G09R2JobListDTO: Codable, Sendable, Equatable {
    public var jobs: [G09R2JobStatusDTO]

    public init(jobs: [G09R2JobStatusDTO]) {
        self.jobs = jobs
    }
}

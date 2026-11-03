// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — service-owned provider workers, bounded result download and
// durable candidate finalisation.
//
// Workers are registered before they start and removed only after they settle;
// Root stop cancels the exact tasks and waits for that settlement. A waiting
// provider job is durable in the job store and does not retain Root.
import Foundation
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWorkbench
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

internal struct G09R2ImageStagingEntry: Codable, Sendable, Equatable {
    var index: Int
    var fileName: String
    var mimeType: String
    var byteCount: Int64
    var sha256: String
    var width: Int
    var height: Int
    var hasAlpha: Bool?
}

internal struct G09R2ImageStagingManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var requestID: String
    var entries: [G09R2ImageStagingEntry]
}

internal struct G09R2VideoStagingManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var jobID: String
    var fileName: String
    var mimeType: String
    var byteCount: Int64
    var sha256: String
    var durationSeconds: Double
    var width: Int?
    var height: Int?
    var rotationDegrees: Double?
}

extension G09R2GenerationService {
    // MARK: - Image worker

    internal func runImageJob(
        token: String, service: G09CreativeDomainService, epoch: UInt64,
        jobID: UUID, context: G09R2ProjectContextDTO,
        payload: G09R2GenerationJobPayload
    ) async {
        let jobKey = jobID.uuidString.lowercased()
        var dispatched = false
        do {
            guard let cluster = await service.r2BoundCluster(),
                  cluster.epoch == epoch else {
                throw G09CreativeError.staleGeneration
            }
            try await requireNoRootStop(service, epoch: epoch)
            let env = try await requireEnvironment(cluster, epoch: epoch)
            let store = jobStore(env)
            let candidateStore = candidateStore(root: env.artifactRoot)
            if let dismissal = try await candidateStore.dismissal(
                projectID: context.projectID, requestID: jobKey) {
                _ = dismissal
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = "dismissed"
                    $0.nextPollAt = nil
                }
                try? removeStaging(
                    candidateStore.incomingDirectoryURL(ownerID: jobKey))
                return
            }
            if isWorkerCancelled(token) {
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = "rootStopping"
                    $0.nextPollAt = nil
                }
                return
            }
            let loaded = try await loadProject(cluster, context: context)
            let (route, provider, model) = try await resolveRoute(
                env: env, kind: .image, routeID: payload.routeID,
                operation: (payload.sourceAssetID != nil
                    || !payload.referenceAssetIDs.isEmpty) ? .edit : .generate)
            guard let adapter = platform.imageAdapter(provider) else {
                throw G09R2Error(.modelUnavailable, detail: "adapterUnavailable")
            }
            let operation: RemoteImageOperation =
                (payload.sourceAssetID != nil
                    || !payload.referenceAssetIDs.isEmpty) ? .edit : .generate
            guard adapter.supports(operation, for: provider) else {
                throw G09R2Error(.modelUnavailable, detail: "operationUnsupported")
            }
            let sources = try await readOwnedImages(
                cluster: cluster, loaded: loaded,
                sourceID: payload.sourceAssetID,
                referenceIDs: payload.referenceAssetIDs,
                maximum: Int64(G09R2CreativeLimits.imageSourceBytes),
                maximumCount: route.referenceImagePolicy.maxImages)
            guard sources.count == (payload.sourceAssetID == nil ? 0 : 1)
                    + payload.referenceAssetIDs.count else {
                throw G09CreativeError.assetReferenceInvalid
            }
            let selection = ImageGenerationSelection(
                nativeSizeOverride: payload.size)
            try ImageGenerationPresetResolver.validateSelection(
                selection, provider: provider, model: model,
                operation: operation, count: payload.count,
                referenceCount: sources.count)
            let credentials = try await requireCredentials(provider)
            if isWorkerCancelled(token) {
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = "rootStopping"
                    $0.nextPollAt = nil
                }
                return
            }
            // Two-phase foreground admission: the App host confirms a REAL
            // dataSync owner for this exact durable job + generation BEFORE
            // the paid provider request. StartDenied/timeout is a definite
            // local failure with NO provider dispatch.
            let admission = await G09R2ForegroundCoordinator.shared.awaitAdmission(
                jobID: jobKey, epoch: epoch,
                projectID: context.projectID, kind: .image)
            guard case .confirmed = admission else {
                if case .cancelled = admission {
                    await markImageUnknown(
                        service: service, epoch: epoch, jobID: jobID,
                        code: "interrupted")
                } else {
                    await markImageFailed(
                        service: service, epoch: epoch, jobID: jobID,
                        code: "foregroundUnavailable")
                }
                return
            }
            if isWorkerCancelled(token) {
                await markImageUnknown(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "interrupted")
                return
            }
            dispatched = true
            let request = RemoteImageRequest(
                operation: operation, prompt: payload.prompt,
                sourceImages: sources.map(\.data),
                selection: selection, count: payload.count,
                modelRemoteID: model.remoteModelID)
            let result = try await adapter.perform(
                request, provider: provider, credentials: credentials)
            if isWorkerCancelled(token) {
                throw CancellationError()
            }
            guard result.images.count == payload.count else {
                throw G09R2Error(.providerRejected,
                                 detail: "imageCountMismatch")
            }
            G09R2ForegroundCoordinator.shared.noteProgress(
                jobID: jobKey, epoch: epoch, fraction: 0.9)
            try await stageImages(
                result.images, payload: payload, jobID: jobID,
                model: model, candidateStore: candidateStore)
            _ = try? await store.transition(id: jobID, to: .completed) {
                $0.lastError = "candidateCommitPending"
                $0.nextPollAt = nil
            }
            let owned = try await store.ownedJob(id: jobID)
            if let owned {
                await finalizeImageIfPossible(
                    env: env, cluster: cluster, owned: owned,
                    payload: payload, store: store,
                    candidateStore: candidateStore)
            }
        } catch is CancellationError {
            await markImageUnknown(
                service: service, epoch: epoch, jobID: jobID,
                code: dispatched ? "outcomeUnknown" : "interrupted")
        } catch let remote as RemoteImageError {
            if case .providerRejected = remote {
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "providerRejected")
            } else if case .requestFailed = remote {
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "providerRejected")
            } else if case .unsupportedOperation = remote {
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "modelUnavailable")
            } else if case .invalidResponse = remote {
                await markImageUnknown(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "outcomeUnknown")
            } else {
                await markImageUnknown(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "outcomeUnknown")
            }
        } catch let typed as G09R2Error {
            switch typed.wire {
            case .modelUnavailable, .unsupportedSourceFormat,
                 .generationUnavailable:
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: typed.code)
            default:
                await markImageUnknown(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "outcomeUnknown")
            }
        } catch let typed as G09CreativeError {
            if typed.code == "staleGeneration" || typed.code == "renderCancelled" {
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: dispatched ? "outcomeUnknown" : typed.code)
            } else if typed.code == "assetTooLarge"
                        || typed.code == "assetDigestMismatch"
                        || typed.code == "assetReferenceInvalid"
                        || typed.code == "assetMissing" {
                await markImageFailed(
                    service: service, epoch: epoch, jobID: jobID,
                    code: typed.code)
            } else {
                await markImageUnknown(
                    service: service, epoch: epoch, jobID: jobID,
                    code: dispatched ? "outcomeUnknown" : typed.code)
            }
        } catch {
            await markImageUnknown(
                service: service, epoch: epoch, jobID: jobID,
                code: "outcomeUnknown")
        }
    }

    private func markImageFailed(
        service: G09CreativeDomainService, epoch: UInt64,
        jobID: UUID, code: String
    ) async {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch,
              let env = try? await requireEnvironment(cluster, epoch: epoch) else {
            return
        }
        let store = jobStore(env)
        _ = try? await store.transition(id: jobID, to: .failed) {
            $0.lastError = code
            $0.nextPollAt = nil
        }
        try? removeStaging(candidateStore(root: env.artifactRoot)
            .incomingDirectoryURL(ownerID: jobID.uuidString.lowercased()))
    }

    private func markImageUnknown(
        service: G09CreativeDomainService, epoch: UInt64,
        jobID: UUID, code: String
    ) async {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch,
              let env = try? await requireEnvironment(cluster, epoch: epoch) else {
            return
        }
        let store = jobStore(env)
        let current = try? await store.ownedJob(id: jobID)
        guard let current, !current.job.state.isTerminal else { return }
        // Unknown is terminal for automatic work: bytes may be recoverable
        // from staging, but no provider call is ever repeated automatically.
        _ = try? await store.transition(id: jobID, to: .expired) {
            $0.lastError = code
            $0.nextPollAt = nil
        }
    }

    // MARK: - Image staging / finalisation

    private func stageImages(
        _ images: [Data], payload: G09R2GenerationJobPayload,
        jobID: UUID, model: ModelProfile,
        candidateStore: G09R2CandidateStore
    ) async throws {
        let owner = jobID.uuidString.lowercased()
        guard let directory = candidateStore.incomingDirectoryURL(ownerID: owner) else {
            throw G09CreativeError.storageUnavailable
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var entries: [G09R2ImageStagingEntry] = []
        for (index, data) in images.enumerated() {
            guard Int64(data.count) <= G09R2MediaProbe.maximumGeneratedImageBytes,
                  let facts = G09R2MediaProbe.imageFacts(data) else {
                throw G09R2Error(.unsupportedSourceFormat,
                                 detail: "imageFormatUnsupported")
            }
            let fileName = "image-\(index).\(G09R2MediaProbe.imageExtension(mimeType: facts.mimeType))"
            let target = directory.appendingPathComponent(fileName)
            try data.write(to: target, options: [])
            try G09R2CandidateStore.flushFile(target)
            entries.append(G09R2ImageStagingEntry(
                index: index, fileName: fileName,
                mimeType: facts.mimeType,
                byteCount: Int64(data.count),
                sha256: FloeDigest.sha256Hex(data),
                width: facts.width, height: facts.height,
                hasAlpha: facts.hasAlpha))
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total <= G09R2MediaProbe.maximumGeneratedImageBatchBytes else {
            throw G09R2Error(.unsupportedSourceFormat,
                             detail: "imageBatchTooLarge")
        }
        let manifest = G09R2ImageStagingManifest(
            schemaVersion: 1, requestID: owner, entries: entries)
        let data = try G09CreativeWire.encoder().encode(manifest)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try data.write(to: manifestURL, options: [])
        try G09R2CandidateStore.flushFile(manifestURL)
        try G09R2CandidateStore.flushDirectory(directory)
        _ = payload
        _ = model
    }

    internal func imageStagingManifest(
        env: G09R2GenerationEnvironment, requestID: String,
        candidateStore: G09R2CandidateStore
    ) async -> G09R2ImageStagingManifest? {
        guard let directory = candidateStore.incomingDirectoryURL(
                ownerID: requestID) else { return nil }
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let manifest = try? G09CreativeWire.decoder().decode(
                G09R2ImageStagingManifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.requestID == requestID,
              !manifest.entries.isEmpty else {
            return nil
        }
        _ = env
        return manifest
    }

    internal func finalizeImageIfPossible(
        env: G09R2GenerationEnvironment, cluster: G09R2BoundCluster,
        owned: OwnedMediaGenerationJob, payload: G09R2GenerationJobPayload,
        store: MediaGenerationJobStore,
        candidateStore: G09R2CandidateStore
    ) async {
        let jobID = owned.job.id
        let owner = jobID.uuidString.lowercased()
        guard beginFinalize(owner) else { return }
        defer { endFinalize(owner) }
        guard owned.job.state == .preparing || owned.job.state == .completed
                || owned.job.state == .downloading,
              let manifest = await imageStagingManifest(
                env: env, requestID: owner, candidateStore: candidateStore) else {
            return
        }
        guard let directory = candidateStore.incomingDirectoryURL(ownerID: owner) else {
            return
        }
        // Root stop before the candidate commit publishes NOTHING; the staged
        // bytes stay recoverable for an explicit replay.
        guard !Task.isCancelled,
              !isRootStopping(epoch: payload.epoch),
              !G09R2MediaRenderHostMailbox.shared.isRootStopping(
                epoch: payload.epoch) else { return }
        do {
            guard manifest.entries.count == payload.count else {
                throw G09R2Error(.providerRejected, detail: "imageCountMismatch")
            }
            var candidates: [G09R2CandidateRecord] = []
            for entry in manifest.entries.sorted(by: { $0.index < $1.index }) {
                let staged = directory.appendingPathComponent(entry.fileName)
                let candidateID = G09SourceCreateIdentity.childID(
                    domain: "generation-image", opID: owner,
                    tag: "candidate-\(entry.index)").uuidString.lowercased()
                if let existing = try await candidateStore.record(
                    projectID: payload.projectID, candidateID: candidateID) {
                    candidates.append(existing)
                    continue
                }
                let display = "Generated Image \(entry.index + 1).\(G09R2MediaProbe.imageExtension(mimeType: entry.mimeType))"
                let relative: String
                if let expected = G09R2CandidateStore.generatedRelativePath(
                    sha256: entry.sha256, preferredName: display),
                   let finalURL = candidateStore.containedURL(
                    relativePath: expected),
                   G09R2CandidateStore.verifyCandidateFile(
                    finalURL, byteCount: entry.byteCount,
                    sha256: entry.sha256) {
                    relative = expected
                } else {
                    guard G09R2CandidateStore.verifyCandidateFile(
                        staged, byteCount: entry.byteCount,
                        sha256: entry.sha256) else {
                        throw G09R2Error(.candidateStale,
                                         detail: "stagedImageMissing")
                    }
                    relative = try await candidateStore.commitGeneratedFile(
                        from: staged, preferredName: display,
                        expectedSHA256: entry.sha256,
                        expectedBytes: entry.byteCount)
                }
                let asset = try await canonicalGeneratedAsset(
                    env: env, contentHash: entry.sha256, kind: .image,
                    displayName: display, mimeType: entry.mimeType,
                    relativePath: relative, byteCount: entry.byteCount,
                    candidateID: candidateID)
                let record = G09R2CandidateRecord(
                    candidateID: candidateID,
                    projectID: payload.projectID,
                    kind: .image,
                    modelDisplayName: payload.remoteModelID,
                    createdAt: owned.job.createdAt.addingTimeInterval(
                        Double(entry.index) * 0.001),
                    byteCount: entry.byteCount,
                    sha256: entry.sha256,
                    relativePath: asset.relativePath,
                    assetID: asset.record.id,
                    mimeType: entry.mimeType,
                    metadata: MediaAssetMetadata(
                        width: entry.width, height: entry.height,
                        hasAlpha: entry.hasAlpha),
                    requestID: owner, jobID: nil, state: .pending)
                try await candidateStore.upsert(record)
                candidates.append(record)
            }
            guard let first = candidates.first else {
                throw G09R2Error(.providerRejected, detail: "noImages")
            }
            _ = try? await store.transition(id: jobID, to: .ready) {
                $0.localAssetID = first.assetID
                $0.lastError = nil
                $0.nextPollAt = nil
                $0.resultURL = nil
                $0.updatedAt = Date()
            }
            try? removeStaging(directory)
            _ = cluster
        } catch let typed as G09R2Error {
            if owned.job.state == .preparing || owned.job.state == .completed {
                _ = try? await store.transition(id: jobID, to: .completed) {
                    $0.lastError = typed.code
                    $0.nextPollAt = nil
                }
            }
        } catch {
            _ = try? await store.transition(id: jobID, to: .completed) {
                $0.lastError = "candidateCommitPending"
                $0.nextPollAt = nil
            }
        }
    }

    internal func rebuildImageCandidate(
        env: G09R2GenerationEnvironment, owned: OwnedMediaGenerationJob,
        payload: G09R2GenerationJobPayload,
        candidateStore: G09R2CandidateStore
    ) async throws -> G09R2CandidateRecord? {
        guard let assetID = owned.job.localAssetID,
              let asset = try await assetStore(env).asset(id: assetID),
              let relative = asset.localRelativePath,
              let fileURL = candidateStore.containedURL(relativePath: relative),
              G09R2CandidateStore.verifyCandidateFile(
                fileURL, byteCount: asset.byteCount,
                sha256: asset.contentHash) else {
            return nil
        }
        let candidateID = G09SourceCreateIdentity.childID(
            domain: "generation-image",
            opID: owned.job.id.uuidString.lowercased(),
            tag: "candidate-0").uuidString.lowercased()
        if let existing = try await candidateStore.record(
            projectID: payload.projectID, candidateID: candidateID) {
            return existing
        }
        let facts = (try? Data(contentsOf: fileURL, options: [.mappedIfSafe]))
            .flatMap { G09R2MediaProbe.imageFacts($0) }
        let record = G09R2CandidateRecord(
            candidateID: candidateID, projectID: payload.projectID,
            kind: .image, modelDisplayName: payload.remoteModelID,
            createdAt: owned.job.updatedAt, byteCount: asset.byteCount,
            sha256: asset.contentHash, relativePath: relative,
            assetID: asset.id, mimeType: asset.mimeType ?? "image/png",
            metadata: facts.map {
                MediaAssetMetadata(width: $0.width, height: $0.height,
                                   hasAlpha: $0.hasAlpha)
            },
            requestID: owned.job.id.uuidString.lowercased(), jobID: nil,
            state: .pending)
        do {
            try await candidateStore.upsert(record)
            return record
        } catch {
            return nil
        }
    }

    // MARK: - Canonical generated asset

    internal struct CanonicalGenerated {
        var record: CreativeAssetRecord
        var relativePath: String
    }

    internal func canonicalGeneratedAsset(
        env: G09R2GenerationEnvironment, contentHash: String,
        kind: MediaKind, displayName: String, mimeType: String,
        relativePath: String, byteCount: Int64, candidateID: String
    ) async throws -> CanonicalGenerated {
        let assets = assetStore(env)
        let reservationOpID = "g09r2.candidate.reserve.\(candidateID)"
        if let existing = try await assets.asset(contentHash: contentHash) {
            let relative = existing.localRelativePath ?? relativePath
            guard let url = candidateStore(root: env.artifactRoot)
                    .containedURL(relativePath: relative),
                  G09R2CandidateStore.verifyCandidateFile(
                    url, byteCount: existing.byteCount > 0
                        ? existing.byteCount : byteCount,
                    sha256: contentHash) else {
                // The row outlives a missing local file. Repair at its own
                // path from the verified generated copy, never at a caller
                // supplied path.
                guard let source = candidateStore(root: env.artifactRoot)
                        .containedURL(relativePath: relativePath),
                      let target = candidateStore(root: env.artifactRoot)
                        .containedURL(relativePath: relative) else {
                    throw G09CreativeError.storageUnavailable
                }
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if source.standardizedFileURL != target.standardizedFileURL {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: source, to: target)
                }
                var updated = existing
                updated.localRelativePath = relative
                updated.mimeType = mimeType
                updated.byteCount = byteCount
                try await assets.save(updated)
                try await assets.applyReferenceOp(
                    opID: reservationOpID, assetID: updated.id, delta: 1)
                return CanonicalGenerated(record: updated, relativePath: relative)
            }
            try await assets.applyReferenceOp(
                opID: reservationOpID, assetID: existing.id, delta: 1)
            return CanonicalGenerated(record: existing, relativePath: relative)
        }
        let record = CreativeAssetRecord(
            id: G09SourceCreateIdentity.assetID(
                domain: "generation-asset", opID: contentHash),
            contentHash: contentHash, kind: kind,
            displayName: displayName, mimeType: mimeType,
            localRelativePath: relativePath, byteCount: byteCount,
            tags: ["generated"], referenceCount: 0)
        let canonical = try await assets.saveResolvingCanonical(record)
        if canonical.id != record.id,
           let canonicalPath = canonical.localRelativePath,
           canonicalPath != relativePath,
           let source = candidateStore(root: env.artifactRoot)
            .containedURL(relativePath: relativePath),
           let target = candidateStore(root: env.artifactRoot)
            .containedURL(relativePath: canonicalPath),
           !G09R2CandidateStore.verifyCandidateFile(
            target, byteCount: byteCount, sha256: contentHash) {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        let relative = canonical.localRelativePath ?? relativePath
        try await assets.applyReferenceOp(
            opID: reservationOpID, assetID: canonical.id, delta: 1)
        return CanonicalGenerated(record: canonical, relativePath: relative)
    }

    // MARK: - Video submit worker

    internal func runVideoSubmit(
        token: String, service: G09CreativeDomainService, epoch: UInt64,
        jobID: UUID, context: G09R2ProjectContextDTO,
        payload: G09R2GenerationJobPayload,
        options: VideoGenerationOptions, videoRoute: VideoModelRoute
    ) async {
        var dispatched = false
        do {
            guard let cluster = await service.r2BoundCluster(),
                  cluster.epoch == epoch else {
                throw G09CreativeError.staleGeneration
            }
            try await requireNoRootStop(service, epoch: epoch)
            let env = try await requireEnvironment(cluster, epoch: epoch)
            let store = jobStore(env)
            if isWorkerCancelled(token) {
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = "rootStopping"
                    $0.nextPollAt = nil
                }
                return
            }
            let loaded = try await loadProject(cluster, context: context)
            let (_, provider, model) = try await resolveRoute(
                env: env, kind: .video, routeID: payload.routeID)
            guard let adapter = platform.videoAdapter(provider) else {
                throw G09R2Error(.modelUnavailable, detail: "adapterUnavailable")
            }
            let references = try await readOwnedImages(
                cluster: cluster, loaded: loaded, sourceID: nil,
                referenceIDs: payload.referenceAssetIDs,
                maximum: Int64(VideoReferenceImagePolicy.maximumBytes),
                maximumCount: routeReferenceLimit(videoRoute),
                videoPolicy: true)
            var referenceURLs: [URL] = []
            for reference in references {
                referenceURLs.append(try VideoReferenceImagePolicy.inlineDataURL(
                    data: reference.data, declaredMIMEType: reference.mimeType))
            }
            let credentials = try await requireCredentials(provider)
            if isWorkerCancelled(token) {
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = "rootStopping"
                    $0.nextPollAt = nil
                }
                return
            }
            // Same two-phase gate as image: no paid video submit before the
            // App host confirms a REAL foreground owner for this exact job.
            let admission = await G09R2ForegroundCoordinator.shared.awaitAdmission(
                jobID: jobID.uuidString.lowercased(), epoch: epoch,
                projectID: context.projectID, kind: .video)
            guard case .confirmed = admission else {
                if case .cancelled = admission {
                    await finishVideoSubmitFailure(
                        service: service, epoch: epoch, jobID: jobID,
                        code: "interrupted", definite: true)
                } else {
                    await finishVideoSubmitFailure(
                        service: service, epoch: epoch, jobID: jobID,
                        code: "foregroundUnavailable", definite: true)
                }
                return
            }
            if isWorkerCancelled(token) {
                await finishVideoSubmitFailure(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "interrupted", definite: true)
                return
            }
            let request = RemoteVideoRequest(
                prompt: payload.prompt,
                modelRemoteID: model.remoteModelID,
                options: options,
                referenceAssetURLs: referenceURLs)
            dispatched = true
            let submission = try await adapter.submit(
                request, provider: provider, credentials: credentials)
            guard !submission.providerTaskID.isEmpty else {
                throw RemoteVideoError.invalidResponse("emptyTaskID")
            }
            if isWorkerCancelled(token) {
                // The provider accepted the request; the task ID is durable
                // and the job keeps running truthfully.
                _ = try? await store.transition(id: jobID, to: .submitted) {
                    $0.providerTaskID = submission.providerTaskID
                    $0.estimatedCompletionAt = submission.estimatedCompletionAt
                    $0.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
                    $0.resultURL = submission.resultURL
                    $0.resultURLExpiresAt = submission.resultURLExpiresAt
                    $0.nextPollAt = Date().addingTimeInterval(15)
                    $0.lastPolledAt = Date()
                }
                return
            }
            _ = try await store.transition(id: jobID, to: .submitted) {
                $0.providerTaskID = submission.providerTaskID
                $0.estimatedCompletionAt = submission.estimatedCompletionAt
                $0.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
                $0.resultURL = submission.resultURL
                $0.resultURLExpiresAt = submission.resultURLExpiresAt
                $0.nextPollAt = Date().addingTimeInterval(15)
                $0.lastPolledAt = Date()
                $0.lastError = nil
            }
        } catch is CancellationError {
            await finishVideoSubmitFailure(
                service: service, epoch: epoch, jobID: jobID,
                code: dispatched ? "outcomeUnknown" : "interrupted",
                definite: !dispatched)
        } catch let remote as RemoteVideoError {
            switch remote {
            case .unsupportedProvider:
                await finishVideoSubmitFailure(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "renderUnsupported", definite: true)
            case .invalidRequest:
                await finishVideoSubmitFailure(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "invalidPayload", definite: true)
            case .requestFailed:
                await finishVideoSubmitFailure(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "providerRejected", definite: true)
            case .invalidResponse:
                await finishVideoSubmitFailure(
                    service: service, epoch: epoch, jobID: jobID,
                    code: "outcomeUnknown", definite: false)
            }
        } catch let typed as G09R2Error {
            await finishVideoSubmitFailure(
                service: service, epoch: epoch, jobID: jobID,
                code: typed.code, definite: typed.wire != .providerTimeout)
        } catch let typed as G09CreativeError {
            await finishVideoSubmitFailure(
                service: service, epoch: epoch, jobID: jobID,
                code: typed.code, definite: !dispatched)
        } catch {
            await finishVideoSubmitFailure(
                service: service, epoch: epoch, jobID: jobID,
                code: "outcomeUnknown", definite: false)
        }
    }

    private func routeReferenceLimit(_ route: VideoModelRoute) -> Int {
        max(0, min(route.contract.maximumReferenceAssets,
                   VideoReferenceImagePolicy.maximumAssets))
    }

    private func finishVideoSubmitFailure(
        service: G09CreativeDomainService, epoch: UInt64, jobID: UUID,
        code: String, definite: Bool
    ) async {
        guard let cluster = await service.r2BoundCluster(),
              cluster.epoch == epoch,
              let env = try? await requireEnvironment(cluster, epoch: epoch) else {
            return
        }
        let store = jobStore(env)
        guard let current = try? await store.ownedJob(id: jobID),
              !current.job.state.isTerminal else { return }
        if definite {
            _ = try? await store.transition(id: jobID, to: .failed) {
                $0.lastError = code
                $0.nextPollAt = nil
            }
        } else {
            // The provider may have accepted the request. Keep the preparing
            // record with an explicit unknown marker; never resubmit.
            _ = try? await store.transition(id: jobID, to: .expired) {
                $0.lastError = "outcomeUnknown"
                $0.nextPollAt = nil
            }
        }
    }

    // MARK: - Video poll / download worker

    internal func runVideoPoll(
        token: String, service: G09CreativeDomainService, epoch: UInt64,
        jobID: UUID, payload: G09R2GenerationJobPayload
    ) async {
        do {
            guard let cluster = await service.r2BoundCluster(),
                  cluster.epoch == epoch else {
                throw G09CreativeError.staleGeneration
            }
            let env = try await requireEnvironment(cluster, epoch: epoch)
            let store = jobStore(env)
            let candidateStore = candidateStore(root: env.artifactRoot)
            guard let owned = try await store.ownedJob(id: jobID),
                  !owned.job.state.isTerminal else { return }
            if owned.job.state == .downloading
                || owned.job.state == .completed {
                await finalizeVideoIfPossible(
                    env: env, cluster: cluster, owned: owned,
                    payload: payload, store: store,
                    candidateStore: candidateStore, epoch: epoch)
                let current = try await store.ownedJob(id: jobID)
                if current?.job.state == .ready { return }
                if current?.job.state == .completed { return }
            }
            if isWorkerCancelled(token) { return }
            // Polling/downloading under the App dataSync owner is required;
            // without an exact native lease this worker leaves the durable
            // state untouched and performs NO network call.
            guard G09R2ForegroundCoordinator.shared.hasLease(
                jobID: jobID.uuidString.lowercased(), epoch: epoch) else {
                return
            }
            guard let taskID = owned.job.providerTaskID else { return }
            let (_, provider, model) = try await resolveRoute(
                env: env, kind: .video, routeID: payload.routeID)
            guard let adapter = platform.videoAdapter(provider) else {
                throw G09R2Error(.modelUnavailable, detail: "adapterUnavailable")
            }
            let credentials = try await requireCredentials(provider)
            let status = try await adapter.status(
                taskID: taskID, modelRemoteID: model.remoteModelID,
                provider: provider, credentials: credentials)
            if let progress = status.progress, progress.isFinite {
                G09R2ForegroundCoordinator.shared.noteProgress(
                    jobID: jobID.uuidString.lowercased(), epoch: epoch,
                    fraction: progress)
            }
            var resultURL = status.resultURL ?? owned.job.resultURL
            var resultExpiry = status.resultURLExpiresAt
                ?? owned.job.resultURLExpiresAt
            if let candidateURL = resultURL, let expiry = resultExpiry,
               expiry <= Date() {
                resultURL = nil
                resultExpiry = nil
            }
            switch status.state {
            case .failed:
                _ = try? await store.transition(id: jobID, to: .failed) {
                    $0.lastError = "providerRejected"
                    $0.nextPollAt = nil
                    $0.lastPolledAt = Date()
                }
            case .cancelled:
                _ = try? await store.transition(id: jobID, to: .cancelled) {
                    $0.lastError = nil
                    $0.nextPollAt = nil
                    $0.lastPolledAt = Date()
                }
            case .expired:
                _ = try? await store.transition(id: jobID, to: .expired) {
                    $0.lastError = "resultExpired"
                    $0.nextPollAt = nil
                    $0.lastPolledAt = Date()
                }
            case .completed, .ready:
                guard let candidateURL = resultURL else {
                    if owned.job.state == .downloading {
                        _ = try? await store.transition(id: jobID, to: .expired) {
                            $0.lastError = "resultExpired"
                            $0.nextPollAt = nil
                            $0.lastPolledAt = Date()
                        }
                    } else {
                        _ = try? await store.transition(id: jobID, to: .running) {
                            $0.lastError = "resultPending"
                            $0.nextPollAt = Self.pollDate(
                                retryCount: $0.retryCount)
                            $0.retryCount += 1
                            $0.lastPolledAt = Date()
                        }
                    }
                    return
                }
                let candidateExpiry = resultExpiry
                _ = try? await store.transition(id: jobID, to: .downloading) {
                    $0.resultURL = candidateURL
                    $0.resultURLExpiresAt = candidateExpiry
                    $0.lastError = nil
                    $0.nextPollAt = nil
                    $0.lastPolledAt = Date()
                }
                let refreshed = try await store.ownedJob(id: jobID) ?? owned
                await finalizeVideoIfPossible(
                    env: env, cluster: cluster, owned: refreshed,
                    payload: payload, store: store,
                    candidateStore: candidateStore, epoch: epoch)
            case .downloading:
                let downloadURL = resultURL
                let downloadExpiry = resultExpiry
                _ = try? await store.transition(id: jobID, to: .downloading) {
                    $0.resultURL = downloadURL
                    $0.resultURLExpiresAt = downloadExpiry
                    $0.lastError = nil
                    $0.nextPollAt = nil
                    $0.lastPolledAt = Date()
                }
                let refreshed = try await store.ownedJob(id: jobID) ?? owned
                await finalizeVideoIfPossible(
                    env: env, cluster: cluster, owned: refreshed,
                    payload: payload, store: store,
                    candidateStore: candidateStore, epoch: epoch)
            case .running, .submitted, .preparing:
                if isWorkerCancelled(token) { return }
                let pollingURL = resultURL
                let pollingExpiry = resultExpiry
                _ = try? await store.transition(id: jobID, to: .running) {
                    $0.resultURL = pollingURL
                    $0.resultURLExpiresAt = pollingExpiry
                    $0.lastError = nil
                    $0.lastPolledAt = Date()
                    $0.nextPollAt = Self.pollDate(retryCount: $0.retryCount)
                    $0.retryCount += 1
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // A poll/network error is not a provider terminal. Keep the
            // durable state and back off; an already terminal job is left
            // untouched by the transition guard.
            if let cluster = await service.r2BoundCluster(),
               cluster.epoch == epoch,
               let env = try? await requireEnvironment(cluster, epoch: epoch) {
                let store = jobStore(env)
                if let current = try? await store.ownedJob(id: jobID),
                   !current.job.state.isTerminal {
                    _ = try? await store.transition(id: jobID, to: .running) {
                        $0.lastError = error is URLError
                            ? "providerTimeout" : "providerUnavailable"
                        $0.lastPolledAt = Date()
                        $0.nextPollAt = Self.pollDate(retryCount: $0.retryCount)
                        $0.retryCount += 1
                    }
                }
            }
        }
    }

    internal static func pollDate(retryCount: Int) -> Date {
        let seconds = min(30 * 60, pow(2.0, Double(min(retryCount, 8))) * 15)
        return Date().addingTimeInterval(seconds)
    }

    internal static func boundedProviderMessage(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "providerRejected" }
        let prefix = String(raw.prefix(96))
        // Provider text is diagnostic only and must never become a code with
        // a path or newline. Keep an allowed alphabet.
        let filtered = String(prefix.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
                || $0 == "." || $0 == "_" || $0 == "-"
        }.prefix(96))
        return filtered.isEmpty ? "providerRejected" : filtered
    }

    // MARK: - Video download / finalisation

    internal func videoStagingManifest(
        env: G09R2GenerationEnvironment, jobID: String,
        candidateStore: G09R2CandidateStore
    ) async -> G09R2VideoStagingManifest? {
        guard let directory = candidateStore.incomingDirectoryURL(
                ownerID: jobID) else { return nil }
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let manifest = try? G09CreativeWire.decoder().decode(
                G09R2VideoStagingManifest.self, from: data),
              manifest.schemaVersion == 1, manifest.jobID == jobID else {
            return nil
        }
        _ = env
        return manifest
    }

    internal func finalizeVideoIfPossible(
        env: G09R2GenerationEnvironment, cluster: G09R2BoundCluster,
        owned: OwnedMediaGenerationJob, payload: G09R2GenerationJobPayload,
        store: MediaGenerationJobStore,
        candidateStore: G09R2CandidateStore,
        epoch: UInt64
    ) async {
        let jobID = owned.job.id
        let owner = jobID.uuidString.lowercased()
        guard beginFinalize(owner) else { return }
        defer { endFinalize(owner) }
        guard owned.job.state == .downloading
                || owned.job.state == .completed else { return }
        guard let directory = candidateStore.incomingDirectoryURL(ownerID: owner) else {
            return
        }
        // Root stop before commit publishes NOTHING. Staged bytes stay for an
        // explicit replay; the job is left non-terminal/terminal as-is.
        guard !isRootStopping(epoch: epoch),
              !G09R2MediaRenderHostMailbox.shared.isRootStopping(
                epoch: epoch) else { return }
        let hasForeground = G09R2ForegroundCoordinator.shared.hasLease(
            jobID: owner, epoch: epoch)
        var manifest = await videoStagingManifest(
            env: env, jobID: owner, candidateStore: candidateStore)
        if manifest == nil {
            // The actual result HTTP download is dataSync foreground work. A
            // missing exact lease defers it (durable state is untouched) and
            // never falls back to an unowned background fetch.
            guard hasForeground else { return }
            guard let resultURL = owned.job.resultURL else { return }
            if let expiry = owned.job.resultURLExpiresAt, expiry <= Date() {
                _ = try? await store.transition(id: jobID, to: .expired) {
                    $0.lastError = "resultExpired"
                    $0.nextPollAt = nil
                }
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let fileName = "video.mp4"
                let target = directory.appendingPathComponent(fileName)
                let receipt = try await platform.download(
                    resultURL, target,
                    G09R2MediaProbe.maximumGeneratedVideoBytes)
                G09R2ForegroundCoordinator.shared.noteProgress(
                    jobID: owner, epoch: epoch, fraction: 0.95)
                guard receipt.byteCount > 0,
                      receipt.byteCount <= G09R2MediaProbe.maximumGeneratedVideoBytes,
                      receipt.sha256.count == 64 else {
                    throw G09R2Error(.providerRejected,
                                     detail: "downloadInvalid")
                }
                let fileURL = receipt.fileURL
                guard let facts = G09R2MediaProbe.videoFacts(fileURL: fileURL) else {
                    try? FileManager.default.removeItem(at: fileURL)
                    throw G09R2Error(.unsupportedSourceFormat,
                                     detail: "videoFormatUnsupported")
                }
                manifest = G09R2VideoStagingManifest(
                    schemaVersion: 1, jobID: owner, fileName: fileName,
                    mimeType: facts.mimeType, byteCount: receipt.byteCount,
                    sha256: receipt.sha256,
                    durationSeconds: facts.durationSeconds,
                    width: facts.width, height: facts.height,
                    rotationDegrees: facts.rotationDegrees)
                let data = try G09CreativeWire.encoder().encode(manifest)
                let manifestURL = directory.appendingPathComponent("manifest.json")
                try data.write(to: manifestURL, options: [])
                try G09R2CandidateStore.flushFile(manifestURL)
                try G09R2CandidateStore.flushDirectory(directory)
                _ = try? await store.transition(id: jobID, to: .completed) {
                    $0.lastError = "downloadCommitPending"
                    $0.nextPollAt = nil
                    $0.resultURL = nil
                    $0.resultURLExpiresAt = nil
                    $0.lastPolledAt = Date()
                }
            } catch is CancellationError {
                // Root stop / user cancellation aborted the real download;
                // leave the durable job non-terminal and publish nothing.
                return
            } catch let typed as G09R2Error {
                await recordDownloadFailure(
                    store: store, jobID: jobID, code: typed.code,
                    expiresAt: owned.job.resultURLExpiresAt)
                return
            } catch {
                await recordDownloadFailure(
                    store: store, jobID: jobID, code: "downloadFailed",
                    expiresAt: owned.job.resultURLExpiresAt)
                return
            }
        }
        guard let manifest else { return }
        guard !Task.isCancelled,
              !isRootStopping(epoch: epoch) else { return }
        do {
            let staged = directory.appendingPathComponent(manifest.fileName)
            let display = "Generated Video.\(G09R2MediaProbe.videoExtension(mimeType: manifest.mimeType))"
            let relative: String
            if let expected = G09R2CandidateStore.generatedRelativePath(
                sha256: manifest.sha256, preferredName: display),
               let finalURL = candidateStore.containedURL(
                relativePath: expected),
               G09R2CandidateStore.verifyCandidateFile(
                finalURL, byteCount: manifest.byteCount,
                sha256: manifest.sha256) {
                relative = expected
            } else {
                guard G09R2CandidateStore.verifyCandidateFile(
                    staged, byteCount: manifest.byteCount,
                    sha256: manifest.sha256) else {
                    throw G09R2Error(.candidateStale,
                                     detail: "stagedVideoMissing")
                }
                relative = try await candidateStore.commitGeneratedFile(
                    from: staged, preferredName: display,
                    expectedSHA256: manifest.sha256,
                    expectedBytes: manifest.byteCount)
            }
            guard !Task.isCancelled,
                  !isRootStopping(epoch: epoch) else { return }
            let asset = try await canonicalGeneratedAsset(
                env: env, contentHash: manifest.sha256, kind: .video,
                displayName: display, mimeType: manifest.mimeType,
                relativePath: relative, byteCount: manifest.byteCount,
                candidateID: owner)
            let candidateID = owner
            var existingCandidate = try? await candidateStore.record(
                projectID: payload.projectID, candidateID: candidateID)
            if existingCandidate == nil {
                let record = G09R2CandidateRecord(
                    candidateID: candidateID,
                    projectID: payload.projectID,
                    kind: .video,
                    modelDisplayName: payload.remoteModelID,
                    createdAt: owned.job.createdAt,
                    byteCount: manifest.byteCount,
                    sha256: manifest.sha256,
                    relativePath: asset.relativePath,
                    assetID: asset.record.id,
                    mimeType: manifest.mimeType,
                    metadata: MediaAssetMetadata(
                        width: manifest.width, height: manifest.height,
                        durationSeconds: manifest.durationSeconds,
                        rotationDegrees: manifest.rotationDegrees),
                    requestID: nil, jobID: candidateID, state: .pending)
                try await candidateStore.upsert(record)
                existingCandidate = record
            }
            _ = try? await store.transition(id: jobID, to: .ready) {
                $0.localAssetID = asset.record.id
                $0.lastError = nil
                $0.nextPollAt = nil
                $0.resultURL = nil
                $0.resultURLExpiresAt = nil
                $0.updatedAt = Date()
            }
            try? removeStaging(directory)
            _ = cluster
        } catch {
            _ = try? await store.transition(id: jobID, to: .completed) {
                $0.lastError = "downloadCommitPending"
                $0.nextPollAt = Self.pollDate(retryCount: $0.retryCount)
                $0.retryCount += 1
            }
        }
    }

    private func recordDownloadFailure(
        store: MediaGenerationJobStore, jobID: UUID, code: String,
        expiresAt: Date?
    ) async {
        if let expiresAt, expiresAt <= Date() {
            _ = try? await store.transition(id: jobID, to: .expired) {
                $0.lastError = "resultExpired"
                $0.nextPollAt = nil
            }
            return
        }
        guard let current = try? await store.ownedJob(id: jobID),
              !current.job.state.isTerminal else { return }
        let next = current.job.retryCount + 1
        if next > Self.maximumDownloadRetries {
            _ = try? await store.transition(id: jobID, to: .expired) {
                $0.lastError = "downloadUnavailable"
                $0.nextPollAt = nil
                $0.retryCount = next
            }
            return
        }
        _ = try? await store.transition(id: jobID, to: .downloading) {
            $0.lastError = code
            $0.retryCount = next
            $0.nextPollAt = Self.pollDate(retryCount: next)
        }
    }

    // MARK: - Staging cleanup

    internal func removeStaging(_ directory: URL?) throws {
        guard let directory else { return }
        guard directory.path.contains("/MediaProjects/Generated/Incoming/") else {
            return
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

// MARK: - Streamed result download

public enum G09R2GenerationDownload {
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate,
                                           @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let target = request.url else {
                completionHandler(nil)
                return
            }
            completionHandler(Self.isSafe(target) ? request : nil)
        }

        static func isSafe(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(), !host.isEmpty else {
                return false
            }
            if host == "localhost" || host.hasSuffix(".local")
                || host == "::1" || host == "[::1]" {
                return false
            }
            let parts = host.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({
                Int($0).map { (0...255).contains($0) } ?? false
            }) {
                let first = Int(parts[0]) ?? 0
                let second = Int(parts[1]) ?? 0
                if first == 10 || first == 127 || first == 0 {
                    return false
                }
                if first == 169 && second == 254 { return false }
                if first == 172, (16...31).contains(second) { return false }
                if first == 192, second == 168 { return false }
            }
            return true
        }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        func install(_ next: URLSessionDownloadTask) {
            lock.lock()
            task = next
            if cancelled { next.cancel() }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            lock.unlock()
            current?.cancel()
        }
    }

    /// Streams a provider result into an owned staging file. The URL is
    /// provider-issued; the request carries NO credential. Only HTTPS
    /// redirects to non-private hosts are followed, the response is bounded
    /// and the actual bytes are hashed after landing on disk. A Root-stop /
    /// user cancellation cancels the real URLSession download task through
    /// the cancellation handler; the worker settles only after it stopped.
    public static func stream(
        from url: URL, to target: URL, maximumBytes: Int64
    ) async throws -> G09R2DownloadReceipt {
        guard RedirectPolicy.isSafe(url), maximumBytes > 0 else {
            throw G09R2Error(.providerRejected, detail: "downloadURLUnsafe")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 900
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let policy = RedirectPolicy()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(
            configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let state = CancellationState()
        let result: (URL, URLResponse)
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(with: request) {
                        location, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let location, let response else {
                            continuation.resume(throwing: G09R2Error(
                                .providerRejected, detail: "downloadResponse"))
                            return
                        }
                        do {
                            try FileManager.default.createDirectory(
                                at: target.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                            try? FileManager.default.removeItem(at: target)
                            do {
                                try FileManager.default.moveItem(
                                    at: location, to: target)
                            } catch {
                                // Fall back to an explicit copy when the
                                // system temporary and accepted root are on
                                // different volumes; never keep both.
                                try FileManager.default.copyItem(
                                    at: location, to: target)
                                try? FileManager.default.removeItem(at: location)
                            }
                            continuation.resume(returning: (target, response))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    state.install(task)
                    if Task.isCancelled {
                        task.cancel()
                    }
                    task.resume()
                }
            } onCancel: {
                state.cancel()
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            try? FileManager.default.removeItem(at: target)
            throw CancellationError()
        } catch is URLError {
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.providerTimeout, detail: "downloadTimeout")
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.providerRejected, detail: "downloadFailed")
        }
        try Task.checkCancellation()
        let (temporary, response) = result
        guard temporary == target else {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.providerRejected, detail: "downloadStaging")
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.providerRejected, detail: "downloadHTTP")
        }
        if http.expectedContentLength > 0,
           http.expectedContentLength > maximumBytes {
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.insufficientStorage, detail: "resultTooLarge")
        }
        guard let size = try? target.resourceValues(
            forKeys: [.fileSizeKey]).fileSize,
            size > 0, Int64(size) <= maximumBytes else {
            try? FileManager.default.removeItem(at: target)
            throw G09R2Error(.providerRejected, detail: "downloadSize")
        }
        guard let digest = try? FloeDigest.sha256Hex(ofFileAt: target) else {
            try? FileManager.default.removeItem(at: target)
            throw G09CreativeError.writeFailed
        }
        return G09R2DownloadReceipt(
            fileURL: target, byteCount: Int64(size), sha256: digest)
    }
}

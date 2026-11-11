// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeMedia
import FloeWorkbench

/// What one M55 Apply produced: the route that ran, the two verified stem
/// products and the honest provider/model identity behind them.
struct MediaV2VoiceSeparationReceipt: Codable, Sendable {
    let route: String
    let modelID: String?
    let remoteJobID: String?
    let vocals: MediaV2AudioDerivationReceipt
    let accompaniment: MediaV2AudioDerivationReceipt
    let limitations: [String]
}

private actor MediaV2VoiceSourceIdentity {
    static let shared = MediaV2VoiceSourceIdentity()
    func resolve(asset: MediaAssetReference, root: URL, cancelled: @escaping @Sendable () -> Bool) throws -> (url: URL, sha256: String) {
        try Task.checkCancellation(); if cancelled() { throw CancellationError() }
        let parent = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = parent.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard asset.kind == .audio, !asset.relativePath.hasPrefix("/"), url.path.hasPrefix(parent.path + "/") else { throw MediaV2CommandError.invalidInput }
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, let bytes = resource.fileSize, bytes > 0, bytes <= 512 * 1_024 * 1_024 else {
            throw MediaPreparedCoreError.limitsExceeded(WorkbenchText.t("请选择较短的音频片段后重试。", "Choose a shorter audio source and retry."))
        }
        let sha = try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: cancelled)
        guard asset.contentHash.map({ $0 == sha }) ?? true else { throw MediaPreparedCoreError.documentChanged }
        return (url, sha)
    }
}

extension MediaV2Session {
    /// Runs one voice separation. The existing provider task/user-action
    /// authority was already verified by the caller; this path re-checks it
    /// before every network step, freezes the explicitly selected source
    /// interval, and commits both stems through the SAME original/undo
    /// transaction (`MediaAudioDerivation.commitStems`).
    func providerVoiceSeparate(input: MediaV2ToolInput, actor: MediaPreparedActorKind, base: Int64,
                               authority: MediaV2ProviderAuthority) async throws -> MediaV2ToolReceipt {
        let fenced = try requireProviderSelection(input, actor: actor)
        guard project.kind == .video else { throw MediaV2CommandError.missingSelection }
        let selected = input.objectID.flatMap { document.trackGraph.clip(id: $0) } ?? (input.objectID == nil && fenced ? selectedClip : nil)
        guard let selected, selected.track.kind == .audio, !selected.track.isLocked else {
            throw MediaV2CommandError.missingSelection
        }
        var selection: AudioVoiceSeparationSelection
        if let supplied = input.voiceSeparation {
            selection = supplied
        } else {
            selection = AudioVoiceSeparationSelection(mode: await automaticVoiceSeparationMode())
        }
        try selection.validate()
        if selection.mode == .localModel, selection.modelID == nil {
            guard let only = await MediaV2StemLocalBridge.automaticModel() else {
                throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t(
                    "请选择要使用的已安装模型（当前不止一个或没有）。",
                    "Choose which installed stem model to use; there is not exactly one automatic choice."))
            }
            selection.modelID = only.id
        }
        guard let assetID = selected.clip.assetID, let asset = document.asset(assetID) else { throw MediaV2CommandError.missingSelection }
        let cancelled: @Sendable () -> Bool = { Task.isCancelled }
        let identity = try await MediaV2VoiceSourceIdentity.shared.resolve(asset: asset, root: root, cancelled: cancelled)
        try Task.checkCancellation()
        let work = try await MediaAudioDerivation.begin(coordinator: coordinator, documentID: id,
            targetClipID: selected.clip.id, verifiedSourceHashes: [assetID: identity.sha256],
            actor: actor, cancelled: cancelled)
        let outputDirectory = root.appendingPathComponent(".stem-output-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let scope = MediaV2ImportScope(token: nil)
        do {
            guard work.target.documentRevision == base else { throw MediaPreparedCoreError.documentChanged }
            let stems: AudioStemCloudOutput?
            let localResult: AudioStemFileResult?
            switch selection.mode {
            case .musicAI:
                providerStatus = WorkbenchText.t("正在导出所选片段…", "Exporting the selected interval…")
                let excerpt = MediaV2ProviderExcerptWriter()
                let excerptURL: URL
                do {
                    excerptURL = try await excerpt.export(source: identity.url, root: root,
                        start: selected.clip.sourceRange.startSeconds, duration: selected.clip.sourceRange.durationSeconds)
                } catch {
                    await excerpt.close()
                    throw error
                }
                defer { Task { await excerpt.close() } }
                let excerptBytes = try excerptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard excerptBytes > 0, excerptBytes <= 128 * 1_024 * 1_024 else {
                    throw MediaPreparedCoreError.limitsExceeded(WorkbenchText.t("所选片段超过 128 MiB，请缩短后重试。", "The selected interval exceeds the 128 MiB upload bound. Shorten it and retry."))
                }
                let excerptSHA = try FloeDigest.sha256Hex(ofFileAt: excerptURL, isCancelled: cancelled)
                let workflow = try await voiceSeparationWorkflow(authority: authority, revision: base)
                let request = try AudioStemCloudRequest(excerptURL: excerptURL, excerptSHA256: excerptSHA,
                    excerptContentType: "audio/mp4",
                    jobName: "Floe video stems · " + (asset.originalName.isEmpty ? id.uuidString : asset.originalName),
                    projectID: id, clipID: selected.clip.id, sourceSHA256: identity.sha256,
                    sourceSeconds: selected.clip.sourceRange.durationSeconds)
                providerStatus = WorkbenchText.t("正在准备云端分离任务…", "Preparing the cloud separation job…")
                stems = try await workflow.start(request, destinationDirectory: outputDirectory,
                    work: .init(isCancelled: cancelled, progress: { _ in }),
                    status: VoiceSeparationProgress.publisher(session: self))
                localResult = nil
            case .localModel:
                guard let modelID = selection.modelID else { throw MediaV2CommandError.invalidInput }
                providerStatus = WorkbenchText.t("正在准备本地模型…", "Preparing the local model…")
                let service = try AudioPCMFileService(workspaceRoot: root)
                let modelService = AudioStemCoreMLService(resolveModel: { identifier in await MediaV2StemLocalBridge.resolve(identifier) })
                providerStatus = WorkbenchText.t("正在本地分离…", "Separating on-device…")
                localResult = try await service.separate(.init(url: identity.url,
                    startSeconds: selected.clip.sourceRange.startSeconds, durationSeconds: selected.clip.sourceRange.durationSeconds,
                    expectedSHA256: identity.sha256), modelID: modelID, modelService: modelService,
                    destinationDirectory: outputDirectory, work: .init(isCancelled: cancelled))
                stems = nil
            }
            try Task.checkCancellation()
            let vocalsSource: URL, accompanimentSource: URL, processingInputSHA: String, modelIdentity: String?, remoteJobID: String?
            let engine: String
            var limitations = [String]()
            let measures: (vocals: (frames: Int, sampleRate: Double, channels: Int), accompaniment: (frames: Int, sampleRate: Double, channels: Int))
            if let stems {
                vocalsSource = stems.vocals.url; accompanimentSource = stems.accompaniment.url
                processingInputSHA = stems.receipt.excerptSHA256; modelIdentity = nil; remoteJobID = stems.receipt.remoteJobID
                engine = "music-ai-stems"; limitations = stems.limitations
                measures = ((stems.vocals.frames, stems.vocals.sampleRate, stems.vocals.channels),
                            (stems.accompaniment.frames, stems.accompaniment.sampleRate, stems.accompaniment.channels))
            } else if let localResult {
                vocalsSource = localResult.vocals.outputURL; accompanimentSource = localResult.accompaniment.outputURL
                processingInputSHA = localResult.vocals.sourceSHA256; modelIdentity = localResult.modelID; remoteJobID = nil
                engine = localResult.vocals.engine
                limitations = localResult.vocals.limitations
                measures = ((localResult.vocals.measurement.frames, localResult.vocals.measurement.sampleRate, localResult.vocals.measurement.channels),
                            (localResult.accompaniment.measurement.frames, localResult.accompaniment.measurement.sampleRate, localResult.accompaniment.measurement.channels))
            } else { throw MediaPreparedCoreError.invalidOperation("voice separation produced no outputs") }
            providerStatus = WorkbenchText.t("正在保存两条音轨…", "Saving the two stems…")
            let (vocalStaged, vocalAsset) = try await MediaV2ImportIO.stage(vocalsSource, root: root, token: nil, ephemeralSource: true)
            scope.add(vocalStaged)
            let (musicStaged, musicAsset) = try await MediaV2ImportIO.stage(accompanimentSource, root: root, token: nil, ephemeralSource: true)
            scope.add(musicStaged)
            try scope.validate()
            let vocalsProduct = try voiceSeparationProduct(staged: vocalAsset, work: work, processingInputSHA: processingInputSHA,
                source: measures.vocals)
            let accompanimentProduct = try voiceSeparationProduct(staged: musicAsset, work: work, processingInputSHA: processingInputSHA,
                source: measures.accompaniment)
            let commit = try await MediaAudioDerivation.commitStems(vocals: vocalsProduct, accompaniment: accompanimentProduct,
                work: work, coordinator: coordinator, assetRoot: root,
                vocalsTitle: WorkbenchText.t("人声", "Vocals"), accompanimentTitle: WorkbenchText.t("伴奏", "Accompaniment"),
                cancelled: cancelled)
            scope.didCommit()
            if let remoteJobID {
                // The document committed atomically. First release the owned
                // remote record best-effort (a revoke failure must not undo
                // the saved stems), then mark the local receipt committed
                // through the durable store only.
                if let cleanup = try? await voiceSeparationWorkflow(authority: authority, revision: base) {
                    _ = try? await cleanup.releaseOwned(projectID: id, clipID: selected.clip.id)
                }
                _ = try? await markVoiceSeparationCommitted(remoteJobID: remoteJobID, clipID: selected.clip.id)
            }
            try await reload()
            if let current = document.trackGraph.clip(id: selected.clip.id) { select(current.track, clip: current.clip) }
            return .init(documentID: id, revision: commit.revision, toolID: "video.voice-separate", groupID: commit.groupID, selectionOnly: false,
                voiceSeparation: .init(route: selection.mode == .localModel ? "coreml" : "music-ai", modelID: modelIdentity, remoteJobID: remoteJobID,
                    vocals: voiceSeparationReceipt(vocalsProduct, originalSHA: identity.sha256, processingInputSHA: processingInputSHA, engine: engine, limitations: limitations),
                    accompaniment: voiceSeparationReceipt(accompanimentProduct, originalSHA: identity.sha256, processingInputSHA: processingInputSHA, engine: engine, limitations: limitations),
                    limitations: limitations))
        } catch {
            try? await coordinator.stop(work.instruction)
            if let durable = try? await coordinator.loadProjectSnapshot(id: id) { scope.retainReferenced(in: durable) }
            throw error
        }
    }
    /// Recovery list for the inspector: non-terminal OWNED cloud records.
    func outstandingVoiceSeparationJobs() async throws -> [AudioStemCloudReceipt] {
        let store = try AudioStemCloudFileReceiptStore(root: root, projectID: id)
        return try await store.outstanding(projectID: id)
    }
    /// Stop waiting locally on one owned record without claiming provider
    /// cancellation; the owned ID remains recoverable. Pure local bookkeeping,
    /// so no network client is required even if the key was removed later.
    func detachVoiceSeparationJob(clipID: UUID, reason: String) async throws {
        let store = try AudioStemCloudFileReceiptStore(root: root, projectID: id)
        guard var receipt = try await store.owned(projectID: id, clipID: clipID) else {
            throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("此片段没有进行中的云端任务。", "This clip has no outstanding cloud job."))
        }
        receipt.state = .detached; receipt.updatedAt = Date()
        receipt.lastError = String(reason.prefix(240))
        try await store.save(receipt)
    }
    /// DELETE only the owned remote record for this clip. Billed in-flight
    /// computation is not claimed to be revoked.
    func releaseVoiceSeparationJob(clipID: UUID) async throws {
        let authority = try await MediaV2ProviderAuthority.userAction(session: self, capability: .stemSeparation)
        let workflow = try await voiceSeparationWorkflow(authority: authority, revision: document.revision)
        _ = try await workflow.releaseOwned(projectID: id, clipID: clipID)
    }
    /// Continue polling the EXACT owned remote job and commit the verified
    /// stems with the current document fences. Never creates a second job.
    @discardableResult
    func resumeVoiceSeparationJob(clipID: UUID) async throws -> MediaV2ToolReceipt {
        let authority = try await MediaV2ProviderAuthority.userAction(session: self, capability: .stemSeparation)
        guard !processingTool, !saving, let found = document.trackGraph.clip(id: clipID),
              found.track.kind == .audio, !found.track.isLocked, let assetID = found.clip.assetID,
              let asset = document.asset(assetID), asset.kind == .audio else { throw MediaV2CommandError.missingSelection }
        let base = document.revision
        processingTool = true
        stopPlayback()
        let worker = Task<MediaV2ToolReceipt, Error> { @MainActor in
            let cancelled: @Sendable () -> Bool = { Task.isCancelled }
            let identity = try await MediaV2VoiceSourceIdentity.shared.resolve(asset: asset, root: root, cancelled: cancelled)
            let work = try await MediaAudioDerivation.begin(coordinator: coordinator, documentID: id,
                targetClipID: clipID, verifiedSourceHashes: [assetID: identity.sha256], actor: .user, cancelled: cancelled)
            let outputDirectory = root.appendingPathComponent(".stem-output-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let scope = MediaV2ImportScope(token: nil)
            do {
                guard work.target.documentRevision == base, work.target.sourceSHA256 == identity.sha256 else {
                    throw MediaPreparedCoreError.documentChanged
                }
                let workflow = try await voiceSeparationWorkflow(authority: authority, revision: base)
                providerStatus = WorkbenchText.t("正在恢复云端任务…", "Resuming the owned cloud job…")
                let stems = try await workflow.resume(projectID: id, clipID: clipID, destinationDirectory: outputDirectory,
                    work: .init(isCancelled: cancelled, progress: { _ in }),
                    status: VoiceSeparationProgress.publisher(session: self))
                try Task.checkCancellation()
                providerStatus = WorkbenchText.t("正在保存两条音轨…", "Saving the two stems…")
                let (vocalStaged, vocalAsset) = try await MediaV2ImportIO.stage(stems.vocals.url, root: root, token: nil, ephemeralSource: true)
                scope.add(vocalStaged)
                let (musicStaged, musicAsset) = try await MediaV2ImportIO.stage(stems.accompaniment.url, root: root, token: nil, ephemeralSource: true)
                scope.add(musicStaged)
                try scope.validate()
                let vocalsProduct = try voiceSeparationProduct(staged: vocalAsset, work: work, processingInputSHA: stems.receipt.excerptSHA256,
                    source: (stems.vocals.frames, stems.vocals.sampleRate, stems.vocals.channels))
                let accompanimentProduct = try voiceSeparationProduct(staged: musicAsset, work: work, processingInputSHA: stems.receipt.excerptSHA256,
                    source: (stems.accompaniment.frames, stems.accompaniment.sampleRate, stems.accompaniment.channels))
                let commit = try await MediaAudioDerivation.commitStems(vocals: vocalsProduct, accompaniment: accompanimentProduct,
                    work: work, coordinator: coordinator, assetRoot: root,
                    vocalsTitle: WorkbenchText.t("人声", "Vocals"), accompanimentTitle: WorkbenchText.t("伴奏", "Accompaniment"), cancelled: cancelled)
                scope.didCommit()
                _ = try? await workflow.releaseOwned(projectID: id, clipID: clipID)
                _ = try? await markVoiceSeparationCommitted(remoteJobID: stems.receipt.remoteJobID, clipID: clipID)
                try await reload()
                if let current = document.trackGraph.clip(id: clipID) { select(current.track, clip: current.clip) }
                return .init(documentID: id, revision: commit.revision, toolID: "video.voice-separate", groupID: commit.groupID, selectionOnly: false,
                    voiceSeparation: .init(route: "music-ai", modelID: nil, remoteJobID: stems.receipt.remoteJobID,
                        vocals: voiceSeparationReceipt(vocalsProduct, originalSHA: identity.sha256, processingInputSHA: stems.receipt.excerptSHA256, engine: "music-ai-stems", limitations: stems.limitations),
                        accompaniment: voiceSeparationReceipt(accompanimentProduct, originalSHA: identity.sha256, processingInputSHA: stems.receipt.excerptSHA256, engine: "music-ai-stems", limitations: stems.limitations),
                        limitations: stems.limitations))
            } catch {
                try? await coordinator.stop(work.instruction)
                if let durable = try? await coordinator.loadProjectSnapshot(id: id) { scope.retainReferenced(in: durable) }
                throw error
            }
        }
        cancelToolWork = { worker.cancel() }
        defer { processingTool = false; cancelToolWork = nil; providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    /// The bridge gate mints the configured Music.AI client under the SAME
    /// existing provider authority; every later step re-enters it.
    private func voiceSeparationWorkflow(authority: MediaV2ProviderAuthority, revision: Int64) async throws -> AudioStemCloudWorkflow {
        let api = try await MediaV2ProviderBridge.voiceSeparationAPI(authority: authority)
        let store = try AudioStemCloudFileReceiptStore(root: root, projectID: id)
        let projectID = id
        return try AudioStemCloudWorkflow(api: api, store: store, downloader: MediaV2StemDownloader(),
            authority: {
                try await authority.authorize(capability: .stemSeparation, projectID: projectID, revision: revision)
            })
    }
    private func automaticVoiceSeparationMode() async -> AudioVoiceSeparationSelection.Mode {
        // Deterministic: installed local models win over the paid route;
        // otherwise the configured cloud route runs; a fully unconfigured
        // state reports through the ordinary error path below.
        if !(await MediaV2StemLocalBridge.models()).isEmpty { return .localModel }
        return .musicAI
    }
    private func voiceSeparationProduct(staged asset: MediaAssetReference, work: MediaAudioDerivationWork,
        processingInputSHA: String, source: (frames: Int, sampleRate: Double, channels: Int)) throws -> MediaAudioDerivedProduct {
        guard source.frames > 0, source.sampleRate.isFinite, (8_000...192_000).contains(source.sampleRate), (1...2).contains(source.channels) else {
            throw MediaPreparedCoreError.invalidOperation("the separated stem has no valid measured sample clock")
        }
        return .init(asset: asset, sourceAssetID: work.target.asset.id, originalSourceSHA256: work.target.sourceSHA256,
            processingInputSHA256: processingInputSHA, frames: source.frames, sampleRate: source.sampleRate, channelCount: source.channels)
    }
    /// Store-only committed marking: durable bookkeeping that cannot fail the
    /// already-committed document outcome.
    private func markVoiceSeparationCommitted(remoteJobID: String, clipID: UUID) async throws {
        let store = try AudioStemCloudFileReceiptStore(root: root, projectID: id)
        guard let receipt = try await store.load(remoteJobID: remoteJobID), receipt.projectID == id, receipt.clipID == clipID,
              receipt.state != .failed else { throw AudioStemCloudError.noOwnedJob }
        if receipt.state == .committed { return }
        var committed = receipt; committed.state = .committed; committed.updatedAt = Date(); committed.lastError = nil
        try await store.save(committed)
    }
    private func voiceSeparationReceipt(_ product: MediaAudioDerivedProduct, originalSHA: String, processingInputSHA: String,
        engine: String, limitations: [String]) -> MediaV2AudioDerivationReceipt {
        .init(sourceAssetID: product.sourceAssetID, outputAssetID: product.asset.id, sourceSHA256: originalSHA,
            processingInputSHA256: processingInputSHA, outputSHA256: product.asset.contentHash ?? "", frames: product.frames,
            sampleRate: product.sampleRate, channelCount: product.channelCount, engine: engine, metrics: [:], limitations: limitations)
    }
}

/// Bridges workflow callbacks onto the session's existing status label
/// without giving the inspector view any ownership of the work.
enum VoiceSeparationProgress {
    @MainActor static func publisher(session: MediaV2Session) -> @MainActor @Sendable (AudioStemCloudStage) -> Void {
        { stage in
            guard session.processingTool else { return }
            session.providerStatus = VoiceSeparationProgress.text(stage)
        }
    }
    static func text(_ stage: AudioStemCloudStage) -> String {
        switch stage.kind {
        case .preparing: return WorkbenchText.t("正在准备上传…", "Preparing the bounded upload…")
        case .uploading: return WorkbenchText.t("正在上传所选片段…", "Uploading the selected interval…")
        case .creating: return WorkbenchText.t("正在创建云端任务…", "Creating the owned cloud job…")
        case .waiting: return String(format: WorkbenchText.t("云端分离中（已等待 %d 秒）…", "Cloud separation running (waited %d s)…"), stage.waitedSeconds ?? 0)
        case .downloading: return WorkbenchText.t("正在下载并校验两条音轨…", "Downloading and verifying both stems…")
        case .verifying: return WorkbenchText.t("正在校验云端结果…", "Verifying the provider results…")
        case .finished: return WorkbenchText.t("正在保存两条音轨…", "Saving the two stems…")
        }
    }
}
#endif

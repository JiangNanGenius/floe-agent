// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeMedia
import FloeWorkbench

struct MediaV2AudioDerivationReceipt: Codable, Sendable {
    let sourceAssetID: UUID
    let outputAssetID: UUID
    let sourceSHA256: String
    let processingInputSHA256: String
    let outputSHA256: String
    let frames: Int
    let sampleRate: Double
    let channelCount: Int
    let engine: String
    let metrics: [String: Double]
    let limitations: [String]
}

extension MediaV2Session {
    static let audioDerivationToolIDs: Set<String> = ["video.noise", "video.duck"]

    /// Entered after performTool's normal task/revision/explicit-selection
    /// checks. The session, not the inspector, owns cancellation and saving.
    func performAudioDerivationTool(_ toolID: String, input: MediaV2ToolInput,
        selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)?, actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard Self.audioDerivationToolIDs.contains(toolID), project.kind == .video,
              !processingTool, !saving, let target = selected, target.track.kind == .audio,
              !target.track.isLocked else { throw MediaV2CommandError.missingSelection }
        var voiceID: UUID?
        if toolID == "video.duck" {
            guard let text = input.property, let suppliedID = UUID(uuidString: text), suppliedID != target.clip.id,
                  let supplied = document.trackGraph.clip(id: suppliedID), !supplied.track.isLocked else {
                throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请选择用于压低配乐的旁白片段。", "Choose the narration clip that should lower the music."))
            }
            // Uses the existing explicit video-to-source-audio association.
            // It refuses multiple linked source clips rather than guessing.
            if supplied.track.kind == .visual {
                voiceID = try await editableSourceAudio(for: suppliedID).clip.id
            } else if supplied.track.kind == .audio { voiceID = suppliedID }
            else { throw MediaV2CommandError.missingSelection }
            guard let current = document.trackGraph.clip(id: target.clip.id), current.clip == target.clip,
                  current.track.volume == target.track.volume, current.track.isMuted == target.track.isMuted,
                  !processingTool, !saving else { throw MediaPreparedCoreError.documentChanged }
        }
        guard toolID == "video.noise" ? input.dialogueDucking == nil : (input.noiseReduction == nil && input.start == nil && input.duration == nil) else {
            throw MediaV2CommandError.invalidInput
        }
        // Partial typed objects use validated defaults; conflicting legacy
        // aliases are refused so supplied settings cannot be silently ignored.
        guard !(input.noiseReduction != nil && (input.number != nil || input.secondary != nil || input.start != nil || input.duration != nil)),
              !(input.dialogueDucking != nil && (input.number != nil || input.secondary != nil)) else { throw MediaV2CommandError.invalidInput }
        let profile: AudioNoiseProfileRange?
        if input.start != nil || input.duration != nil {
            guard let start = input.start, let duration = input.duration else { throw MediaV2CommandError.invalidInput }
            profile = .init(startSeconds: start, durationSeconds: duration)
        } else { profile = nil }
        let noise = input.noiseReduction ?? .init(amount: input.number ?? 0.8, maximumReductionDB: input.secondary ?? 18, noiseOnlyRange: profile)
        let duck = input.dialogueDucking ?? .init(thresholdDB: input.secondary ?? -38, reductionDB: input.number ?? 12)
        try noise.validate(); try duck.validate()
        let base = document, token = CancellationToken()
        processingTool = true
        stopPlayback()
        let worker = Task { @MainActor in
            try await processAudioDerivation(toolID, targetID: target.clip.id, voiceID: voiceID,
                base: base, noise: noise, duck: duck, actor: actor, token: token)
        }
        cancelToolWork = { token.cancel(); worker.cancel() }
        defer { processingTool = false; cancelToolWork = nil; providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { token.cancel(); worker.cancel() }
    }

    private func processAudioDerivation(_ toolID: String, targetID: UUID, voiceID: UUID?, base: MediaPreparedDocument,
        noise: AudioSpectralDenoiseSettings, duck: AudioDuckingSettings,
        actor: MediaPreparedActorKind, token: CancellationToken) async throws -> MediaV2ToolReceipt {
        providerStatus = WorkbenchText.t("正在准备音频…", "Preparing audio…")
        let identifiers = [targetID] + (voiceID.map { [$0] } ?? [])
        var urls: [UUID: URL] = [:], hashes: [UUID: String] = [:]
        for identifier in identifiers {
            guard let source = base.trackGraph.clip(id: identifier), let assetID = source.clip.assetID, let asset = base.asset(assetID) else {
                throw MediaV2CommandError.missingSelection
            }
            let identity = try await MediaV2AudioSourceIdentity.shared.resolve(asset: asset, root: root, token: token)
            urls[assetID] = identity.url; hashes[assetID] = identity.sha256
        }
        try token.throwIfCancelled(); try Task.checkCancellation()
        let work = try await MediaAudioDerivation.begin(coordinator: coordinator, documentID: id, targetClipID: targetID,
            sidechainClipIDs: voiceID.map { [$0] } ?? [], verifiedSourceHashes: hashes, actor: actor, cancelled: { token.isCancelled })
        let scope = MediaV2ImportScope(token: token)
        do {
            guard work.target.documentRevision == base.revision,
                  let targetURL = urls[work.target.asset.id] else { throw MediaPreparedCoreError.documentChanged }
            let output = try MediaV2ImportTemporaryFile(root: root, fileExtension: "wav")
            defer { withExtendedLifetime(output) {} }
            let service = try AudioPCMFileService(workspaceRoot: root)
            let audioWork = AudioPCMWork(isCancelled: { token.isCancelled })
            let result: AudioPCMFileResult
            let clock: MediaAudioDerivedClock
            if toolID == "video.noise" {
                providerStatus = WorkbenchText.t("正在减少背景噪声…", "Reducing background noise…")
                result = try await service.denoise(.init(url: targetURL, startSeconds: work.target.clip.sourceRange.startSeconds,
                    durationSeconds: work.target.clip.sourceRange.durationSeconds, expectedSHA256: work.target.sourceSHA256),
                    destination: output.url, settings: noise, work: audioWork)
                clock = .sourceInterval
            } else {
                guard let voiceID, let voice = work.inputs.first(where: { $0.clip.id == voiceID }), let voiceURL = urls[voice.asset.id] else {
                    throw MediaV2CommandError.missingSelection
                }
                providerStatus = WorkbenchText.t("正在对齐旁白和配乐…", "Aligning narration and music…")
                let music = try MediaV2ImportTemporaryFile(root: root, fileExtension: "wav")
                let narration = try MediaV2ImportTemporaryFile(root: root, fileExtension: "wav")
                defer { withExtendedLifetime((music, narration)) {} }
                let targetInput = try MediaAudioDerivation.retimedInput(fence: work.target, sourceURL: targetURL,
                    window: work.target.clip.timelineRange, preserveMixControls: false)
                let voiceInput = try MediaAudioDerivation.retimedInput(fence: voice, sourceURL: voiceURL,
                    window: work.target.clip.timelineRange, preserveMixControls: true)
                let cancellation = PreparedVideoCancellation(external: { token.isCancelled })
                // Offline native rendering only. Effects and gain are bypassed
                // for the music intermediate, then applied exactly once by
                // its preserved original controls after replacement.
                let mixer = PreparedVideoAudioMixer(limits: .init(maximumRequestedFrames: 8_000_000,
                    maximumRenderFrames: 8_240_000, maximumScheduledPCMBytes: 64 * 1_024 * 1_024))
                _ = try await mixer.mix(.init(plan: targetInput.plan, window: targetInput.window, sampleRate: targetInput.sampleRate,
                    channelCount: 2, destination: music.url, tailFrames: 0), cancellation: cancellation)
                _ = try await mixer.mix(.init(plan: voiceInput.plan, window: voiceInput.window, sampleRate: voiceInput.sampleRate,
                    channelCount: 2, destination: narration.url, tailFrames: 0), cancellation: cancellation)
                providerStatus = WorkbenchText.t("正在自动压低配乐…", "Lowering music during narration…")
                result = try await service.duck(.init(url: music.url), sidechain: .init(url: narration.url), sidechainStartSeconds: 0,
                    destination: output.url, settings: duck, work: audioWork)
                clock = .retimedTimeline
            }
            try token.throwIfCancelled(); try Task.checkCancellation()
            providerStatus = WorkbenchText.t("正在保存音频…", "Saving audio…")
            let (staged, asset) = try await MediaV2ImportIO.stage(result.outputURL, root: root, token: token)
            scope.add(staged); try scope.validate()
            let product = MediaAudioDerivedProduct(asset: asset, sourceAssetID: work.target.asset.id,
                originalSourceSHA256: work.target.sourceSHA256, processingInputSHA256: result.sourceSHA256,
                frames: result.measurement.frames, sampleRate: result.measurement.sampleRate, channelCount: result.measurement.channels)
            let commit = try await MediaAudioDerivation.commitReplacement(product, clock: clock, work: work,
                coordinator: coordinator, assetRoot: root, cancelled: { token.isCancelled })
            scope.didCommit()
            try await reload()
            if let current = document.trackGraph.clip(id: targetID) { select(current.track, clip: current.clip) }
            return .init(documentID: id, revision: commit.revision, toolID: toolID, groupID: commit.groupID, selectionOnly: false,
                audioDerivation: .init(sourceAssetID: work.target.asset.id, outputAssetID: asset.id, sourceSHA256: work.target.sourceSHA256,
                    processingInputSHA256: result.sourceSHA256, outputSHA256: result.outputSHA256, frames: result.measurement.frames,
                    sampleRate: result.measurement.sampleRate, channelCount: result.measurement.channels,
                    engine: result.engine, metrics: result.metrics, limitations: result.limitations))
        } catch {
            try? await coordinator.stop(work.instruction)
            // A late reload/lease error must not delete an already committed
            // file. The durable document decides which staged files survive.
            if let durable = try? await coordinator.loadDocument(id: id) { scope.retainReferenced(durable.assets) }
            throw error
        }
    }
}

private actor MediaV2AudioSourceIdentity {
    static let shared = MediaV2AudioSourceIdentity()
    func resolve(asset: MediaAssetReference, root: URL, token: CancellationToken) throws -> (url: URL, sha256: String) {
        try Task.checkCancellation(); try token.throwIfCancelled()
        let parent = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = parent.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard asset.kind == .audio, !asset.relativePath.hasPrefix("/"), url.path.hasPrefix(parent.path + "/") else { throw MediaV2CommandError.invalidInput }
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, let bytes = resource.fileSize, bytes > 0, bytes <= 512 * 1_024 * 1_024 else {
            throw MediaPreparedCoreError.limitsExceeded(WorkbenchText.t("请选择较短的音频片段后重试。", "Choose a shorter audio source and retry."))
        }
        let sha = try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: { token.isCancelled })
        guard asset.contentHash.map({ $0 == sha }) ?? true else { throw MediaPreparedCoreError.documentChanged }
        return (url, sha)
    }
}
#endif

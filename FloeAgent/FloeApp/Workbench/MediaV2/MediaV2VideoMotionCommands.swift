// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func performVideoMotionTool(_ tool: String, input: MediaV2ToolInput,
                                selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)?,
                                actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard !processingTool, !saving, !rendering, let selected,
              selected.track.kind == .visual, !selected.track.isLocked,
              let assetID = selected.clip.assetID, let asset = document.asset(assetID), asset.kind == .video,
              selected.clip.crop == nil else { throw MediaV2CommandError.missingSelection }
        let base = document.revision, original = selected.clip
        if input.property == "clear" {
            var next = original
            if tool == "video.tracking" { next.videoTracking = nil } else { next.stabilization = nil }
            let commit = try await apply([.init(action: .replaceClip(trackID: selected.track.id, clipID: next.id,
                expectedRevision: original.revision, clip: next))], expectedRevision: base, actor: actor)
            return .init(documentID: id, revision: document.revision, toolID: tool, groupID: commit.groupID, selectionOnly: false)
        }
        guard input.property == nil, let source = try resolvedAssets()[assetID] else { throw MediaV2CommandError.invalidInput }
        let region: NormalizedRect?
        if tool == "video.tracking" {
            guard let p = input.points, p.count == 2 else { throw MediaV2CommandError.invalidInput }
            let value = NormalizedRect(x: min(p[0].x,p[1].x), y: min(p[0].y,p[1].y), width: abs(p[1].x-p[0].x), height: abs(p[1].y-p[0].y))
            try MediaVideoMotionMath.validateRegion(value); region = value
        } else {
            guard input.points == nil else { throw MediaV2CommandError.invalidInput }; region = nil
        }
        let request = MediaVideoMotionRequest(assetID: assetID, assetRevision: document.assetRevisions?[assetID] ?? 0,
            expectedContentHash: asset.contentHash, startSeconds: original.sourceRange.startSeconds,
            durationSeconds: original.sourceRange.durationSeconds, sampleRate: tool == "video.tracking" ? (input.secondary ?? 15) : 15)
        let cancellation = PreparedVideoCancellation()
        processingTool = true; stopPlayback()
        providerStatus = WorkbenchText.t("正在分析画面…", "Analyzing video…")
        let worker = Task { @MainActor in
            var next = original
            let progress: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard !cancellation.isCancelled, self?.document.revision == base, self?.processingTool == true else { return }
                    self?.providerStatus = WorkbenchText.t("正在分析画面", "Analyzing video") + " · \(Int(value*100))%"
                }
            }
            if let region {
                next.videoTracking = try await MediaVideoMotionService.shared.track(url: source, request: request,
                    region: region, minimumConfidence: input.number ?? 0.3, cancellation: cancellation, progress: progress)
            } else {
                next.stabilization = try await MediaVideoMotionService.shared.stabilize(url: source, request: request,
                    smoothingSeconds: input.number ?? 0.3, strength: input.secondary ?? 1,
                    cropEdges: input.flag ?? true, cancellation: cancellation, progress: progress)
            }
            try Task.checkCancellation(); try cancellation.check()
            let binding = region == nil ? next.stabilization!.source : next.videoTracking!.source
            guard try await MediaVideoMotionService.shared.contentHash(source, cancellation: cancellation) == binding.contentHash,
                  self.document.revision == base, self.document.asset(assetID) == asset,
                  (self.document.assetRevisions?[assetID] ?? 0) == request.assetRevision,
                  actor != .user || self.selectedClipID == original.id else { throw MediaPreparedCoreError.documentChanged }
            try Task.checkCancellation(); try cancellation.check()
            let commit = try await self.apply([.init(action: .replaceClip(trackID: selected.track.id, clipID: next.id,
                expectedRevision: original.revision, clip: next))], expectedRevision: base, actor: actor)
            return MediaV2ToolReceipt(documentID: self.id, revision: self.document.revision, toolID: tool,
                groupID: commit.groupID, selectionOnly: false, tracking: next.videoTracking, stabilization: next.stabilization)
        }
        cancelToolWork = { cancellation.cancel(); worker.cancel() }
        defer { cancellation.cancel(); processingTool = false; cancelToolWork = nil; providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
}
#endif

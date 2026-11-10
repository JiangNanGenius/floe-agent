// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func colorMatchFrameRequest(clip: MediaPreparedClip,seconds: Double?,excludingMatch: Bool) throws -> MediaVideoColorFrameRequest {
        guard let assetID = clip.assetID, let asset = document.asset(assetID), asset.kind != .audio else { throw MediaV2CommandError.missingSelection }
        let sourceSeconds = seconds ?? (asset.kind == .image ? 0 : clip.sourceRange.startSeconds)
        guard sourceSeconds.isFinite,
              asset.kind == .image ? sourceSeconds == 0 : sourceSeconds >= clip.sourceRange.startSeconds && sourceSeconds < clip.sourceRange.endSeconds else {
            throw MediaV2CommandError.invalidInput
        }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let url = (asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: asset.relativePath) : canonical.appendingPathComponent(asset.relativePath))
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path+"/"), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PersonalContentError.missingDocument }
        var grade = clip.videoGrade
        if excludingMatch { grade?.colorMatch = nil }
        return .init(assetID: assetID,assetRevision: document.assetRevisions?[assetID] ?? 0,url: url,kind: asset.kind,
            expectedContentHash: asset.contentHash,sourceSeconds: sourceSeconds,grade: grade,
            chromaKey: clip.chromaKey,mask: clip.videoMask,stabilization: clip.stabilization)
    }
    func performColorMatchTool(input: MediaV2ToolInput, selected: (track: MediaPreparedTrack,clip: MediaPreparedClip)?,
                               actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard !processingTool, !saving, !rendering, let selected, selected.track.kind == .visual,
              !selected.track.isLocked, selected.clip.assetID != nil else { throw MediaV2CommandError.missingSelection }
        let base = document.revision
        var next = selected.clip, grade = next.videoGrade ?? .init()
        if input.flag == false {
            grade.colorMatch = nil;next.videoGrade = grade.isEmpty ? nil : grade
            let commit = try await apply([.init(action: .replaceClip(trackID: selected.track.id,clipID: next.id,
                expectedRevision: selected.clip.revision,clip: next))],expectedRevision: base,actor: actor)
            return .init(documentID: id,revision: document.revision,toolID: "video.color-match",groupID: commit.groupID,selectionOnly: false)
        }
        guard let value = input.property, let refID = UUID(uuidString: value),
              let reference = document.trackGraph.clip(id: refID), reference.track.kind == .visual,
              reference.clip.id != selected.clip.id, input.points == nil else { throw MediaV2CommandError.invalidInput }
        let targetRequest = try colorMatchFrameRequest(clip: selected.clip,seconds: input.start,excludingMatch: true)
        let referenceRequest = try colorMatchFrameRequest(clip: reference.clip,seconds: input.secondary,excludingMatch: false)
        let mix = input.number ?? 1
        guard mix.isFinite,(0...1).contains(mix), input.text == nil || input.text == "color" || input.text == "color-and-contrast" else { throw MediaV2CommandError.invalidInput }
        let token = PreparedVideoCancellation()
        processingTool = true;stopPlayback();providerStatus = WorkbenchText.t("正在匹配镜头色彩…", "Matching shot colors…")
        let worker = Task { @MainActor in
            let match = try await MediaVideoColorMatchService.shared.match(target: targetRequest,reference: referenceRequest,
                referenceClipID: refID,mix: mix,matchesContrast: input.text != "color",cancellation: token)
            try Task.checkCancellation();try token.check()
            guard try await MediaVideoMotionService.shared.contentHash(targetRequest.url,cancellation: token) == match.target.contentHash,
                  try await MediaVideoMotionService.shared.contentHash(referenceRequest.url,cancellation: token) == match.reference.contentHash,
                  self.document.revision == base,
                  (self.document.assetRevisions?[match.target.assetID] ?? 0) == match.target.assetRevision,
                  (self.document.assetRevisions?[match.reference.assetID] ?? 0) == match.reference.assetRevision,
                  actor != .user || self.selectedClipID == selected.clip.id else { throw MediaPreparedCoreError.documentChanged }
            try Task.checkCancellation();try token.check()
            var updated = selected.clip, color = updated.videoGrade ?? .init();color.colorMatch = match;updated.videoGrade = color
            let commit = try await self.apply([.init(action: .replaceClip(trackID: selected.track.id,clipID: updated.id,
                expectedRevision: selected.clip.revision,clip: updated))],expectedRevision: base,actor: actor)
            return MediaV2ToolReceipt(documentID: self.id,revision: self.document.revision,toolID: "video.color-match",
                groupID: commit.groupID,selectionOnly: false,colorMatch: match)
        }
        cancelToolWork = { token.cancel();worker.cancel() }
        defer { token.cancel();processingTool = false;cancelToolWork = nil;providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { token.cancel();worker.cancel() }
    }
}
#endif

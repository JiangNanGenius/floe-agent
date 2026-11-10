// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func performHDRTool(input: MediaV2ToolInput,selected: (track: MediaPreparedTrack,clip: MediaPreparedClip)?,
                        actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard project.kind == .video, document.canvas != nil, !processingTool, !saving, !rendering else { throw MediaV2CommandError.invalidInput }
        let base = document.revision, generation = document.canvasRevision ?? 0
        let sourceRequest: MediaVideoColorFrameRequest?
        let explicit: MediaVideoColorProfile?
        if input.flag == false || input.property == "standard" { sourceRequest = nil;explicit = nil }
        else if input.property == "source" {
            guard let selected, selected.track.kind == .visual else { throw MediaV2CommandError.missingSelection }
            sourceRequest = try colorMatchFrameRequest(clip: selected.clip,seconds: nil,excludingMatch: true);explicit = nil
        } else {
            guard let raw = input.property, let value = MediaVideoColorProfile(rawValue: raw) else { throw MediaV2CommandError.invalidInput }
            sourceRequest = nil;explicit = value
        }
        processingTool = true;stopPlayback()
        providerStatus = WorkbenchText.t("正在设置视频颜色…", "Setting video color…")
        let worker = Task { @MainActor in
            let profile: MediaVideoColorProfile?
            if let sourceRequest {
                let hash = try await MediaVideoMotionService.shared.contentHash(sourceRequest.url)
                if let expected = sourceRequest.expectedContentHash, expected != hash { throw MediaPreparedCoreError.documentChanged }
                profile = try await MediaVideoColorProfileDetector.shared.detect(url: sourceRequest.url,kind: sourceRequest.kind)
                guard try await MediaVideoMotionService.shared.contentHash(sourceRequest.url) == hash,
                      self.document.revision == base,
                      (self.document.assetRevisions?[sourceRequest.assetID] ?? 0) == sourceRequest.assetRevision,
                      actor != .user || self.selectedClipID == selected?.clip.id else { throw MediaPreparedCoreError.documentChanged }
            } else { profile = explicit }
            try Task.checkCancellation()
            guard self.document.revision == base else { throw MediaPreparedCoreError.documentChanged }
            if self.document.canvas?.videoColorProfile == profile {
                return MediaV2ToolReceipt(documentID: self.id,revision: base,toolID: "video.hdr",groupID: nil,selectionOnly: false,colorProfile: profile)
            }
            let commit = try await self.apply([.init(action: .setVideoColorProfile(expectedRevision: generation,profile: profile))],expectedRevision: base,actor: actor)
            return MediaV2ToolReceipt(documentID: self.id,revision: self.document.revision,toolID: "video.hdr",
                groupID: commit.groupID,selectionOnly: false,colorProfile: profile)
        }
        cancelToolWork = { worker.cancel() }
        defer { processingTool = false;cancelToolWork = nil;providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif

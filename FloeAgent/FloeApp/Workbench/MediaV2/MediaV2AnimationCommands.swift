// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    static let extendedAnimationTools: Set<String> = ["video.motion-path", "video.motion-title", "video.preset-motion"]
    func performAnimationTool(_ id: String, input: MediaV2ToolInput,
                              selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)?,
                              cursor: Double, actor: MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard project.kind == .video else { throw MediaV2CommandError.invalidInput }
        var actions: [MediaPreparedAction] = []
        var newSelection: (UUID, UUID)?
        if id == "video.motion-title" {
            guard let text = input.text else { throw MediaV2CommandError.invalidInput }
            let existing = selected?.clip.motionTitle
            let title = MediaMotionTitle(text: text, fontSize: input.number ?? existing?.fontSize ?? 48,
                                         colorHex: input.color ?? existing?.colorHex ?? "#FFFFFF",
                                         backgroundHex: existing?.backgroundHex)
            try title.validate()
            if let selected, existing != nil {
                var clip = selected.clip; clip.motionTitle = title
                if input.start != nil || input.duration != nil {
                    clip.timelineRange = try Self.range(start: input.start ?? clip.timelineRange.startSeconds,
                        duration: input.duration ?? clip.timelineRange.durationSeconds)
                    clip.sourceRange = try Self.range(start: 0,duration: clip.timelineRange.durationSeconds)
                    clip.keyframeTracks = try MediaAnimation.sliced(clip.keyframeTracks,from:0,duration:clip.timelineRange.durationSeconds)
                }
                if let name = input.property {
                    guard let preset = MediaAnimationPreset(rawValue:name) else { throw MediaV2CommandError.invalidInput }
                    clip.keyframeTracks = try MediaAnimation.applying(preset,to:clip)
                }
                actions.append(.replaceClip(trackID:selected.track.id,clipID:clip.id,expectedRevision:selected.clip.revision,clip:clip))
            } else {
                guard input.objectID == nil else { throw MediaV2CommandError.missingSelection }
                let track = MediaPreparedTrack(kind:.visual,name:WorkbenchText.t("标题", "Titles"))
                let range = try Self.range(start:input.start ?? cursor,duration:input.duration ?? 3)
                var clip = MediaPreparedClip(timelineRange:range,sourceRange:try Self.range(start:0,duration:range.durationSeconds),motionTitle:title)
                guard let preset = MediaAnimationPreset(rawValue:input.property ?? "fade") else { throw MediaV2CommandError.invalidInput }
                clip.keyframeTracks = try MediaAnimation.applying(preset,to:clip)
                actions.append(.insertTrack(track:track,index:nil)); actions.append(.insertClip(trackID:track.id,clip:clip,index:nil))
                newSelection = (track.id,clip.id)
            }
        } else {
            guard let selected,selected.track.kind == .visual else { throw MediaV2CommandError.missingSelection }
            let keys: [MediaKeyframeTrack]
            if id == "video.motion-path" {
                guard let points = input.points else { throw MediaV2CommandError.invalidInput }
                let start = input.start ?? 0
                keys = try MediaAnimation.motionPath(points,start:start,
                    duration:input.duration ?? selected.clip.timelineRange.durationSeconds - start,in:selected.clip)
            } else {
                guard let preset = MediaAnimationPreset(rawValue:input.text ?? "fade") else { throw MediaV2CommandError.invalidInput }
                keys = try MediaAnimation.applying(preset,to:selected.clip)
            }
            actions.append(.replaceClipKeyframes(trackID:selected.track.id,clipID:selected.clip.id,expectedRevision:selected.clip.revision,keyframeTracks:keys))
        }
        let commit = try await apply(actions.map { .init(action:$0) },expectedRevision:input.expectedRevision,actor:actor)
        if let (track,clip) = newSelection { selectedTrackID = track;selectedClipID = clip }
        return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2PlaybackInspector: View {
    @Bindable var session: MediaV2Session
    @State private var duration = 3.0
    private var selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)? { session.selectedClip }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected, selected.track.kind == .visual,
               selected.clip.assetID.flatMap({ session.document.asset($0)?.kind }) == .video {
                if session.tool == "video.reverse" {
                    Toggle(WorkbenchText.t("反向播放", "Play in reverse"), isOn: Binding(
                        get: { selected.clip.sourcePlayback?.isReversed == true },
                        set: { run("video.reverse", flag: $0) })).frame(minHeight: 44)
                    Text(WorkbenchText.t("画面与原声一起反放。", "Reverses the picture and its source audio together."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(WorkbenchText.t("先将播放头移到要保留的画面。", "Move the playhead to the frame to hold."))
                        .font(.caption).foregroundStyle(.secondary)
                    MediaV2NumberField(title: WorkbenchText.t("定格时长", "Hold duration"), value: $duration, suffix: "s")
                    Button(WorkbenchText.t("定格当前画面", "Hold current frame")) { run("video.freeze", flag: true) }
                        .frame(minHeight: 44)
                        .disabled(session.playhead < selected.clip.timelineRange.startSeconds || session.playhead >= selected.clip.timelineRange.endSeconds)
                    if selected.clip.sourcePlayback?.holdSeconds != nil {
                        Button(WorkbenchText.t("恢复播放", "Resume source playback")) { run("video.freeze", flag: false) }.frame(minHeight: 44)
                    }
                    Text(WorkbenchText.t("定格期间不播放原声；独立配乐保留。", "Source audio is silent during a held frame. Independent music continues."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(WorkbenchText.t("请选择视频片段。", "Select a video clip.")).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(session.saving || selected?.track.isLocked == true)
            .onAppear { duration = selected?.clip.timelineRange.durationSeconds ?? 3 }
            .onChange(of: session.selectedClipID) { _, _ in duration = selected?.clip.timelineRange.durationSeconds ?? 3 }
    }
    private func run(_ id: String, flag: Bool) {
        guard let selected else { return }
        var input = MediaV2ToolInput()
        input.objectID = selected.clip.id; input.expectedRevision = session.document.revision; input.flag = flag
        if id == "video.freeze", flag { input.start = session.playhead; input.duration = duration }
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif

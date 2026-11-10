// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

/// Feature-local target selection. Import stays owned by this workspace's sheet.
struct MediaV2VisualClipTarget: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    private var tracks: [MediaPreparedTrack] { session.document.trackGraph.tracks.filter { $0.kind == .visual && !$0.clips.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected = session.selectedClip, selected.track.kind == .visual {
                HStack(spacing: 10) {
                    PersonalEditorAssetPreview(sourceID: "inspector:\(session.id):\(session.document.revision):\(selected.clip.id)",
                        title: title(selected.clip), opensQuickPreview: false) { pixels in
                        try await PersonalEditorPreviewRequests.mediaClip(session: session, track: selected.track, clip: selected.clip, pixels: pixels)
                    }.frame(width: 64, height: 48).allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(selected.clip)).font(.subheadline.weight(.medium)).lineLimit(2)
                        Label(selected.track.name, systemImage: selected.track.isLocked ? "lock.fill" : "film.stack")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if selected.track.isLocked {
                    Label(WorkbenchText.t("先解锁轨道以编辑此片段。", "Unlock the track to edit this clip."), systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(WorkbenchText.t("解锁轨道", "Unlock track"), systemImage: "lock.open") {
                        session.submit([.updateTrackFlags(id: selected.track.id, expectedRevision: selected.track.revision,
                            name: nil, isMuted: nil, isLocked: false, volume: nil)])
                    }.frame(minHeight: 44)
                }
                targetMenu
            } else if tracks.isEmpty {
                ContentUnavailableView {
                    Label(WorkbenchText.t("尚无视频素材", "No visual media"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(WorkbenchText.t("导入视频或图片后即可合成。", "Import a video or image to start compositing."))
                } actions: {
                    Button(WorkbenchText.t("导入素材", "Import media"), systemImage: "plus") { onImport() }
                        .frame(minHeight: 44)
                }
            } else {
                Label(WorkbenchText.t("选择要调整的片段", "Choose a clip to adjust"), systemImage: "cursorarrow.click")
                    .font(.subheadline.weight(.medium))
                Text(WorkbenchText.t("在时间线上点选片段，或从下方列表选择。", "Select a timeline clip or choose from the list below."))
                    .font(.caption).foregroundStyle(.secondary)
                targetMenu
            }
        }
    }
    private var targetMenu: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(tracks) { track in
                    Section(track.name) {
                        ForEach(track.clips) { clip in
                            Button { session.select(track, clip: clip) } label: {
                                Label(title(clip), systemImage: session.selectedClipID == clip.id ? "checkmark" : "film")
                            }
                        }
                    }
                }
            } label: {
                Label(WorkbenchText.t("选择片段", "Choose clip"), systemImage: "rectangle.stack")
                    .frame(minHeight: 44)
            }.disabled(tracks.isEmpty)
            Spacer(minLength: 0)
            Button(WorkbenchText.t("导入", "Import"), systemImage: "plus") { onImport() }.frame(minHeight: 44)
        }
    }
    private func title(_ clip: MediaPreparedClip) -> String {
        clip.motionTitle?.text ?? clip.captionText ?? clip.assetID.flatMap { session.document.asset($0)?.originalName } ?? WorkbenchText.t("片段", "Clip")
    }
}

struct MediaV2InspectorApplyButton: View {
    let title: String
    let isWorking: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark") }
                Text(isWorking ? WorkbenchText.t("正在保存…", "Saving…") : title)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent).disabled(isWorking)
    }
}
#endif

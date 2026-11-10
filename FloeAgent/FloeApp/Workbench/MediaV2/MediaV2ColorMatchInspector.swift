// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import ImageIO
import FloeWorkbench

struct MediaV2ColorMatchInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    @State private var referenceID: UUID?
    @State private var referenceSeconds = 0.0
    @State private var targetSeconds = 0.0
    @State private var mix = 1.0
    @State private var contrast = true
    @State private var preview: CGImage?
    @State private var previewError: String?
    @State private var viewingReference = false
    private var references: [(track: MediaPreparedTrack,clip: MediaPreparedClip)] {
        var values: [(track: MediaPreparedTrack, clip: MediaPreparedClip)] = []
        for track in session.document.trackGraph.tracks where track.kind == .visual {
            for clip in track.clips where clip.id != session.selectedClipID {
                guard let assetID = clip.assetID,
                      let kind = session.document.asset(assetID)?.kind,
                      kind == .image || kind == .video else { continue }
                values.append((track: track, clip: clip))
            }
        }
        return values
    }
    private var reference: (track: MediaPreparedTrack,clip: MediaPreparedClip)? { references.first { $0.clip.id == referenceID } }
    private var busy: Bool { session.processingTool || session.saving || session.rendering }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            MediaV2VisualClipTarget(session: session,onImport: onImport)
            if let selected = session.selectedClip, selected.track.kind == .visual, selected.clip.assetID != nil {
                if references.isEmpty {
                    ContentUnavailableView { Label(WorkbenchText.t("添加参考镜头", "Add a reference shot"),systemImage: "photo.on.rectangle.angled") }
                        description: { Text(WorkbenchText.t("导入另一段视频或图片，用它的色彩匹配当前片段。", "Import another video or image to match its colors to this clip.")) }
                        actions: { Button(WorkbenchText.t("导入素材", "Import media"),systemImage: "plus") { onImport() } }
                } else {
                    VStack(alignment: .leading,spacing: 12) {
                        Picker(WorkbenchText.t("参考镜头", "Reference shot"),selection: Binding(get: { referenceID },set: { value in referenceID = value;referenceSeconds = reference?.clip.assetID.flatMap { session.document.asset($0)?.kind } == .image ? 0 : (reference?.clip.sourceRange.startSeconds ?? 0) })) {
                            ForEach(references,id: \.clip.id) { value in
                                Text(title(value.clip,track: value.track)).tag(Optional(value.clip.id))
                            }
                        }.frame(minHeight: 44)
                        if let preview {
                            Button { viewingReference = true } label: {
                                Image(decorative: preview,scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity,maxHeight: 160).overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8).background(.regularMaterial,in: Circle()).padding(6)
                                    }
                            }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("全屏查看参考画面", "View reference frame full screen"))
                        } else if let previewError {
                            Label(WorkbenchText.t("无法读取参考画面", "Couldn’t read reference frame"),systemImage: "exclamationmark.triangle").font(.callout)
                            Text(previewError).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Button(WorkbenchText.t("重试", "Retry"),systemImage: "arrow.clockwise") { Task { await loadReference() } }.frame(minHeight: 44)
                        } else { ProgressView(WorkbenchText.t("正在读取参考画面…", "Loading reference frame…")).frame(maxWidth: .infinity,minHeight: 100) }
                        if let reference { sourceTimeControl(WorkbenchText.t("参考画面", "Reference frame"),clip: reference.clip,value: $referenceSeconds) }
                        sourceTimeControl(WorkbenchText.t("当前镜头画面", "Target frame"),clip: selected.clip,value: $targetSeconds)
                        MusicValueSlider(title: WorkbenchText.t("匹配强度", "Match strength"),value: mix,range: 0...1,suffix: "") { mix = $0 }
                        Toggle(WorkbenchText.t("同时匹配对比度", "Match contrast too"),isOn: $contrast).frame(minHeight: 44)
                        Text(WorkbenchText.t("参考片段当前的调色会固定保存到这次匹配中。", "This match captures the reference clip’s saved color treatment."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(busy || selected.track.isLocked)
                    if session.processingTool {
                        ProgressView(session.providerStatus ?? WorkbenchText.t("正在匹配…", "Matching…"))
                        Button(WorkbenchText.t("取消", "Cancel"),systemImage: "xmark.circle") { session.cancelToolProcessing() }.frame(minHeight: 44)
                    } else {
                        MediaV2InspectorApplyButton(title: WorkbenchText.t("匹配到当前片段", "Match selected clip"),isWorking: session.saving) { run(clear: false) }
                            .disabled(busy || selected.track.isLocked || reference == nil).accessibilityIdentifier("media.v2.colorMatch.apply")
                    }
                }
                if selected.clip.videoGrade?.colorMatch != nil {
                    Label(WorkbenchText.t("参考色彩已保存", "Reference colors saved"),systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button(WorkbenchText.t("移除色彩匹配", "Remove color match"),systemImage: "arrow.uturn.backward") { run(clear: true) }
                        .frame(minHeight: 44).disabled(busy || selected.track.isLocked)
                }
            }
        }.onAppear(perform: load)
            .onChange(of: session.selectedClipID) { _,_ in load() }
            .task(id: "\(referenceID?.uuidString ?? "none"):\(referenceSeconds):\(session.document.revision)") { await loadReference() }
            .sheet(isPresented: $viewingReference) {
                NavigationStack {
                    if let preview { Image(decorative: preview,scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity,maxHeight: .infinity).padding() }
                    else { ContentUnavailableView(WorkbenchText.t("参考画面暂不可用", "Reference frame unavailable"),systemImage: "photo") }
                }.toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { viewingReference = false } } }
            }
    }
    @ViewBuilder private func sourceTimeControl(_ title: String,clip: MediaPreparedClip,value: Binding<Double>) -> some View {
        if clip.assetID.flatMap({ session.document.asset($0)?.kind }) == .video {
            let fps = clip.assetID.flatMap { session.document.asset($0)?.metadata?.frameRate } ?? 30
            let start = clip.sourceRange.startSeconds, end = max(start,clip.sourceRange.endSeconds-1/max(1,fps))
            VStack(alignment: .leading,spacing: 4) {
                HStack { Text(title);Spacer();Text(value.wrappedValue,format: .number.precision(.fractionLength(2))).monospacedDigit();Text("s").foregroundStyle(.secondary) }.font(.caption)
                if end > start { Slider(value: value,in: start...end).accessibilityLabel(title) }
            }
        }
    }
    private func title(_ clip: MediaPreparedClip,track: MediaPreparedTrack) -> String {
        let name = clip.assetID.flatMap { session.document.asset($0)?.originalName } ?? track.name
        return name + " · " + clip.timelineRange.startSeconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }
    private func load() {
        let saved = session.selectedClip?.clip.videoGrade?.colorMatch
        referenceID = references.contains { $0.clip.id == saved?.referenceClipID } ? saved?.referenceClipID : references.first?.clip.id
        referenceSeconds = saved?.reference.sourceSeconds ?? reference?.clip.sourceRange.startSeconds ?? 0
        targetSeconds = saved?.target.sourceSeconds ?? session.selectedClip?.clip.sourceRange.startSeconds ?? 0
        if let clip = session.selectedClip?.clip { targetSeconds = frameTime(targetSeconds,clip: clip) }
        if let clip = reference?.clip { referenceSeconds = frameTime(referenceSeconds,clip: clip) }
        mix = saved?.mix ?? 1;contrast = saved?.matchesContrast ?? true
    }
    private func frameTime(_ seconds: Double,clip: MediaPreparedClip) -> Double {
        if clip.assetID.flatMap({ session.document.asset($0)?.kind }) == .image { return 0 }
        let fps = clip.assetID.flatMap { session.document.asset($0)?.metadata?.frameRate } ?? 30
        return min(max(clip.sourceRange.startSeconds,clip.sourceRange.endSeconds-1/max(1,fps)),max(clip.sourceRange.startSeconds,seconds))
    }
    private func loadReference() async {
        preview = nil;previewError = nil
        guard let reference else { return }
        let revision = session.document.revision, id = reference.clip.id, seconds = referenceSeconds
        do {
            try await Task.sleep(for: .milliseconds(180))
            let request = try session.colorMatchFrameRequest(clip: reference.clip,seconds: seconds,excludingMatch: false)
            let sample = try await MediaVideoColorMatchService.shared.sample(request)
            try Task.checkCancellation()
            guard session.document.revision == revision, referenceID == id, referenceSeconds == seconds else { return }
            guard let source = CGImageSourceCreateWithData(sample.previewPNG as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
                throw MediaV2CommandError.invalidInput
            }
            preview = image
        } catch is CancellationError { }
        catch { if session.document.revision == revision, referenceID == id { previewError = error.localizedDescription } }
    }
    private func run(clear: Bool) {
        var input = MediaV2ToolInput();input.objectID = session.selectedClipID;input.expectedRevision = session.document.revision
        if clear { input.flag = false }
        else { input.property = referenceID?.uuidString;input.start = targetSeconds;input.secondary = referenceSeconds;input.number = mix;input.text = contrast ? "color-and-contrast" : "color" }
        Task { do { _ = try await session.performTool("video.color-match",input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif

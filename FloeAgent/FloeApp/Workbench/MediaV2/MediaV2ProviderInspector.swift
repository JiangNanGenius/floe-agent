// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2ProviderInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    let onImportCaptions: () -> Void
    let onConfigure: () -> Void
    @State private var prompt = ""
    @State private var modelID: UUID?
    @State private var language = "简体中文"
    @State private var customLanguage = ""
    private var capability: MediaV2ProviderBridge.Capability { MediaV2Session.providerCapability(for:session.tool) ?? .imageEditing }
    private var configured: Bool { MediaV2ProviderBridge.capabilities.contains(capability) }
    var body: some View {
        VStack(alignment: .leading,spacing: 14) {
            if session.tool == "image.outpaint" { MediaV2OutpaintInspector(session:session,configured:configured,onImport:onImport) }
            else if session.tool == "image.inpaint" { imageControls }
            else if session.tool == "video.transcribe" { transcriptionControls }
            else if session.tool == "video.voice-separate" { MediaV2VoiceSeparationInspector(session:session) }
            else { translationControls }
            if !configured {
                Label(WorkbenchText.t("先配置所需的模型或语音服务。", "Configure the required model or speech service first."),systemImage:"slider.horizontal.3").font(.callout)
                Button(WorkbenchText.t("打开服务设置", "Open service settings"),systemImage:"gearshape") { onConfigure() }.frame(minHeight:44)
            }
            if session.processingTool {
                ProgressView(session.providerStatus ?? WorkbenchText.t("正在处理…", "Processing…"))
                Button(WorkbenchText.t("取消处理", "Cancel processing"),systemImage:"xmark.circle") { session.cancelToolProcessing() }.frame(minHeight:44)
            }
        }.onChange(of:session.selectedLayerID) { _,_ in prompt = "" }
    }
    @ViewBuilder private var imageControls: some View {
        if let layer = session.selectedLayer {
            Label(layer.name,systemImage:layer.isLocked ? "lock.fill":"photo.on.rectangle").font(.subheadline.weight(.medium))
            if layer.isLocked {
                Button(WorkbenchText.t("解锁图层", "Unlock layer"),systemImage:"lock.open") { session.submit([.updateLayerFlags(id:layer.id,expectedRevision:layer.revision,name:nil,isVisible:nil,isLocked:false,opacity:nil)]) }.frame(minHeight:44)
            }
            Menu {
                ForEach(session.document.layers.filter { $0.parentID == nil && $0.contentKind != .group }) { target in
                    Button { session.select(target) } label: { Label(target.name,systemImage:target.id == layer.id ? "checkmark":"photo") }
                }
            } label: { Label(WorkbenchText.t("选择图层", "Choose layer"),systemImage:"square.3.layers.3d").frame(minHeight:44) }
            if layer.parentID != nil || layer.contentKind == .group {
                Text(WorkbenchText.t("请选择独立的图片、绘画或文字图层。", "Choose an individual image, drawing or text layer.")).font(.caption).foregroundStyle(.secondary)
            }
            if session.selection == nil {
                Text(WorkbenchText.t("先框选需要重绘的区域，选区外画面会保留。", "Select the area to redraw. Pixels outside it are retained.")).font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("选择重绘区域", "Select edit area"),systemImage:"rectangle.dashed") { session.tool = "image.rectangle" }.frame(minHeight:44)
            } else { Label(WorkbenchText.t("已选定重绘区域", "Edit area selected"),systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment:.leading,spacing:6) {
                Text(WorkbenchText.t("希望如何修改？", "What should change?")).font(.subheadline.weight(.medium))
                TextField(WorkbenchText.t("例如：把选中的花改成白色雏菊", "For example: replace the selected flowers with white daisies"),text:$prompt,axis:.vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
            }
            Picker(WorkbenchText.t("图像模型", "Image model"),selection:$modelID) {
                Text(WorkbenchText.t("使用默认模型", "Use default model")).tag(Optional<UUID>.none)
                ForEach(MediaV2ProviderBridge.imageRoutes) { route in Text(route.title).tag(Optional(route.id)) }
            }
            Button { run() } label: { Label(WorkbenchText.t("重绘所选区域", "Redraw selection"),systemImage:"sparkles").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!configured || layer.isLocked || layer.parentID != nil || layer.contentKind == .group || session.selection == nil || prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || session.processingTool || session.saving)
        } else {
            ContentUnavailableView {
                Label(WorkbenchText.t("选择图片图层", "Select an image layer"),systemImage:"photo.on.rectangle")
            } description: { Text(WorkbenchText.t("导入图片后选择需要编辑的图层。", "Import an image and select the layer to edit.")) }
            actions: { Button(WorkbenchText.t("导入图片", "Import image"),systemImage:"plus",action:onImport).frame(minHeight:44) }
        }
    }
    private var transcriptionControls: some View {
        VStack(alignment:.leading,spacing:12) {
            MediaV2TranscriptionTarget(session:session,onImport:onImport)
            Text(WorkbenchText.t("将片段中的语音保存为新字幕轨；已有字幕会保留。", "Save the clip's speech as a new caption track, retaining existing captions.")).font(.caption).foregroundStyle(.secondary)
            Button { run() } label: { Label(WorkbenchText.t("转写所选片段", "Transcribe selected clip"),systemImage:"waveform.badge.mic").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(!configured || !canTranscribe || session.processingTool || session.saving)
        }
    }
    private var canTranscribe: Bool {
        guard let selected=session.selectedClip,[.visual,.audio].contains(selected.track.kind),!selected.track.isLocked,let id=selected.clip.assetID,let asset=session.document.asset(id) else { return false }
        return [.video,.audio].contains(asset.kind) && selected.clip.sourcePlayback?.isReversed != true && selected.clip.sourcePlayback?.holdSeconds == nil
    }
    private var captionTracks: [MediaPreparedTrack] { session.document.trackGraph.tracks.filter{$0.kind == .caption && !$0.clips.isEmpty} }
    private var translationControls: some View {
        VStack(alignment:.leading,spacing:12) {
            if captionTracks.isEmpty {
                ContentUnavailableView {
                    Label(WorkbenchText.t("尚无字幕", "No captions yet"),systemImage:"captions.bubble")
                } description: { Text(WorkbenchText.t("先转写片段或导入字幕，再创建翻译。", "Transcribe a clip or import captions before translating.")) }
                actions: {
                    Button(WorkbenchText.t("转写片段", "Transcribe a clip"),systemImage:"waveform") { session.tool="video.transcribe" }.frame(minHeight:44)
                    Button(WorkbenchText.t("导入字幕", "Import captions"),systemImage:"doc.badge.plus",action:onImportCaptions).frame(minHeight:44)
                }
            } else {
                Picker(WorkbenchText.t("字幕轨", "Caption track"),selection:Binding(get:{session.selectedTrack?.kind == .caption ? session.selectedTrackID:nil},set:{id in if let track=captionTracks.first(where:{$0.id == id}) { session.select(track) }})) {
                    Text(WorkbenchText.t("选择字幕轨", "Choose caption track")).tag(Optional<UUID>.none)
                    ForEach(captionTracks) { track in Text(track.name).tag(Optional(track.id)) }
                }
                if let track=session.selectedTrack,track.kind == .caption {
                    Label(WorkbenchText.t("\(track.clips.count) 段字幕", "\(track.clips.count) captions"),systemImage:"text.bubble").font(.caption).foregroundStyle(.secondary)
                    if let first=track.clips.first?.captionText { Text(first).font(.caption).lineLimit(3).textSelection(.enabled) }
                    if track.isLocked { Button(WorkbenchText.t("解锁轨道", "Unlock track"),systemImage:"lock.open") { session.submit([.updateTrackFlags(id:track.id,expectedRevision:track.revision,name:nil,isMuted:nil,isLocked:false,volume:nil)]) }.frame(minHeight:44) }
                }
                Picker(WorkbenchText.t("翻译成", "Translate into"),selection:$language) {
                    ForEach(["简体中文","繁體中文","English","日本語","한국어","Français","Deutsch","Español","Other"],id:\.self) { language in Text(language == "Other" ? WorkbenchText.t("其他语言", "Other language"):language).tag(language) }
                }
                if language == "Other" { TextField(WorkbenchText.t("目标语言", "Target language"),text:$customLanguage).textFieldStyle(.roundedBorder) }
                Text(WorkbenchText.t("另建翻译字幕轨，保留原文和时间位置。", "Create a new translated track, retaining the source text and timing.")).font(.caption).foregroundStyle(.secondary)
                Button { run() } label: { Label(WorkbenchText.t("翻译字幕轨", "Translate caption track"),systemImage:"character.bubble").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).disabled(!configured || session.selectedTrack?.kind != .caption || session.selectedTrack?.isLocked == true || session.processingTool || session.saving || targetLanguage.isEmpty)
            }
        }
    }
    private var targetLanguage: String { (language == "Other" ? customLanguage:language).trimmingCharacters(in:.whitespacesAndNewlines) }
    private func run() {
        var input=MediaV2ToolInput();input.expectedRevision=session.document.revision
        if session.tool == "image.inpaint" { input.objectID=session.selectedLayerID;input.text=prompt;input.property=modelID?.uuidString }
        else if session.tool == "video.transcribe" { input.objectID=session.selectedClipID }
        else { input.objectID=session.selectedTrackID;input.text=targetLanguage }
        let tool=session.tool
        Task { do { _ = try await session.performTool(tool,input:input) } catch { session.diagnostic=error.localizedDescription } }
    }
}

private struct MediaV2TranscriptionTarget: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    private var tracks: [MediaPreparedTrack] { session.document.trackGraph.tracks.filter { [.visual,.audio].contains($0.kind) } }
    private func clips(_ track: MediaPreparedTrack) -> [MediaPreparedClip] { track.clips.filter { $0.assetID.flatMap{session.document.asset($0)?.kind}.map{[.video,.audio].contains($0)} ?? false } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if let selected=session.selectedClip,let assetID=selected.clip.assetID,let asset=session.document.asset(assetID),[.video,.audio].contains(asset.kind) {
                HStack(spacing:10) {
                    PersonalEditorAssetPreview(sourceID:"asr:\(session.id):\(session.document.revision):\(selected.clip.id)",title:asset.originalName,opensQuickPreview:false) { pixels in
                        try await PersonalEditorPreviewRequests.mediaClip(session:session,track:selected.track,clip:selected.clip,pixels:pixels)
                    }.frame(width:64,height:48).allowsHitTesting(false)
                    Text(asset.originalName).font(.subheadline.weight(.medium)).lineLimit(2)
                }
                if selected.track.isLocked {
                    Button(WorkbenchText.t("解锁轨道", "Unlock track"),systemImage:"lock.open") { session.submit([.updateTrackFlags(id:selected.track.id,expectedRevision:selected.track.revision,name:nil,isMuted:nil,isLocked:false,volume:nil)]) }.frame(minHeight:44)
                }
                if selected.clip.sourcePlayback?.isReversed == true || selected.clip.sourcePlayback?.holdSeconds != nil {
                    Label(WorkbenchText.t("请选择正向播放的片段或原始音频。", "Select forward playback or the original audio."),systemImage:"arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                }
            }
            Menu {
                ForEach(tracks) { track in
                    Section(track.name) {
                        ForEach(clips(track)) { clip in Button { session.select(track,clip:clip) } label: { Label(clip.assetID.flatMap{session.document.asset($0)?.originalName} ?? WorkbenchText.t("片段", "Clip"),systemImage:session.selectedClipID == clip.id ? "checkmark":"waveform") } }
                    }
                }
            } label: { Label(WorkbenchText.t("选择音频或视频片段", "Choose audio or video clip"),systemImage:"rectangle.stack").frame(minHeight:44) }
            Button(WorkbenchText.t("导入素材", "Import media"),systemImage:"plus",action:onImport).frame(minHeight:44)
        }
    }
}
#endif

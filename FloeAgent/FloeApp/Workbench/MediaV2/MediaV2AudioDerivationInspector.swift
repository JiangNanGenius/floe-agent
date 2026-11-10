// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMedia
import FloeTools
import FloeWorkbench

struct MediaV2AudioDerivationInspector: View {
    @Bindable var session: MediaV2Session
    @State private var noise = AudioSpectralDenoiseSettings()
    @State private var duck = AudioDuckingSettings()
    @State private var useNoiseSample = false
    @State private var noiseStart = 0.0
    @State private var noiseDuration = 0.5
    @State private var narrationID: UUID?
    @State private var waveform: AudioWaveformInspection?
    @State private var waveformError: String?
    private var isDucking: Bool { session.tool == "video.duck" }
    private var busy: Bool { session.saving || session.processingTool }
    private var selectedAudio: (track: MediaPreparedTrack, clip: MediaPreparedClip)? {
        guard let selected = session.selectedClip, selected.track.kind == .audio else { return nil }
        return selected
    }
    private var narrationChoices: [(track: MediaPreparedTrack, clip: MediaPreparedClip)] {
        session.document.trackGraph.tracks.filter { ($0.kind == .audio || $0.kind == .visual) && !$0.isLocked && !$0.isMuted && $0.volume > 0 }
            .flatMap { track in track.clips.filter { clip in
                guard clip.id != session.selectedClipID, !clip.isMuted, clip.volume > 0, clip.sourcePlayback?.holdSeconds == nil,
                      let assetID = clip.assetID, let asset = session.document.asset(assetID),
                      asset.kind == .audio || (asset.kind == .video && asset.metadata?.audioTracks != 0),
                      let target = selectedAudio?.clip else { return false }
                return min(target.timelineRange.endSeconds, clip.timelineRange.endSeconds) > max(target.timelineRange.startSeconds, clip.timelineRange.startSeconds)
            }.map { (track, $0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selected = selectedAudio {
                sourcePreview(selected)
                Group {
                    if isDucking { duckControls } else { noiseControls(selected.clip) }
                }.disabled(busy || selected.track.isLocked)
                if session.processingTool {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(session.providerStatus ?? WorkbenchText.t("正在处理音频…", "Processing audio…")).font(.callout)
                        Spacer(minLength: 0)
                        Button(WorkbenchText.t("取消", "Cancel")) { session.cancelToolProcessing() }.frame(minHeight: 44)
                    }
                } else {
                    Button(action: apply) {
                        Label(WorkbenchText.t("应用并保存", "Apply and save"), systemImage: isDucking ? "speaker.wave.2.fill" : "waveform")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                        .disabled(busy || selected.track.isLocked || (isDucking && narrationID == nil))
                }
                Text(WorkbenchText.t("保留原始音频，可撤销。", "Keeps the original audio. You can undo this edit."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let selected = session.selectedClip, selected.track.kind == .visual {
                Label(WorkbenchText.t("编辑视频原声", "Edit source audio"), systemImage: "waveform").font(.subheadline)
                Text(WorkbenchText.t("先分离此片段的原声，再调整音频。", "Separate this clip’s source audio before adjusting it."))
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { do { let audio = try await session.editableSourceAudio(for: selected.clip.id); session.select(audio.track, clip: audio.clip) }
                        catch { session.diagnostic = error.localizedDescription } }
                } label: { Label(WorkbenchText.t("分离并选择原声", "Separate and select audio"), systemImage: "waveform.path") }
                    .buttonStyle(.bordered).frame(minHeight: 44).disabled(busy || selected.track.isLocked)
            } else {
                ContentUnavailableView(WorkbenchText.t("选择音频片段", "Select an audio clip"), systemImage: "waveform",
                    description: Text(WorkbenchText.t("在时间轴中选择配乐、录音或带原声的视频。", "Choose music, a recording, or a video with source audio in the timeline.")))
            }
        }.onChange(of: session.selectedClipID) { _, _ in
            waveform = nil; waveformError = nil
            noiseStart = 0; noiseDuration = min(0.5, selectedAudio?.clip.sourceRange.durationSeconds ?? 0.5)
            if !narrationChoices.contains(where: { $0.clip.id == narrationID }) { narrationID = nil }
        }
    }
    private func sourcePreview(_ selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(selected.track.name, systemImage: "waveform").font(.subheadline).lineLimit(2)
                Spacer()
                Text(String(format: "%.2f s", selected.clip.timelineRange.durationSeconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                if let waveform {
                    Canvas { context, size in
                        let bins = waveform.window.effectiveBins, count = waveform.channels.count
                        guard bins > 0, count > 0 else { return }
                        for (channelIndex, channel) in waveform.channels.enumerated() {
                            let height = size.height / CGFloat(count), center = CGFloat(channelIndex) * height + height / 2
                            var path = Path()
                            for index in 0..<min(bins, min(channel.binMin.count, channel.binMax.count)) {
                                let x = (CGFloat(index) + 0.5) * size.width / CGFloat(bins)
                                path.move(to: .init(x: x, y: center - CGFloat(min(1, max(-1, channel.binMax[index]))) * height * 0.44))
                                path.addLine(to: .init(x: x, y: center - CGFloat(min(1, max(-1, channel.binMin[index]))) * height * 0.44))
                            }
                            context.stroke(path, with: .color(.accentColor), lineWidth: max(1, size.width / CGFloat(bins) * 0.65))
                        }
                    }.padding(8).accessibilityLabel(WorkbenchText.t("所选原声音频波形", "Selected source audio waveform"))
                } else if let waveformError { Label(waveformError, systemImage: "waveform.slash").font(.caption).foregroundStyle(.secondary).padding(10) }
                else { ProgressView().controlSize(.small) }
            }.frame(height: 88)
            if let waveform {
                Text(String(format: WorkbenchText.t("原声 %.2f–%.2f 秒", "Source %.2f–%.2f s"), waveform.window.startSeconds, waveform.window.endSeconds))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }.task(id: previewIdentity(selected.clip)) { await loadWaveform(selected.clip) }
    }
    private var duckControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(WorkbenchText.t("旁白", "Narration"), selection: $narrationID) {
                Text(WorkbenchText.t("选择旁白片段", "Choose narration")).tag(Optional<UUID>.none)
                ForEach(narrationChoices, id: \.clip.id) { item in
                    Text(item.track.name + " · " + String(format: "%.2f s", item.clip.timelineRange.startSeconds)).tag(Optional(item.clip.id))
                }
            }.pickerStyle(.menu).frame(minHeight: 44)
            if narrationChoices.isEmpty {
                Text(WorkbenchText.t("添加旁白并与配乐在时间轴上对齐。旁白需要取消静音。", "Add narration overlapping the music in the timeline, and unmute it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            MusicValueSlider(title: WorkbenchText.t("配乐压低", "Music reduction"), value: duck.reductionDB, range: 0...30, suffix: "dB") { duck.reductionDB = $0 }
            MusicValueSlider(title: WorkbenchText.t("旁白触发音量", "Narration threshold"), value: duck.thresholdDB, range: -70...(-6), suffix: "dB") { duck.thresholdDB = $0 }
            DisclosureGroup(WorkbenchText.t("淡入淡出", "Envelope")) {
                MusicValueSlider(title: WorkbenchText.t("压低速度", "Attack"), value: duck.attackSeconds * 1000, range: 1...500, suffix: "ms") { duck.attackSeconds = $0 / 1000 }
                MusicValueSlider(title: WorkbenchText.t("恢复时间", "Recovery"), value: duck.releaseSeconds * 1000, range: 10...3000, suffix: "ms") { duck.releaseSeconds = $0 / 1000 }
                MusicValueSlider(title: WorkbenchText.t("保持时间", "Hold"), value: duck.holdSeconds * 1000, range: 0...1000, suffix: "ms") { duck.holdSeconds = $0 / 1000 }
            }
        }
    }
    private func noiseControls(_ clip: MediaPreparedClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MusicValueSlider(title: WorkbenchText.t("降噪强度", "Noise reduction"), value: noise.amount, range: 0...1) { noise.amount = $0 }
            MusicValueSlider(title: WorkbenchText.t("最多减少", "Maximum reduction"), value: noise.maximumReductionDB, range: 0...30, suffix: "dB") { noise.maximumReductionDB = $0 }
            Toggle(WorkbenchText.t("使用一段纯噪声作为样本", "Use a noise-only sample"), isOn: $useNoiseSample).frame(minHeight: 44)
            if useNoiseSample {
                MusicValueSlider(title: WorkbenchText.t("样本起点", "Sample start"), value: noiseStart,
                    range: 0...max(0.05, clip.sourceRange.durationSeconds - 0.05), suffix: "s") { noiseStart = $0 }
                MusicValueSlider(title: WorkbenchText.t("样本时长", "Sample duration"), value: noiseDuration,
                    range: 0.05...max(0.05, min(5, clip.sourceRange.durationSeconds - noiseStart)), suffix: "s") { noiseDuration = $0 }
            }
            DisclosureGroup(WorkbenchText.t("使用建议", "Tips")) {
                Text(WorkbenchText.t("纯噪声样本不应包含需要保留的人声或音乐。强度过高可能削弱声音细节。", "A noise sample should contain no voice or music you want to keep. Strong reduction can remove audio detail."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func apply() {
        guard let target = selectedAudio else { return }
        var input = MediaV2ToolInput(); input.objectID = target.clip.id; input.expectedRevision = session.document.revision
        if isDucking { input.property = narrationID?.uuidString; input.dialogueDucking = duck }
        else {
            var value = noise
            value.noiseOnlyRange = useNoiseSample ? .init(startSeconds: noiseStart, durationSeconds: noiseDuration) : nil
            input.noiseReduction = value
        }
        let toolID = session.tool
        Task { do { _ = try await session.performTool(toolID, input: input) }
            catch is CancellationError {}
            catch let error as AudioPCMProcessingError {
                switch error {
                case .cancelled: break
                case .changedSource: session.diagnostic = WorkbenchText.t("原始音频已变化，请重新选择后重试。", "The source audio changed. Select it again and retry.")
                case .limitExceeded: session.diagnostic = WorkbenchText.t("这段音频较长，请先裁剪后处理。", "This audio exceeds the processing limit. Trim it before processing.")
                default: session.diagnostic = WorkbenchText.t("请检查音频和噪声样本的范围后重试。", "Check the audio and noise sample ranges, then retry.")
                }
            }
            catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func previewIdentity(_ clip: MediaPreparedClip) -> String {
        "\(clip.id)/\(clip.revision)/\(clip.assetID?.uuidString ?? "")/\(clip.assetID.flatMap { session.document.assetRevisions?[$0] } ?? 0)/\(clip.assetID.flatMap { session.document.asset($0)?.contentHash } ?? "")/\(clip.sourceRange.startSeconds)/\(clip.sourceRange.durationSeconds)"
    }
    private func loadWaveform(_ clip: MediaPreparedClip) async {
        waveform = nil; waveformError = nil
        let token = CancellationToken(), documentID = session.id
        do {
            guard let assetID = clip.assetID, let asset = session.document.asset(assetID), asset.kind == .audio else { throw MediaV2CommandError.missingSelection }
            let root = session.root.standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard !asset.relativePath.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { throw MediaV2CommandError.invalidInput }
            let report = try await withTaskCancellationHandler {
                try await AudioWaveformInspector().inspectNativePreview(at: url, sourceReference: "audio-editor/\(documentID)/\(clip.id)", expectedSHA256: asset.contentHash,
                    startSeconds: clip.sourceRange.startSeconds, endSeconds: clip.sourceRange.startSeconds + min(30, clip.sourceRange.durationSeconds), bins: 160,
                    cancellation: token, validateSource: { @MainActor in
                        guard session.id == documentID, session.document.trackGraph.clip(id: clip.id)?.clip == clip,
                              session.document.asset(assetID) == asset else { throw MediaPreparedCoreError.documentChanged }
                    })
            } onCancel: { token.cancel() }
            try Task.checkCancellation()
            guard session.selectedClipID == clip.id else { return }; waveform = report
        } catch {
            if !Task.isCancelled { waveformError = WorkbenchText.t("无法预览此音频", "Audio preview unavailable") }
        }
    }
}
#endif

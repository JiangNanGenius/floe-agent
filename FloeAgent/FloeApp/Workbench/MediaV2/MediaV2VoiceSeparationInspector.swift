// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMedia
import FloeTools
import FloeWorkbench

/// M55 `video.voice-separate` controls. One feature, two real routes:
/// an installed local CoreML stem bundle (shared ModelArtifactStore) or the
/// user-configured Music.AI service. Long cloud work is owned by the session
/// service worker; this view only displays status and issues start/stop.
struct MediaV2VoiceSeparationInspector: View {
    @Bindable var session: MediaV2Session
    @ObservedObject private var settings: MusicAIStemSettingsStore
    init(session: MediaV2Session, settings: MusicAIStemSettingsStore = MusicAIStemSettingsStore.shared) {
        self.session = session; self.settings = settings
    }
    private enum Route: Hashable { case automatic, local, cloud }
    @State private var route: Route = .automatic
    @State private var models: [MediaV2StemLocalBridge.Model] = []
    @State private var selectedModelID: String?
    @State private var outstanding: [AudioStemCloudReceipt] = []
    @State private var waveform: AudioWaveformInspection?
    @State private var waveformError: String?
    @State private var importing = false
    @State private var showSettings = false
    @State private var receipt: MediaV2VoiceSeparationReceipt?
    private var busy: Bool { session.saving || session.processingTool }
    private var selectedAudio: (track: MediaPreparedTrack, clip: MediaPreparedClip)? {
        guard let selected = session.selectedClip, selected.track.kind == .audio, !selected.track.isLocked else { return nil }
        return selected
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selected = selectedAudio {
                sourcePreview(selected)
                controls
                recovery
                applyArea(selected)
                if let receipt { receiptSummary(receipt) }
                Text(WorkbenchText.t("原始音频保留并静音，新增人声与伴奏两条音轨；此操作可撤销。",
                    "The original stays in place (muted) and two new tracks — vocals and accompaniment — are added. You can undo this."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let selected = session.selectedClip, selected.track.kind == .visual {
                Label(WorkbenchText.t("编辑视频原声", "Edit source audio"), systemImage: "waveform").font(.subheadline)
                Text(WorkbenchText.t("应用时会直接处理此视频片段的原声区间。", "Applying separates the source audio interval of this video clip."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(WorkbenchText.t("选择音频片段", "Select an audio clip"), systemImage: "waveform",
                    description: Text(WorkbenchText.t("在时间轴中选择要分离人声的配乐、录音或带原声的视频。",
                        "Choose the music, recording or video-with-audio you want to separate in the timeline.")))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): importBundle(urls.first)
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
        .sheet(isPresented: $showSettings) { MusicAIStemSettingsView() }
        .task(id: session.selectedClipID) { await refreshState() }
    }
    private func sourcePreview(_ selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(selected.track.name, systemImage: "waveform").font(.subheadline).lineLimit(2)
                Spacer()
                Text(String(format: "%.2f s", selected.clip.sourceRange.durationSeconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(WorkbenchText.t("分离方式", "Separation route"), selection: $route) {
                Text(WorkbenchText.t("自动（优先本地模型）", "Automatic (local model first)")).tag(Route.automatic)
                Text(WorkbenchText.t("本地 CoreML 模型", "Local CoreML model")).tag(Route.local)
                Text(WorkbenchText.t("Music.AI 云端", "Music.AI (cloud)")).tag(Route.cloud)
            }.pickerStyle(.menu).frame(minHeight: 44).disabled(busy)
            if route == .local || route == .automatic {
                VStack(alignment: .leading, spacing: 8) {
                    if models.isEmpty {
                        Text(WorkbenchText.t("尚未导入兼容的本地模型。模型需符合本 App 的波形分离合同（manifest/contract/model.mlmodelc）。",
                            "No compatible local model yet. A model must match this App's waveform separation bundle contract (manifest/contract/model.mlmodelc)."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker(WorkbenchText.t("本地模型", "Local model"), selection: $selectedModelID) {
                            Text(WorkbenchText.t("自动（仅此一个）", "Automatic (the only one)")).tag(Optional<String>.none)
                            ForEach(models) { model in Text(model.id + " · " + model.version).tag(Optional(model.id)) }
                        }.pickerStyle(.menu).frame(minHeight: 44).disabled(busy)
                        if models.count > 1 && selectedModelID == nil && route == .automatic {
                            Text(WorkbenchText.t("已安装多个模型，请指定一个。", "Several models are installed; choose one.")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { importing = true } label: {
                            Label(WorkbenchText.t("导入模型…", "Import model…"), systemImage: "square.and.arrow.down").frame(minHeight: 44)
                        }.buttonStyle(.bordered).disabled(busy)
                        if let selectedModelID, models.contains(where: { $0.id == selectedModelID }) {
                            Button(WorkbenchText.t("移除所选模型", "Remove selected"), role: .destructive) {
                                Task { do { try await MediaV2StemLocalBridge.remove(selectedModelID); await refreshState() }
                                    catch { session.diagnostic = error.localizedDescription } }
                            }.frame(minHeight: 44).disabled(busy)
                        }
                    }
                }
            }
            if route == .cloud || route == .automatic {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.isReady {
                        Label(WorkbenchText.t("Music.AI 已配置；只上传所选片段的冻结区间（≤128 MiB）。",
                            "Music.AI configured; only the frozen selected interval (≤128 MiB) is uploaded."), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if route == .automatic && !models.isEmpty {
                        EmptyView()
                    } else {
                        Label(WorkbenchText.t("Music.AI 未配置。", "Music.AI is not configured."), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                        Button(WorkbenchText.t("打开 Music.AI 设置", "Open Music.AI settings")) { showSettings = true }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
            }
        }
    }
    @ViewBuilder private var recovery: some View {
        if let pending = outstanding.first(where: { $0.clipID == session.selectedClipID }) {
            VStack(alignment: .leading, spacing: 8) {
                Label(WorkbenchText.t("有一个属于此片段的云端任务", "An owned cloud job exists for this clip"), systemImage: "icloud.and.arrow.forecast")
                    .font(.subheadline)
                Text(voiceSeparationStateText(pending)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(WorkbenchText.t("继续并保存", "Continue and save")) {
                        Task { await run { try await session.resumeVoiceSeparationJob(clipID: pending.clipID) } }
                    }.buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy)
                    Button(WorkbenchText.t("停止等待", "Stop waiting")) {
                        Task { do { try await session.detachVoiceSeparationJob(clipID: pending.clipID,
                            reason: WorkbenchText.t("用户停止等待", "user stopped waiting")); await refreshState() }
                            catch { session.diagnostic = error.localizedDescription } }
                    }.frame(minHeight: 44).disabled(busy)
                    Button(WorkbenchText.t("删除远端记录", "Delete remote record")) {
                        Task { do { try await session.releaseVoiceSeparationJob(clipID: pending.clipID); await refreshState() }
                            catch { session.diagnostic = error.localizedDescription } }
                    }.frame(minHeight: 44).disabled(busy)
                }
                Text(WorkbenchText.t("删除远端记录只清除本服务拥有的任务与结果存储，不承诺撤销已产生的费用。",
                    "Deleting removes only this service's own remote job and stored results. It does not claim to revoke charges already incurred."))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        }
    }
    private func applyArea(_ selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)) -> some View {
        VStack(spacing: 10) {
            if session.processingTool {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(session.providerStatus ?? WorkbenchText.t("正在分离人声…", "Separating voice…")).font(.callout)
                        .lineLimit(2).animation(nil)
                    Spacer(minLength: 0)
                    Button(WorkbenchText.t("取消", "Cancel")) { session.cancelToolProcessing() }.frame(minHeight: 44)
                }
            } else {
                Button { runSeparation(selected) } label: {
                    Label(WorkbenchText.t("分离人声并保存", "Separate and save"), systemImage: "person.wave.2.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                    .disabled(busy || route == .local && models.isEmpty ||
                        route == .cloud && !settings.isReady ||
                        route == .automatic && models.isEmpty && !settings.isReady)
            }
        }
    }
    private func receiptSummary(_ receipt: MediaV2VoiceSeparationReceipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(WorkbenchText.t(receipt.route == "music-ai" ? "云端分离完成" : "本地分离完成",
                receipt.route == "music-ai" ? "Cloud separation finished" : "Local separation finished"), systemImage: "checkmark.seal")
                .font(.subheadline)
            ForEach(receipt.limitations, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func runSeparation(_ selected: (track: MediaPreparedTrack, clip: MediaPreparedClip)) {
        run {
            var input = MediaV2ToolInput()
            input.objectID = selected.clip.id
            input.expectedRevision = session.document.revision
            switch route {
            case .automatic: input.voiceSeparation = nil
            case .local: input.voiceSeparation = AudioVoiceSeparationSelection(mode: .localModel, modelID: selectedModelID)
            case .cloud: input.voiceSeparation = AudioVoiceSeparationSelection(mode: .musicAI)
            }
            let toolID = session.tool
            return try await session.performTool(toolID, input: input)
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> MediaV2ToolReceipt) {
        Task {
            do {
                let result = try await operation()
                receipt = result.voiceSeparation
                await refreshState()
            } catch is CancellationError {}
            catch let error as AudioPCMProcessingError {
                switch error {
                case .cancelled: break
                case .changedSource: session.diagnostic = WorkbenchText.t("原始音频已变化，请重新选择后重试。", "The source audio changed. Select it again and retry.")
                case .limitExceeded: session.diagnostic = WorkbenchText.t("这段音频超过处理上限，请先裁剪后处理。", "This audio exceeds the processing bound. Trim it first.")
                default: session.diagnostic = WorkbenchText.t("请检查所选片段后重试。", "Check the selected clip and retry.")
                }
            } catch let error as AudioStemCloudError {
                switch error {
                case .noOwnedJob: session.diagnostic = WorkbenchText.t("这个云端任务已不属于此片段。", "That cloud job no longer belongs to this clip.")
                case .timedOut: session.diagnostic = WorkbenchText.t("云端仍在处理；稍后可用“继续并保存”恢复，不会重复创建付费任务。",
                    "The cloud is still working. Use “Continue and save” later; no duplicate paid job is created.")
                case .providerFailure(let message): session.diagnostic = message
                default: session.diagnostic = error.localizedDescription
                }
            } catch let error as MusicAIStemError {
                switch error {
                case .missingConfiguration(let key): session.diagnostic = key == "apiKey"
                    ? WorkbenchText.t("请先在设置中保存 Music.AI 密钥。", "Save the Music.AI key in settings first.")
                    : WorkbenchText.t("Music.AI 配置不完整。", "The Music.AI configuration is incomplete.")
                case .httpStatus(let code): session.diagnostic = String(format: WorkbenchText.t("Music.AI 返回错误 %d。", "Music.AI returned error %d."), code)
                default: session.diagnostic = error.localizedDescription
                }
            }
            catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func importBundle(_ directory: URL?) {
        guard let directory else { return }
        Task {
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            do {
                let model = try await MediaV2StemLocalBridge.importBundle(directory)
                if selectedModelID == nil { selectedModelID = model.id }
                await refreshState()
            } catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func refreshState() async {
        models = await MediaV2StemLocalBridge.models()
        if let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) { self.selectedModelID = nil }
        do { outstanding = try await session.outstandingVoiceSeparationJobs() } catch { outstanding = [] }
        await loadWaveform()
    }
    private func loadWaveform() async {
        waveform = nil; waveformError = nil
        guard let selected = selectedAudio, let assetID = selected.clip.assetID,
              let asset = session.document.asset(assetID), asset.kind == .audio else { return }
        let token = CancellationToken(), documentID = session.id, clipID = selected.clip.id, clip = selected.clip
        do {
            let root = session.root.standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard !asset.relativePath.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { throw MediaV2CommandError.invalidInput }
            let report = try await withTaskCancellationHandler {
                try await AudioWaveformInspector().inspectNativePreview(at: url,
                    sourceReference: "voice-separate/\(documentID)/\(clipID)", expectedSHA256: asset.contentHash,
                    startSeconds: clip.sourceRange.startSeconds,
                    endSeconds: clip.sourceRange.startSeconds + min(30, clip.sourceRange.durationSeconds), bins: 160,
                    cancellation: token, validateSource: { @MainActor in
                        guard session.id == documentID, session.document.trackGraph.clip(id: clipID)?.clip == clip,
                              session.document.asset(assetID) == asset else { throw MediaPreparedCoreError.documentChanged }
                    })
            } onCancel: { token.cancel() }
            try Task.checkCancellation()
            guard session.selectedClipID == clipID else { return }
            waveform = report
        } catch {
            if !Task.isCancelled { waveformError = WorkbenchText.t("无法预览此音频", "Audio preview unavailable") }
        }
    }
    private func voiceSeparationStateText(_ receipt: AudioStemCloudReceipt) -> String {
        let age = Int(Date().timeIntervalSince(receipt.updatedAt))
        switch receipt.state {
        case .detached: return String(format: WorkbenchText.t("已停止等待（%d 秒前更新）；可继续轮询此拥有任务。", "Waiting stopped (updated %d s ago); polling can resume this owned job."), age)
        case .polling, .created, .submitting: return String(format: WorkbenchText.t("云端处理中（%d 秒前更新）。", "Still working in the cloud (updated %d s ago)."), age)
        case .succeeded: return WorkbenchText.t("云端已完成，等待下载与保存。", "The cloud finished; download and save are pending.")
        case .downloaded: return WorkbenchText.t("结果已下载校验，等待保存到项目。", "Results were downloaded and verified; saving to the project is pending.")
        case .committed, .released, .failed: return WorkbenchText.t("此记录已结束。", "This record has finished.")
        }
    }
}
#endif

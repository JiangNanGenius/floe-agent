// SPDX-License-Identifier: MPL-2.0

import AppKit
import AVKit
import FloeCore
import FloeProviders
import SwiftUI
import UniformTypeIdentifiers

// Compact bilingual video workbench for the unified Mac workspace, modeled
// on MacImageWorkbenchView. Prompt, supported video options and one optional
// reference image feed `MacVideoGeneration`; finished clips stay playable
// and exportable from local history.
//
// Bilingual copy lives in `MacVideoStrings` below because this file ships
// before the Mac string tables gain video entries; the helper follows the
// in-code `zh`/`en` convention used by the iPad workbench (`FloeLocalized`)
// and resolves through the shared `FloeL10n` language state.

struct MacVideoWorkbenchView: View {
    @ObservedObject var videos: MacVideoGeneration
    let openSettings: () -> Void
    var initialReference: URL? = nil

    @State private var prompt = ""
    @State private var providerOverride: MacMediaProviderSelection?
    @State private var selectedID: UUID?
    @State private var player: AVPlayer?
    @State private var aspectRatio: String?
    @State private var resolution: String?
    @State private var duration: Int?
    @State private var includeAudio: Bool?
    @State private var watermark: Bool?
    @State private var referenceImageURL: URL?
    @State private var exportFailed = false

    private var selection: MacVideoGeneration.JobItem? {
        videos.history.first(where: { $0.id == selectedID }) ?? videos.history.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(MacVideoStrings.promptPlaceholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(videos.isGenerating)
            if let contract {
                optionsRow(contract)
                if supportsReferenceImage {
                    referenceImageRow
                }
            }
            HStack {
                MacCreativeModelMenu(choices: videos.modelChoices, defaultModelName: videos.configuration?.modelID,
                                     selection: $providerOverride, openSettings: openSettings)
                    .disabled(videos.isGenerating)
                Spacer()
                if videos.isGenerating {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "host.chat.stop")) { videos.cancel() }
                } else {
                    Button(String(localized: "mac.images.generate")) { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled((providerOverride == nil && !videos.hasCredential) || contract == nil
                                  || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let notice = videos.notice {
                ErrorEventView(message: notice)
            }
            Divider()
            if videos.history.isEmpty {
                ContentUnavailableView(MacVideoStrings.emptyTitle, systemImage: "film")
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(videos.history) { item in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.prompt).lineLimit(2)
                                    Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    if item.state == .running, let progress = item.progress {
                                        ProgressView(value: progress).controlSize(.small)
                                    }
                                    if let error = item.error {
                                        Text(error).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if item.state != .ready {
                                    StateBadge(state: item.state)
                                }
                            }
                            .tag(item.id)
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 240)
                    VStack(alignment: .leading, spacing: 8) {
                        if player != nil, let item = selection, videos.videoURL(for: item) != nil {
                            MacCreativePlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(Text(item.prompt))
                        } else {
                            ContentUnavailableView(MacVideoStrings.unavailable, systemImage: "film")
                        }
                        if let item = selection {
                            HStack {
                                Button(String(localized: "mac.images.reusePrompt")) { prompt = item.prompt }
                                    .disabled(videos.isGenerating)
                                Spacer()
                                if !item.state.isTerminal {
                                    if videos.isWorking(on: item.id) {
                                        Button("host.chat.stop") { videos.cancel(item) }
                                    } else if videos.canResume(item) {
                                        Button("mac.videos.resume") { videos.resume(item.id) }
                                    }
                                }
                                Button(MacVideoStrings.saveAs) { export(item) }
                                    .disabled(videos.videoURL(for: item) == nil)
                            }
                        }
                    }
                    .padding(10)
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(18)
        .onChange(of: videos.history.first?.id, initial: true) { _, id in selectedID = id }
        .onChange(of: selection?.id, initial: true) { _, _ in resetPlayback() }
        .onChange(of: selection?.state) { _, _ in resetPlayback() }
        .onAppear { if supportsReferenceImage { referenceImageURL = initialReference } }
        .onChange(of: contract) { _, contract in
            if let aspectRatio, contract?.aspectRatios.contains(aspectRatio) != true { self.aspectRatio = nil }
            if let duration, contract?.supportedDurations.contains(duration) != true { self.duration = nil }
            if let resolution, contract?.resolutions.contains(resolution) != true { self.resolution = nil }
            if contract?.supportsAudio != true { includeAudio = nil }
            if contract?.supportsWatermark != true { watermark = nil }
        }
        .onChange(of: supportsReferenceImage) { _, supported in if !supported { referenceImageURL = nil } }
        .onDisappear { stopPlayback() }
        .alert(MacVideoStrings.exportFailed, isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Supported video options (shared contract)

    private var contract: VideoParameterContract? { videos.parameterContract(for: providerOverride) }
    private var supportsReferenceImage: Bool { videos.supportsReferenceImage(for: providerOverride) }

    static func acceptsReference(_ configuration: MacVideoGeneration.Configuration?) -> Bool {
        guard let config = configuration, let endpoint = URL(string: config.endpoint),
              let preset = ProviderPreset.all.first(where: { $0.id == config.presetID }) else { return false }
        return VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: preset.kind, modelRemoteID: config.modelID, baseURL: endpoint)
    }

    @ViewBuilder private func optionsRow(_ contract: VideoParameterContract) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if !contract.aspectRatios.isEmpty {
                    CompactOptionPicker(label: MacVideoStrings.aspectRatio, selection: $aspectRatio) {
                        Text(MacVideoStrings.defaultOption).tag(nil as String?)
                        ForEach(contract.aspectRatios, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                if !contract.resolutions.isEmpty {
                    CompactOptionPicker(label: MacVideoStrings.resolution, selection: $resolution) {
                        Text(MacVideoStrings.defaultOption).tag(nil as String?)
                        ForEach(contract.resolutions, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                if !contract.supportedDurations.isEmpty {
                    CompactOptionPicker(label: MacVideoStrings.duration, selection: $duration) {
                        Text(MacVideoStrings.defaultOption).tag(nil as Int?)
                        ForEach(contract.supportedDurations, id: \.self) { Text("\($0)s").tag(Optional($0)) }
                    }
                }
                if contract.supportsAudio {
                    CompactOptionPicker(label: MacVideoStrings.audio, selection: $includeAudio) {
                        Text(MacVideoStrings.defaultOption).tag(nil as Bool?)
                        Text(MacVideoStrings.on).tag(Optional(true))
                        Text(MacVideoStrings.off).tag(Optional(false))
                    }
                }
                if contract.supportsWatermark {
                    CompactOptionPicker(label: MacVideoStrings.watermark, selection: $watermark) {
                        Text(MacVideoStrings.defaultOption).tag(nil as Bool?)
                        Text(MacVideoStrings.on).tag(Optional(true))
                        Text(MacVideoStrings.off).tag(Optional(false))
                    }
                }
            }
        }
    }

    @ViewBuilder private var referenceImageRow: some View {
        HStack(spacing: 8) {
            Button(String(localized: "mac.creative.import")) { chooseReferenceImage() }
                .disabled(videos.isGenerating)
            if let referenceImageURL {
                Label(referenceImageURL.lastPathComponent, systemImage: "photo")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Button(MacVideoStrings.clearReference) { self.referenceImageURL = nil }
                    .disabled(videos.isGenerating)
            }
        }
    }

    // MARK: - Actions

    private func generate() {
        var options = VideoGenerationOptions()
        options.aspectRatio = aspectRatio
        options.resolution = resolution
        options.durationSeconds = duration
        options.includeAudio = includeAudio
        options.watermark = watermark
        videos.generate(prompt: prompt, options: options, referenceImage: referenceImageURL, providerOverride: providerOverride)
    }

    private func chooseReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            referenceImageURL = url
        }
    }

    private func export(_ item: MacVideoGeneration.JobItem) {
        guard let source = videos.videoURL(for: item) else { exportFailed = true; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = exportName(for: item, pathExtension: source.pathExtension)
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                let temporary = target.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
                let manager = FileManager.default
                defer { try? manager.removeItem(at: temporary) }
                try manager.copyItem(at: source, to: temporary)
                if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: temporary) }
                else { try manager.moveItem(at: temporary, to: target) }
            } catch {
                exportFailed = true
            }
        }
    }

    private func exportName(for item: MacVideoGeneration.JobItem, pathExtension: String) -> String {
        let firstLine = item.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        let ext = pathExtension.isEmpty ? "mp4" : pathExtension
        return (trimmed.isEmpty ? "Floe Video" : trimmed) + ".\(ext)"
    }

    // MARK: - Playback lifecycle

    private func resetPlayback() {
        stopPlayback()
        guard let item = selection, let url = videos.videoURL(for: item) else { return }
        player = AVPlayer(url: url)
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
    }

    /// Short per-item status for clips that are not ready to play yet.
    private struct StateBadge: View {
        let state: MediaGenerationJobState

        var body: some View {
            Text(label(for: state))
                .font(.caption2)
                .foregroundStyle(color(for: state))
        }

        private func color(for state: MediaGenerationJobState) -> Color {
            switch state {
            case .failed, .cancelled, .expired: .red
            default: .orange
            }
        }

        private func label(for state: MediaGenerationJobState) -> String {
            switch state {
            case .preparing: MacVideoStrings.statePreparing
            case .submitted: MacVideoStrings.stateSubmitted
            case .running: MacVideoStrings.stateRunning
            case .completed: MacVideoStrings.stateCompleted
            case .downloading: MacVideoStrings.stateDownloading
            case .failed: MacVideoStrings.stateFailed
            case .cancelled: MacVideoStrings.stateCancelled
            case .expired: MacVideoStrings.stateExpired
            case .ready: ""
            @unknown default: String(describing: state).capitalized
            }
        }
    }
}

/// Label plus hidden-caption dropdown used by the compact options row.
private struct MacCreativePlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}

private struct CompactOptionPicker<Value: Hashable, Content: View>: View {
    let label: String
    @Binding var selection: Value?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Picker(label, selection: $selection) { content }.labelsHidden()
        }
        .fixedSize()
    }
}

struct MacVideoSettingsView: View {
    @ObservedObject var videos: MacVideoGeneration
    @State private var presetID: ProviderTemplateID = .volcengineArk
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var status: String?

    /// Same adapter-backed supplier list as the workbench, plus the saved
    /// configuration's preset when it uses a legacy route.
    private let eligiblePresets = ProviderFormSpecResolver.eligiblePresets(for: .video)

    private var presets: [ProviderPreset] {
        guard let config = videos.configuration,
              !eligiblePresets.contains(where: { $0.id == config.presetID }),
              let saved = ProviderPreset.all.first(where: { $0.id == config.presetID }) else {
            return eligiblePresets
        }
        return eligiblePresets + [saved]
    }

    /// A stored configuration always carries its key, so a matching
    /// preset + endpoint pair can reuse it without retyping.
    private var canUseSavedKey: Bool {
        guard let configuration = videos.configuration else { return false }
        return videos.hasCredential && configuration.presetID == presetID
            && configuration.endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                Picker(MacVideoStrings.provider, selection: Binding(
                    get: { presetID },
                    set: { id in
                        guard id != presetID else { return }
                        presetID = id
                        endpoint = presets.first(where: { $0.id == id })?.defaultBaseURL.absoluteString ?? ""
                        modelID = ""
                        key = ""
                        status = nil
                    }
                )) {
                    ForEach(presets) { preset in Text(preset.displayName).tag(preset.id) }
                }
                TextField("host.chat.endpoint", text: Binding(
                    get: { endpoint }, set: { if endpoint != $0 { endpoint = $0; key = ""; status = nil } }
                )).textContentType(.URL)
                TextField("host.chat.modelID", text: $modelID)
                SecureField(canUseSavedKey ? MacVideoStrings.replaceKey : String(localized: "host.chat.key"),
                            text: $key)
            }
            Section {
                Button(String(localized: "host.chat.save")) { save() }
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!canUseSavedKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || videos.isGenerating)
                if let status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let configuration = videos.configuration {
                presetID = configuration.presetID
                endpoint = configuration.endpoint
                modelID = configuration.modelID
            } else {
                endpoint = presets.first(where: { $0.id == presetID })?.defaultBaseURL.absoluteString ?? ""
            }
        }
    }

    private func save() {
        do {
            try videos.save(.init(presetID: presetID, endpoint: endpoint, modelID: modelID),
                            apiKey: key.isEmpty ? nil : key)
            key = ""
            status = MacVideoStrings.settingsSaved
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Bilingual strings

/// English/Simplified-Chinese pairs for the video workbench copy. Keys that
/// already exist in the Mac string tables are reused at their call sites;
/// everything video-specific resolves here until the tables gain entries.
private enum MacVideoStrings {
    static var promptPlaceholder: String { t(en: "Describe the video you want…", zh: "描述要生成的视频…") }
    static var configure: String { t(en: "Configure Video Model…", zh: "配置视频模型…") }
    static var emptyTitle: String { t(en: "No Generated Videos", zh: "还没有生成的视频") }
    static var unavailable: String { t(en: "Video Unavailable", zh: "视频不可用") }
    static var saveAs: String { t(en: "Save Video…", zh: "保存视频…") }
    static var exportFailed: String { t(en: "Couldn’t save the video.", zh: "无法保存视频。") }
    static var provider: String { t(en: "Video Provider", zh: "视频服务商") }
    static var replaceKey: String { t(en: "Replace Saved API Key (Optional)", zh: "替换已保存的 API 密钥（选填）") }
    static var settingsSaved: String { t(en: "Video settings saved.", zh: "已保存视频设置。") }
    static var aspectRatio: String { t(en: "Aspect Ratio", zh: "画面比例") }
    static var resolution: String { t(en: "Resolution", zh: "分辨率") }
    static var duration: String { t(en: "Duration", zh: "时长") }
    static var audio: String { t(en: "Audio", zh: "声音") }
    static var watermark: String { t(en: "Watermark", zh: "水印") }
    static var defaultOption: String { t(en: "Default", zh: "默认") }
    static var on: String { t(en: "On", zh: "开") }
    static var off: String { t(en: "Off", zh: "关") }
    static var clearReference: String { t(en: "Clear", zh: "清除") }
    static var statePreparing: String { t(en: "Preparing", zh: "准备中") }
    static var stateSubmitted: String { t(en: "Queued", zh: "已提交") }
    static var stateRunning: String { t(en: "Generating…", zh: "生成中…") }
    static var stateCompleted: String { t(en: "Finalizing…", zh: "收尾中…") }
    static var stateDownloading: String { t(en: "Downloading…", zh: "下载中…") }
    static var stateFailed: String { t(en: "Failed", zh: "失败") }
    static var stateCancelled: String { t(en: "Cancelled", zh: "已取消") }
    static var stateExpired: String { t(en: "Expired", zh: "已过期") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicAssetLibrary: View {
    @Bindable var session: MusicProjectSession
    let onImport: () -> Void
    let onInstrument: () -> Void
    var body: some View {
        List {
            Section(WorkbenchText.t("工程素材", "Project assets")) {
                ForEach(session.document.assets) { asset in
                    HStack {
                        PersonalEditorAssetPreview(sourceID: "music:\(session.id):\(session.document.revision):\(asset.id.rawValue):\(asset.sourceRevision)", title: asset.name) { pixels in
                            try await PersonalEditorPreviewRequests.musicAsset(session: session, asset: asset, pixels: pixels)
                        }.frame(width: 76, height: 52).accessibilityIdentifier("music.asset.preview.\(asset.id.rawValue)")
                        VStack(alignment: .leading) {
                            Text(asset.name).lineLimit(1)
                            Text(MusicWorkbenchFormat.time(Double(asset.durationSamples.value) / Double(session.document.tempoMap.sampleRate))).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if asset.kind != .midiFile {
                            Button(WorkbenchText.t("加入", "Insert")) { place(asset) }.frame(minHeight: 44)
                        }
                    }
                }
                Button(action: onImport) { Label(WorkbenchText.t("导入音频或 MIDI", "Import audio or MIDI"), systemImage: "square.and.arrow.down").frame(minHeight: 44) }.accessibilityIdentifier("music.import")
            }
            let midiClips = session.document.tracks.flatMap(\.clips).filter { if case .midi = $0.body { true } else { false } }
            if !midiClips.isEmpty {
                Section(WorkbenchText.t("MIDI 片段预览", "MIDI clip previews")) {
                    ForEach(midiClips) { clip in
                        HStack(spacing: 10) {
                            PersonalEditorAssetPreview(sourceID: "midi-clip:\(session.id):\(session.document.revision):\(clip.id.rawValue)", title: clip.name) { pixels in
                                try await PersonalEditorPreviewRequests.musicClip(session: session, clip: clip, pixels: pixels)
                            }.frame(width: 96, height: 60).accessibilityIdentifier("music.clip.preview.\(clip.id.rawValue)")
                            Text(clip.name.isEmpty ? WorkbenchText.t("MIDI 片段", "MIDI clip") : clip.name).lineLimit(2)
                        }
                    }
                }
            }
            Section(WorkbenchText.t("乐器", "Instruments")) {
                NavigationLink {
                    MusicPresetBrowser(session: session)
                } label: {
                    Label(WorkbenchText.t("浏览合成音色", "Browse synthesized presets"), systemImage: "pianokeys").frame(minHeight: 44)
                }.accessibilityIdentifier("music.library.presets")
                Button(action: onInstrument) { Label(WorkbenchText.t("添加合成器轨", "Add synthesizer track"), systemImage: "pianokeys").frame(minHeight: 44) }
                MusicEditingActionsButton(session: session, initialPanel: .patterns)
            }
        }
    }
    private func place(_ asset: MusicAsset) {
        Task {
            do {
                var ops: [MusicEditOp] = []
                let track: MusicTrack
                if let selected = session.currentTrack, selected.kind == .audio { track = selected }
                else { track = try MusicTrack(name: asset.name, kind: .audio); ops.append(.insertTrack(track)) }
                let clip = try MusicClip(name: asset.name, trackID: track.id,
                    offset: .init(Int64(session.playheadSeconds * Double(session.document.tempoMap.sampleRate))),
                    body: .audio(.init(assetID: asset.id, durationSamples: asset.durationSamples.value)))
                ops.append(.insertClip(clip)); try await session.apply(ops); session.selectClip(clip)
            } catch { session.diagnostic = error.localizedDescription }
        }
    }
}

struct MusicExportSheet: View {
    @Bindable var session: MusicProjectSession
    var onExported: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var content = "mix"
    @State private var format = "mp3"
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(WorkbenchText.t("导出内容", "Export content"), selection: $content) {
                        Text(WorkbenchText.t("总混音", "Stereo mix")).tag("mix")
                        Text(WorkbenchText.t("分轨音频", "Track stems")).tag("stems")
                        Text(WorkbenchText.t("完整工程包", "Project package")).tag("project")
                    }
                    if content == "mix" {
                        Picker(WorkbenchText.t("格式", "Format"), selection: $format) { Text("MP3").tag("mp3"); Text("WAV").tag("wav") }.pickerStyle(.segmented)
                    } else { Text(content == "stems" ? "WAV" : "ZIP").font(.caption).foregroundStyle(.secondary) }
                    LabeledContent(WorkbenchText.t("范围", "Range"), value: WorkbenchText.t("整个工程", "Entire project"))
                    LabeledContent(WorkbenchText.t("时长", "Duration"), value: MusicWorkbenchFormat.time(session.durationSeconds))
                    LabeledContent(WorkbenchText.t("保存到", "Save to"), value: WorkbenchText.t("当前工程", "Current project"))
                    Button {
                        if content == "mix" { session.render(asMP3: format == "mp3") }
                        else { session.exportOriginals(stems: content == "stems") }
                    } label: { Label(WorkbenchText.t("生成文件", "Create files"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        .disabled(session.isRendering || (content != "project" && session.document.tracks.flatMap(\.clips).isEmpty))
                        .accessibilityIdentifier("music.export.create")
                }
                if session.isRendering {
                    Section { ProgressView(WorkbenchText.t("正在准备…", "Preparing…")); Button(WorkbenchText.t("取消", "Cancel")) { session.cancelRender() } }
                }
                if !session.exportedFiles.isEmpty {
                    Section(WorkbenchText.t("已保存文件", "Saved files")) {
                        ForEach(session.exportedFiles, id: \.self) { file in
                            ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up").lineLimit(2).frame(minHeight: 44) }
                            if let onExported {
                                Button(WorkbenchText.t("返回此文件", "Return this file")) { onExported(file); dismiss() }.frame(minHeight: 44)
                            }
                        }
                        if session.exportedFiles.count > 1 {
                            ShareLink(items: session.exportedFiles) { Label(WorkbenchText.t("分享全部分轨", "Share all stems"), systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                if let diagnostic = session.diagnostic {
                    Section { Label(WorkbenchText.t("导出未完成", "Export unfinished"), systemImage: "exclamationmark.triangle"); DisclosureGroup(WorkbenchText.t("详情", "Details")) { Text(diagnostic).textSelection(.enabled) } }
                }
            }
            .navigationTitle(WorkbenchText.t("导出音乐", "Export music")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

/// Media entry without an extra editor navigation stack. The existing
/// WorkbenchSheet owns navigation, while personal originals remain in Files.
struct MusicWorkbenchBootstrapSheet: View {
    @ObservedObject var center: WorkbenchCenter
    var title: String
    var sourceURL: URL? = nil
    var owner: WorkbenchCenter.Owner = .standalone
    var onExported: ((URL) -> Void)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var prepared = false
    var body: some View {
        Group {
            if center.musicContext != nil {
                WorkbenchSheet(center: center, title: title, onExported: onExported)
            } else if prepared {
                ContentUnavailableView {
                    Label(WorkbenchText.t("无法打开音乐工作台", "Unable to open music workbench"), systemImage: "exclamationmark.triangle")
                } description: { Text(center.alert?.message ?? WorkbenchText.t("请重试。", "Please retry.")) } actions: {
                    Button(WorkbenchText.t("重试", "Retry")) { Task { await prepare() } }
                    Button(WorkbenchText.t("关闭", "Close")) { dismiss() }
                }
            } else { ProgressView(WorkbenchText.t("正在打开音乐工程…", "Opening music project…")) }
        }.task { if !prepared { await prepare() } }
    }
    private func prepare() async {
        prepared = false
        _ = await center.startMusicProject(sourceURL: sourceURL, owner: owner, environment: environment)
        prepared = true
    }
}

struct MusicWorkbenchContextView: View {
    let context: WorkbenchCenter.MusicContext
    var onExported: ((URL) -> Void)?
    @State private var assistant = false
    var body: some View {
        MusicWorkbenchView(session: context.session, onAssistant: { assistant = true }, onExported: onExported)
            .sheet(isPresented: $assistant, onDismiss: { Task { try? await context.session.reload() } }) { StudioAssistantView(record: context.record) }
            .onReceive(NotificationCenter.default.publisher(for: .floeStudioDocumentDidChange)) { notification in
                if notification.object as? UUID == context.record.id { Task { try? await context.session.reload() } }
            }
    }
}
#endif

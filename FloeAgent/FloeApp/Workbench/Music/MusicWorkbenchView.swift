// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeMusicCore
import FloeMusicKeyboard

enum MusicWorkbenchDock: String, CaseIterable, Identifiable {
    case mixer, piano, drums, keyboard, dj
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixer: return WorkbenchText.t("调音台", "Mixer")
        case .piano: return WorkbenchText.t("钢琴卷帘", "Piano roll")
        case .drums: return WorkbenchText.t("鼓机", "Drums")
        case .keyboard: return WorkbenchText.t("电子琴", "Keyboard")
        case .dj: return WorkbenchText.t("DJ 打碟", "DJ decks")
        }
    }
    var icon: String {
        switch self { case .mixer: "slider.horizontal.3"; case .piano: "pianokeys"; case .drums: "square.grid.3x3"; case .keyboard: "pianokeys.inverse"; case .dj: "opticaldisc" }
    }
}

/// Transport, arrangement, effects inspector and an expanded mixer follow
/// the accepted studio. Only transient editor state belongs to the view.
struct MusicWorkbenchView: View {
    @Bindable var session: MusicProjectSession
    var onAssistant: (() -> Void)? = nil
    var onExported: ((URL) -> Void)? = nil
    @State private var dock: MusicWorkbenchDock = .mixer
    @State private var section = "arrange"
    @State private var importing = false
    @State private var exporting = false
    @State private var library = false
    @State private var renaming = false
    @State private var name = ""
    @State private var bpm = 120.0
    @State private var zoom = 1.0
    @State private var snap = true
    @State private var automation = false
    @State private var expanded = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            VStack(spacing: 0) {
                titlebar
                Divider()
                transport
                Divider()
                if !wide { sectionBar }
                if dock == .dj && (wide || section == "arrange") {
                    dockBar
                    MusicDJWorkbench(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if wide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if !expanded { arrangement.frame(maxHeight: .infinity) }
                            dockBar
                            dockContent.frame(height: expanded ? max(260, geometry.size.height - 170) : min(290, max(220, geometry.size.height * 0.38)))
                        }
                        Divider()
                        inspectorContent.frame(width: min(300, geometry.size.width * 0.25))
                    }
                } else { compactContent }
                Divider()
                statusBar
            }.background(Color(uiColor: .systemBackground))
        }
        .onAppear { bpm = session.document.tempoMap.segments.first?.bpm ?? 120; name = session.document.name }
        .onChange(of: session.document.revision) { _, _ in bpm = session.document.tempoMap.segments.first?.bpm ?? 120 }
        .onDisappear {
            session.stopLive(); session.stopPlayback()
            if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            session.stopLive(); session.stopPlayback()
            if session.isRecording { Task { await session.stopMicrophone() } }
            if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, UTType(filenameExtension: "mid") ?? .data, UTType(filenameExtension: "midi") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await session.importFile(url) }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
        .sheet(isPresented: $exporting) { MusicExportSheet(session: session, onExported: onExported) }
        .sheet(isPresented: $library) {
            NavigationStack {
                MusicAssetLibrary(session: session, onImport: { library = false; importing = true }, onInstrument: {
                    Task { await session.addTrack(); dock = .keyboard; library = false }
                })
                .navigationTitle(WorkbenchText.t("素材与乐器", "Assets and instruments"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { library = false } } }
            }
        }
        .alert(WorkbenchText.t("工程名称", "Project name"), isPresented: $renaming) {
            TextField(WorkbenchText.t("名称", "Name"), text: $name)
            Button(WorkbenchText.t("保存", "Save")) { session.edit([.setName(name)]) }
            Button(WorkbenchText.t("取消", "Cancel"), role: .cancel) {}
        }
    }
    private var titlebar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path").foregroundStyle(.tint)
            Button { name = session.document.name; renaming = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.document.name).font(.headline).lineLimit(1)
                    Text(session.saving ? WorkbenchText.t("正在保存…", "Saving…") : WorkbenchText.t("已保存", "Saved") + " · r\(session.document.revision)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).frame(minHeight: 44)
            Spacer(minLength: 4)
            if let onAssistant {
                MusicIconButton("sparkles", WorkbenchText.t("作品助手", "Work assistant"), action: onAssistant)
                    .accessibilityIdentifier("music.assistant")
            }
            MusicIconButton("arrow.uturn.backward", WorkbenchText.t("撤销", "Undo")) { Task { await session.undo() } }.accessibilityIdentifier("music.undo")
            MusicIconButton("arrow.uturn.forward", WorkbenchText.t("重做", "Redo")) { Task { await session.undo(redo: true) } }
            Button { exporting = true } label: { Label(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                .accessibilityIdentifier("music.export.settings")
        }.padding(.horizontal, 12).padding(.vertical, 3).background(Color(uiColor: .secondarySystemBackground))
    }
    private var transport: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MusicIconButton("backward.end.fill", WorkbenchText.t("回到开头", "Return to start")) { session.seek(to: 0) }
                Button {
                    if session.playbackIsActive { session.stopPlayback() } else { session.render(asMP3: false, play: true) }
                } label: {
                    Label(session.playbackIsActive ? WorkbenchText.t("停止", "Stop") : WorkbenchText.t("播放", "Play"), systemImage: session.playbackIsActive ? "stop.fill" : "play.fill")
                        .frame(minWidth: 64, minHeight: 44)
                }.buttonStyle(.borderedProminent).disabled(session.isRendering || session.isRecording).accessibilityIdentifier("music.play")
                Menu {
                    Button(session.isMIDIRecording ? WorkbenchText.t("结束演奏录制", "Finish performance")
                        : session.currentTrack?.kind == .midi ? WorkbenchText.t("录制键盘演奏", "Record keyboard")
                        : WorkbenchText.t("添加乐器轨并录制", "Add instrument track and record")) {
                        if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
                        else { dock = .keyboard; Task { await session.activateKeyboard(recording: true) } }
                    }
                    Button(session.isRecording ? WorkbenchText.t("结束麦克风录音", "Finish microphone recording") : WorkbenchText.t("麦克风录音", "Record microphone")) {
                        Task { if session.isRecording { await session.stopMicrophone() } else { await session.startMicrophone() } }
                    }
                } label: {
                    Label(WorkbenchText.t("录音", "Record"), systemImage: session.isRecording || session.isMIDIRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(.red).frame(minHeight: 44)
                }.accessibilityIdentifier("music.record")
                Toggle(isOn: Binding(get: { session.looping }, set: { session.setLooping($0) })) { Image(systemName: "repeat") }
                    .toggleStyle(.button).frame(minWidth: 44, minHeight: 44).accessibilityLabel(WorkbenchText.t("循环播放", "Loop playback"))
                Divider().frame(height: 32)
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MusicWorkbenchFormat.position(session.playbackPosition, tempoMap: session.document.tempoMap)).font(.system(.headline, design: .monospaced))
                        Text(MusicWorkbenchFormat.time(session.playbackPosition)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(width: 106, alignment: .leading)
                }
                VStack(spacing: 2) {
                    Text("BPM").font(.caption2).foregroundStyle(.secondary)
                    TextField("BPM", value: $bpm, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 58).keyboardType(.decimalPad).multilineTextAlignment(.center).onSubmit { applyTempo() }
                }
                MusicIconButton("checkmark", WorkbenchText.t("应用速度", "Apply tempo")) { applyTempo() }
                Text("\(session.document.tempoMap.segments.first?.beatsPerBar ?? 4)/\(session.document.tempoMap.segments.first?.beatUnit ?? 4)")
                    .font(.callout.monospacedDigit()).padding(.trailing, 8)
                if session.isRendering { ProgressView(); Button(WorkbenchText.t("取消", "Cancel")) { session.cancelRender() }.frame(minHeight: 44) }
            }.padding(.horizontal, 10).padding(.vertical, 4)
        }
    }
    private var sectionBar: some View {
        Picker(WorkbenchText.t("工作台区域", "Workbench section"), selection: $section) {
            Text(WorkbenchText.t("编排", "Arrange")).tag("arrange")
            Text(WorkbenchText.t("调音台", "Mixer")).tag("mixer")
            Text(WorkbenchText.t("效果器", "Effects")).tag("effects")
        }.pickerStyle(.segmented).padding(.horizontal, 8).padding(.vertical, 6)
    }
    @ViewBuilder private var compactContent: some View {
        switch section {
        case "mixer": MusicMixerPanel(session: session)
        case "effects": MusicEffectsInspector(session: session)
        default:
            VStack(spacing: 0) {
                if !expanded { arrangement.frame(maxHeight: .infinity) }
                dockBar
                if dock != .mixer || expanded { dockContent.frame(maxHeight: .infinity) }
            }
        }
    }
    private var arrangement: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { library = true } label: { Label(WorkbenchText.t("素材", "Library"), systemImage: "folder") }
                    Menu {
                        Button(WorkbenchText.t("乐器轨", "Instrument track"), systemImage: "pianokeys") { Task { await session.addTrack() } }
                        Button(WorkbenchText.t("音频轨", "Audio track"), systemImage: "waveform") { Task { await session.addAudioTrack() } }
                        Button(WorkbenchText.t("导入音频或 MIDI", "Import audio or MIDI"), systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityIdentifier("music.addTrack")
                    MusicIconButton("scissors", WorkbenchText.t("在播放头处分割", "Split at playhead")) { session.splitSelection() }.disabled(session.currentClip == nil)
                    MusicIconButton("plus.square.on.square", WorkbenchText.t("复制片段", "Duplicate clip")) { session.duplicateSelection() }.disabled(session.currentClip == nil)
                    MusicEditingActionsButton(session: session)
                    MusicIconButton("trash", WorkbenchText.t("删除片段", "Delete clip")) { if let clip = session.currentClip { session.edit([.removeClip(clip.id)]) } }.disabled(session.currentClip == nil)
                    Toggle(WorkbenchText.t("吸附", "Snap"), isOn: $snap).toggleStyle(.button).frame(minHeight: 44)
                    Toggle(WorkbenchText.t("自动化", "Automation"), isOn: $automation).toggleStyle(.button).frame(minHeight: 44)
                    MusicIconButton("minus.magnifyingglass", WorkbenchText.t("缩小时间线", "Zoom out")) { zoom = max(0.25, zoom / 1.4) }
                    MusicIconButton("plus.magnifyingglass", WorkbenchText.t("放大时间线", "Zoom in")) { zoom = min(8, zoom * 1.4) }
                }.buttonStyle(.borderless).padding(.horizontal, 8)
            }
            Divider()
            MusicArrangementTimeline(session: session, zoom: zoom, snap: snap, showsAutomation: automation) { clip in
                session.selectClip(clip)
                if case .midi = clip.body { dock = .piano }
            }
            HStack {
                Text(session.currentClip?.name ?? session.currentTrack?.name ?? WorkbenchText.t("选择轨道或导入素材", "Select a track or import media")).lineLimit(1)
                Spacer()
                Text(WorkbenchText.t("拖动移动 · 双击编曲", "Drag to move · Double-tap to edit")).lineLimit(1)
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
    }
    private var dockBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(MusicWorkbenchDock.allCases) { value in
                        Button { let wasDJ = dock == .dj; dock = value; if value == .dj { expanded = true } else if wasDJ { expanded = false } } label: {
                            Label(value.title, systemImage: value.icon).font(.callout).padding(.horizontal, 9).frame(minHeight: 44)
                                .background(dock == value ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).foregroundStyle(dock == value ? Color.accentColor : .primary).accessibilityIdentifier("music.dock." + value.rawValue)
                    }
                }
            }
            MusicIconButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", WorkbenchText.t("展开或收起编辑器", "Expand or collapse editor")) { expanded.toggle() }
        }.padding(.horizontal, 6).background(Color(uiColor: .secondarySystemBackground))
    }
    @ViewBuilder private var dockContent: some View {
        switch dock {
        case .mixer: MusicMixerPanel(session: session)
        case .piano: MusicPianoRoll(session: session)
        case .drums: MusicDrumGrid(session: session)
        case .keyboard: MusicKeyboardWorkbench(session: session)
        case .dj: MusicDJWorkbench(session: session)
        }
    }
    private var inspectorContent: some View {
        VStack(spacing: 0) {
            Text(WorkbenchText.t("效果器", "Effects")).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            MusicEffectsInspector(session: session)
        }
    }
    private var statusBar: some View {
        HStack(spacing: 6) {
            if let error = session.diagnostic {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Menu(WorkbenchText.t("操作未完成", "Action unfinished")) {
                    Text(error)
                    Button(WorkbenchText.t("关闭提示", "Dismiss notice")) { session.diagnostic = nil }
                }
            } else { Text(session.isRecording || session.isMIDIRecording ? WorkbenchText.t("正在录音", "Recording") : WorkbenchText.t("音乐工程", "Music project")) }
            Spacer()
            Text("\(session.document.tracks.count) " + WorkbenchText.t("轨", "tracks"))
            Text("· \(session.document.tempoMap.sampleRate / 1000) kHz")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 25)
    }
    private func applyTempo() {
        let segment = session.document.tempoMap.segments.first
        session.edit([.setTempo(atTick: .init(0), bpm: bpm, beatsPerBar: segment?.beatsPerBar ?? 4, beatUnit: segment?.beatUnit ?? 4)])
    }
}

struct MusicIconButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    init(_ icon: String, _ title: String, action: @escaping () -> Void) { self.icon = icon; self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

enum MusicWorkbenchFormat {
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%02d:%02d.%03d", Int(value) / 60, Int(value) % 60, Int(value * 1000) % 1000)
    }
    static func position(_ seconds: Double, tempoMap: MusicTempoMap) -> String {
        let samples = Int64(max(0, seconds) * Double(tempoMap.sampleRate))
        let tick = (try? tempoMap.tick(atSample: .init(samples)).value) ?? 0
        let beat = tick / Int64(tempoMap.ticksPerQuarter)
        let bar = Int64(tempoMap.segments.first?.beatsPerBar ?? 4)
        return String(format: "%03d.%d.%03d", beat / bar + 1, beat % bar + 1, tick % Int64(tempoMap.ticksPerQuarter))
    }
    static func decibels(_ gain: Double) -> Double { gain > 0 ? max(-60, 20 * log10(gain)) : -60 }
    static func gain(_ decibels: Double) -> Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    static func color(_ index: Int) -> Color { [.blue, .orange, .green, .purple, .teal, .pink][index % 6] }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeMusicCore
import FloeMusicKeyboard

enum MusicWorkbenchDock: String, CaseIterable, Identifiable {
    case mixer, piano, drums, keyboard, dj, score
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixer: return WorkbenchText.t("调音台", "Mixer")
        case .piano: return WorkbenchText.t("钢琴卷帘", "Piano roll")
        case .drums: return WorkbenchText.t("鼓机", "Drums")
        case .keyboard: return WorkbenchText.t("电子琴", "Keyboard")
        case .dj: return WorkbenchText.t("DJ 打碟", "DJ decks")
        case .score: return WorkbenchText.t("乐谱", "Score")
        }
    }
    var icon: String {
        switch self { case .mixer: "slider.horizontal.3"; case .piano: "pianokeys"; case .drums: "square.grid.3x3"; case .keyboard: "pianokeys.inverse"; case .dj: "opticaldisc"; case .score: "music.note.list" }
    }
}

/// Transport, arrangement, effects inspector and an expanded mixer follow
/// the accepted studio. Only transient editor state belongs to the view.
struct MusicWorkbenchView: View {
    @State private var tempoEditor: MusicTempoEditorRoute?
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var zoom = 1.0
    @State private var snap = true
    @State private var automation = false
    @State private var expanded = false
    @State private var showsInspector = false
    @State private var usesWideLayout = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            VStack(spacing: 0) {
                if dock == .score {
                    dockBar
                    dockContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transport
                    Divider()
                    if !wide { sectionBar }
                    if dock == .dj && (wide || section == "arrange") {
                        dockBar
                        MusicDJWorkbench(session: session, onImport: { importing = true }).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if wide {
                        MusicWorkbenchPanels(expanded: expanded, showsDock: true,
                            inspectorWidth: showsInspector ? min(260, geometry.size.width * 0.22) : 0, prioritizesKeyboard: dock == .keyboard,
                            arrangement: arrangement, dockBar: dockBar, dockContent: dockContent, inspector: inspectorContent)
                    } else { compactContent }
                    Divider()
                    statusBar
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(uiColor: .systemBackground))
                .onChange(of: wide, initial: true) { _, value in usesWideLayout = value }
        }
        .toolbar { projectToolbar }
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
        .sheet(item: $tempoEditor) { _ in MusicTempoEditor(session: session) }
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
            Button(WorkbenchText.t("保存", "Save")) { renameProject() }
            Button(WorkbenchText.t("取消", "Cancel"), role: .cancel) {}
        }
    }
    @ToolbarContentBuilder private var projectToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let onAssistant {
                Button(WorkbenchText.t("作品助手", "Work assistant"), systemImage: "sparkles", action: onAssistant)
                    .accessibilityIdentifier("music.assistant")
            }
            if usesWideLayout && dock != .score && dock != .dj {
                Button(showsInspector ? WorkbenchText.t("隐藏检查器", "Hide inspector")
                    : WorkbenchText.t("显示检查器", "Show inspector"), systemImage: "sidebar.right") {
                    showsInspector.toggle()
                }.accessibilityIdentifier("music.inspector.toggle")
                    .accessibilityValue(showsInspector ? WorkbenchText.t("已展开", "Expanded") : WorkbenchText.t("已收起", "Collapsed"))
            }
            if sizeClass == .regular {
                Button(WorkbenchText.t("撤销", "Undo"), systemImage: "arrow.uturn.backward") { Task { await session.undo() } }
                    .accessibilityIdentifier("music.undo")
                Button(WorkbenchText.t("重做", "Redo"), systemImage: "arrow.uturn.forward") { Task { await session.undo(redo: true) } }
                Button(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up") { exporting = true }
                    .accessibilityIdentifier("music.export.settings")
            }
            Menu {
                if sizeClass != .regular {
                    Button(WorkbenchText.t("撤销", "Undo"), systemImage: "arrow.uturn.backward") { Task { await session.undo() } }
                        .accessibilityIdentifier("music.undo")
                    Button(WorkbenchText.t("重做", "Redo"), systemImage: "arrow.uturn.forward") { Task { await session.undo(redo: true) } }
                    Divider()
                    Button(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up") { exporting = true }
                        .accessibilityIdentifier("music.export.settings")
                }
                Button(WorkbenchText.t("重命名", "Rename"), systemImage: "pencil") { name = session.document.name; renaming = true }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(WorkbenchText.t("工程选项", "Project options"))
                .accessibilityIdentifier("music.project.options")
        }
    }
    private var transport: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    MusicIconButton("backward.end.fill", WorkbenchText.t("回到开头", "Return to start")) { session.seek(to: 0) }
                    Button {
                        if session.playbackIsActive { session.stopPlayback() }
                        else if dock == .dj { session.toggleDJ() }
                        else { session.render(asMP3: false, play: true) }
                    } label: {
                        Image(systemName: session.playbackIsActive ? "stop.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Circle())
                            .contentShape(Circle())
                    }.buttonStyle(MusicTransportPlayStyle())
                        .accessibilityLabel(session.playbackIsActive ? WorkbenchText.t("停止", "Stop") : WorkbenchText.t("播放", "Play"))
                        .disabled(session.isRendering || session.isRecording).accessibilityIdentifier("music.play")
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
                        Image(systemName: session.isRecording || session.isMIDIRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title3).foregroundStyle(.red)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel(WorkbenchText.t("录音选项", "Recording options"))
                        .accessibilityIdentifier("music.record")
                    Toggle(isOn: Binding(get: { session.looping }, set: { session.setLooping($0) })) {
                        Image(systemName: "repeat").frame(width: 44, height: 44)
                    }.toggleStyle(.button).tint(.accentColor)
                        .accessibilityLabel(WorkbenchText.t("循环播放", "Loop playback"))
                }
                Divider().frame(height: 32)
                TimelineView(.animation(minimumInterval: 0.1, paused: !session.playbackIsActive)) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MusicWorkbenchFormat.position(session.playbackPosition, tempoMap: session.document.tempoMap))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                        Text(MusicWorkbenchFormat.time(session.playbackPosition))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(minWidth: 116, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(WorkbenchText.t("播放位置", "Playhead position"))
                }
                Button { tempoEditor = MusicTempoEditorRoute() } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((session.document.tempoMap.segments.first?.bpm ?? 120).formatted(.number.precision(.fractionLength(0...1))) + " BPM")
                                .font(.callout.monospacedDigit().weight(.medium))
                            Text("\(session.document.tempoMap.segments.first?.beatsPerBar ?? 4)/\(session.document.tempoMap.segments.first?.beatUnit ?? 4)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).frame(minHeight: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("编辑速度与拍号", "Edit tempo and meter"))
                    .accessibilityIdentifier("music.tempo.open").disabled(session.isMIDIRecording)
                if session.isRendering {
                    ProgressView().accessibilityLabel(WorkbenchText.t("正在生成音频", "Generating audio"))
                    Button(WorkbenchText.t("取消", "Cancel")) { session.cancelRender() }.frame(minHeight: 44)
                }
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 6)
        }.frame(height: dynamicTypeSize.isAccessibilitySize ? 104 : 64).background(.bar)
            .accessibilityIdentifier("music.transport")
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
            MusicWorkbenchPanels(expanded: expanded, showsDock: dock != .mixer || expanded,
                inspectorWidth: 0, prioritizesKeyboard: dock == .keyboard, arrangement: arrangement, dockBar: dockBar,
                dockContent: dockContent, inspector: EmptyView())
        }
    }
    private var arrangement: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                editingToolbar
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            MusicArrangementTimeline(session: session, zoom: $zoom, snap: snap, showsAutomation: automation,
                onImport: { importing = true }) { clip in
                session.selectClip(clip)
                if case .midi = clip.body { dock = .piano }
            }
            HStack {
                Text(session.currentClip?.name ?? session.currentTrack?.name ?? WorkbenchText.t("选择轨道或导入素材", "Select a track or import media")).lineLimit(1)
                Spacer()
                Text(WorkbenchText.t("长按移动 · 拖边修剪 · 双指缩放", "Hold to move · Drag edges to trim · Pinch to zoom")).lineLimit(1)
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
    }
    private var editingToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button { library = true } label: {
                    Label(WorkbenchText.t("素材", "Library"), systemImage: "folder")
                        .frame(minHeight: 36).padding(.horizontal, 4)
                }.buttonStyle(.bordered).controlSize(.regular)
                Menu {
                    Button(WorkbenchText.t("乐器轨", "Instrument track"), systemImage: "pianokeys") { Task { await session.addTrack() } }
                    Button(WorkbenchText.t("音频轨", "Audio track"), systemImage: "waveform") { Task { await session.addAudioTrack() } }
                    Button(WorkbenchText.t("导入音频或 MIDI", "Import audio or MIDI"), systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .accessibilityLabel(WorkbenchText.t("添加轨道或导入素材", "Add track or import media"))
                    .accessibilityIdentifier("music.addTrack")
            }
            Divider().frame(height: 24)
            HStack(spacing: 0) {
                MusicIconButton("scissors", WorkbenchText.t("在播放头处分割", "Split at playhead")) { session.splitSelection() }.disabled(session.currentClip == nil)
                MusicIconButton("plus.square.on.square", WorkbenchText.t("复制片段", "Duplicate clip")) { session.duplicateSelection() }.disabled(session.currentClip == nil)
                MusicIconButton("trash", WorkbenchText.t("删除片段", "Delete clip")) { if let clip = session.currentClip { session.edit([.removeClip(clip.id)]) } }.disabled(session.currentClip == nil)
                MusicEditingActionsButton(session: session).labelStyle(.iconOnly)
                    .help(WorkbenchText.t("MIDI 工具", "MIDI tools")).frame(minWidth: 44, minHeight: 44)
            }
            Divider().frame(height: 24)
            HStack(spacing: 16) {
                Toggle(WorkbenchText.t("吸附", "Snap"), isOn: $snap)
                Toggle(WorkbenchText.t("自动化", "Automation"), isOn: $automation)
            }.toggleStyle(.switch).controlSize(.small).tint(.accentColor)
                .fixedSize(horizontal: true, vertical: false).frame(minHeight: 44)
            Divider().frame(height: 24)
            HStack(spacing: 0) {
                MusicIconButton("minus.magnifyingglass", WorkbenchText.t("缩小时间线", "Zoom out")) { zoom = max(0.25, zoom / 1.4) }.disabled(zoom <= 0.25)
                MusicIconButton("plus.magnifyingglass", WorkbenchText.t("放大时间线", "Zoom in")) { zoom = min(8, zoom * 1.4) }.disabled(zoom >= 8)
            }
        }.buttonStyle(.borderless).font(.callout).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityIdentifier("music.editingToolbar")
    }
    private var dockBar: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                dockPicker.pickerStyle(.segmented).frame(minWidth: 600)
                dockPicker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
            if dock != .score {
                MusicIconButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", WorkbenchText.t("展开或收起编辑器", "Expand or collapse editor")) { expanded.toggle() }
            }
        }.padding(.horizontal, 6).background(Color(uiColor: .secondarySystemBackground))
    }
    private var dockPicker: some View {
        Picker(WorkbenchText.t("编辑器", "Editor"), selection: Binding(get: { dock }, set: { value in
            let wasExpandedEditor = dock == .dj || dock == .score
            if dock == .score || value == .score { session.stopLive(); session.stopPlayback() }
            dock = value
            if value == .dj || value == .score { expanded = true }
            else if wasExpandedEditor { expanded = false }
        })) {
            ForEach(MusicWorkbenchDock.allCases) { value in
                Label(value.title, systemImage: value.icon).tag(value)
            }
        }.accessibilityIdentifier("music.dock")
    }
    @ViewBuilder private var dockContent: some View {
        switch dock {
        case .mixer: MusicMixerPanel(session: session)
        case .piano: MusicPianoRoll(session: session)
        case .drums: MusicDrumGrid(session: session)
        case .keyboard: MusicKeyboardWorkbench(session: session)
        case .dj: MusicDJWorkbench(session: session, onImport: { importing = true })
        case .score: MusicNotationWorkbench(session: session, onAssistant: onAssistant, onClose: { dock = .mixer; expanded = false })
        }
    }
    private var inspectorContent: some View {
        VStack(spacing: 0) {
            Text(WorkbenchText.t("检查器", "Inspector")).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            MusicEffectsInspector(session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WorkbenchText.t("检查器", "Inspector"))
        .accessibilityIdentifier("music.inspector")
    }
    private var statusBar: some View {
        HStack(spacing: 6) {
            if let error = session.diagnostic {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Menu(WorkbenchText.t("操作未完成", "Action unfinished")) {
                    Text(error)
                    Button(WorkbenchText.t("关闭提示", "Dismiss notice")) { session.diagnostic = nil }
                }
            } else { Text(session.isRecording || session.isMIDIRecording ? WorkbenchText.t("正在录音", "Recording") : session.isRendering ? WorkbenchText.t("正在生成音频…", "Generating audio…") : session.saving ? WorkbenchText.t("正在保存…", "Saving…") : WorkbenchText.t("已保存", "Saved")) }
            Spacer()
            Text("\(session.document.tracks.count) " + WorkbenchText.t("轨", "tracks"))
            Text("· \(session.document.tempoMap.sampleRate / 1000) kHz")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 25)
            .accessibilityElement(children: .combine).accessibilityIdentifier("music.status")
    }
    private func renameProject() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let revision = session.document.revision
        Task {
            do {
                _ = try await session.apply([.setName(title)], expectedRevision: revision)
                // File-list metadata follows the committed document; a
                // metadata refresh failure never replays an already saved edit.
                try? await PersonalContentService.shared.library().markChanged(session.id, title: session.document.name)
            } catch { session.diagnostic = error.localizedDescription }
        }
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

/// Keep the custom play control's pressed and disabled feedback explicit.
private struct MusicTransportPlayStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

enum MusicWorkbenchFormat {
    static func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%02d:%02d.%03d", Int(value) / 60, Int(value) % 60, Int(value * 1000) % 1000)
    }
    static func position(_ seconds: Double, tempoMap: MusicTempoMap) -> String {
        let safe = seconds.isFinite ? min(9.0e15, max(0, seconds * Double(tempoMap.sampleRate))) : 0
        let tick = (try? tempoMap.tick(atSample: .init(Int64(safe))).value) ?? 0
        var meter = tempoMap.segments[0]
        var sectionStart: Int64 = 0, bar: Int64 = 1
        for segment in tempoMap.segments.dropFirst() where segment.startTick.value <= tick {
            guard segment.beatsPerBar != meter.beatsPerBar || segment.beatUnit != meter.beatUnit else { continue }
            let step = max(1, Int64(tempoMap.ticksPerQuarter * 4 / meter.beatUnit))
            let barTicks = step * Int64(meter.beatsPerBar), span = segment.startTick.value - sectionStart
            bar += span / barTicks + (span % barTicks == 0 ? 0 : 1)
            sectionStart = segment.startTick.value; meter = segment
        }
        let step = max(1, Int64(tempoMap.ticksPerQuarter * 4 / meter.beatUnit))
        let barTicks = step * Int64(meter.beatsPerBar), elapsed = tick - sectionStart
        return String(format: "%03lld.%lld.%03lld", bar + elapsed / barTicks, (elapsed % barTicks) / step + 1, elapsed % step)
    }
    static func decibels(_ gain: Double) -> Double { gain > 0 ? max(-60, 20 * log10(gain)) : -60 }
    static func gain(_ decibels: Double) -> Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    static func color(_ index: Int) -> Color { [.blue, .orange, .green, .purple, .teal, .pink][index % 6] }
}
/// The editor's remaining height belongs to this split. Scroll views inside
/// the mixer/inspector must not choose the arrangement's height from content.
struct MusicWorkbenchPanels<Arrangement: View, DockBar: View, Dock: View, Inspector: View>: View {
    let expanded: Bool
    let showsDock: Bool
    let inspectorWidth: CGFloat
    var prioritizesKeyboard = false
    let arrangement: Arrangement
    let dockBar: DockBar
    let dockContent: Dock
    let inspector: Inspector
    var body: some View {
        GeometryReader { geometry in
            let height = max(0, geometry.size.height)
            let barHeight = min(44, height)
            // Performance keys need usable depth, particularly in portrait.
            // Keep the timeline available, while sharing height with the keys
            // instead of capping every lower editor at 290 points.
            let desiredDockHeight = prioritizesKeyboard ? max(220, height * 0.55)
                : min(290, max(220, height * 0.38))
            // Keep one ruler and one lane visible whenever the viewport fits;
            // a short viewport reduces the dock first. Expand gives it all.
            let dockHeight = expanded ? max(0, height - barHeight)
                : showsDock ? min(desiredDockHeight, max(0, height - barHeight - 196)) : 0
            let arrangementHeight = expanded ? 0 : max(0, height - barHeight - dockHeight)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !expanded { arrangement.frame(height: arrangementHeight).clipped() }
                    dockBar.frame(height: barHeight)
                    if showsDock { dockContent.frame(height: dockHeight).clipped() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if inspectorWidth > 0 {
                    Divider()
                    inspector.frame(width: inspectorWidth, height: height, alignment: .top)
                }
            }.frame(width: geometry.size.width, height: height, alignment: .topLeading)
        }
    }
}

#endif

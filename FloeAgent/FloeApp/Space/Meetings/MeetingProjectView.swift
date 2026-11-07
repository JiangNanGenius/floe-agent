// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import FloeMeetings

struct MeetingProjectView: View {
    @Bindable var session: MeetingProjectSession
    let record: PersonalContentRecord
    @Binding var assistantRequested: Bool
    @State private var inspector = 0
    @State private var compactNotes = true
    @State private var showsInspector = true
    @State private var importing = false
    @State private var recordings = false
    @State private var settings = false
    @State private var todo = ""
    @FocusState private var todoFocused: Bool
    @State private var composerEditingSources: Set<UUID> = []
    @State private var correction: TranscriptSegment?
    @State private var correctedText = ""
    @State private var speaker: Speaker?
    @State private var followupTodo: TodoItem?
    @State private var speakerName = ""
    @State private var bilingual = true
    @State private var transcriptionServices: [AssistantAudioServiceDescriptor] = []
    @ScaledMetric(relativeTo: .body) private var recorderHeight: CGFloat = 54

    var body: some View {
        // Measure before reserving the recorder. Its removal in compact input
        // mode must never increase the measured height and flip the mode back.
        GeometryReader { available in
            let compactInput = (todoFocused || !composerEditingSources.isEmpty)
                && available.size.height > 0 && available.size.height < 440
            meetingContent(compactInput: compactInput)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !compactInput { recorder }
                }
        }
        // Only this page's actual text editors own its keyboard avoidance.
        // A covered library/search field must not shorten the whole meeting.
        .ignoresSafeArea(.keyboard, edges: todoFocused || !composerEditingSources.isEmpty ? [] : .bottom)
        .onPreferenceChange(NativeComposerEditingSourcesKey.self) { sources in
            if composerEditingSources != sources { composerEditingSources = sources }
        }
        .onChange(of: inspector) { _, _ in todoFocused = false }
        .onChange(of: compactNotes) { _, _ in todoFocused = false }
        .accessibilityIdentifier("meeting.workbench")
        .task { await session.loadNotebook() }
        .onChange(of: assistantRequested) { _, requested in
            guard requested else { return }
            inspector = 2; showsInspector = true; compactNotes = false
            assistantRequested = false
        }
        .onDisappear { session.stopPlayback() }
        .sheet(isPresented: $recordings) { recordingSheet }
        .sheet(isPresented: $settings) { settingsSheet }
        .sheet(item: $followupTodo) { MeetingFollowupView(session: session, todo: $0) }
        .alert(t("更正逐字稿", "Correct transcript"), isPresented: Binding(get: { correction != nil }, set: { if !$0 { correction = nil } })) {
            TextField(t("文字", "Text"), text: $correctedText, axis: .vertical)
            Button(t("保存", "Save")) {
                if let correction { Task { await session.correct(correction, text: correctedText) } }; correction = nil
            }
            Button(t("取消", "Cancel"), role: .cancel) { correction = nil }
        }
        .alert(t("发言人", "Speaker"), isPresented: Binding(get: { speaker != nil }, set: { if !$0 { speaker = nil } })) {
            TextField(t("姓名", "Name"), text: $speakerName)
            Button(t("保存", "Save")) {
                if let speaker { Task { await session.renameSpeaker(speaker, label: speakerName) } }; speaker = nil
            }
            Button(t("取消", "Cancel"), role: .cancel) { speaker = nil }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): Task { await session.importFile(url); recordings = true }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
    }
    private func meetingContent(compactInput: Bool) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if compactInput { compactInputHeader(wide: geometry.size.width >= 820) }
                else { header(wide: geometry.size.width >= 820) }
                Divider()
                if geometry.size.width >= 820 {
                    HStack(alignment: .top, spacing: 0) {
                        notebook(compactInput: compactInput)
                        if showsInspector { Divider(); sidePanel(compactInput: compactInput).frame(width: min(400, geometry.size.width * 0.36)) }
                    }.frame(maxHeight: .infinity)
                } else {
                    Picker(t("会议工作区", "Meeting workspace"), selection: $compactNotes) {
                        Text(t("我的笔记", "My notes")).tag(true)
                        Text(t("转写与整理", "Transcript and minutes")).tag(false)
                    }.pickerStyle(.segmented).padding(8)
                    if compactNotes { notebook(compactInput: compactInput) } else { sidePanel(compactInput: compactInput) }
                }
                if let player = session.player {
                    HStack {
                        VideoPlayer(player: player).frame(height: 130)
                        Button(t("关闭播放", "Close playback"), systemImage: "xmark") { session.stopPlayback() }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }.padding(.horizontal, 8)
                }
                if session.isExportingDocument {
                    HStack {
                        ProgressView(); Text(t("正在导出会议", "Exporting meeting"))
                        Spacer()
                        Button(t("取消", "Cancel")) { session.cancelDocumentExport() }.frame(minHeight: 44)
                    }.font(.callout).padding(.horizontal, 12)
                }
                if let file = session.export {
                    HStack {
                        ShareLink(item: file) { Label(t("分享导出文件", "Share exported file"), systemImage: "square.and.arrow.up") }
                        if let index = session.exportSourceIndex, index != file {
                            ShareLink(item: index) { Text(t("来源与时间索引", "Source and time index")) }
                        }
                    }.font(.callout).padding(8)
                }
                if let diagnostic = session.diagnostic {
                    DisclosureGroup(t("操作未完成，查看详情", "Unable to finish. View details")) {
                        Text(diagnostic).font(.caption).textSelection(.enabled)
                    }.font(.footnote).padding(.horizontal).padding(.vertical, 6)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .background(Color(uiColor: .systemGroupedBackground))
                .clipped()
                .accessibilityElement(children: .contain)
                #if DEBUG
                .background {
                    if MeetingLayoutObservation.enabled {
                        MeetingLayoutObservation(geometrySize: geometry.size,
                            geometryFrame: geometry.frame(in: .global), geometryInsets: geometry.safeAreaInsets,
                            todoFocused: todoFocused, editingComposerCount: composerEditingSources.count)
                            .frame(width: 0, height: 0).accessibilityHidden(true)
                    }
                }
                #endif
        }
    }
    private func header(wide: Bool) -> some View {
        HStack {
            Label(session.meeting.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            Text(t("\(session.speakers.count) 位发言人", "\(session.speakers.count) speakers"))
            Spacer()
            if wide {
                Button(t("会议侧栏", "Meeting sidebar"), systemImage: "sidebar.right") { showsInspector.toggle() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            Menu {
                Button(t("会议设置", "Meeting settings"), systemImage: "slider.horizontal.3") { settings = true }
                Button(t("录音与素材", "Recordings and media"), systemImage: "waveform") { recordings = true }
                Button(t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") { importing = true }
                templatesMenu
                exportMenu
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel(t("会议操作", "Meeting actions"))
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal)
    }
    private func compactInputHeader(wide: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                if !wide {
                    Button(t("我的笔记", "My notes")) { compactNotes = true }
                    Divider()
                }
                Picker(t("会议侧栏", "Meeting sidebar"), selection: Binding(
                    get: { inspector }, set: { inspector = $0; showsInspector = true; compactNotes = false })) {
                    Text(t("转写", "Transcript")).tag(0)
                    Text(t("重点", "Highlights")).tag(1)
                    Text(t("会议助手", "Assistant")).tag(2)
                }
            } label: {
                Label(inspector == 0 ? t("转写", "Transcript") : inspector == 1 ? t("重点", "Highlights") : t("会议助手", "Assistant"),
                      systemImage: "sidebar.right")
                    .lineLimit(1).frame(minHeight: 44)
            }.accessibilityIdentifier("meeting.compact.sections")
            Spacer(minLength: 0)
            Group {
                if session.isRecording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel(t("录音中", "Recording"))
                    Button(t("暂停", "Pause"), systemImage: "pause") { Task { await session.pauseRecording() } }
                        .accessibilityIdentifier("meeting.record.pause")
                    Button(t("结束", "Finish"), systemImage: "stop.fill") { Task { await session.stopRecording() } }
                        .accessibilityIdentifier("meeting.record.stop")
                } else {
                    Button(session.isPaused ? t("继续录音", "Resume") : t("开始录音", "Record"), systemImage: "record.circle") { Task { await session.startRecording() } }
                        .accessibilityIdentifier("meeting.record")
                    if session.isPaused {
                        Button(t("结束", "Finish"), systemImage: "stop.fill") { session.isPaused = false }
                            .accessibilityIdentifier("meeting.record.stop")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .disabled(session.changingCapture)
            Menu {
                Text(session.meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                Text(t("\(session.speakers.count) 位发言人", "\(session.speakers.count) speakers"))
                Divider()
                Button(t("标记重点", "Mark moment"), systemImage: "bookmark") { Task { await session.addMarker() } }
                    .disabled(!session.isRecording && session.playingSession == nil)
                Button(t("录音与素材", "Recordings and media"), systemImage: "waveform") { recordings = true }
                Button(t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") { importing = true }
                Button(t("会议设置", "Meeting settings"), systemImage: "slider.horizontal.3") { settings = true }
                templatesMenu
                exportMenu
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel(t("会议操作", "Meeting actions"))
        }
        .font(.callout).padding(.horizontal, 12).background(.bar)
        .buttonStyle(CompactMeetingButtonStyle())
    }

    private struct CompactMeetingButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.frame(minWidth: 44, minHeight: 44)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }

    private var templatesMenu: some View {
        Menu(t("纪要模板", "Minutes template"), systemImage: "list.bullet.rectangle") {
            ForEach(MeetingMinutesTemplate.allCases) { template in
                Button { session.selectTemplate(template) } label: {
                    if session.minutesTemplate == template { Label(template.title, systemImage: "checkmark") }
                    else { Text(template.title) }
                }
            }
            Divider()
            Button(t("插入提纲", "Insert outline"), systemImage: "text.badge.plus") { Task { await session.insertTemplateOutline() } }
        }
    }
    private var exportMenu: some View {
        Menu(t("导出会议", "Export meeting"), systemImage: "square.and.arrow.up") {
            Button(t("Word 文字纪要", "Word text minutes")) { session.startDocumentExport(.word) }
            Button(t("PDF 文字纪要", "PDF text minutes")) { session.startDocumentExport(.pdf) }
            Button(t("笔记 PDF（含手写）", "Notes PDF with handwriting")) { session.startDocumentExport(.notebookPDF) }
            Button(t("来源与时间索引", "Source and time index")) { session.startDocumentExport(.sources) }
            Divider()
            Menu(t("逐字稿与字幕", "Transcript and captions")) {
                ForEach(MeetingExportFormat.allCases, id: \.self) { format in
                    Button(format == .markdown ? "Markdown" : format.rawValue.uppercased()) { Task { await session.exportTranscript(format) } }
                }
            }
            Button(t("整理成手记副本", "Save a compiled note")) { Task { await session.saveAsNote() } }
        }.disabled(session.isExportingDocument)
    }
    private func notebook(compactInput: Bool) -> some View {
        VStack(spacing: 0) {
            if let document = session.notebook.document {
                NotesDocumentEditor(session: session.notebook, document: document, embedded: true, compactEmbeddedChrome: compactInput,
                    onAssistant: { inspector = 2; showsInspector = true; compactNotes = false }).id(document.id)
                    .modifier(NotesConflictAccess(session: session.notebook))
            } else {
                ContentUnavailableView {
                    Label(t("我的会议笔记", "My meeting notes"), systemImage: "note.text")
                } actions: { Button(t("打开笔记", "Open notes")) { Task { await session.loadNotebook() } } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("meeting.personalNotes")
    }
    private func sidePanel(compactInput: Bool) -> some View {
        VStack(spacing: 0) {
            if !compactInput {
                Picker(t("会议侧栏", "Meeting sidebar"), selection: $inspector) {
                    Text(t("转写", "Transcript")).tag(0); Text(t("重点", "Highlights")).tag(1); Text(t("会议助手", "Assistant")).tag(2)
                }.pickerStyle(.segmented).padding(10)
                Divider()
            }
            if session.isAnalyzing {
                HStack { ProgressView(); Text(t("正在整理", "Organizing")); Spacer()
                    Button(t("停止", "Stop")) { session.intelligenceTask?.cancel() }
                }.font(.caption).padding()
            }
            Group {
                switch inspector { case 0: transcriptPanel; case 1: highlightsPanel; default: questionsPanel(compactInput: compactInput) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
    private var transcriptPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text(t("逐字稿", "Transcript")).font(.headline); Spacer()
                    Toggle(t("双语", "Bilingual"), isOn: $bilingual).fixedSize().font(.caption)
                }
                liveTranscriptionStatus
                if bilingual {
                    Button(t("翻译未处理的段落", "Translate new segments"), systemImage: "character.bubble") { session.analyze("translate") }
                        .disabled(session.isAnalyzing || session.transcript.isEmpty)
                }
                if session.transcript.isEmpty {
                    ContentUnavailableView(t("转写会显示在这里", "The transcript appears here"), systemImage: "text.bubble",
                        description: Text(t("录音时分段转写；也可在素材中转写已保存的音视频。", "Recording transcribes in chunks. Saved media can also be transcribed from Media.")))
                    Button(t("录音与素材", "Recordings and media")) { recordings = true }
                }
                ForEach(session.transcript) { segment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            if let current = session.speakers.first(where: { $0.id == segment.speakerID }) {
                                Button(current.label) { speakerName = current.label; speaker = current }.font(.caption.weight(.medium))
                            } else { Text(t("发言", "Speech")).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button(time(segment.range.start)) { session.play(segment) }.font(.caption.monospacedDigit())
                        }
                        Text(segment.text).textSelection(.enabled)
                        if bilingual, let value = session.intelligence.translations[segment.id.rawValue], value.original == segment.text {
                            Text(value.text).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.contextMenu {
                        Button(t("更正文字", "Correct text")) { correctedText = segment.text; correction = segment }
                        Button(t("插入笔记", "Insert in notes")) { insert("[\(time(segment.range.start))] \(segment.text)", ai: false) }
                    }
                    Divider()
                }
            }.padding(16)
        }.accessibilityIdentifier("meeting.transcript")
    }
    private var liveTranscriptionText: String {
        guard let live = session.liveTranscription else { return t("转写准备中", "Preparing transcription") }
        if !live.enabled { return session.isRecording ? t("转写已暂停，录音继续", "Transcription paused; recording continues") : t("转写已暂停", "Transcription paused") }
        if live.requiresRetry { return t("录音已保留，待重试 \(live.unfinishedCount) 段", "Recording saved; \(live.unfinishedCount) chunks need retrying") }
        if live.waitingForService { return t("正在等待转写服务，录音继续保留", "Waiting for transcription; audio is being saved") }
        if live.isWorking { return t("正在转写 · 等待 \(live.pendingCount) 段", "Transcribing · \(live.pendingCount) chunks pending") }
        if session.isRecording { return t("正在收集下一段录音", "Collecting the next audio chunk") }
        return t("已转写 \(live.chunks.filter { $0.state == .complete }.count) 段", "\(live.chunks.filter { $0.state == .complete }.count) chunks transcribed")
    }
    @ViewBuilder private var liveTranscriptionStatus: some View {
        if let live = session.liveTranscription {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if live.isWorking { ProgressView().controlSize(.small) }
                    Text(liveTranscriptionText).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("meeting.transcription.status")
                    Spacer(minLength: 0)
                }
                if live.requiresRetry || (!live.enabled && live.unfinishedCount > 0) {
                    HStack {
                        Button(t("重试转写", "Retry transcription")) {
                            session.diagnostic = nil
                            if session.intelligence.liveTranscription == false {
                                session.updateIntelligence { $0.liveTranscription = true }
                            } else { live.retryUnfinished() }
                        }.disabled(live.isWorking).frame(minHeight: 44)
                            .accessibilityIdentifier("meeting.transcription.retry")
                        Button(t("转写设置", "Transcription settings")) { settings = true }.frame(minHeight: 44)
                    }
                }
            }
        }
    }
    private var highlightsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(t("AI 纪要", "AI minutes")).font(.headline); Spacer()
                    if session.isUpdatingMinutes { ProgressView().controlSize(.small) }
                    Button(t("更新", "Update"), systemImage: "sparkles") { session.analyze("summary") }.disabled(session.isAnalyzing || session.transcript.isEmpty)
                }
                if session.summaries.isEmpty { Text(t("纪要独立整理，需要时再插入自己的笔记。", "Minutes are organized separately. Insert what you want into your notes.")).font(.callout).foregroundStyle(.secondary) }
                ForEach(session.summaries.reversed()) { summary in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        Text(summary.text).textSelection(.enabled)
                        Button(t("插入笔记", "Insert in notes"), systemImage: "text.badge.plus") { insert(summary.text, ai: true) }
                    }; Divider()
                }
                Text(t("结论与待办", "Decisions and to-dos")).font(.headline)
                ForEach(session.decisions) { Text($0.text).textSelection(.enabled) }
                ForEach(session.todos) { item in
                    HStack {
                        Toggle(item.text, isOn: Binding(get: { item.status == .done }, set: { value in Task { await session.setDone(item, done: value) } }))
                        Button(t("跟进", "Follow up"), systemImage: "bell.badge") { followupTodo = item }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .disabled(item.status != .open)
                    }
                }
                HStack {
                    TextField(t("添加待办", "Add to-do"), text: $todo, axis: .vertical)
                        .focused($todoFocused)
                    Button(t("添加", "Add"), systemImage: "plus.circle") {
                        let text = todo; Task { if await session.addTodo(text), todo == text { todo = "" } }
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !session.markers.isEmpty {
                    Text(t("时间标记", "Time markers")).font(.headline)
                    ForEach(session.markers) { marker in Button(marker.label ?? t("重点", "Highlight"), systemImage: "bookmark") { session.play(marker.source) } }
                }
            }.padding(16)
        }
    }
    private func questionsPanel(compactInput: Bool) -> some View {
        VStack(spacing: 0) {
            if !session.intelligence.answers.isEmpty {
                DisclosureGroup(t("以往问答", "Previous Q&A")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(session.intelligence.answers) { answer in
                                Text(answer.question).font(.headline)
                                Text(answer.answer).textSelection(.enabled)
                                Button(t("插入笔记", "Insert in notes")) { insert(answer.answer, ai: true) }
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 180)
                }.padding(12)
                Divider()
            }
            StudioAssistantView(record: record, embedded: true, showsMeetingHelp: !compactInput)
                .id(record.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("meeting.assistant")
    }
    private var recorder: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(session.isRecording ? t("录音中", "Recording") : session.isPaused ? t("已暂停", "Paused") : t("准备录音", "Ready to record"), systemImage: session.isRecording ? "record.circle.fill" : "mic")
                        if session.isRecording || (session.liveTranscription?.unfinishedCount ?? 0) > 0 {
                            Text(liveTranscriptionText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                        .foregroundStyle(session.isRecording ? Color.red : Color.secondary)
                    if session.liveTranscription?.isWorking == true { Label(t("转写中", "Transcribing"), systemImage: "text.bubble").font(.caption) }
                    Button(t("素材", "Media"), systemImage: "waveform") { recordings = true }
                    Button(t("标记重点", "Mark moment"), systemImage: "bookmark") { Task { await session.addMarker() } }.disabled(!session.isRecording && session.playingSession == nil)
                    if session.isRecording {
                        Button(t("暂停", "Pause"), systemImage: "pause") { Task { await session.pauseRecording() } }
                        Button(t("结束", "Finish"), systemImage: "stop.fill") { Task { await session.stopRecording() } }
                    } else {
                        Button(session.isPaused ? t("继续录音", "Resume") : t("开始录音", "Record"), systemImage: "record.circle") { Task { await session.startRecording() } }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("meeting.record")
                        if session.isPaused { Button(t("结束", "Finish")) { session.isPaused = false } }
                    }
                }.buttonStyle(.bordered).frame(minHeight: recorderHeight).padding(.horizontal, 12).disabled(session.changingCapture)
            }.frame(height: recorderHeight).scrollIndicators(.hidden).background(.bar)
        }
        // Keep the complete bar at the bottom safe-area boundary; its outer
        // stack must not compete with the editor for flexible height.
        .frame(height: recorderHeight + 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.recorder")
    }
    private var recordingSheet: some View {
        NavigationStack {
            List {
                Button(t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") { recordings = false; importing = true }
                if let live = session.liveTranscription, !live.chunks.isEmpty {
                    HStack {
                        Text(t("录音片段转写", "Recorded chunk transcription"))
                        Spacer()
                        Text("\(live.chunks.filter { $0.state == .complete }.count) / \(live.chunks.count)").font(.caption.monospacedDigit())
                    }
                    if live.isWorking { Button(t("停止片段转写", "Stop chunk transcription")) { live.cancel() } }
                    Button(t("重试未完成片段", "Retry unfinished chunks")) { live.retryUnfinished() }.disabled(live.isWorking)
                }
                if session.isProcessing {
                    ProgressView(value: session.progress) { Text(t("正在转写", "Transcribing")) }
                    Button(t("停止转写", "Stop transcription")) { session.cancelProcessing() }
                }
                ForEach(session.visibleRecordings) { recording in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(recording.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? t("现场录音", "Recording"), systemImage: "waveform")
                        if let seconds = recording.durationSeconds { Text(time(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        HStack {
                            Button(t("播放", "Play")) { session.play(recording); recordings = false }
                            Button(t("转写", "Transcribe")) { session.transcribe(recording); inspector = 0; compactNotes = false }.disabled(session.isProcessing)
                            if let file = try? session.mediaFile(for: recording) { ShareLink(item: file) { Text(t("导出原片", "Export source")) } }
                        }.disabled(recording.state != .stopped)
                    }.padding(.vertical, 6)
                }
            }.navigationTitle(t("录音与素材", "Recordings and media"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(t("完成", "Done")) { recordings = false } } }
        }
    }
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section(t("录音与转写", "Recording and transcription")) {
                    Toggle(t("边录音边转写", "Transcribe while recording"), isOn: Binding(get: { session.intelligence.liveTranscription != false },
                        set: { value in session.updateIntelligence { $0.liveTranscription = value } }))
                    Picker(t("转写服务", "Transcription service"), selection: Binding(get: { session.intelligence.transcriptionServiceID ?? "" },
                        set: { value in session.updateIntelligence { $0.transcriptionServiceID = value.isEmpty ? nil : value } })) {
                        Text(t("本机 Whisper", "On-device Whisper")).tag("")
                        ForEach(transcriptionServices) { service in
                            Text(service.title + (service.local ? "" : t(" · 云端", " · Cloud"))).tag(service.id)
                        }
                    }
                    Text(t("默认保留本地录音；云端转写需在这里明确选择已有服务。", "Recordings stay local. Cloud transcription uses a service you explicitly select here."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(t("纪要", "Minutes")) {
                    Picker(t("模板", "Template"), selection: Binding(get: { session.minutesTemplate.rawValue }, set: { value in
                        if let template = MeetingMinutesTemplate(rawValue: value) { session.selectTemplate(template) }
                    })) {
                        ForEach(MeetingMinutesTemplate.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text(session.minutesTemplate.sections.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Button(t("插入提纲到我的笔记", "Insert an outline in my notes")) { Task { await session.insertTemplateOutline() } }
                    Toggle(t("自动更新 AI 纪要", "Update AI minutes automatically"), isOn: Binding(get: { session.intelligence.automaticSummary }, set: { value in session.updateIntelligence { $0.automaticSummary = value } }))
                    Picker(t("更新间隔", "Update interval"), selection: Binding(get: { session.intelligence.summaryInterval }, set: { value in session.updateIntelligence { $0.summaryInterval = value } })) {
                        Text(t("60 秒", "60 seconds")).tag(60); Text(t("30 秒", "30 seconds")).tag(30)
                    }
                    Text(t("使用模型设置中选择的文本模型整理已有转写。", "Uses the text model selected in model settings to organize the transcript.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(t("翻译", "Translation")) {
                    TextField(t("目标语言", "Target language"), text: Binding(get: { session.intelligence.translationLanguage }, set: { value in session.updateIntelligence { $0.translationLanguage = String(value.prefix(100)) } }))
                }
            }.navigationTitle(t("会议设置", "Meeting settings"))
                .task {
                    await session.environment.assistantAudioService.refreshAvailability()
                    transcriptionServices = session.environment.assistantAudioService.services.filter { $0.capability == .transcription }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(t("完成", "Done")) { settings = false } } }
        }
    }
    private func insert(_ text: String, ai: Bool) { Task { do { try await session.appendToNotebook(text, aiGenerated: ai) } catch { session.diagnostic = error.localizedDescription } } }
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
#endif

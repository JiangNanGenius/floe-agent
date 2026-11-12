// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeMeetings

struct MeetingProjectView: View {
    @Bindable var session: MeetingProjectSession
    let record: PersonalContentRecord
    @Binding var assistantRequested: Bool
    @State private var inspector = 0
    @State private var compactNotes = true
    @State private var showsInspector = true
    @State private var sidePanelWidth: CGFloat?
    @State private var splitDragOrigin: CGFloat?
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
            let wide = geometry.size.width >= 820
            let sideWidth = wide && showsInspector ? splitSideWidth(available: geometry.size.width) : nil
            VStack(spacing: 0) {
                if compactInput { compactInputHeader() }
                else { header(wide: wide) }
                Divider()
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        notebook(compactInput: compactInput)
                        if let sideWidth {
                            splitHandle(available: geometry.size.width, sideWidth: sideWidth)
                            sidePanel(compactInput: compactInput,
                                      showsSectionPicker: !compactInput, available: geometry.size.width)
                                .frame(width: sideWidth)
                        }
                    }.frame(maxHeight: .infinity)
                } else {
                    if compactNotes { notebook(compactInput: compactInput) }
                    else {
                        sidePanel(compactInput: compactInput,
                                  showsSectionPicker: false, available: geometry.size.width)
                    }
                }
                if let player = session.player {
                    MeetingAudioPlaybackView(player: player, title: playbackTitle,
                        onClose: { session.stopPlayback() })
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
                    DisclosureGroup(t("有内容未完成，查看详情", "Something is unfinished. View details")) {
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
                        let notesWidth = wide && showsInspector
                            ? max(0, geometry.size.width - (sideWidth ?? 0) - 16)
                            : geometry.size.width
                        MeetingLayoutObservation(geometrySize: geometry.size,
                            geometryFrame: geometry.frame(in: .global), geometryInsets: geometry.safeAreaInsets,
                            todoFocused: todoFocused, editingComposerCount: composerEditingSources.count,
                            compactInput: compactInput, wideSplit: wide,
                            notesWidth: notesWidth, sideWidth: sideWidth,
                            showsPlayer: session.player != nil, recording: session.isRecording,
                            savedRecordingCount: session.visibleRecordings.count,
                            transcriptBubbles: session.displayTranscriptBubbles.count)
                            .frame(width: 0, height: 0).accessibilityHidden(true)
                    }
                }
                #endif
        }
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            if wide {
                Label(session.meeting.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .foregroundStyle(.secondary)
                if !session.speakers.isEmpty {
                    Text(t("\(session.speakers.count) 位发言人", "\(session.speakers.count) speakers"))
                        .foregroundStyle(.secondary)
                }
            } else {
                sectionMenu
            }
            Spacer(minLength: 8)
            if wide {
                Button(t("会议侧栏", "Meeting sidebar"), systemImage: "sidebar.right") { showsInspector.toggle() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .accessibilityValue(showsInspector ? t("已显示", "Shown") : t("已隐藏", "Hidden"))
                    .accessibilityIdentifier("meeting.inspector.toggle")
            }
            meetingActionsMenu
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .accessibilityIdentifier("meeting.header")
    }
    private func compactInputHeader() -> some View {
        HStack(spacing: 8) {
            sectionMenu
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let presentation = capturePresentation(now: context.date)
                HStack(spacing: 4) {
                    if session.changingCapture {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(t("正在处理录音", "Working with the recording"))
                    } else {
                        if session.isRecording {
                            Circle().fill(.red).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        } else if session.isPaused {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.orange)
                                .accessibilityLabel(t("已暂停", "Paused"))
                        }
                        if presentation.elapsedSeconds > 0 {
                            Text(durationText(presentation.elapsedSeconds))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        compactCaptureControls
                            .labelStyle(.iconOnly)
                    }
                }
            }
            meetingActionsMenu
        }
        .font(.callout).padding(.horizontal, 12).frame(minHeight: 48).background(.bar)
        .buttonStyle(.plain)
    }
    @ViewBuilder private var compactCaptureControls: some View {
        if session.isRecording {
            Button(t("暂停", "Pause"), systemImage: "pause") { Task { await session.pauseRecording() } }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("meeting.record.pause")
            Button(t("结束", "Finish"), systemImage: "stop.fill") { Task { await session.stopRecording() } }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("meeting.record.stop")
        } else if session.isPaused {
            Button(t("继续录音", "Resume"), systemImage: "record.circle") { Task { await session.startRecording() } }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("meeting.record")
            Button(t("结束", "Finish"), systemImage: "stop.fill") { finishPausedRecording() }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("meeting.record.stop")
        } else {
            Button(t("开始录音", "Record"), systemImage: "record.circle") { Task { await session.startRecording() } }
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("meeting.record")
        }
    }
    private var sectionMenu: some View {
        Menu {
            sectionButton(t("我的笔记", "My notes"), systemImage: "note.text", tag: 0)
            Divider()
            sectionButton(t("转写", "Transcript"), systemImage: "text.bubble", tag: 1)
            sectionButton(t("重点", "Highlights"), systemImage: "bookmark", tag: 2)
            sectionButton(t("会议助手", "Assistant"), systemImage: "sparkles", tag: 3)
        } label: {
            Label(sectionTitle, systemImage: sectionIcon)
                .font(.subheadline.weight(.medium))
                .lineLimit(1).frame(minHeight: 44)
        }
        .accessibilityIdentifier("meeting.compact.sections")
    }
    @ViewBuilder private func sectionButton(_ title: String, systemImage: String, tag: Int) -> some View {
        Button {
            selectSection(tag)
        } label: {
            if compactSection == tag { Label(title, systemImage: "checkmark") }
            else { Label(title, systemImage: systemImage) }
        }
    }
    private var compactSection: Int { compactNotes ? 0 : inspector + 1 }
    private var sectionTitle: String {
        switch compactSection {
        case 0: t("我的笔记", "My notes")
        case 1: t("转写", "Transcript")
        case 2: t("重点", "Highlights")
        default: t("会议助手", "Assistant")
        }
    }
    private var sectionIcon: String {
        switch compactSection {
        case 0: "note.text"
        case 1: "text.bubble"
        case 2: "bookmark"
        default: "sparkles"
        }
    }
    private func selectSection(_ section: Int) {
        if section == 0 { compactNotes = true }
        else { compactNotes = false; inspector = section - 1; showsInspector = true }
    }
    @ViewBuilder private var meetingActionsMenu: some View {
        Menu {
            Text(session.meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
            if !session.speakers.isEmpty {
                Text(t("\(session.speakers.count) 位发言人", "\(session.speakers.count) speakers"))
            }
            Divider()
            Button(t("录音与素材", "Recordings and media"), systemImage: "waveform") { recordings = true }
            Button(t("标记重点", "Mark moment"), systemImage: "bookmark") { Task { await session.addMarker() } }
                .disabled(!session.isRecording && session.playingSession == nil)
            Button(t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") { importing = true }
            Button(t("会议设置", "Meeting settings"), systemImage: "slider.horizontal.3") { settings = true }
            templatesMenu
            exportMenu
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
        .accessibilityLabel(t("会议操作", "Meeting actions"))
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
                VStack(alignment: .leading, spacing: 8) {
                    Label(t("我的会议笔记", "My meeting notes"), systemImage: "note.text")
                        .font(.headline)
                    Text(t("记下要点，或把转写和重点插入这里。",
                           "Capture what matters, or insert transcript and highlights here."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(t("打开笔记", "Open notes")) { Task { await session.loadNotebook() } }
                        .frame(minHeight: 44)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("meeting.personalNotes")
    }
    private func sidePanel(compactInput: Bool, showsSectionPicker: Bool, available: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsSectionPicker, !compactInput {
                HStack(spacing: 8) {
                    Picker(t("会议侧栏", "Meeting sidebar"), selection: Binding(
                        get: { inspector },
                        set: { value in inspector = value; compactNotes = false; showsInspector = true })) {
                        Text(t("转写", "Transcript")).tag(0); Text(t("重点", "Highlights")).tag(1); Text(t("会议助手", "Assistant")).tag(2)
                    }.pickerStyle(.segmented)
                    Button {
                        toggleWidePanel(available: available)
                    } label: {
                        Image(systemName: "arrow.left.and.right")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("切换转写侧栏宽度", "Toggle side panel width"))
                    .accessibilityValue(sidePanelWidth == nil ? t("标准", "Standard") : t("加宽", "Wide"))
                    .accessibilityIdentifier("meeting.inspector.width")
                }.padding(10)
                Divider()
            }
            if session.isAnalyzing {
                HStack(spacing: 8) {
                    Label(t("正在整理", "Organizing"), systemImage: "sparkles")
                    Spacer()
                    Button(t("停止", "Stop")) { session.intelligenceTask?.cancel() }
                        .frame(minHeight: 44)
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 4)
            }
            Group {
                switch inspector { case 0: transcriptPanel; case 1: highlightsPanel; default: questionsPanel(compactInput: compactInput) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
    private var transcriptPanel: some View {
        MeetingTranscriptPanel(session: session, bilingual: $bilingual,
            onCorrect: { correctedText = $0.text; correction = $0 },
            onRenameSpeaker: { speakerName = $0.label; speaker = $0 },
            onInsert: { insert($0, ai: false) }, onOpenMedia: { recordings = true },
            onOpenSettings: { settings = true },
            liveStatus: liveTranscriptionStatus)
    }
    /// Continuous, user-facing transcription state. Internal chunk counts,
    /// queue depths and collection scheduling stay in the diagnostics
    /// disclosure, never in the ordinary recording flow.
    private var liveTranscriptionText: String {
        guard let live = session.liveTranscription else { return "" }
        guard session.isRecording || session.isPaused || live.isWorking || session.isProcessing else { return "" }
        if !live.enabled {
            return session.isRecording || session.isPaused
                ? t("转写已暂停，录音会继续", "Transcription paused; recording continues")
                : t("转写已暂停", "Transcription paused")
        }
        if live.waitingForService {
            return t("转写服务繁忙，稍后继续", "Transcription service is busy; it will continue")
        }
        return ""
    }
    @ViewBuilder private var liveTranscriptionStatus: some View {
        if let live = session.liveTranscription {
            let status = liveTranscriptionText
            let offersRetry = live.requiresRetry || (!live.enabled && live.unfinishedCount > 0)
            if !status.isEmpty || offersRetry {
                VStack(alignment: .leading, spacing: 4) {
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("meeting.transcription.status")
                    }
                    if offersRetry {
                        HStack(spacing: 4) {
                            Text(t("未完成的转写可以重试", "Unfinished transcription can be retried"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(t("重试", "Retry")) { retryTranscription() }
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                                .disabled(live.isWorking)
                                .accessibilityIdentifier("meeting.transcription.retry")
                        }
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let presentation = capturePresentation(now: context.date)
                HStack(alignment: .center, spacing: 12) {
                    captureStatus(presentation)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        recorderButton(t("录音与素材", "Recordings and media"), systemImage: "waveform",
                            identifier: "meeting.recorder.media") { recordings = true }
                        if session.isRecording {
                            recorderButton(t("暂停", "Pause"), systemImage: "pause",
                                identifier: "meeting.record.pause") { Task { await session.pauseRecording() } }
                            recorderButton(t("结束录音", "Finish recording"), systemImage: "stop.fill",
                                identifier: "meeting.record.stop", prominent: true, tint: .red) { Task { await session.stopRecording() } }
                        } else if session.isPaused {
                            recorderButton(t("继续录音", "Resume recording"), systemImage: "record.circle",
                                identifier: "meeting.record", prominent: true) { Task { await session.startRecording() } }
                            recorderButton(t("结束录音", "Finish recording"), systemImage: "stop.fill",
                                identifier: "meeting.record.stop") { finishPausedRecording() }
                        } else {
                            recorderButton(t("开始录音", "Start recording"), systemImage: "record.circle",
                                identifier: "meeting.record", prominent: true) { Task { await session.startRecording() } }
                        }
                    }
                    .disabled(session.changingCapture)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: recorderHeight)
            }
        }
        // Keep the complete bar at the bottom safe-area boundary; a minimum
        // height keeps the 44 pt targets compact, while content can grow for
        // larger Dynamic Type instead of clipping.
        .frame(minHeight: recorderHeight + 1)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.recorder")
    }
    private func captureStatus(_ presentation: MeetingCapturePresentation) -> some View {
        HStack(spacing: 10) {
            captureIndicator(presentation)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(captureTitle(presentation))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(presentation.phase == .recording ? Color.red : Color.primary)
                    if presentation.elapsedSeconds > 0 {
                        Text(durationText(presentation.elapsedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(t("已录音 \(durationText(presentation.elapsedSeconds))",
                                                  "Recorded \(durationText(presentation.elapsedSeconds))"))
                            .accessibilityIdentifier("meeting.recorder.duration")
                    }
                }
                if let detail = captureDetail(presentation) {
                    HStack(spacing: 4) {
                        Text(detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        if presentation.canRetryTranscription {
                            Button { retryTranscription() } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(t("重试未完成转写", "Retry unfinished transcription"))
                            .accessibilityIdentifier("meeting.recorder.retry")
                        }
                    }
                }
            }
            .layoutPriority(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.recorder.status")
    }
    @ViewBuilder private func captureIndicator(_ presentation: MeetingCapturePresentation) -> some View {
        switch presentation.phase {
        case .recording:
            Circle().fill(.red).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.red.opacity(0.25), lineWidth: 5))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        case .paused:
            Image(systemName: "pause.circle.fill").font(.title3).foregroundStyle(.orange)
                .frame(width: 20, height: 20).accessibilityHidden(true)
        case .saved:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                .frame(width: 20, height: 20).accessibilityHidden(true)
        case .preparing, .finishing:
            ProgressView().controlSize(.small).frame(width: 20, height: 20)
                .accessibilityHidden(true)
        case .ready:
            Image(systemName: "mic.circle").font(.title3).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).accessibilityHidden(true)
        }
    }
    private var recordingSheet: some View {
        NavigationStack {
            List {
                if let diagnostic = session.diagnostic {
                    Section {
                        Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(t("清除提示", "Clear message")) { session.diagnostic = nil }
                    } header: { Text(t("需要处理", "Needs attention")) }
                }
                Section {
                    if session.isRecording {
                        Button(role: .destructive) {
                            Task { await session.stopRecording() }
                        } label: {
                            Label(t("结束录音", "Finish recording"), systemImage: "stop.fill")
                        }
                        .accessibilityIdentifier("meeting.recordings.stop")
                    }
                    Button(t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") {
                        recordings = false; importing = true
                    }
                    if session.isProcessing {
                        ProgressView(value: session.progress) { Text(t("正在转写录音", "Transcribing recording")) }
                        Button(t("停止转写", "Stop transcription")) { session.cancelProcessing() }
                    }
                }
                Section(t("录音", "Recordings")) {
                    if session.visibleRecordings.isEmpty {
                        Text(t("还没有录音。可以导入音视频，或在这里开始一段新录音。",
                               "No recordings yet. Import audio or video, or start a new recording here."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(session.visibleRecordings) { recording in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Label(recording.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent }
                                      ?? t("现场录音", "Recording"), systemImage: "waveform")
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(recordingStateLabel(recording.state))
                                    .font(.caption)
                                    .foregroundStyle(recording.state == .stopped ? Color.secondary : Color.red)
                            }
                            if let seconds = recording.durationSeconds {
                                Text(time(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Button(t("播放", "Play")) { session.play(recording); recordings = false }
                                    .disabled(session.isRecording)
                                Button(t("转写", "Transcribe")) {
                                    session.transcribe(recording); inspector = 0; compactNotes = false
                                }.disabled(session.isProcessing || session.isRecording)
                                if let file = try? session.mediaFile(for: recording) {
                                    ShareLink(item: file) { Text(t("导出原片", "Export source")) }
                                }
                                Spacer(minLength: 0)
                            }
                            .font(.callout)
                            .disabled(recording.state != .stopped)
                        }.padding(.vertical, 6)
                    }
                }
                if let live = session.liveTranscription, !live.chunks.isEmpty || live.diagnostic != nil {
                    Section(t("实时转写", "Live transcription")) {
                        if live.requiresRetry || (!live.enabled && live.unfinishedCount > 0) {
                            Button(t("重试未完成转写", "Retry unfinished transcription")) { retryTranscription() }
                                .disabled(live.isWorking)
                        }
                        if live.isWorking {
                            Button(t("停止转写", "Stop transcription")) { live.cancel() }
                        }
                        // Internal chunk scheduling detail: only inside the
                        // explicitly opened diagnostics group.
                        DisclosureGroup(t("诊断详情", "Diagnostics")) {
                            HStack {
                                Text(t("转写进度", "Transcription progress"))
                                Spacer()
                                Text("\(live.chunks.filter { $0.state == .complete }.count) / \(live.chunks.count)")
                                    .font(.caption.monospacedDigit())
                            }
                            if let diagnostic = live.diagnostic {
                                Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.font(.footnote)
                    }
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
                            let profile = session.environment.assistantAudioService.cloudASRSettings.profile(forServiceID: service.id)
                            let separatesSpeakers = profile?.fileCapabilities.supportsSpeakerAttribution == true
                                || profile?.liveCapabilities?.supportsSpeakerAttribution == true
                            return Text(service.title + (service.local ? "" : t(" · 云端", " · Cloud"))
                                 + (separatesSpeakers ? t(" · 区分说话人", " · Speaker labels") : "")).tag(service.id)
                        }
                    }
                    Text(t("录音保留在本机；云端转写只使用这里明确选择的服务。能否区分说话人取决于该服务，或使用下方本机说话人识别。",
                           "Recordings stay on this device; cloud transcription uses only the service selected here. Speaker labels depend on that service or on on-device speaker recognition below."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(t("说话人", "Speakers")) {
                    if let recognition = session.speakerRecognition {
                        switch recognition.modelStatus {
                        case .ready:
                            Label(t("本地说话人识别已就绪", "Local speaker recognition is ready"), systemImage: "person.2")
                        case .downloading(let fraction):
                            ProgressView(value: fraction) {
                                Text(t("正在准备说话人识别", "Preparing speaker recognition"))
                            }
                            Button(t("取消下载", "Cancel download"), role: .cancel) { Task { await recognition.cancelPreparation() } }
                        case .unsupported:
                            Text(t("当前构建未包含本地说话人识别", "Local speaker recognition is not included in this build"))
                        case .absent, .failed:
                            Button(t("准备本地说话人识别 · 11.2 MB", "Prepare local speaker recognition · 11.2 MB")) { Task { await recognition.retry() } }
                        }
                        if let failure = recognition.diagnostic {
                            Text(failure).font(.caption).foregroundStyle(.secondary)
                            Button(t("重试说话人识别", "Retry speaker recognition")) { Task { await recognition.retry() } }
                        }
                    }
                    Text(t("说话人识别在本机处理，不改变所选转写服务。未能确认的片段不标注姓名。", "Speaker recognition runs on device and keeps your transcription service. Uncertain passages remain unlabelled."))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(t("Argmax SpeakerKit · 模型 CC BY 4.0", "Argmax SpeakerKit · model CC BY 4.0"), destination: URL(string: "https://huggingface.co/argmaxinc/speakerkit-coreml")!)
                        .font(.caption)
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
    private func capturePresentation(now: Date) -> MeetingCapturePresentation {
        let live = session.liveTranscription
        let status = session.transcriptionStatus
        let isTranscribing: Bool
        if session.changingCapture {
            isTranscribing = false
        } else {
            switch status.phase {
            case .recordingLive, .recordingFallback, .finalizing, .transcribing:
                isTranscribing = true
            case .idle, .needsRetry, .paused:
                isTranscribing = false
            }
        }
        let spans = session.recordings.map { recording in
            MeetingRecordingSpan(
                isLiveRecording: recording.kind == .liveRecording,
                isActive: session.isRecording
                    && (recording.state == .capturing || recording.state == .pending || recording.state == .stopping),
                duration: recording.state == .stopped ? recording.durationSeconds : nil,
                startedAt: recording.startedAt)
        }
        return .resolve(
            isRecording: session.isRecording,
            isPaused: session.isPaused,
            isChangingCapture: session.changingCapture,
            transcriptionEnabled: session.intelligence.liveTranscription != false && live?.enabled != false,
            isTranscribing: isTranscribing,
            transcriptionLive: !session.changingCapture && status.isLive,
            waitingForService: !session.changingCapture && live?.waitingForService == true,
            requiresRetry: status.phase == .needsRetry,
            unfinishedCount: status.unfinishedChunks,
            isProcessingSavedRecording: session.isProcessing,
            spans: spans,
            now: now)
    }
    private func captureTitle(_ presentation: MeetingCapturePresentation) -> String {
        switch presentation.phase {
        case .ready: t("准备录音", "Ready to record")
        case .preparing: t("正在准备录音", "Preparing recording")
        case .recording: t("录音中", "Recording")
        case .finishing: t("正在结束并保存", "Finishing and saving")
        case .paused: t("已暂停", "Paused")
        case .saved: t("录音已保存", "Recording saved")
        }
    }
    private func captureDetail(_ presentation: MeetingCapturePresentation) -> String? {
        switch presentation.transcription {
        case .off:
            return t("仅录音", "Audio only")
        case .idle:
            if presentation.phase == .recording || presentation.phase == .preparing
                || presentation.phase == .finishing { return nil }
            if presentation.savedRecordingCount > 0 {
                return presentation.savedRecordingCount == 1
                    ? t("1 段录音 · 可回放", "1 recording · Ready to play")
                    : t("\(presentation.savedRecordingCount) 段录音 · 可回放", "\(presentation.savedRecordingCount) recordings · Ready to play")
            }
            return nil
        case .live:
            return t("实时转写中", "Live transcription")
        case .fallback:
            return presentation.phase == .recording
                ? t("录音继续，文字稍后补全", "Recording continues; text may arrive later")
                : t("正在转写录音", "Transcribing recording")
        case .waiting:
            return t("转写服务繁忙，稍后继续", "Transcription service is busy; it will continue")
        case .retry:
            switch presentation.phase {
            case .recording, .paused:
                return t("转写未完成，录音会保留", "Transcription is unfinished; the audio is preserved")
            case .preparing:
                return t("转写未完成，录音准备中", "Transcription is unfinished; the recording is being prepared")
            case .finishing:
                return t("转写未完成，正在保存录音", "Transcription is unfinished; the recording is being saved")
            case .saved, .ready:
                return t("转写未完成，录音已保存", "Transcription is unfinished; the recording is saved")
            }
        case .savedPass:
            return t("正在整理录音文字", "Organizing the recording's text")
        }
    }
    private var playbackTitle: String? {
        guard let id = session.playingSession,
              let recording = session.visibleRecordings.first(where: { $0.id == id }) else { return nil }
        if let path = recording.sourceFile { return URL(fileURLWithPath: path).lastPathComponent }
        return t("现场录音", "Recording")
    }
    private func retryTranscription() {
        session.diagnostic = nil
        if session.intelligence.liveTranscription == false {
            session.updateIntelligence { $0.liveTranscription = true }
        } else {
            session.liveTranscription?.retryUnfinished()
        }
    }
    private func finishPausedRecording() { session.isPaused = false }
    private func recorderButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        prominent: Bool = false,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(prominent ? tint : Color.clear, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
    private func splitSideWidth(available: CGFloat) -> CGFloat {
        let preferred = sidePanelWidth ?? min(720, max(440, available * 0.56))
        return clampedSideWidth(preferred, available: available)
    }
    private func clampedSideWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let handle: CGFloat = 16
        let minimumNotes: CGFloat = 340
        let minimumSide: CGFloat = 420
        let maximumSide = max(minimumSide, available - minimumNotes - handle)
        return min(max(width, minimumSide), maximumSide)
    }
    private func toggleWidePanel(available: CGFloat) {
        let maximum = clampedSideWidth(available - 340 - 16, available: available)
        let current = sidePanelWidth ?? splitSideWidth(available: available)
        sidePanelWidth = current >= maximum - 1 ? nil : maximum
    }
    private func splitAccessibilityValue(available: CGFloat, sideWidth: CGFloat) -> String {
        guard available > 0 else { return "" }
        let side = Int(((sideWidth / available) * 100).rounded())
        return t("笔记 \(100 - side)%，侧栏 \(side)%", "Notes \(100 - side)%, side panel \(side)%")
    }
    private func splitHandle(available: CGFloat, sideWidth: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 1)
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 3, height: 36)
            Color.clear
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let origin = splitDragOrigin ?? sideWidth
                    if splitDragOrigin == nil { splitDragOrigin = origin }
                    sidePanelWidth = clampedSideWidth(origin - value.translation.width, available: available)
                }
                .onEnded { _ in splitDragOrigin = nil }
        )
        .accessibilityElement()
        .accessibilityLabel(t("调整笔记与侧栏宽度", "Resize notes and side panel"))
        .accessibilityValue(splitAccessibilityValue(available: available, sideWidth: sideWidth))
        .accessibilityHint(t("左右拖动，或上下轻扫调整宽度", "Drag left or right, or swipe up or down to resize"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: sidePanelWidth = clampedSideWidth(sideWidth - 48, available: available)
            case .decrement: sidePanelWidth = clampedSideWidth(sideWidth + 48, available: available)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("meeting.split.inspector")
        .onDisappear { splitDragOrigin = nil }
    }
    private func insert(_ text: String, ai: Bool) { Task { do { try await session.appendToNotebook(text, aiGenerated: ai) } catch { session.diagnostic = error.localizedDescription } } }
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    private func time(_ seconds: Double) -> String { durationText(seconds) }
    private func recordingStateLabel(_ state: CaptureSessionState) -> String {
        switch state {
        case .stopped: t("已保存", "Saved")
        case .pending, .capturing: t("录音中", "Recording")
        case .stopping: t("正在保存", "Saving")
        case .cancelled: t("已取消", "Cancelled")
        case .failed: t("录音失败", "Recording failed")
        }
    }
}
#endif

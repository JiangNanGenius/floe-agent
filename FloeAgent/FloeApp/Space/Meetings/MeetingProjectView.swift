// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVKit
import UniformTypeIdentifiers
import FloeMeetings

struct MeetingProjectView: View {
    @Bindable var session: MeetingProjectSession
    @State private var section = 0
    @State private var importing = false
    @State private var entry = ""
    @State private var correction: TranscriptSegment?
    @State private var correctedText = ""
    @State private var speakerName = ""
    @State private var addingSpeaker = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(session.isRecording ? IDELanguageRunText.t("结束录音", "Finish recording") : IDELanguageRunText.t("开始录音", "Record"),
                       systemImage: session.isRecording ? "stop.circle.fill" : "record.circle") {
                    Task { if session.isRecording { await session.stopRecording() } else { await session.startRecording() } }
                }.disabled(session.changingCapture).accessibilityIdentifier("meeting.record")
                Button(IDELanguageRunText.t("标记重点", "Mark moment"), systemImage: "bookmark") {
                    Task { await session.addMarker() }
                }.disabled(!session.isRecording && session.playingSession == nil)
                Spacer()
                Menu {
                    Button(IDELanguageRunText.t("导入音视频", "Import audio or video"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(IDELanguageRunText.t("添加发言人", "Add speaker")) { speakerName = ""; addingSpeaker = true }
                    ForEach(MeetingExportFormat.allCases, id: \.self) { format in
                        Button(format.rawValue.uppercased()) { Task { await session.exportTranscript(format) } }
                    }
                    Button(IDELanguageRunText.t("保存到手记", "Save to Notes")) { Task { await session.saveAsNote() } }
                        .disabled(session.savedToNotes)
                } label: { Label(IDELanguageRunText.t("更多", "More"), systemImage: "ellipsis.circle") }
            }.padding()
            if let player = session.player { VideoPlayer(player: player).frame(height: 160) }
            Picker(IDELanguageRunText.t("会议内容", "Meeting content"), selection: $section) {
                Text(IDELanguageRunText.t("录音", "Recordings")).tag(0)
                Text(IDELanguageRunText.t("逐字稿", "Transcript")).tag(1)
                Text(IDELanguageRunText.t("笔记", "Notes")).tag(2)
                Text(IDELanguageRunText.t("待办", "To-dos")).tag(3)
            }.pickerStyle(.segmented).padding(.horizontal)
            List {
                if session.isProcessing {
                    ProgressView(value: session.progress) { Text(IDELanguageRunText.t("正在转写", "Transcribing")) }
                    Button(IDELanguageRunText.t("停止转写", "Stop transcription")) { session.cancelProcessing() }
                }
                switch section {
                case 0:
                    ForEach(session.recordings) { recording in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(recording.kind == .liveRecording ? IDELanguageRunText.t("现场录音", "Recording") : IDELanguageRunText.t("导入素材", "Imported media"),
                                    systemImage: "waveform")
                                Spacer()
                                if recording.state == .capturing { Label(IDELanguageRunText.t("录制中", "Recording"), systemImage: "record.circle") }
                            }
                            if let duration = recording.durationSeconds {
                                Text("\(duration, format: .number.precision(.fractionLength(1))) s").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(IDELanguageRunText.t("播放", "Play")) { session.play(recording) }
                                Button(IDELanguageRunText.t("转写", "Transcribe")) { session.transcribe(recording) }
                                    .disabled(session.isProcessing)
                            }.disabled(recording.state != .stopped)
                        }.padding(.vertical, 6)
                    }
                    if session.recordings.isEmpty {
                        ContentUnavailableView(IDELanguageRunText.t("开始一场会议", "Start a meeting"), systemImage: "waveform.and.mic",
                            description: Text(IDELanguageRunText.t("录音或导入素材，整理逐字稿、笔记与待办。", "Record or import media, then organize transcripts, notes and to-dos.")))
                    }
                case 1:
                    ForEach(session.transcript) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                session.play(segment)
                            } label: {
                                Label("\(segment.range.start, format: .number.precision(.fractionLength(1))) s", systemImage: "play.circle")
                            }
                            Text(segment.text).textSelection(.enabled)
                            Button(IDELanguageRunText.t("更正文字", "Correct text")) { correctedText = segment.text; correction = segment }
                                .font(.caption)
                        }.padding(.vertical, 5)
                    }
                    ForEach(session.speakers) { speaker in
                        Label(speaker.label, systemImage: "person.crop.circle").foregroundStyle(.secondary)
                    }
                case 2:
                    ForEach(session.summaries) { summary in Text(summary.text).textSelection(.enabled) }
                    ForEach(session.notes) { note in Text(note.body).textSelection(.enabled) }
                    entryRow(isTodo: false)
                default:
                    ForEach(session.todos) { todo in
                        Toggle(todo.text, isOn: Binding(get: { todo.status == .done }, set: { value in
                            Task { await session.setDone(todo, done: value) }
                        }))
                    }
                    entryRow(isTodo: true)
                }
                if session.savedToNotes { Label(IDELanguageRunText.t("已保存到手记", "Saved to Notes"), systemImage: "checkmark.circle") }
                if let file = session.export {
                    ShareLink(item: file) { Label(IDELanguageRunText.t("导出文件", "Export file"), systemImage: "square.and.arrow.up") }
                }
                if let diagnostic = session.diagnostic {
                    Label(IDELanguageRunText.t("操作未完成", "Unable to finish"), systemImage: "exclamationmark.triangle")
                    DisclosureGroup(IDELanguageRunText.t("详情", "Details")) { Text(diagnostic).textSelection(.enabled) }
                }
            }.refreshable { await session.refresh() }
        }
        .onDisappear { session.stopPlayback() }
        .alert(IDELanguageRunText.t("更正逐字稿", "Correct transcript"), isPresented: Binding(
            get: { correction != nil }, set: { if !$0 { correction = nil } })) {
            TextField(IDELanguageRunText.t("文字", "Text"), text: $correctedText, axis: .vertical)
            Button(IDELanguageRunText.t("保存", "Save")) {
                if let segment = correction { Task { await session.correct(segment, text: correctedText) } }
                correction = nil
            }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { correction = nil }
        }
        .alert(IDELanguageRunText.t("发言人", "Speaker"), isPresented: $addingSpeaker) {
            TextField(IDELanguageRunText.t("姓名", "Name"), text: $speakerName)
            Button(IDELanguageRunText.t("添加", "Add")) { Task { await session.addSpeaker(speakerName) } }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): Task { await session.importFile(url) }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
    }
    private func entryRow(isTodo: Bool) -> some View {
        HStack {
            TextField(isTodo ? IDELanguageRunText.t("添加待办", "Add to-do") : IDELanguageRunText.t("添加笔记", "Add note"),
                text: $entry, axis: .vertical)
            Button(IDELanguageRunText.t("添加", "Add")) {
                let text = entry
                Task {
                    let saved = await (isTodo ? session.addTodo(text) : session.addNote(text))
                    if saved, entry == text { entry = "" }
                }
            }.disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
#endif

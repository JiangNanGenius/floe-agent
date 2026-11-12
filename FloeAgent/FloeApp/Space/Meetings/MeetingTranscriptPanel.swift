// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMeetings

/// Groups stable source segments for reading; capture and original records
/// remain owned by MeetingProjectSession/MeetingService.
struct MeetingTranscriptPanel<LiveStatus: View>: View {
    @Bindable var session: MeetingProjectSession
    @Binding var bilingual: Bool
    let onCorrect: (TranscriptSegment) -> Void
    let onRenameSpeaker: (Speaker) -> Void
    let onInsert: (String) -> Void
    let onOpenMedia: () -> Void
    let onOpenSettings: () -> Void
    let liveStatus: LiveStatus
    @State private var following = MeetingTranscriptFollowState()
    @State private var userScrolling = false
    @State private var nearLiveEnd = true
    @State private var attributionNote: String?
    private let liveEndID = "meeting.transcript.liveEnd"
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private var isLive: Bool { session.isRecording || session.liveTranscription?.isWorking == true }
    /// Concise, actionable state shown once when the selected engine cannot
    /// separate speakers. Never per-segment, never a fabricated label.
    private var showsAttributionNote: Bool {
        attributionNote != nil && !session.transcript.isEmpty
    }

    private var bubbles: [MeetingTranscriptBubble] { session.panelConfirmedTranscriptBubbles }
    private var liveDraft: String? { session.panelLiveTranscriptDraft }
    private var isLiveTranscription: Bool { session.transcriptionStatus.isLive }
    private var transcriptionBadgeText: String? {
        let status = session.transcriptionStatus
        if status.isLive { return t("实时", "Live") }
        switch status.phase {
        case .recordingFallback, .finalizing, .transcribing: return t("转写中", "Transcribing")
        default: return nil
        }
    }
    private var liveDraftIsPending: Bool {
        liveDraft == nil && session.panelLiveTranscriptDraftRaw != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptHeader
            Divider()
            transcriptScroll
        }
        .task(id: session.id) { await session.observeTranscriptPartials() }
        .task(id: session.intelligence.transcriptionServiceID) {
            await refreshAttributionNote()
        }
        .onChange(of: session.speakerRecognition?.modelStatus) { _, _ in
            Task { await refreshAttributionNote() }
        }
        .onChange(of: session.speakerRecognition?.diagnostic) { _, _ in
            Task { await refreshAttributionNote() }
        }
        .accessibilityIdentifier("meeting.transcript")
    }

    private var transcriptHeader: some View {
        HStack(spacing: 8) {
            Text(t("逐字稿", "Transcript")).font(.headline)
            if let badge = transcriptionBadgeText {
                Label(badge, systemImage: "waveform")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                    .accessibilityIdentifier("meeting.transcript.liveBadge")
            }
            Spacer(minLength: 4)
            Menu {
                Toggle(t("双语", "Bilingual"), isOn: $bilingual)
                Button(t("翻译未处理的段落", "Translate new segments"), systemImage: "character.bubble") {
                    session.analyze("translate")
                }.disabled(session.isAnalyzing || session.transcript.isEmpty)
                Divider()
                Button(t("录音与素材", "Recordings and media"), systemImage: "waveform", action: onOpenMedia)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(t("逐字稿操作", "Transcript actions"))
            .accessibilityIdentifier("meeting.transcript.actions")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    liveStatus
                    if let note = attributionNote, showsAttributionNote {
                        HStack(spacing: 4) {
                            Label(note, systemImage: "person.slash")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button(t("说话人设置", "Speaker settings")) { onOpenSettings() }
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                                .accessibilityIdentifier("meeting.transcript.speakerSettings")
                        }
                        .accessibilityIdentifier("meeting.transcript.attributionNote")
                    }
                    if isLive, attributionNote == nil, !session.speakers.isEmpty {
                        Label(t("说话人标签会随整理更新", "Speaker labels may update as the transcript settles"),
                              systemImage: "person.2")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("meeting.transcript.speakerNote")
                    }
                    if bubbles.isEmpty, liveDraft == nil, !liveDraftIsPending { emptyState }
                    ForEach(bubbles) { bubble in bubbleView(bubble) }
                    if let liveDraft { draftCard(liveDraft) }
                    else if liveDraftIsPending { draftPendingCard }
                    Color.clear.frame(height: 1).id(liveEndID)
                }.padding(12)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: userScrolling = true
                case .idle:
                    if userScrolling { following.userScrolled(nearLiveEnd: nearLiveEnd) }
                    userScrolling = false
                default: userScrolling = false
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 70
            } action: { _, near in
                nearLiveEnd = near
                if userScrolling { following.userScrolled(nearLiveEnd: near) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following.followsLive, !bubbles.isEmpty || liveDraft != nil || liveDraftIsPending {
                    Button {
                        following.returnToLive()
                        proxy.scrollTo(liveEndID, anchor: .bottom)
                    } label: {
                        Label(isLiveTranscription ? t("回到实时", "Return to live") : t("回到最新", "Jump to latest"), systemImage: "arrow.down")
                            .font(.callout.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule()).padding(12)
                    .accessibilityIdentifier("meeting.transcript.returnToLive")
                }
            }
            // A final row changes the readable transcript. A live partial is a
            // single draft card updated in place, so it never scrolls or
            // inserts a new bubble on every provider revision.
            .onChange(of: bubbles.count) { _, _ in
                if following.shouldScrollForContentUpdate { proxy.scrollTo(liveEndID, anchor: .bottom) }
            }
            .onChange(of: liveDraft != nil || liveDraftIsPending) { _, hasDraft in
                if hasDraft, following.shouldScrollForContentUpdate { proxy.scrollTo(liveEndID, anchor: .bottom) }
            }
            .onAppear {
                following.userScrolled(nearLiveEnd: isLive)
                if isLive { proxy.scrollTo(liveEndID, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        let paused = session.liveTranscription?.enabled == false
            || session.intelligence.liveTranscription == false
        return VStack(alignment: .leading, spacing: 8) {
            Label(paused ? t("转写已暂停", "Transcription paused")
                  : session.isRecording ? t("正在聆听…", "Listening…") : t("还没有逐字稿", "No transcript yet"),
                  systemImage: paused ? "pause.circle" : session.isRecording ? "waveform" : "text.bubble")
                .font(.subheadline.weight(.medium))
            Text(paused
                 ? t("录音会继续保存；可在会议设置中开启转写。", "The recording keeps saving; enable transcription in meeting settings.")
                 : session.isRecording
                 ? t("文字会先显示为草稿，确认后成为可回听的段落。", "Text appears as a draft, then becomes a saved passage you can play back.")
                 : t("录音时自动转写，也可以转写已保存的录音。", "Transcribe while recording, or transcribe a saved recording."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if paused {
                    Button(t("会议设置", "Meeting settings"), systemImage: "slider.horizontal.3", action: onOpenSettings)
                        .font(.callout).frame(minHeight: 44)
                }
                Button(t("录音与素材", "Recordings and media"), systemImage: "waveform", action: onOpenMedia)
                    .font(.callout).frame(minHeight: 44)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("meeting.transcript.empty")
    }

    private func draftCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(isLiveTranscription ? t("实时草稿", "Live draft") : t("转写草稿", "Transcription draft"),
                      systemImage: "waveform")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(t("可能更新", "May change"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.quaternary)
        }
        .transaction { transaction in transaction.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLiveTranscription ? t("实时草稿，可能继续更新", "Live draft, may still change") : t("转写草稿，可能继续更新", "Transcription draft, may still change"))
        .accessibilityIdentifier("meeting.transcript.liveDraft")
    }

    /// There is live input, but the current provider revision has no readable
    /// word yet. Show that honestly instead of a blank transcript or raw
    /// replacement/control glyphs.
    private var draftPendingCard: some View {
        HStack(spacing: 8) {
            Label(isLiveTranscription ? t("实时草稿", "Live draft") : t("转写草稿", "Transcription draft"),
                  systemImage: "waveform")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(t("正在识别…", "Recognizing…"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.quaternary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLiveTranscription ? t("实时草稿正在识别", "Live draft is recognizing") : t("转写草稿正在识别", "Transcription draft is recognizing"))
        .accessibilityIdentifier("meeting.transcript.liveDraft.pending")
    }

    private func refreshAttributionNote() async {
        attributionNote = switch await session.speakerAttributionCapability {
        case .available: nil
        case .degraded(let note): note
        case .unavailable(let reason): reason
        }
    }

    private func bubbleView(_ bubble: MeetingTranscriptBubble) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                speakerLabel(bubble)
                Spacer(minLength: 4)
                if let range = bubble.playbackRange {
                    Button { session.playTranscriptBubble(bubble) } label: {
                        Label("\(time(range.start))–\(time(range.end))", systemImage: "play.fill")
                            .font(.caption.monospacedDigit()).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(session.isRecording)
                    .accessibilityLabel(t("回听这一段", "Play this passage"))
                    .accessibilityValue("\(time(range.start))–\(time(range.end))")
                    .accessibilityIdentifier("meeting.transcript.play.\(bubble.id.uuidString)")
                }
            }
            Text(bubble.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if bubble.hasLiveTail {
                Label(t("识别中", "Recognizing"), systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if bilingual { translations(bubble) }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 2)
        }
        .contextMenu { sourceActions(bubble) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.transcript.bubble.\(bubble.id.uuidString)")
    }

    @ViewBuilder private func speakerLabel(_ bubble: MeetingTranscriptBubble) -> some View {
        if let id = bubble.speakerID,
           let speaker = session.speakers.first(where: { $0.id.rawValue == id }) {
            Menu {
                Button(t("修改姓名", "Rename speaker")) { onRenameSpeaker(speaker) }
                let targets = session.speakers.filter { $0.id != speaker.id && $0.mergedInto == nil }
                if !targets.isEmpty {
                    Menu(t("合并到说话人", "Merge into speaker")) {
                        ForEach(targets) { target in
                            Button(session.displaySpeakerLabel(target)) { Task { await session.mergeTranscriptSpeaker(speaker, into: target) } }
                        }
                    }
                    Menu(t("改判此段说话人", "Reassign this passage")) {
                        ForEach(targets) { target in
                            Button(session.displaySpeakerLabel(target)) { Task { await reassign(bubble, to: target) } }
                        }
                    }
                }
            } label: {
                Label(session.displaySpeakerLabel(speaker), systemImage: "person.fill")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.transcript.speaker.\(speaker.id.rawValue.uuidString)")
        }
    }

    /// Move every final segment of the bubble to the chosen speaker. The
    /// engine's original attribution stays recoverable through the speaker
    /// list; the user's correction wins over late engine results.
    private func reassign(_ bubble: MeetingTranscriptBubble, to speaker: Speaker) async {
        for fragment in bubble.fragments where fragment.isFinal {
            guard let segment = session.transcript.first(where: { $0.id.rawValue == fragment.id }) else { continue }
            await session.reassignSegment(segment, to: speaker)
        }
    }

    @ViewBuilder private func translations(_ bubble: MeetingTranscriptBubble) -> some View {
        let finals = bubble.fragments.filter(\.isFinal)
        let values = finals.map { session.displayTranslation(for: $0) }
        let translated = values.compactMap { value -> String? in if case .ready(let text) = value { return text }; return nil }
        if !translated.isEmpty {
            Text(translated.reduce("") { MeetingTranscriptPresentation.join($0, $1) })
                .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if values.contains(.translating) {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(t("正在翻译", "Translating")) }.font(.caption).foregroundStyle(.secondary)
        } else if !finals.isEmpty, values.contains(where: { if case .ready = $0 { return false }; return true }) {
            HStack {
                Text(values.contains(.failed) ? t("部分译文未完成", "Some translation is unfinished")
                     : (values.contains(.stale) ? t("译文待更新", "Translation needs updating") : t("待翻译", "Not translated")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(values.contains(.failed) ? t("重试", "Retry") : t("翻译", "Translate")) {
                    session.analyze("translate", segmentIDs: Set(finals.map(\.id)))
                }.font(.caption).frame(minHeight: 44).disabled(session.isAnalyzing)
            }
        }
    }

    @ViewBuilder private func sourceActions(_ bubble: MeetingTranscriptBubble) -> some View {
        let segments = bubble.fragments.compactMap { fragment in session.transcript.first { $0.id.rawValue == fragment.id } }
        if segments.count == 1, let segment = segments.first {
            Button(t("更正文字", "Correct text")) { onCorrect(segment) }
        } else if !segments.isEmpty {
            Menu(t("更正片段", "Correct a segment")) {
                ForEach(segments) { segment in
                    Button("\(time(segment.range.start)) · \(segment.text.prefix(28))") { onCorrect(segment) }
                }
            }
        }
        if !segments.isEmpty {
            Menu(t("分段回听", "Play a segment")) {
                ForEach(bubble.fragments.filter(\.isFinal)) { fragment in
                    Button("\(time(fragment.start ?? 0)) · \(fragment.text.prefix(28))") { session.playTranscriptFragment(fragment) }
                        .disabled(session.isRecording || !fragment.hasValidRange)
                }
            }
            let assignable = session.speakers.filter { $0.mergedInto == nil }
            if !assignable.isEmpty {
                Menu(t("归属此段说话人", "Attribute this passage")) {
                    ForEach(assignable) { speaker in
                        Button(session.displaySpeakerLabel(speaker)) { Task { await reassign(bubble, to: speaker) } }
                    }
                    if bubble.speakerID != nil {
                        Button(t("清除归属", "Clear attribution"), role: .destructive) {
                            Task {
                                for fragment in bubble.fragments where fragment.isFinal {
                                    guard let segment = session.transcript.first(where: { $0.id.rawValue == fragment.id }) else { continue }
                                    await session.reassignSegment(segment, to: nil)
                                }
                            }
                        }
                    }
                }
            }
            Button(t("插入笔记", "Insert in notes")) {
                let prefix = bubble.playbackRange.map { "[\(time($0.start))] " } ?? ""
                onInsert(prefix + bubble.text)
            }
        }
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "–" }
        let seconds = Int(min(value, Double(Int.max / 2)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

extension MeetingProjectSession {
    /// Confirmed rows only. A RAM-only partial revision is never promoted to
    /// a new paragraph, so bubble identity, order and text remain stable until
    /// the durable segment actually lands.
    var panelConfirmedTranscriptBubbles: [MeetingTranscriptBubble] {
        let finals = displayTranscriptFragments.filter(\.isFinal)
        guard !finals.isEmpty else { return [] }
        var originals: [UUID: UUID] = [:]
        for fragment in finals {
            originals[fragment.sessionID] = originalCaptureSession(for: CaptureSessionID(fragment.sessionID)).rawValue
        }
        return MeetingTranscriptPresentation.confirmedBubbles(
            finals,
            speakers: speakers.map { .init(id: $0.id.rawValue, label: $0.label, mergedInto: $0.mergedInto?.rawValue) },
            originalSessions: originals)
    }

    /// The single live draft is distinct from durable rows. Prefer the active
    /// capture's partial over a background chunk draft from an older range.
    var panelLiveTranscriptDraftRaw: String? {
        guard isRecording || liveTranscription?.isWorking == true || isProcessing else { return nil }
        guard liveTranscription?.enabled != false else { return nil }
        let active = recordings.first(where: { $0.state == .capturing || $0.state == .pending || $0.state == .stopping })?.id
        if let active {
            return transcriptPartials.last(where: {
                $0.sessionID == active && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.text
        }
        return transcriptPartials.last(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text
    }

    var panelLiveTranscriptDraft: String? {
        guard let raw = panelLiveTranscriptDraftRaw else { return nil }
        return MeetingTranscriptPresentation.liveDraft(raw)
    }
}
#endif

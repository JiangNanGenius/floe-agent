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
    let liveStatus: LiveStatus
    @State private var following = MeetingTranscriptFollowState()
    @State private var userScrolling = false
    @State private var nearLiveEnd = true
    private let liveEndID = "meeting.transcript.liveEnd"
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    private var isLive: Bool { session.isRecording || session.liveTranscription?.isWorking == true }

    var body: some View {
        let bubbles = session.displayTranscriptBubbles
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(t("逐字稿", "Transcript")).font(.headline)
                        Spacer()
                        Toggle(t("双语", "Bilingual"), isOn: $bilingual).fixedSize().font(.caption)
                    }
                    liveStatus
                    if bilingual {
                        Button(t("翻译未处理的段落", "Translate new segments"), systemImage: "character.bubble") {
                            session.analyze("translate")
                        }.disabled(session.isAnalyzing || session.transcript.isEmpty)
                    }
                    if session.isRecording {
                        Text(t("停止录音后可回听片段。", "Stop recording to play back a passage."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if bubbles.isEmpty {
                        ContentUnavailableView(t("转写会显示在这里", "The transcript appears here"), systemImage: "text.bubble",
                            description: Text(t("录音时分段转写；也可转写已保存的录音。", "Transcribe while recording, or transcribe a saved recording.")))
                        Button(t("录音与素材", "Recordings and media"), action: onOpenMedia)
                    }
                    ForEach(bubbles) { bubble in bubbleView(bubble) }
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
                if !following.followsLive, !bubbles.isEmpty {
                    Button {
                        following.returnToLive()
                        proxy.scrollTo(liveEndID, anchor: .bottom)
                    } label: {
                        Label(isLive ? t("回到实时", "Return to live") : t("回到最新", "Jump to latest"), systemImage: "arrow.down")
                            .font(.callout.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Capsule()).padding(12)
                    .accessibilityIdentifier("meeting.transcript.returnToLive")
                }
            }
            .onChange(of: session.displayTranscriptFragments) { _, _ in
                if following.shouldScrollForContentUpdate { proxy.scrollTo(liveEndID, anchor: .bottom) }
            }
            .onAppear {
                following.userScrolled(nearLiveEnd: isLive)
                if isLive { proxy.scrollTo(liveEndID, anchor: .bottom) }
            }
        }
        .task(id: session.id) { await session.observeTranscriptPartials() }
        .accessibilityIdentifier("meeting.transcript")
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
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
                            Button(target.label) { Task { await session.mergeTranscriptSpeaker(speaker, into: target) } }
                        }
                    }
                }
            } label: { Label(speaker.label, systemImage: "person.fill").font(.caption.weight(.medium)).frame(minHeight: 44) }
            .buttonStyle(.plain)
        } else {
            Text(t("说话人未识别", "Speaker not identified")).font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
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
            Button(t("插入笔记", "Insert in notes")) {
                let prefix = bubble.playbackRange.map { "[\(time($0.start))] " } ?? ""
                onInsert(prefix + bubble.text)
            }
        }
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "–" }
        let seconds = Int(min(value, Double(Int.max / 2)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
#endif

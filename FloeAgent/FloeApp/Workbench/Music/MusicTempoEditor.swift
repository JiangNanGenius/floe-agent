// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicTempoEditorRoute: Identifiable { let id = UUID() }
struct MusicTempoEditor: View {
    @Bindable var session: MusicProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var position = 0.0
    @State private var bpm = 120.0
    @State private var numerator = 4
    @State private var denominator = 4
    @State private var revision: Int64 = 0
    var body: some View {
        NavigationStack {
            Form {
                Section(WorkbenchText.t("速度与拍号", "Tempo and meter")) {
                    TextField(WorkbenchText.t("位置（四分音符拍）", "Position (quarter-note beats)"), value: $position, format: .number).keyboardType(.decimalPad)
                    TextField("BPM", value: $bpm, format: .number).keyboardType(.decimalPad)
                    Stepper(WorkbenchText.t("每小节拍数", "Beats per bar") + " · \(numerator)", value: $numerator, in: 1...64)
                    Picker(WorkbenchText.t("拍子单位", "Beat unit"), selection: $denominator) { ForEach([1,2,4,8,16], id: \.self) { Text("1/\($0)").tag($0) } }
                    Button(WorkbenchText.t("保存变更", "Save change")) { save() }.disabled(session.saving || session.isMIDIRecording)
                        .accessibilityIdentifier("music.tempo.save")
                }
                Section(WorkbenchText.t("已设置的变化", "Tempo map")) {
                    ForEach(session.document.tempoMap.segments, id: \.startTick.value) { segment in
                        Button { load(segment) } label: {
                            HStack { Text(String(format: "%.2f", Double(segment.startTick.value) / Double(session.document.tempoMap.ticksPerQuarter)))
                                Spacer(); Text(String(format: "%.1f BPM · %d/%d", segment.bpm, segment.beatsPerBar, segment.beatUnit)) }
                        }.swipeActions {
                            if segment.startTick.value != 0 { Button(WorkbenchText.t("删除", "Delete"), role: .destructive) { remove(segment) } }
                        }
                    }
                    Button(WorkbenchText.t("在播放位置添加", "Add at playhead")) {
                        let map = session.document.tempoMap
                        if let tick = try? map.tick(atSample: .init(Int64(session.playbackPosition * Double(map.sampleRate)))).value {
                            let active = map.segments.last(where: { $0.startTick.value <= tick }) ?? map.segments[0]
                            load(active); position = Double(tick) / Double(map.ticksPerQuarter)
                        }
                    }.disabled(session.isMIDIRecording)
                }
            }
            .navigationTitle(WorkbenchText.t("速度与拍号", "Tempo and meter")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
            .onAppear { if let segment = session.document.tempoMap.segments.first { load(segment) } }
        }.accessibilityIdentifier("music.tempo.editor")
    }
    private func load(_ segment: MusicTempoSegment) {
        position = Double(segment.startTick.value) / Double(session.document.tempoMap.ticksPerQuarter)
        bpm = segment.bpm; numerator = segment.beatsPerBar; denominator = segment.beatUnit; revision = session.document.revision
    }
    private func save() {
        guard position.isFinite, position >= 0, position < 9.0e12 else { return }
        let tick = Int64((position * Double(session.document.tempoMap.ticksPerQuarter)).rounded())
        Task { do { try await session.apply([.setTempo(atTick: .init(tick), bpm: bpm, beatsPerBar: numerator, beatUnit: denominator)], expectedRevision: revision); revision = session.document.revision }
            catch { session.diagnostic = error.localizedDescription } }
    }
    private func remove(_ segment: MusicTempoSegment) {
        let map = session.document.tempoMap, base = session.document.revision
        Task { do { let next = try MusicTempoMap(ticksPerQuarter: map.ticksPerQuarter, sampleRate: map.sampleRate, segments: map.segments.filter { $0.startTick != segment.startTick }); try await session.apply([.setTempoMap(next)], expectedRevision: base); revision = session.document.revision }
            catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif

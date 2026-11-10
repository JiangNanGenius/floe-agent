// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicKeyboard

struct MusicDrumGrid: View {
    @Bindable var session: MusicProjectSession
    private let pitches = [36, 38, 42, 46]
    private var labels: [String] { [WorkbenchText.t("底鼓", "Kick"), WorkbenchText.t("军鼓", "Snare"), WorkbenchText.t("闭镲", "Closed hat"), WorkbenchText.t("开镲", "Open hat")] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(WorkbenchText.t("节奏步进", "Step sequencer")).font(.caption.weight(.medium)); Spacer()
                MusicEditingActionsButton(session: session, initialPanel: .patterns)
                Text("1/16").font(.caption.monospacedDigit())
            }.padding(.horizontal, 12)
            if let clip = session.currentClip, case .midi(let payload) = clip.body {
                ScrollView(.horizontal) {
                    VStack(spacing: 3) {
                        ForEach(Array(pitches.enumerated()), id: \.offset) { index, pitch in
                            HStack(spacing: 3) {
                                Text(labels[index]).font(.caption).frame(width: 75, alignment: .leading)
                                ForEach(0..<16, id: \.self) { step in
                                    let tick = Int64(step * session.document.tempoMap.ticksPerQuarter / 4)
                                    let active = payload.notes.contains { $0.pitch == pitch && $0.startTick.value == tick }
                                    Button { toggle(clip, pitch: pitch, tick: tick) } label: {
                                        Text("\(step + 1)").font(.caption2.monospacedDigit()).frame(width: 44, height: 44)
                                            .background(active ? Color.accentColor : Color.secondary.opacity(step % 4 == 0 ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(active ? Color.white : Color.primary)
                                    }.buttonStyle(.plain).accessibilityLabel(labels[index] + " \(step + 1)").accessibilityAddTraits(active ? .isSelected : [])
                                }
                            }
                        }
                    }.padding(.horizontal, 12)
                }
                Text(WorkbenchText.t("步进写入当前乐器轨的 MIDI 音符。", "Steps write MIDI notes to the current instrument track.")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
            } else {
                Text(WorkbenchText.t("先在编排中选择 MIDI 片段。", "Select a MIDI clip in the arrangement.")).font(.callout).foregroundStyle(.secondary).padding()
                Button(session.currentTrack?.kind == .midi ? WorkbenchText.t("添加节奏片段", "Add rhythm clip")
                    : WorkbenchText.t("添加电子鼓组和节奏片段", "Add electronic drums and rhythm clip")) {
                    Task {
                        _ = await session.insertPattern(.drumGroove, bars: 1, rootPitch: 60, velocity: 96,
                            newTrack: session.currentTrack?.kind != .midi)
                    }
                }.padding(.horizontal).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }.padding(.top, 10).accessibilityIdentifier("music.drums")
    }
    private func toggle(_ clip: MusicClip, pitch: Int, tick: Int64) {
        guard case .midi(var payload) = clip.body else { return }
        if let index = payload.notes.firstIndex(where: { $0.pitch == pitch && $0.startTick.value == tick }) { payload.notes.remove(at: index) }
        else {
            guard tick < payload.durationTicks else { return }
            if let note = try? MusicMIDINote(pitch: pitch, startTick: .init(tick), durationTicks: min(Int64(session.document.tempoMap.ticksPerQuarter / 8), payload.durationTicks - tick), velocity: 100, channel: 9) { payload.notes.append(note) }
        }
        var next = clip; next.body = .midi(payload); session.edit([.updateClip(next)])
    }
}

struct MusicKeyboardWorkbench: View {
    @Bindable var session: MusicProjectSession
    @ScaledMetric(relativeTo: .caption) private var toolbarHeight: CGFloat = 52
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentTrack?.name ?? WorkbenchText.t("电子琴", "Keyboard")).font(.caption.weight(.medium))
                    Text(MusicInstrumentPresentation.name(session.currentTrack?.instrument)).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("music.keyboard.currentPreset")
                }.lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                MusicPresetPickerButton(session: session)
                Button(session.isLive ? WorkbenchText.t("关闭琴声", "Mute keyboard")
                    : session.currentTrack?.kind == .midi ? WorkbenchText.t("启用琴声", "Enable keyboard")
                    : WorkbenchText.t("添加乐器并启用", "Add instrument and enable")) {
                    if session.isLive { session.stopLive() }
                    else { Task { await session.activateKeyboard() } }
                }.frame(minHeight: 44).disabled(session.saving || session.isRecording)
                Toggle(WorkbenchText.t("延音", "Sustain"), isOn: Binding(
                    get: { session.keyboard.sustain }, set: { session.keyboard.sustain = $0 }))
                    .toggleStyle(.button).buttonStyle(.bordered).controlSize(.small)
                    .frame(minHeight: 44).disabled(!session.isLive)
                    .accessibilityIdentifier("floe.music.keyboard.sustain")
                Button(session.isMIDIRecording ? WorkbenchText.t("结束录制", "Finish take")
                    : session.currentTrack?.kind == .midi ? WorkbenchText.t("录制演奏", "Record take")
                    : WorkbenchText.t("添加乐器并录制", "Add instrument and record"), systemImage: session.isMIDIRecording ? "stop.circle.fill" : "record.circle") {
                    if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
                    else { Task { await session.activateKeyboard(recording: true) } }
                }.foregroundStyle(.red).frame(minHeight: 44).disabled(session.saving || session.isRecording)
            }.font(.caption).padding(.horizontal, 12) }
                .frame(height: toolbarHeight)
                .accessibilityIdentifier("music.keyboard.toolbar")
            // The host provides one preset/sustain/record toolbar. The shared
            // panel uses all remaining space for keys and performance wheels.
            ElectronicKeyboardPanel(controller: session.keyboard,
                configuration: .init(keyCount: 25, showsToneControls: false, showsExpandControl: false))
                .disabled(!session.isLive).frame(maxHeight: .infinity)
        }.accessibilityIdentifier("music.keyboard")
            .onDisappear {
                session.stopLive()
                if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
            }
    }
}
#endif

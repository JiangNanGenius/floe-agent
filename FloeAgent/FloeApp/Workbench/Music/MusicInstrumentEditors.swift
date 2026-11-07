// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicKeyboard

struct MusicPianoRoll: View {
    @Bindable var session: MusicProjectSession
    @State private var selectedNote: String?
    @State private var dragRevision: Int64?
    private let cell: CGFloat = 36
    private let row: CGFloat = 16
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                Text(session.currentClip?.name ?? WorkbenchText.t("钢琴卷帘", "Piano roll")).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Button { addClip() } label: { Image(systemName: "plus.rectangle").frame(width: 44, height: 44) }
                    .accessibilityLabel(session.currentTrack?.kind == .midi ? WorkbenchText.t("添加 MIDI 片段", "Add MIDI clip")
                        : WorkbenchText.t("添加乐器轨和 MIDI 片段", "Add instrument track and MIDI clip"))
                    .accessibilityIdentifier("music.addMIDIClip")
                MusicEditingActionsButton(session: session)
                MusicIconButton("trash", WorkbenchText.t("删除音符", "Delete note")) { changeNote { notes in notes.removeAll { $0.id == selectedNote } } }.disabled(selectedNote == nil)
            }.padding(.horizontal, 10) }
            Divider()
            if let clip = session.currentClip, case .midi(let midi) = clip.body {
                noteGrid(clip, midi: midi)
                if let note = midi.notes.first(where: { $0.id == selectedNote }) {
                    HStack(spacing: 12) {
                        MusicValueSlider(title: WorkbenchText.t("力度", "Velocity"), value: Double(note.velocity), range: 1...127) { value in
                            changeNote { notes in if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].velocity = Int(value) } }
                        }
                        MusicValueSlider(title: WorkbenchText.t("时长（拍）", "Length (beats)"), value: Double(note.durationTicks) / Double(session.document.tempoMap.ticksPerQuarter), range: 0.125...min(8, max(0.125, Double(midi.durationTicks - note.startTick.value) / Double(session.document.tempoMap.ticksPerQuarter)))) { value in
                            changeNote { notes in if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].durationTicks = min(midi.durationTicks - note.startTick.value, Int64(value * Double(session.document.tempoMap.ticksPerQuarter))) } }
                        }
                    }.padding(.horizontal, 12).padding(.top, 4)
                }
            } else {
                VStack(spacing: 10) {
                    Text(WorkbenchText.t("选择 MIDI 片段，或创建一个片段。", "Select a MIDI clip, or create one.")).foregroundStyle(.secondary)
                    Button(session.currentTrack?.kind == .midi ? WorkbenchText.t("创建 MIDI 片段", "Create MIDI clip")
                        : WorkbenchText.t("添加乐器轨和 MIDI 片段", "Add instrument track and MIDI clip")) { addClip() }.frame(minHeight: 44)
                }.font(.callout).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityIdentifier("music.pianoRoll")
            .onChange(of: session.selectedClip) { _, _ in selectedNote = nil }
    }
    private func noteGrid(_ clip: MusicClip, midi: MusicMIDIClipPayload) -> some View {
        let low = min(48, midi.notes.map(\.pitch).min() ?? 48)
        let high = min(127, max(low + 23, midi.notes.map(\.pitch).max() ?? 72))
        let grid = max(1, Int64(session.document.tempoMap.ticksPerQuarter) / 4)
        let width = max(600, CGFloat(midi.durationTicks) / CGFloat(grid) * cell)
        let height = CGFloat(high - low + 1) * row
        return ScrollView([.horizontal, .vertical]) {
            SwiftUI.Canvas { context, size in
                for pitch in low...high {
                    let y = CGFloat(high - pitch) * row
                    let black = [1, 3, 6, 8, 10].contains(pitch % 12)
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: row)), with: .color(.secondary.opacity(black ? 0.1 : 0.025)))
                    if pitch % 12 == 0 { context.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 18, y: y + row / 2)) }
                }
                for step in 0...Int(midi.durationTicks / grid) {
                    let x = 40 + CGFloat(step) * cell
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(step % 4 == 0 ? 0.25 : 0.1)), lineWidth: 1)
                }
                for note in midi.notes {
                    let rect = noteRect(note, high: high, grid: grid)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(note.id == selectedNote ? .orange : .accentColor))
                }
            }.frame(width: width + 40, height: height).contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    if let note = midi.notes.first(where: { noteRect($0, high: high, grid: grid).insetBy(dx: -3, dy: -3).contains(value.location) }) { selectedNote = note.id }
                    else {
                        let pitch = min(high, max(low, high - Int(value.location.y / row)))
                        let tick = max(0, min(midi.durationTicks - 1, Int64(max(0, (value.location.x - 40) / cell).rounded(.down)) * grid))
                        do {
                            let note = try MusicMIDINote(pitch: pitch, startTick: .init(tick), durationTicks: min(grid * 2, midi.durationTicks - tick), velocity: 100)
                            selectedNote = note.id; changeNote { $0.append(note) }
                        } catch { session.diagnostic = error.localizedDescription }
                    }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in if dragRevision == nil { dragRevision = session.document.revision } }.onEnded { value in
                    defer { dragRevision = nil }
                    guard let note = midi.notes.first(where: { noteRect($0, high: high, grid: grid).insetBy(dx: -3, dy: -3).contains(value.startLocation) }) else { return }
                    var payload = midi
                    guard let index = payload.notes.firstIndex(where: { $0.id == note.id }) else { return }
                    let delta = Int64((value.translation.width / cell).rounded()) * grid
                    payload.notes[index].startTick = .init(min(midi.durationTicks - note.durationTicks, max(0, note.startTick.value + delta)))
                    payload.notes[index].pitch = min(127, max(0, note.pitch - Int((value.translation.height / row).rounded())))
                    var next = clip; next.body = .midi(payload); selectedNote = note.id
                    let base = dragRevision ?? session.document.revision
                    Task { do { try await session.apply([.updateClip(next)], expectedRevision: base) } catch { session.diagnostic = error.localizedDescription } }
                })
        }.background(Color(uiColor: .secondarySystemBackground).opacity(0.4))
    }
    private func noteRect(_ note: MusicMIDINote, high: Int, grid: Int64) -> CGRect {
        CGRect(x: 40 + CGFloat(note.startTick.value) / CGFloat(grid) * cell, y: CGFloat(high - note.pitch) * row + 1,
            width: max(5, CGFloat(note.durationTicks) / CGFloat(grid) * cell - 1), height: row - 2)
    }
    private func changeNote(_ change: (inout [MusicMIDINote]) -> Void) {
        guard var clip = session.currentClip, case .midi(var payload) = clip.body else { return }
        change(&payload.notes); clip.body = .midi(payload); session.edit([.updateClip(clip)])
    }
    private func addClip() {
        Task {
            if session.currentTrack?.kind != .midi { await session.addTrack() }
            guard let id = session.selectedTrack else { return }
            do { _ = try await session.addMIDIClip(to: id) } catch { session.diagnostic = error.localizedDescription }
        }
    }
}

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
    private var presetDescriptors: [KeyboardPresetDescriptor] {
        var values = MusicPresetCatalog.all.map {
            KeyboardPresetDescriptor(id: String($0.index), displayName: $0.displayName(isChinese: WorkbenchText.isChinese))
        }
        if let patch = session.currentTrack?.instrument, !MusicInstrumentPresentation.isEditable(patch) {
            values.insert(.init(id: "unavailable", displayName: MusicInstrumentPresentation.name(patch)), at: 0)
        }
        return values
    }
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
                Button(session.isMIDIRecording ? WorkbenchText.t("结束录制", "Finish take")
                    : session.currentTrack?.kind == .midi ? WorkbenchText.t("录制演奏", "Record take")
                    : WorkbenchText.t("添加乐器并录制", "Add instrument and record"), systemImage: session.isMIDIRecording ? "stop.circle.fill" : "record.circle") {
                    if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
                    else { Task { await session.activateKeyboard(recording: true) } }
                }.foregroundStyle(.red).frame(minHeight: 44).disabled(session.saving || session.isRecording)
            }.font(.caption).padding(.horizontal, 12) }
            ElectronicKeyboardPanel(controller: session.keyboard, configuration: .init(keyCount: 25, showsExpandControl: false),
                toneSurface: .init(presets: presetDescriptors,
                    selectedPresetID: Binding(get: {
                        guard session.currentTrack?.kind == .midi else { return nil }
                        return MusicInstrumentPresentation.isEditable(session.currentTrack?.instrument) ? session.preset : "unavailable"
                    }, set: { session.changePreset($0) })))
                .disabled(!session.isLive).frame(maxHeight: .infinity)
        }.accessibilityIdentifier("music.keyboard")
            .onDisappear {
                session.stopLive()
                if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
            }
    }
}
#endif

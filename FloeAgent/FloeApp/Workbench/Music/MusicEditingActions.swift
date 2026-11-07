// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicNative

extension MusicProjectSession {
    var selectedMIDIClip: MusicClip? {
        guard let clip = currentClip, clip.trackID == selectedTrack, case .midi = clip.body else { return nil }
        return clip
    }
    var canEditMIDI: Bool { !saving && !isRecording && !isMIDIRecording }

    func quantizeSelection(division: Int, strength: Double, ends: Bool) async -> Bool {
        await editMIDISelection { document, clipID in
            guard [4, 8, 16, 32].contains(division) else {
                throw MusicError.invalidMIDI(reason: "unsupported quantize division")
            }
            return try MusicPatternTools.quantize(document: document, clipID: clipID,
                gridTicks: max(1, Int64(document.tempoMap.ticksPerQuarter * 4 / division)),
                strength: strength, quantizeEnds: ends)
        }
    }
    func transposeSelection(semitones: Int) async -> Bool {
        await editMIDISelection { document, clipID in
            try MusicPatternTools.transpose(document: document, clipID: clipID, semitones: semitones)
        }
    }
    func changeSelectionVelocity(delta: Int) async -> Bool {
        await editMIDISelection { document, clipID in
            try MusicPatternTools.adjustVelocity(document: document, clipID: clipID, delta: delta)
        }
    }
    private func editMIDISelection(_ make: (MusicDocument, MusicClipID) throws -> [MusicEditOp]) async -> Bool {
        do {
            guard canEditMIDI, let clip = selectedMIDIClip else {
                throw MusicError.invalidMIDI(reason: WorkbenchText.t("结束录制，并选择一个 MIDI 片段。", "Finish recording and select a MIDI clip."))
            }
            let revision = document.revision
            let operations = try make(document, clip.id)
            if !operations.isEmpty { try await apply(operations, expectedRevision: revision) }
            diagnostic = nil
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }
    /// A new track (when requested) and a new clip form one undoable commit.
    /// Existing clips and instruments are never replaced by a template.
    func insertPattern(_ template: MusicPatternTemplate, bars: Int, rootPitch: Int,
                       velocity: Int, newTrack: Bool) async -> Bool {
        do {
            guard canEditMIDI else {
                throw MusicError.invalidMIDI(reason: WorkbenchText.t("请先结束当前录制或保存。", "Finish recording or saving first."))
            }
            let revision = document.revision
            var draft = document
            var operations: [MusicEditOp] = []
            let track: FloeMusicCore.MusicTrack
            if newTrack {
                let index: Int
                switch template {
                case .drumGroove: index = 40
                case .bassLine: index = 9
                case .chordProgression: index = 2
                case .arpeggio: index = 27
                }
                guard MusicPresetCatalog.preset(index: index) != nil else {
                    throw MusicError.invalidTrack(reason: WorkbenchText.t("模板音色不可用。", "The template preset is unavailable."))
                }
                track = try .init(name: MusicPatternPresentation.name(template), kind: .midi,
                    instrument: .init(pluginID: MusicNativeBuiltins.synth, presetIndex: index))
                operations.append(.insertTrack(track)); draft.tracks.append(track)
            } else {
                guard let selected = currentTrack, selected.kind == .midi else {
                    throw MusicError.invalidTrack(reason: WorkbenchText.t("请选择乐器轨，或将模板加入新轨道。", "Select an instrument track, or add the template to a new track."))
                }
                track = selected
            }
            let position = playbackPosition
            guard position.isFinite, position >= 0,
                  position < Double(Int64.max / 2) / Double(document.tempoMap.sampleRate) else {
                throw MusicError.invalidSampleTime(reason: "invalid template playhead")
            }
            let tick = try document.tempoMap.tick(atSample: .init(Int64((position * Double(document.tempoMap.sampleRate)).rounded())))
            let inserted = try MusicPatternTools.insertTemplate(template, document: draft, trackID: track.id,
                atTick: tick, bars: bars, rootPitch: rootPitch, velocity: velocity,
                name: MusicPatternPresentation.name(template))
            operations += inserted
            try await apply(operations, expectedRevision: revision)
            selectTrack(track.id)
            if let clip = inserted.compactMap({ operation -> MusicClip? in
                if case .insertClip(let clip) = operation { return clip }; return nil
            }).last { selectedClip = clip.id }
            diagnostic = nil
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }
}

enum MusicPatternPresentation {
    static func name(_ template: MusicPatternTemplate) -> String {
        switch template {
        case .drumGroove: WorkbenchText.t("节奏起步", "Drum groove")
        case .chordProgression: WorkbenchText.t("和弦进行", "Chord progression")
        case .arpeggio: WorkbenchText.t("琶音", "Arpeggio")
        case .bassLine: WorkbenchText.t("贝斯线", "Bass line")
        }
    }
    static func pitch(_ pitch: Int) -> String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][pitch % 12] + "\(pitch / 12 - 1)"
    }
}

enum MusicEditingPanel: String, Identifiable {
    case notes, patterns
    var id: String { rawValue }
}

struct MusicEditingActionsButton: View {
    let session: MusicProjectSession
    var initialPanel: MusicEditingPanel = .notes
    @State private var panel: MusicEditingPanel?
    var body: some View {
        Button { panel = initialPanel } label: {
            Label(initialPanel == .patterns ? WorkbenchText.t("起步模板", "Patterns") : WorkbenchText.t("MIDI 工具", "MIDI tools"),
                systemImage: initialPanel == .patterns ? "music.note.list" : "slider.horizontal.3").frame(minHeight: 44)
        }
        .accessibilityIdentifier(initialPanel == .patterns ? "music.patterns.open" : "music.midiTools.open")
        .sheet(item: $panel) { MusicEditingActionsSheet(session: session, initialPanel: $0) }
    }
}

private struct MusicEditingActionsSheet: View {
    @Bindable var session: MusicProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var panel: MusicEditingPanel
    @State private var division = 16
    @State private var strength = 1.0
    @State private var quantizeEnds = false
    @State private var semitones = 0
    @State private var velocityDelta = 0
    @State private var template: MusicPatternTemplate = .chordProgression
    @State private var bars = 4
    @State private var rootPitch = 60
    @State private var velocity = 96
    @State private var outcome: String?

    init(session: MusicProjectSession, initialPanel: MusicEditingPanel) {
        self.session = session; _panel = State(initialValue: initialPanel)
    }
    private var canEditSelection: Bool { session.canEditMIDI && session.selectedMIDIClip != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(WorkbenchText.t("工具", "Tools"), selection: $panel) {
                        Text(WorkbenchText.t("片段编辑", "Clip editing")).tag(MusicEditingPanel.notes)
                        Text(WorkbenchText.t("起步模板", "Patterns")).tag(MusicEditingPanel.patterns)
                    }.pickerStyle(.segmented)
                }
                if panel == .notes { noteTools } else { patternTools }
                if let outcome {
                    Section { Label(outcome, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }
                MusicActionNotice(diagnostic: session.diagnostic)
            }
            .navigationTitle(WorkbenchText.t("MIDI 工具", "MIDI tools"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
        }.presentationDetents([.large])
            .accessibilityIdentifier("music.midiTools")
    }
    @ViewBuilder private var noteTools: some View {
        Section(WorkbenchText.t("选中片段", "Selected clip")) {
            if let clip = session.selectedMIDIClip, case .midi(let midi) = clip.body {
                LabeledContent(clip.name, value: "\(midi.notes.count) " + WorkbenchText.t("个音符", "notes"))
            } else {
                Text(WorkbenchText.t("先在编排或钢琴卷帘中选择 MIDI 片段。", "Select a MIDI clip in the arrangement or piano roll first."))
                    .foregroundStyle(.secondary)
            }
        }
        Section(WorkbenchText.t("量化", "Quantize")) {
            Picker(WorkbenchText.t("网格", "Grid"), selection: $division) {
                ForEach([4, 8, 16, 32], id: \.self) { Text("1/\($0)").tag($0) }
            }.pickerStyle(.segmented)
            HStack { Text(WorkbenchText.t("强度", "Strength")); Spacer(); Text(strength, format: .percent.precision(.fractionLength(0))) }
            Slider(value: $strength, in: 0...1).accessibilityLabel(WorkbenchText.t("量化强度", "Quantize strength"))
            Toggle(WorkbenchText.t("同时量化音符结尾", "Quantize note ends too"), isOn: $quantizeEnds)
            Button(WorkbenchText.t("量化选中片段", "Quantize selected clip")) {
                Task { if await session.quantizeSelection(division: division, strength: strength, ends: quantizeEnds) {
                    outcome = WorkbenchText.t("已量化片段，可在工作台撤销。", "Clip quantized. Undo is available in the workbench.")
                } }
            }.frame(minHeight: 44).accessibilityIdentifier("music.midiTools.quantize")
        }.disabled(!canEditSelection)
        Section(WorkbenchText.t("移调", "Transpose")) {
            Stepper(value: $semitones, in: -24...24) {
                LabeledContent(WorkbenchText.t("半音", "Semitones"), value: String(format: "%+d", semitones))
            }
            Button(WorkbenchText.t("移调选中片段", "Transpose selected clip")) {
                Task { if await session.transposeSelection(semitones: semitones) {
                    outcome = WorkbenchText.t("已移调片段，可在工作台撤销。", "Clip transposed. Undo is available in the workbench.")
                } }
            }.frame(minHeight: 44).disabled(semitones == 0).accessibilityIdentifier("music.midiTools.transpose")
        }.disabled(!canEditSelection)
        Section(WorkbenchText.t("力度", "Velocity")) {
            Stepper(value: $velocityDelta, in: -126...126) {
                LabeledContent(WorkbenchText.t("力度增减", "Velocity change"), value: String(format: "%+d", velocityDelta))
            }
            Button(WorkbenchText.t("调整选中片段力度", "Adjust selected clip velocity")) {
                Task { if await session.changeSelectionVelocity(delta: velocityDelta) {
                    outcome = WorkbenchText.t("已调整力度，可在工作台撤销。", "Velocity adjusted. Undo is available in the workbench.")
                } }
            }.frame(minHeight: 44).disabled(velocityDelta == 0).accessibilityIdentifier("music.midiTools.velocity")
        }.disabled(!canEditSelection)
    }
    @ViewBuilder private var patternTools: some View {
        Section {
            Picker(WorkbenchText.t("模板", "Pattern"), selection: $template) {
                ForEach(MusicPatternTemplate.allCases) { Text(MusicPatternPresentation.name($0)).tag($0) }
            }
            Picker(WorkbenchText.t("小节数", "Bars"), selection: $bars) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            if template != .drumGroove {
                Stepper(value: $rootPitch, in: 24...96) {
                    LabeledContent(WorkbenchText.t("根音", "Root note"), value: MusicPatternPresentation.pitch(rootPitch))
                }
            }
            Stepper(value: $velocity, in: 1...127) { LabeledContent(WorkbenchText.t("力度", "Velocity"), value: "\(velocity)") }
            LabeledContent(WorkbenchText.t("插入位置", "Insert at"), value: MusicWorkbenchFormat.time(session.playbackPosition))
            if let track = session.currentTrack, track.kind == .midi {
                Text(track.name + " · " + MusicInstrumentPresentation.name(track.instrument)).font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("加入当前乐器轨", "Add to current instrument track")) { insert(newTrack: false) }
                    .frame(minHeight: 44).accessibilityIdentifier("music.patterns.insertCurrent")
            }
            Button(template == .drumGroove ? WorkbenchText.t("加入新的电子鼓组轨", "Add to a new electronic drum track")
                : WorkbenchText.t("加入新乐器轨", "Add to a new instrument track")) { insert(newTrack: true) }
                .frame(minHeight: 44).accessibilityIdentifier("music.patterns.insertNew")
        } header: {
            Text(WorkbenchText.t("新建片段", "New clip"))
        } footer: {
            Text(WorkbenchText.t("模板添加为新片段，保留原有内容和当前轨音色，可在工作台撤销。", "Patterns add a new clip, preserving existing content and the current track's preset. Undo is available in the workbench."))
        }.disabled(!session.canEditMIDI)
    }
    private func insert(newTrack: Bool) {
        Task {
            if await session.insertPattern(template, bars: bars, rootPitch: rootPitch, velocity: velocity, newTrack: newTrack) {
                outcome = WorkbenchText.t("已添加片段，可在工作台撤销。", "Clip added. Undo is available in the workbench.")
            }
        }
    }
}
#endif

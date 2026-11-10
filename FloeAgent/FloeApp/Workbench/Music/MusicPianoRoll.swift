// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeMusicCore

struct MusicPianoRoll: View {
    @Bindable var session: MusicProjectSession
    @State private var selection: Set<String> = []
    @State private var grid: MusicPianoRollGrid = .sixteenth
    @State private var boxSelection = false
    @State private var fingerEditing = false
    @State private var cursorTick: Int64 = 0
    @State private var preview: MusicMIDIClipPayload?
    @State private var dragBase: (clip: MusicClip, payload: MusicMIDIClipPayload, revision: Int64)?
    @State private var dragEdge: MusicPianoRollEditing.Edge?
    @State private var box: CGRect?
    @State private var clipboardAvailable = false
    @State private var editChannel = 0
    private let quarterWidth: CGFloat = 96
    private let row: CGFloat = 20
    private static let clipboardType = "com.floe.midi-notes"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let clip = session.currentClip, case .midi(let payload) = clip.body {
                noteGrid(clip, payload: payload)
                if let first = payload.notes.first(where: { selection.contains($0.id) }) {
                    HStack(spacing: 12) {
                        Text("\(selection.count)").font(.caption.monospacedDigit()).accessibilityLabel(WorkbenchText.t("已选音符", "Selected notes"))
                        Picker(WorkbenchText.t("音符通道", "Note channel"), selection: Binding(get: { first.channel }, set: { value in
                            editChannel = value
                            perform(clip) { var next = $0; for index in next.notes.indices where selection.contains(next.notes[index].id) { next.notes[index].channel = value }; return next }
                        })) { ForEach(0..<16) { Text("CH \($0 + 1)").tag($0) } }.accessibilityIdentifier("music.notes.channel")
                        MusicValueSlider(title: WorkbenchText.t("力度", "Velocity"), value: Double(first.velocity), range: 1...127) { value in
                            perform(clip) { try MusicPianoRollEditing.setVelocity($0, selection: selection, value: Int(value)) }
                        }
                        MusicValueSlider(title: WorkbenchText.t("时长（拍）", "Length (beats)"), value: Double(first.durationTicks) / Double(ppq), range: 0.0625...16) { value in
                            let delta = Int64(value * Double(ppq)) - first.durationTicks
                            perform(clip) { try MusicPianoRollEditing.resize($0, selection: selection, edge: .end, ticks: delta) }
                        }
                    }.padding(.horizontal, 12).padding(.top, 4)
                }
            } else {
                VStack(spacing: 10) {
                    Text(WorkbenchText.t("选择或创建 MIDI 片段。", "Select or create a MIDI clip.")).foregroundStyle(.secondary)
                    Button(WorkbenchText.t("创建 MIDI 片段", "Create MIDI clip")) { addClip() }.frame(minHeight: 44)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("music.pianoRoll")
        .onChange(of: session.selectedClip) { _, _ in selection = []; preview = nil; dragBase = nil; box = nil; cursorTick = 0; loadChannel() }
        .onAppear { loadChannel() }
        .onChange(of: session.document.revision) { _, _ in
            if let clip = session.currentClip, case .midi(let payload) = clip.body { selection.formIntersection(payload.notes.map(\.id)) }
        }
    }

    private var ppq: Int { session.document.tempoMap.ticksPerQuarter }
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(session.currentClip?.name ?? WorkbenchText.t("钢琴卷帘", "Piano roll")).font(.caption.weight(.medium)).lineLimit(1)
                Button { addClip() } label: { Image(systemName: "plus.rectangle").frame(width: 44, height: 44) }
                    .accessibilityLabel(WorkbenchText.t("添加 MIDI 片段", "Add MIDI clip")).accessibilityIdentifier("music.addMIDIClip")
                Toggle(isOn: $boxSelection) { Label(WorkbenchText.t("框选", "Box select"), systemImage: "selection.pin.in.out") }
                    .toggleStyle(.button).frame(minHeight: 44).accessibilityIdentifier("music.notes.boxSelect")
                Toggle(isOn: $fingerEditing) { Image(systemName: "hand.draw") }.toggleStyle(.button).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(WorkbenchText.t("手指编辑", "Finger editing")).accessibilityIdentifier("music.notes.fingerEditing")
                Picker(WorkbenchText.t("网格", "Grid"), selection: $grid) {
                    Text(WorkbenchText.t("自由", "Free")).tag(MusicPianoRollGrid.free)
                    Text("1/4").tag(MusicPianoRollGrid.quarter); Text("1/8").tag(MusicPianoRollGrid.eighth)
                    Text("1/8T").tag(MusicPianoRollGrid.eighthTriplet); Text("1/16").tag(MusicPianoRollGrid.sixteenth)
                    Text("1/32").tag(MusicPianoRollGrid.thirtySecond)
                }.accessibilityIdentifier("music.notes.grid")
                Menu {
                    Button(WorkbenchText.t("全选音符", "Select all notes")) { selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button(WorkbenchText.t("取消选择", "Deselect")) { selection = [] }
                    Divider()
                    Button(WorkbenchText.t("复制音符", "Copy notes")) { copy(cut: false) }.keyboardShortcut("c", modifiers: .command).disabled(selection.isEmpty)
                    Button(WorkbenchText.t("剪切音符", "Cut notes")) { copy(cut: true) }.keyboardShortcut("x", modifiers: .command).disabled(selection.isEmpty)
                    Button(WorkbenchText.t("粘贴音符", "Paste notes")) { paste() }.keyboardShortcut("v", modifiers: .command).disabled(!clipboardAvailable)
                    Button(WorkbenchText.t("删除音符", "Delete notes"), role: .destructive) { delete() }.keyboardShortcut(.delete, modifiers: []).disabled(selection.isEmpty)
                } label: { Label(WorkbenchText.t("音符", "Notes"), systemImage: "music.note.list").frame(minHeight: 44) }
                    .accessibilityIdentifier("music.notes.editMenu")
                MusicIconButton("trash", WorkbenchText.t("删除所选音符", "Delete selected notes")) { delete() }.disabled(selection.isEmpty)
            }.font(.caption).padding(.horizontal, 10)
        }
        .onAppear { clipboardAvailable = UIPasteboard.general.contains(pasteboardTypes: [Self.clipboardType]) }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardAvailable = UIPasteboard.general.contains(pasteboardTypes: [Self.clipboardType])
        }
    }

    private func noteGrid(_ clip: MusicClip, payload: MusicMIDIClipPayload) -> some View {
        let low = min(48, payload.notes.map(\.pitch).min() ?? 48)
        let high = min(127, max(low + 23, payload.notes.map(\.pitch).max() ?? 72))
        let display = preview ?? payload
        let width = max(640, CGFloat(display.durationTicks) / CGFloat(ppq) * quarterWidth + 44)
        let height = CGFloat(high - low + 1) * row
        return GeometryReader { available in
          ScrollView(.horizontal) {
           VStack(spacing: 0) {
            ScrollView(.vertical) {
            SwiftUI.Canvas { context, size in
                for pitch in low...high {
                    let y = CGFloat(high - pitch) * row
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: row)), with: .color(.secondary.opacity([1, 3, 6, 8, 10].contains(pitch % 12) ? 0.1 : 0.025)))
                    if pitch % 12 == 0 { context.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 18, y: y + row / 2)) }
                }
                let step = grid == .free ? Int64(ppq) : grid.ticks(ticksPerQuarter: ppq)
                for index in 0...min(16_384, Int(display.durationTicks / step)) {
                    let tick = Int64(index) * step
                    let x = x(tick)
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(tick.isMultiple(of: Int64(ppq)) ? 0.25 : 0.1)), lineWidth: 1)
                }
                for note in display.notes {
                    let rect = rect(note, high: high)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(selection.contains(note.id) ? .orange : .accentColor))
                    if selection.contains(note.id) {
                        context.fill(Path(CGRect(x: rect.maxX - 4, y: rect.minY + 2, width: 2, height: rect.height - 4)), with: .color(.white.opacity(0.8)))
                    }
                }
                if let box { context.fill(Path(box), with: .color(.accentColor.opacity(0.15))); context.stroke(Path(box), with: .color(.accentColor), lineWidth: 1) }
            }
            .frame(width: width, height: height)
            .overlay {
                MusicPianoRollInput(fingerEditing: fingerEditing,
                    tap: { point in tapped(point, clip: clip, payload: payload, low: low, high: high) },
                    drag: { start, point, state in dragged(start, point: point, state: state, clip: clip, payload: payload, high: high) })
            }
            }.frame(height: max(100, available.size.height - 140))
            MusicMIDIExpressionLane(session: session, clip: clip, quarterWidth: quarterWidth, grid: grid,
                                    fingerEditing: fingerEditing, cursorTick: cursorTick, channel: $editChannel).frame(width: width, height: 140)
           }.frame(width: width)
          }.background(Color(uiColor: .secondarySystemBackground).opacity(0.4))
        }
    }

    private func x(_ tick: Int64) -> CGFloat { 40 + CGFloat(tick) / CGFloat(ppq) * quarterWidth }
    private func tick(_ x: CGFloat) -> Int64 {
        let value = min(9.0e15, max(0, Double((x - 40) / quarterWidth) * Double(ppq)))
        return grid.snapped(Int64(value.rounded()), ticksPerQuarter: ppq)
    }
    private func rect(_ note: MusicMIDINote, high: Int) -> CGRect {
        CGRect(x: x(note.startTick.value), y: CGFloat(high - note.pitch) * row + 1,
               width: max(6, CGFloat(note.durationTicks) / CGFloat(ppq) * quarterWidth - 1), height: row - 2)
    }
    private func tapped(_ point: CGPoint, clip: MusicClip, payload: MusicMIDIClipPayload, low: Int, high: Int) {
        cursorTick = tick(point.x)
        if let note = payload.notes.reversed().first(where: { rect($0, high: high).insetBy(dx: -3, dy: -2).contains(point) }) {
            editChannel = note.channel
            if boxSelection { if !selection.insert(note.id).inserted { selection.remove(note.id) } }
            else { selection = [note.id] }
        } else if boxSelection { selection = [] }
        else {
            do {
                let start = min(max(0, cursorTick), payload.durationTicks - 1)
                let note = try MusicMIDINote(pitch: min(high, max(low, high - Int(point.y / row))), startTick: .init(start),
                                             durationTicks: min(max(1, grid == .free ? Int64(ppq) / 4 : grid.ticks(ticksPerQuarter: ppq)), payload.durationTicks - start), velocity: 100, channel: editChannel)
                selection = [note.id]; perform(clip) { var next = $0; next.notes.append(note); return next }
            } catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func dragged(_ start: CGPoint, point: CGPoint, state: UIGestureRecognizer.State,
                         clip: MusicClip, payload: MusicMIDIClipPayload, high: Int) {
        if state == .cancelled || state == .failed { preview = nil; dragBase = nil; box = nil; return }
        if state == .began {
            dragBase = (clip, payload, session.document.revision)
            if let note = payload.notes.reversed().first(where: { rect($0, high: high).insetBy(dx: -4, dy: -2).contains(start) }), !boxSelection {
                if !selection.contains(note.id) { selection = [note.id] }
                let bounds = rect(note, high: high)
                dragEdge = start.x > bounds.maxX - 9 ? .end : (start.x < bounds.minX + 7 ? .start : nil)
            } else { box = CGRect(origin: start, size: .zero); dragEdge = nil }
        }
        guard let base = dragBase, session.selectedClip == base.clip.id else { return }
        if box != nil {
            let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            box = area
            selection = Set(base.payload.notes.filter { area.intersects(rect($0, high: high)) }.map(\.id))
        } else {
            do {
                let dt = tick(max(40, 40 + point.x - start.x)) - tick(max(40, 40 + start.x - point.x))
                if let edge = dragEdge { preview = try MusicPianoRollEditing.resize(base.payload, selection: selection, edge: edge, ticks: dt) }
                else { preview = try MusicPianoRollEditing.move(base.payload, selection: selection, ticks: dt, semitones: -Int(((point.y - start.y) / row).rounded())) }
            } catch { session.diagnostic = error.localizedDescription }
        }
        if state == .ended {
            let next = preview
            preview = nil; dragBase = nil; box = nil
            if let next { submit(base.clip, payload: next, revision: base.revision) }
        }
    }
    private func perform(_ clip: MusicClip, change: (MusicMIDIClipPayload) throws -> MusicMIDIClipPayload) {
        guard case .midi(let payload) = clip.body else { return }
        do { submit(clip, payload: try change(payload), revision: session.document.revision) }
        catch { session.diagnostic = error.localizedDescription }
    }
    private func submit(_ clip: MusicClip, payload: MusicMIDIClipPayload, revision: Int64) {
        var next = clip; next.body = .midi(payload)
        Task { do { try await session.apply([.updateClip(next)], expectedRevision: revision) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func selectAll() { if let clip = session.currentClip, case .midi(let payload) = clip.body { selection = Set(payload.notes.map(\.id)) } }
    private func delete() { if let clip = session.currentClip { perform(clip) { var next = $0; next.notes.removeAll { selection.contains($0.id) }; return next }; selection = [] } }
    private func copy(cut: Bool) {
        guard let clip = session.currentClip, case .midi(let payload) = clip.body else { return }
        do {
            let clipboard = try MusicMIDINoteClipboard(notes: payload.notes.filter { selection.contains($0.id) })
            UIPasteboard.general.setData(try JSONEncoder().encode(clipboard), forPasteboardType: Self.clipboardType)
            clipboardAvailable = true
            if cut { delete() }
        } catch { session.diagnostic = error.localizedDescription }
    }
    private func paste() {
        guard let clip = session.currentClip, case .midi(let payload) = clip.body,
              let data = UIPasteboard.general.data(forPasteboardType: Self.clipboardType), data.count <= 8_388_608 else { return }
        do {
            let clipboard = try JSONDecoder().decode(MusicMIDINoteClipboard.self, from: data)
            let next = try MusicPianoRollEditing.paste(clipboard, into: payload, at: cursorTick)
            selection = next.1; submit(clip, payload: next.0, revision: session.document.revision)
        } catch { session.diagnostic = error.localizedDescription }
    }
    private func addClip() {
        Task {
            if session.currentTrack?.kind != .midi { await session.addTrack() }
            guard let id = session.selectedTrack else { return }
            do { _ = try await session.addMIDIClip(to: id) } catch { session.diagnostic = error.localizedDescription }
        }
    }
    private func loadChannel() {
        if let clip = session.currentClip, case .midi(let payload) = clip.body { editChannel = payload.notes.first?.channel ?? 0 }
    }
}
#endif

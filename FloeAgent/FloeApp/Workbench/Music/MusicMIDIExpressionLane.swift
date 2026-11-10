// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeMusicCore

struct MusicMIDIExpressionLane: View {
    @Bindable var session: MusicProjectSession
    let clip: MusicClip
    let quarterWidth: CGFloat
    let grid: MusicPianoRollGrid
    let fingerEditing: Bool
    let cursorTick: Int64
    @Binding var channel: Int
    @State private var controller = 64
    @State private var erasing = false
    @State private var preview: MusicMIDIControllerPoint?
    @State private var dragRevision: Int64?
    private var payload: MusicMIDIClipPayload? { if case .midi(let value) = clip.body { return value }; return nil }
    private var maximum: Int { controller == 128 ? 16_383 : 127 }
    private var points: [MusicMIDIControllerPoint] { payload?.controllerPoints.filter { $0.controller == controller && $0.channel == channel } ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Picker(WorkbenchText.t("表达", "Expression"), selection: $controller) {
                    Text(WorkbenchText.t("调制", "Modulation")).tag(1)
                    Text(WorkbenchText.t("延音踏板", "Sustain")).tag(64)
                    Text(WorkbenchText.t("弯音", "Pitch bend")).tag(128)
                }.accessibilityIdentifier("music.expression.controller")
                Picker(WorkbenchText.t("通道", "Channel"), selection: $channel) { ForEach(0..<16) { Text("CH \($0 + 1)").tag($0) } }
                    .accessibilityIdentifier("music.expression.channel")
                Toggle(isOn: $erasing) { Image(systemName: "eraser") }.toggleStyle(.button).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(WorkbenchText.t("删除表达点", "Erase expression points"))
                Menu {
                    let program = payload?.programChanges.last(where: { $0.channel == channel && $0.tick.value <= cursorTick })?.program ?? 0
                    Picker(WorkbenchText.t("MIDI 音色编号", "MIDI program"), selection: Binding(get: { program }, set: { setProgram($0) })) {
                        ForEach(0..<128) { Text("\($0 + 1)").tag($0) }
                    }
                    Text(WorkbenchText.t("编号随 MIDI 导出；本机琴声由轨道音色决定。", "Programs are exported in MIDI; the track preset controls the built-in sound."))
                } label: { Text(WorkbenchText.t("MIDI 音色", "MIDI program")) }.frame(minHeight: 44)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            GeometryReader { geometry in
                SwiftUI.Canvas { context, size in
                    var path = Path()
                    for (index, point) in points.enumerated() {
                        let x = 40 + CGFloat(point.tick.value) / CGFloat(session.document.tempoMap.ticksPerQuarter) * quarterWidth
                        let y = size.height - 5 - CGFloat(point.value) / CGFloat(maximum) * (size.height - 10)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(.accentColor))
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                    if let point = preview {
                        let x = 40 + CGFloat(point.tick.value) / CGFloat(session.document.tempoMap.ticksPerQuarter) * quarterWidth
                        let y = size.height - 5 - CGFloat(point.value) / CGFloat(maximum) * (size.height - 10)
                        context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.orange))
                    }
                }.overlay {
                    MusicPianoRollInput(fingerEditing: fingerEditing, tap: { point in commit(point, height: geometry.size.height, revision: session.document.revision) }, drag: { _, point, state in
                        if state == .began { dragRevision = session.document.revision }
                        if state == .cancelled || state == .failed { preview = nil; dragRevision = nil; return }
                        preview = makePoint(point, height: geometry.size.height)
                        if state == .ended { commit(point, height: geometry.size.height, revision: dragRevision ?? session.document.revision); preview = nil; dragRevision = nil }
                    })
                }
            }.frame(minHeight: 70)
        }.background(Color(uiColor: .tertiarySystemBackground)).accessibilityIdentifier("music.expression.lane")
    }
    private func makePoint(_ point: CGPoint, height: CGFloat) -> MusicMIDIControllerPoint? {
        guard let payload else { return nil }
        let raw = min(Double(payload.durationTicks), max(0, Double((point.x - 40) / quarterWidth) * Double(session.document.tempoMap.ticksPerQuarter)))
        let tick = min(payload.durationTicks, grid.snapped(Int64(raw.rounded()), ticksPerQuarter: session.document.tempoMap.ticksPerQuarter))
        let fraction = min(1, max(0, Double((height - 5 - point.y) / max(1, height - 10))))
        let value = controller == 64 ? (fraction >= 0.5 ? 127 : 0) : Int((fraction * Double(maximum)).rounded())
        return try? MusicMIDIControllerPoint(controller: controller, tick: .init(tick), value: value, channel: channel)
    }
    private func commit(_ point: CGPoint, height: CGFloat, revision: Int64) {
        guard var next = payload, let value = makePoint(point, height: height), session.selectedClip == clip.id else { return }
        if erasing {
            let radius = max(1, grid.ticks(ticksPerQuarter: session.document.tempoMap.ticksPerQuarter) / 2)
            if let nearest = points.min(by: { abs($0.tick.value - value.tick.value) < abs($1.tick.value - value.tick.value) }), abs(nearest.tick.value - value.tick.value) <= radius {
                next.controllerPoints.removeAll { $0 == nearest }
            }
        } else {
            next.controllerPoints.removeAll { $0.controller == controller && $0.channel == channel && $0.tick == value.tick }
            next.controllerPoints.append(value)
            next.controllerPoints.sort { ($0.controller, $0.channel, $0.tick.value) < ($1.controller, $1.channel, $1.tick.value) }
        }
        var updated = clip; updated.body = .midi(next)
        Task { do { try await session.apply([.updateClip(updated)], expectedRevision: revision) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func setProgram(_ program: Int) {
        guard var next = payload else { return }
        let tick = min(next.durationTicks, cursorTick), revision = session.document.revision
        do {
            next.programChanges.removeAll { $0.channel == channel && $0.tick.value == tick }
            next.programChanges.append(try .init(tick: .init(tick), channel: channel, program: program))
            next.programChanges.sort { ($0.channel, $0.tick.value) < ($1.channel, $1.tick.value) }
            var updated = clip; updated.body = .midi(next)
            Task { do { try await session.apply([.updateClip(updated)], expectedRevision: revision) } catch { session.diagnostic = error.localizedDescription } }
        } catch { session.diagnostic = error.localizedDescription }
    }
}
#endif

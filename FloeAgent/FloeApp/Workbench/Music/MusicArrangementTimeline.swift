// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicArrangementTimeline: View {
    @Bindable var session: MusicProjectSession
    @Binding var zoom: Double
    var snap: Bool
    var showsAutomation: Bool
    var onImport: (() -> Void)? = nil
    var onEdit: (MusicClip) -> Void
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var horizontalOffset: CGFloat = 0
    @State private var pinchStart: (zoom: Double, offset: CGFloat, anchor: CGFloat)?
    @GestureState private var pinching = false
    private let rowHeight: CGFloat = 76
    private let rulerHeight: CGFloat = 44
    private var scale: CGFloat { 48 * zoom }
    private var horizon: Double {
        let bpm = session.document.tempoMap.segments.first?.bpm ?? 120
        return max(60 / bpm * 32, max(session.durationSeconds, session.playbackPosition) + 60 / bpm * 4)
    }
    private var rulerMarks: [(mark: MusicBarBeatMark, seconds: Double)] {
        let map = session.document.tempoMap
        let last = (try? map.tick(atSample: .init(Int64(horizon * Double(map.sampleRate)))).value) ?? 0
        return MusicMusicalRuler.marks(tempoMap: map, through: last).compactMap { mark in
            guard let sample = try? map.sample(atTick: .init(mark.tick)) else { return nil }
            return (mark, Double(sample.value) / Double(map.sampleRate))
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let labelWidth = min(178, max(128, geometry.size.width * 0.23))
            let width = max(geometry.size.width - labelWidth, CGFloat(horizon) * scale)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text(WorkbenchText.t("轨道", "Tracks") + " · \(session.document.tracks.count)").font(.caption.weight(.medium))
                            Spacer()
                        }.padding(.horizontal, 10).frame(height: rulerHeight)
                        ForEach(Array(session.document.tracks.enumerated()), id: \.element.id) { index, track in
                            trackHeader(track, color: MusicWorkbenchFormat.color(index))
                        }
                    }.frame(width: labelWidth)
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            ruler(width: width)
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ForEach(Array(session.document.tracks.enumerated()), id: \.element.id) { index, track in
                                        trackLane(track, color: MusicWorkbenchFormat.color(index), width: width)
                                    }
                                    if session.document.tracks.isEmpty {
                                        emptyTimeline(visibleWidth: max(0, geometry.size.width - labelWidth - 1))
                                            .frame(width: width, height: max(200, geometry.size.height - rulerHeight))
                                    }
                                }
                                TimelineView(.animation(minimumInterval: 0.1, paused: !session.playbackIsActive)) { _ in
                                    Rectangle().fill(Color.accentColor).frame(width: 1.5)
                                        .offset(x: CGFloat(session.playbackPosition) * scale)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        }.frame(width: width)
                    }
                    .scrollPosition($scrollPosition)
                    .scrollIndicators(.visible, axes: .horizontal)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, value in horizontalOffset = value }
                    .simultaneousGesture(MagnifyGesture().updating($pinching) { _, state, _ in state = true }
                        .onChanged { value in
                            if pinchStart == nil { pinchStart = (zoom, horizontalOffset, value.startLocation.x) }
                            guard let start = pinchStart else { return }
                            let next = min(8, max(0.25, start.zoom * Double(value.magnification)))
                            let offset = MusicTimelineEditing.anchoredScrollOffset(offset: Double(start.offset), anchorX: Double(start.anchor),
                                oldScale: 48 * start.zoom, newScale: 48 * next)
                            zoom = next; scrollPosition.scrollTo(x: CGFloat(offset))
                        }.onEnded { _ in pinchStart = nil })
                    .onChange(of: pinching) { _, active in if !active { pinchStart = nil } }
                }.frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.65))
        .accessibilityIdentifier("music.arrangement")
    }
    private func trackHeader(_ track: MusicTrack, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: track.kind == .midi ? "pianokeys" : "waveform")
                .foregroundStyle(color).frame(width: 30, height: 36).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(track.kind == .midi ? WorkbenchText.t("乐器 · MIDI", "Instrument · MIDI") : WorkbenchText.t("音频", "Audio")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { session.updateStrip(track.id) { $0.recordArmed.toggle() } } label: {
                Text("R").font(.caption.weight(.semibold)).foregroundStyle(track.strip.recordArmed ? .red : .secondary).frame(width: 32, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(track.name + WorkbenchText.t("录音准备", " record arm"))
        }
        .padding(.leading, 8).frame(height: rowHeight)
        .background(session.selectedTrack == track.id ? Color.accentColor.opacity(0.1) : .clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle()).onTapGesture { session.selectTrack(track.id) }
        .contextMenu {
            Button(WorkbenchText.t("选择音轨", "Select track")) { session.selectTrack(track.id) }
            Button(track.strip.muted ? WorkbenchText.t("取消静音", "Unmute") : WorkbenchText.t("静音", "Mute")) { session.updateStrip(track.id) { $0.muted.toggle() } }
            Button(WorkbenchText.t("添加 MIDI 片段", "Add MIDI clip")) { Task { do { _ = try await session.addMIDIClip(to: track.id) } catch { session.diagnostic = error.localizedDescription } } }.disabled(track.kind != .midi)
            Button(WorkbenchText.t("删除音轨", "Delete track"), role: .destructive) { session.edit([.removeTrack(track.id)]) }
        }
        .accessibilityIdentifier("music.track." + track.id.rawValue)
    }
    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            SwiftUI.Canvas { context, size in
                for entry in rulerMarks {
                    let x = CGFloat(entry.seconds) * scale
                    if entry.mark.beat == 1 {
                        context.draw(Text("\(entry.mark.bar)").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 8, y: 12))
                    }
                }
            }
            TimelineView(.animation(minimumInterval: 0.05, paused: !session.playbackIsActive)) { _ in
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 17)).foregroundStyle(Color.accentColor)
                    .position(x: CGFloat(session.playbackPosition) * scale, y: rulerHeight - 12)
                    .allowsHitTesting(false)
            }
            MusicTimelineInput(ruler: true, seek: { session.seek(to: Double($0 / scale)) })
        }.frame(width: width, height: rulerHeight)
            .background(Color(uiColor: .tertiarySystemBackground))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WorkbenchText.t("时间标尺与播放头", "Time ruler and playhead"))
            .accessibilityValue(MusicWorkbenchFormat.time(session.playbackPosition))
            .accessibilityAdjustableAction { direction in
                let beat = 60 / (session.document.tempoMap.segments.first?.bpm ?? 120)
                session.seek(to: session.playbackPosition + (direction == .increment ? beat : -beat))
            }
            .accessibilityIdentifier("music.timeline.ruler")
    }
    private func trackLane(_ track: MusicTrack, color: Color, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            grid.frame(height: rowHeight)
            ForEach(track.clips) { clip in
                MusicTimelineClip(session: session, clip: clip, color: color, scale: scale, snap: snap, onEdit: onEdit)
                    .offset(x: CGFloat(clip.offset.value) / CGFloat(session.document.tempoMap.sampleRate) * scale, y: 7)
            }
            if showsAutomation,
               let lane = session.document.automationLanes.first(where: { $0.ownerID == track.id.rawValue && $0.target == .trackGain }) {
                SwiftUI.Canvas { context, size in
                    var path = Path()
                    for (index, point) in lane.points.enumerated() {
                        let location = CGPoint(x: CGFloat(point.sample.value) / CGFloat(session.document.tempoMap.sampleRate) * scale,
                            y: size.height - CGFloat(point.value) * (size.height - 8) - 4)
                        if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                        context.fill(Path(ellipseIn: CGRect(x: location.x - 3, y: location.y - 3, width: 6, height: 6)), with: .color(.orange))
                    }
                    context.stroke(path, with: .color(.orange), lineWidth: 2)
                }.allowsHitTesting(false)
            }
        }.frame(width: width, height: rowHeight).clipped()
            .background(session.selectedTrack == track.id ? color.opacity(0.04) : .clear)
            .overlay(alignment: .bottom) { Divider() }
    }
    private var grid: some View {
        SwiftUI.Canvas { context, size in
            for entry in rulerMarks {
                let x = CGFloat(entry.seconds) * scale
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(entry.mark.beat == 1 ? 0.25 : 0.1)), lineWidth: 1)
            }
        }.allowsHitTesting(false)
    }
    private func emptyTimeline(visibleWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            grid
            VStack(spacing: 8) {
                Image(systemName: "music.note.list").font(.title2).foregroundStyle(.secondary)
                Text(WorkbenchText.t("开始编曲", "Start arranging")).font(.headline)
                Text(WorkbenchText.t("导入音频或 MIDI，也可以先添加乐器轨。", "Import audio or MIDI, or start with an instrument track."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(WorkbenchText.t("添加乐器轨", "Add instrument track"), systemImage: "pianokeys") { Task { await session.addTrack() } }
                        .buttonStyle(.bordered)
                    if let onImport {
                        Button(WorkbenchText.t("导入", "Import"), systemImage: "square.and.arrow.down", action: onImport)
                            .buttonStyle(.borderedProminent)
                    }
                }.controlSize(.regular)
            }.padding(12).frame(width: visibleWidth).offset(x: horizontalOffset)
        }
    }
}

private struct MusicTimelineClip: View {
    @Bindable var session: MusicProjectSession
    let clip: MusicClip
    let color: Color
    let scale: CGFloat
    let snap: Bool
    let onEdit: (MusicClip) -> Void
    @State private var preview: MusicClip?
    @State private var drag: DragSnapshot?
    private struct DragSnapshot {
        let clip: MusicClip
        let revision: Int64
        let tempoMap: MusicTempoMap
        let scale: CGFloat
        let snapping: Bool
        let sourceDuration: Int64?
    }
    private var shownClip: MusicClip { preview ?? clip }
    private var length: Double { Double(((try? shownClip.endSample(tempoMap: session.document.tempoMap).value) ?? shownClip.offset.value + 1) - shownClip.offset.value) / Double(session.document.tempoMap.sampleRate) }
    private var movement: CGFloat { CGFloat(shownClip.offset.value - clip.offset.value) / CGFloat(session.document.tempoMap.sampleRate) * scale }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.18))
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name.isEmpty ? WorkbenchText.t("片段", "Clip") : clip.name).font(.caption2.weight(.medium)).lineLimit(1)
                content
            }.padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(color)
            if session.selectedClip == clip.id {
                HStack(spacing: 0) {
                    trimHandle
                    Spacer(minLength: 4)
                    trimHandle
                }.allowsHitTesting(false)
            }
        }
        .frame(width: max(44, CGFloat(length) * scale), height: 62)
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(session.selectedClip == clip.id ? color : color.opacity(0.3), lineWidth: session.selectedClip == clip.id ? 2 : 1) }
        .overlay {
            MusicTimelineInput(selected: session.selectedClip == clip.id,
                select: { session.selectClip(clip) }, open: { onEdit(clip) }, edit: gesture)
        }
        .offset(x: movement)
        .onDisappear { drag = nil; preview = nil }
        .accessibilityElement(children: .ignore).accessibilityLabel(clip.name)
        .accessibilityValue(MusicWorkbenchFormat.time(Double(clip.offset.value) / Double(session.document.tempoMap.sampleRate)))
        .accessibilityAddTraits(.isButton).accessibilityAction { onEdit(clip) }
        .accessibilityAction(named: WorkbenchText.t("选择", "Select")) { session.selectClip(clip) }
        .accessibilityAction(named: WorkbenchText.t("复制", "Duplicate")) { session.selectClip(clip); session.duplicateSelection() }
        .accessibilityAction(named: WorkbenchText.t("删除", "Delete")) { session.edit([.removeClip(clip.id)]) }
        .accessibilityIdentifier("music.clip." + clip.id.rawValue)
    }
    @ViewBuilder private var content: some View {
        switch shownClip.body {
        case .audio(let payload):
            let asset = session.document.assets.first { $0.id == payload.assetID }
            if let peaks = session.waveforms[payload.assetID], let asset, asset.durationSamples.value > 0 {
                MusicWaveformView(peaks: peaks, color: color,
                    start: Double(payload.trimStartSamples) / Double(asset.durationSamples.value),
                    end: Double(payload.trimStartSamples + payload.durationSamples) / Double(asset.durationSamples.value))
            } else {
                Text(session.waveformErrors[payload.assetID] == nil ? WorkbenchText.t("读取波形…", "Loading waveform…") : WorkbenchText.t("波形不可用", "Waveform unavailable"))
                    .font(.caption2).foregroundStyle(.secondary).frame(maxHeight: .infinity)
            }
        case .midi(let payload):
            SwiftUI.Canvas { context, size in
                let low = payload.notes.map(\.pitch).min() ?? 48
                let high = max(low + 12, payload.notes.map(\.pitch).max() ?? 72)
                for note in payload.notes {
                    let x = CGFloat(note.startTick.value) / CGFloat(payload.durationTicks) * size.width
                    let width = max(2, CGFloat(note.durationTicks) / CGFloat(payload.durationTicks) * size.width)
                    let y = CGFloat(high - note.pitch) / CGFloat(high - low + 1) * max(1, size.height - 4)
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: 3), cornerRadius: 1), with: .color(color))
                }
            }
        }
    }
    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.8)).frame(width: 4, height: 28)
            .frame(width: 18, height: 62)
    }
    private func gesture(_ kind: MusicTimelineEditKind, _ delta: CGFloat, _ state: UIGestureRecognizer.State) {
        if state == .began {
            guard !session.saving, !session.isRecording, !session.isMIDIRecording else { return }
            session.selectClip(clip)
            let duration: Int64?
            if case .audio(let payload) = clip.body {
                duration = session.document.assets.first { $0.id == payload.assetID }?.durationSamples.value
            } else { duration = nil }
            drag = DragSnapshot(clip: clip, revision: session.document.revision,
                tempoMap: session.document.tempoMap, scale: scale, snapping: snap, sourceDuration: duration)
        }
        guard let captured = drag else { return }
        if state == .cancelled || state == .failed { drag = nil; preview = nil; return }
        guard state == .began || state == .changed || state == .ended else { return }
        do {
            let next = try MusicTimelineEditing.edit(captured.clip, kind: kind, deltaSeconds: Double(delta / captured.scale),
                snapping: captured.snapping, tempoMap: captured.tempoMap, sourceDurationSamples: captured.sourceDuration)
            preview = next
            guard state == .ended else { return }
            drag = nil; preview = nil
            guard next != captured.clip else { return }
            Task { do { try await session.apply([.updateClip(next)], expectedRevision: captured.revision) }
                catch { session.diagnostic = error.localizedDescription } }
        } catch {
            if state == .ended { drag = nil; preview = nil; session.diagnostic = error.localizedDescription }
        }
    }

}

struct MusicWaveformView: View {
    let peaks: [Float]
    var color: Color = .accentColor
    var start = 0.0
    var end = 1.0
    var body: some View {
        SwiftUI.Canvas { context, size in
            guard !peaks.isEmpty, end > start else { return }
            let count = max(1, Int(size.width / 3))
            var path = Path()
            for bin in 0..<count {
                let fraction = start + Double(bin) / Double(count) * (end - start)
                let peak = min(1, max(0, peaks[min(peaks.count - 1, max(0, Int(fraction * Double(peaks.count))))]))
                let x = CGFloat(bin) / CGFloat(count) * size.width
                let half = max(0.5, CGFloat(peak) * size.height * 0.48)
                path.move(to: CGPoint(x: x, y: size.height / 2 - half)); path.addLine(to: CGPoint(x: x, y: size.height / 2 + half))
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }.accessibilityLabel(WorkbenchText.t("音频波形", "Audio waveform"))
    }
}
#endif

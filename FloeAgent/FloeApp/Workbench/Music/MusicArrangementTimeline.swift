// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicArrangementTimeline: View {
    @Bindable var session: MusicProjectSession
    var zoom: Double
    var snap: Bool
    var showsAutomation: Bool
    var onEdit: (MusicClip) -> Void
    private let rowHeight: CGFloat = 76
    private var scale: CGFloat { 48 * zoom }
    private var horizon: Double {
        let bpm = session.document.tempoMap.segments.first?.bpm ?? 120
        return max(60 / bpm * 32, session.durationSeconds + 60 / bpm * 4)
    }
    private var beatPositions: [Double] {
        let map = session.document.tempoMap
        let last = (try? map.tick(atSample: .init(Int64(horizon * Double(map.sampleRate)))).value) ?? 0
        return (0...min(4096, Int(last) / map.ticksPerQuarter + 1)).compactMap { beat in
            guard let sample = try? map.sample(atTick: .init(Int64(beat * map.ticksPerQuarter))) else { return nil }
            return Double(sample.value) / Double(map.sampleRate)
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
                        }.padding(.horizontal, 10).frame(height: 34)
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
                                    if session.document.tracks.isEmpty { emptyTimeline.frame(width: width, height: max(200, geometry.size.height - 34)) }
                                }
                                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                                    Rectangle().fill(Color.accentColor).frame(width: 1.5)
                                        .offset(x: CGFloat(session.playbackPosition) * scale)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        }.frame(width: width)
                    }
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
        SwiftUI.Canvas { context, size in
            for (index, seconds) in beatPositions.enumerated() {
                let x = CGFloat(seconds) * scale
                if index % 4 == 0 {
                    context.draw(Text("\(index / 4 + 1)").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 8, y: size.height / 2))
                }
            }
        }.frame(width: width, height: 34)
            .background(Color(uiColor: .tertiarySystemBackground))
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in session.seek(to: Double(value.location.x / scale)) })
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
            for (index, seconds) in beatPositions.enumerated() {
                let x = CGFloat(seconds) * scale
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(index % 4 == 0 ? 0.25 : 0.1)), lineWidth: 1)
            }
        }.allowsHitTesting(false)
    }
    private var emptyTimeline: some View {
        ZStack {
            grid
            VStack(spacing: 12) {
                Image(systemName: "waveform.path").font(.largeTitle).foregroundStyle(.secondary)
                Text(WorkbenchText.t("开始一段音乐", "Start a piece")).font(.headline)
                Text(WorkbenchText.t("导入音频、MIDI，或添加乐器轨。", "Import audio or MIDI, or add an instrument track.")).font(.callout).foregroundStyle(.secondary)
                Button(WorkbenchText.t("添加乐器轨", "Add instrument track")) { Task { await session.addTrack() } }.frame(minHeight: 44)
            }.padding()
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
    @State private var movement: CGFloat = 0
    @State private var revision: Int64?
    private var length: Double { Double(((try? clip.endSample(tempoMap: session.document.tempoMap).value) ?? clip.offset.value + 1) - clip.offset.value) / Double(session.document.tempoMap.sampleRate) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.18))
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name.isEmpty ? WorkbenchText.t("片段", "Clip") : clip.name).font(.caption2.weight(.medium)).lineLimit(1)
                content
            }.padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(color)
            HStack(spacing: 0) {
                trimHandle(start: true)
                Spacer(minLength: 4)
                trimHandle(start: false)
            }
        }
        .frame(width: max(44, CGFloat(length) * scale), height: 62)
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(session.selectedClip == clip.id ? color : color.opacity(0.3), lineWidth: session.selectedClip == clip.id ? 2 : 1) }
        .offset(x: movement)
        .onTapGesture(count: 2) { onEdit(clip) }
        .onTapGesture { session.selectClip(clip) }
        .gesture(DragGesture(minimumDistance: 8).onChanged { value in
            if revision == nil { revision = session.document.revision; session.selectClip(clip) }
            movement = value.translation.width
        }.onEnded { value in
            var next = clip
            let seconds = Double(clip.offset.value) / Double(session.document.tempoMap.sampleRate) + Double(value.translation.width / scale)
            next.offset = .init(Int64(snapped(max(0, seconds)) * Double(session.document.tempoMap.sampleRate)))
            commit(next); movement = 0
        })
        .contextMenu {
            Button(WorkbenchText.t("编辑片段", "Edit clip")) { onEdit(clip) }
            Button(WorkbenchText.t("复制", "Duplicate")) { session.selectClip(clip); session.duplicateSelection() }
            Button(WorkbenchText.t("删除", "Delete"), role: .destructive) { session.edit([.removeClip(clip.id)]) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(clip.name)
        .accessibilityValue(MusicWorkbenchFormat.time(Double(clip.offset.value) / Double(session.document.tempoMap.sampleRate)))
        .accessibilityAddTraits(.isButton).accessibilityAction { onEdit(clip) }
        .accessibilityIdentifier("music.clip." + clip.id.rawValue)
    }
    @ViewBuilder private var content: some View {
        switch clip.body {
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
    private func trimHandle(start: Bool) -> some View {
        Rectangle().fill(color.opacity(session.selectedClip == clip.id ? 0.7 : 0.2)).frame(width: 4)
            .padding(.horizontal, 6).frame(width: 18, height: 62).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 8).onChanged { _ in if revision == nil { revision = session.document.revision } }.onEnded { value in
                let rate = Double(session.document.tempoMap.sampleRate)
                let lower = Double(clip.offset.value) / rate
                let upper = lower + length
                let shifted = snapped((start ? lower : upper) + Double(value.translation.width / scale))
                let a = start ? min(upper - 0.02, max(lower, shifted)) : lower
                let b = start ? upper : max(lower + 0.02, min(upper, shifted))
                do {
                    let next = try MusicWorkbenchEditing.trim(clip, start: .init(Int64(a * rate)), end: .init(Int64(b * rate)), tempoMap: session.document.tempoMap)
                    commit(next)
                } catch { revision = nil; session.diagnostic = error.localizedDescription }
            })
    }
    private func snapped(_ seconds: Double) -> Double {
        guard snap else { return seconds }
        let map = session.document.tempoMap
        let tick = (try? map.tick(atSample: .init(Int64(max(0, seconds) * Double(map.sampleRate)))).value) ?? 0
        let quarter = Double(map.ticksPerQuarter) / 4
        let gridTick = Int64((Double(tick) / quarter).rounded() * quarter)
        return Double((try? map.sample(atTick: .init(gridTick)).value) ?? 0) / Double(map.sampleRate)
    }
    private func commit(_ next: MusicClip) {
        let base = revision ?? session.document.revision; revision = nil
        Task { do { try await session.apply([.updateClip(next)], expectedRevision: base) } catch { session.diagnostic = error.localizedDescription } }
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

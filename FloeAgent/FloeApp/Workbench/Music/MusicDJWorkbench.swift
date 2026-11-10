// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicDJWorkbench: View {
    @Bindable var session: MusicProjectSession
    var onImport: (() -> Void)? = nil
    @State private var search = ""
    @State private var exportSeconds = 60.0
    @State private var jogStarts: [MusicDJSession.DeckSlot: Int64] = [:]
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !session.playbackIsActive && session.djCapturePhase != .recording)) { _ in
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text(WorkbenchText.t("双碟打碟", "Dual decks")).font(.headline)
                        Spacer()
                        if session.djLoading {
                            ProgressView()
                            Button(WorkbenchText.t("取消", "Cancel")) { session.stopDJ() }.frame(minHeight: 44)
                        }
                        Button {
                            if session.djCapturePhase == .recording { session.finishDJRecording() }
                            else {
                                Task {
                                    do { _ = try await session.startDJRecording(expectedMusicRevision: session.document.revision, expectedDJRevision: session.djRevision) }
                                    catch { session.diagnostic = WorkbenchText.t("录制未能开始，请先载入曲目。", "Recording could not start. Load a track first.") }
                                }
                            }
                        } label: {
                            Label(session.djCapturePhase == .recording ? WorkbenchText.t("保存录音", "Save recording") : WorkbenchText.t("录制混音", "Record mix"),
                                systemImage: session.djCapturePhase == .recording ? "stop.circle.fill" : "record.circle")
                                .foregroundStyle(.red).labelStyle(.iconOnly).frame(width: 44, height: 44)
                        }.disabled(session.djLoading || session.isRendering || session.djCapturePhase == .starting || session.djCapturePhase == .finishing
                            || (state(.a)?.assetID == nil && state(.b)?.assetID == nil))
                            .accessibilityIdentifier("music.dj.record")
                        Button(session.djIsActive ? WorkbenchText.t("停止", "Stop") : WorkbenchText.t("播放混音", "Play mix"), systemImage: session.djIsActive ? "stop.fill" : "play.fill") {
                            session.toggleDJ()
                        }.disabled((session.isRendering && !session.djIsActive) || session.dj == nil || session.djLoading).frame(minHeight: 44)
                            .accessibilityIdentifier("music.dj.play")
                    }
                    if session.djRecoveryRequired {
                        HStack {
                            Text(WorkbenchText.t("已保存的双碟设置需要恢复。", "Saved deck settings need recovery.")).font(.callout)
                            Spacer()
                            Button(WorkbenchText.t("保留原件并重置", "Retain original and reset")) { session.resetDJSettingsPreservingOriginal() }
                        }
                    }
                    recordingAndExport
                    deckWaveforms.allowsHitTesting(!session.djLoading)
                    if geometry.size.width >= 800 {
                        HStack(alignment: .top, spacing: 16) {
                            deck(.a).frame(maxWidth: .infinity)
                            Divider()
                            mixer.frame(width: 160)
                            Divider()
                            deck(.b).frame(maxWidth: .infinity)
                        }
                    } else {
                        deck(.a)
                        Divider()
                        mixer
                        Divider()
                        deck(.b)
                    }
                    Divider()
                    library
                    DisclosureGroup(WorkbenchText.t("输出详情", "Output details")) {
                        Text(WorkbenchText.t("两盘实时混音；速度、锁调、跳点和循环直接作用于当前音频。耳机预听需要独立输出通道。", "Both decks mix live. Rate, key lock, cues and loops control the current audio. Headphone cueing requires a separate output channel."))
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }.padding(16)
            }
        }
        }
        .onAppear {
            if session.dj == nil && !session.djRecoveryRequired { session.changeDJ { _ in } }
            exportSeconds = session.suggestedDJExportSeconds
        }
        .accessibilityIdentifier("music.dj")
    }
    private var recordingAndExport: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.djCapturePhase == .starting || session.djCapturePhase == .finishing {
                if session.djCapturePhase == .starting {
                    Button(WorkbenchText.t("取消录制", "Cancel recording")) { session.finishDJRecording() }
                }
                ProgressView(session.djCapturePhase == .starting ? WorkbenchText.t("正在准备录制…", "Preparing recording…") : WorkbenchText.t("正在保存录音…", "Saving recording…"))
            }
            HStack {
                Text(WorkbenchText.t("导出时长", "Export duration")).font(.caption)
                TextField(WorkbenchText.t("秒", "Seconds"), value: $exportSeconds, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).keyboardType(.decimalPad).frame(width: 84)
                    .accessibilityIdentifier("music.dj.export.duration")
                Text(WorkbenchText.t("秒", "s")).font(.caption)
                Spacer()
                Menu {
                    Button("WAV") { session.exportDJ(asMP3: false, durationSeconds: exportSeconds) }
                    Button("MP3") { session.exportDJ(asMP3: true, durationSeconds: exportSeconds) }
                } label: { Label(WorkbenchText.t("导出混音", "Export mix"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                    .disabled(session.isRendering || session.djCaptureBusy || session.djLoading
                        || (state(.a)?.assetID == nil && state(.b)?.assetID == nil))
                    .accessibilityIdentifier("music.dj.export")
            }
            if let receipt = session.djLastRecording {
                HStack {
                    Label(!receipt.recovered && session.document.assets.contains(where: { $0.contentHash == receipt.sha256 })
                        ? WorkbenchText.t("录音已保存到素材库", "Recording saved to the library") : WorkbenchText.t("已保留录音", "Recording retained"), systemImage: "waveform")
                        .font(.caption)
                    Spacer()
                    ShareLink(item: receipt.file) { Label(WorkbenchText.t("分享", "Share"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                }.accessibilityIdentifier("music.dj.recording.saved")
            }
            if let details = session.djDiagnosticDetails {
                DisclosureGroup(WorkbenchText.t("操作详情", "Operation details")) { Text(details).font(.caption).textSelection(.enabled) }.font(.caption)
            }
        }
    }
    private var deckWaveforms: some View {
        VStack(spacing: 5) {
            ForEach([MusicDJSession.DeckSlot.a, .b], id: \.self) { slot in
                HStack(spacing: 8) {
                    Text(slot.rawValue.uppercased()).font(.caption.weight(.bold)).frame(width: 20)
                    waveform(slot).frame(height: 52)
                }.foregroundStyle(slot == .a ? Color.blue : Color.orange)
            }
        }
    }
    private func waveform(_ slot: MusicDJSession.DeckSlot) -> some View {
        let value = state(slot)
        let color: Color = slot == .a ? .blue : .orange
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let id = value?.assetID, let peaks = session.waveforms[id] {
                    MusicWaveformView(peaks: peaks, color: color)
                    SwiftUI.Canvas { context, size in
                        guard let value, value.assetDurationSamples > 0 else { return }
                        if let grid = value.beatGrid {
                            let length = grid.beatLengthSamples(sampleRate: session.document.tempoMap.sampleRate)
                            let step = max(1, grid.beatCount / 160)
                            for beat in stride(from: 0, to: grid.beatCount, by: step) {
                                let sample = Double(grid.firstBeatSample) + Double(beat) * length
                                let x = sample / Double(value.assetDurationSamples) * size.width
                                guard x >= 0, x <= size.width else { continue }
                                var path = Path(); path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height))
                                context.stroke(path, with: .color(color.opacity(beat % 4 == 0 ? 0.5 : 0.16)), lineWidth: 1)
                            }
                        }
                    }.allowsHitTesting(false)
                    Rectangle().fill(.primary).frame(width: 2)
                        .offset(x: geometry.size.width * Double(value?.playheadSamples ?? 0) / Double(max(1, value?.assetDurationSamples ?? 1)))
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.06))
                    Text(WorkbenchText.t("从曲库载入音频", "Load audio from the library")).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let sample = Int64(min(1, max(0, event.location.x / max(1, geometry.size.width))) * Double(value?.assetDurationSamples ?? 0))
                    session.seekDJ(slot, sample: sample, commit: false)
                }.onEnded { event in
                    let sample = Int64(min(1, max(0, event.location.x / max(1, geometry.size.width))) * Double(value?.assetDurationSamples ?? 0))
                    session.seekDJ(slot, sample: sample, commit: true)
                })
                .accessibilityLabel(slot.rawValue.uppercased() + WorkbenchText.t("盘波形与播放位置", " waveform and position"))
                .accessibilityValue(MusicWorkbenchFormat.time(Double(value?.playheadSamples ?? 0) / Double(session.document.tempoMap.sampleRate)))
                .accessibilityIdentifier("music.dj.waveform." + slot.rawValue)
        }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(WorkbenchText.t("曲库", "Library")).font(.headline)
                Spacer()
                TextField(WorkbenchText.t("搜索曲目", "Search tracks"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            let assets = session.document.assets.filter { $0.kind != .midiFile && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            if assets.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                    Button(WorkbenchText.t("清除搜索", "Clear search")) { search = "" }.frame(minHeight: 44)
                } else {
                    ContentUnavailableView {
                        Label(WorkbenchText.t("导入你的曲目", "Import your tracks"), systemImage: "music.note.list")
                    } description: {
                        Text(WorkbenchText.t("导入音频后，即可载入 A／B 盘、设置 Cue 和制作混音。", "Import audio to load decks A and B, set cues and create a mix."))
                    } actions: {
                        if let onImport {
                            Button(WorkbenchText.t("导入音频", "Import audio"), systemImage: "square.and.arrow.down", action: onImport)
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        }
                    }
                }
            }
            ForEach(assets) { asset in
                HStack(spacing: 10) {
                    MusicWaveformView(peaks: session.waveforms[asset.id] ?? [], color: .secondary).frame(width: 64, height: 32)
                    VStack(alignment: .leading) {
                        Text(asset.name).lineLimit(1)
                        Text(MusicWorkbenchFormat.time(Double(asset.durationSamples.value) / Double(session.document.tempoMap.sampleRate)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let bpm = session.djBeatEstimates[asset.id]?.bpm { Text(bpm, format: .number.precision(.fractionLength(1))).font(.caption.monospacedDigit()) }
                    Button("A") { session.loadDJ(.a, asset: asset) }.frame(minWidth: 44, minHeight: 44)
                    Button("B") { session.loadDJ(.b, asset: asset) }.frame(minWidth: 44, minHeight: 44)
                }.disabled(session.djLoading).padding(.vertical, 3)
                Divider()
            }
        }.accessibilityIdentifier("music.dj.library")
    }
    private func deck(_ slot: MusicDJSession.DeckSlot) -> some View {
        let value = state(slot)
        let color: Color = slot == .a ? .blue : .orange
        return VStack(spacing: 10) {
            HStack {
                Text(slot.rawValue.uppercased()).font(.title2.weight(.semibold)).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    ForEach(session.document.assets.filter { $0.kind != .midiFile }) { asset in
                        Button(asset.name) {
                            session.loadDJ(slot, asset: asset)
                        }
                    }
                } label: {
                    HStack { Text(session.document.assets.first { $0.id == value?.assetID }?.name ?? WorkbenchText.t("选择曲目", "Load track")).lineLimit(1); Spacer(); Image(systemName: "chevron.down") }
                        .font(.callout.weight(.medium)).frame(minHeight: 44)
                }
            }
            HStack {
                Text(value?.beatGrid == nil ? WorkbenchText.t("节拍待设定", "Set the beat grid") : String(format: "%.1f BPM", value?.beatGrid?.bpm ?? 120))
                    .font(.callout.monospacedDigit())
                Spacer()
                if let id = value?.assetID { Button(WorkbenchText.t("分析节拍", "Analyze beats")) { session.analyzeDJ(assetID: id, slot: slot) }.font(.caption) }
            }
            MusicValueSlider(title: WorkbenchText.t("拍格 BPM", "Beat grid BPM"), value: value?.beatGrid?.bpm ?? 120, range: 40...240) { bpm in
                session.changeDJ { dj in
                    let deck = slot == .a ? dj.deckA : dj.deckB
                    try dj.setBeatGrid(slot, bpm: bpm, firstBeatSample: deck.beatGrid?.firstBeatSample ?? 0, beatCount: min(100_000, max(1, Int(Double(max(0, deck.assetDurationSamples - (deck.beatGrid?.firstBeatSample ?? 0))) / Double(dj.sampleRate) * bpm / 60))))
                }
            }.disabled(value?.assetID == nil)
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color(uiColor: .darkGray))
                    ForEach(1..<7) { ring in Circle().stroke(.white.opacity(0.07), lineWidth: 1).padding(CGFloat(ring) * 7) }
                    VStack(spacing: 5) { Text(slot.rawValue.uppercased()).font(.title.weight(.semibold)); Text("Floe").font(.caption2) }.foregroundStyle(.white)
                    Capsule().fill(color).frame(width: 3, height: 17).offset(y: -62)
                }.frame(width: 156, height: 156).contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { gesture in
                        if jogStarts[slot] == nil { jogStarts[slot] = value?.playheadSamples ?? 0 }
                        let sample = (jogStarts[slot] ?? 0) + Int64(gesture.translation.width * 160)
                        session.seekDJ(slot, sample: max(0, sample), commit: false)
                    }.onEnded { gesture in
                        let sample = (jogStarts.removeValue(forKey: slot) ?? value?.playheadSamples ?? 0) + Int64(gesture.translation.width * 160)
                        session.seekDJ(slot, sample: max(0, sample), commit: true)
                    })
                    .accessibilityLabel(slot.rawValue.uppercased() + WorkbenchText.t("盘点动", " deck jog"))
                    .accessibilityAdjustableAction { direction in session.changeDJ { try $0.seek(slot, sample: max(0, (value?.playheadSamples ?? 0) + (direction == .increment ? 2400 : -2400))) } }
                VStack {
                    MusicValueSlider(title: WorkbenchText.t("速度", "Rate"), value: (value?.rate ?? 1) * 100 - 100, range: -16...16, suffix: "%") { rate in session.changeDJ { try $0.setRate(slot, rate: 1 + rate / 100) } }
                    Button(WorkbenchText.t("重置速度", "Reset rate")) { session.changeDJ { try $0.setRate(slot, rate: 1) } }.font(.caption).frame(minHeight: 44)
                    Toggle(WorkbenchText.t("锁调", "Key lock"), isOn: Binding(get: { value?.keyLocked ?? false }, set: { locked in session.changeDJ { try $0.setKeyLocked(slot, locked) } }))
                        .font(.caption).disabled(value?.assetID == nil)
                }.frame(maxWidth: .infinity)
            }
            MusicValueSlider(title: WorkbenchText.t("位置", "Position"), value: Double(value?.playheadSamples ?? 0) / Double(session.document.tempoMap.sampleRate), range: 0...max(0.01, Double(value?.assetDurationSamples ?? 0) / Double(session.document.tempoMap.sampleRate)), suffix: "s") { seconds in
                session.changeDJ { try $0.seek(slot, sample: Int64(seconds * Double($0.sampleRate))) }
            }.disabled(value?.assetID == nil)
            HStack(spacing: 4) {
                Button { session.toggleDJ(slot) } label: { Label(value?.playing == true ? WorkbenchText.t("暂停", "Pause") : WorkbenchText.t("播放", "Play"), systemImage: value?.playing == true ? "pause.fill" : "play.fill").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
                    .disabled(value?.assetID == nil || session.isRendering)
                Button("CUE") {
                    session.changeDJ { dj in
                        if (slot == .a ? dj.deckA : dj.deckB).cue == nil { try dj.setCue(slot, sample: value?.playheadSamples ?? 0) }
                        else { try dj.jumpToCue(slot) }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .contextMenu {
                        Button(WorkbenchText.t("设置当前起播点", "Set current cue")) { session.changeDJ { try $0.setCue(slot, sample: value?.playheadSamples ?? 0) } }
                        Button(WorkbenchText.t("清除起播点", "Clear cue"), role: .destructive) { session.changeDJ { try $0.clearCue(slot) } }
                    }
                Button("SYNC") { session.changeDJ { try $0.syncDeck(slot, to: slot == .a ? .b : .a) } }.frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(value?.beatGrid == nil || state(slot == .a ? .b : .a)?.beatGrid == nil)
            }.disabled(value?.assetID == nil)
            HStack {
                Text(WorkbenchText.t("循环", "Loop")).font(.caption)
                ForEach([1, 2, 4, 8], id: \.self) { beats in
                    Button("\(beats)") {
                        session.changeDJ { dj in
                            if value?.activeLoop?.lengthBeats == beats { try dj.exitLoop(slot) }
                            else {
                                let beatLength = value?.beatGrid?.beatLengthSamples(sampleRate: dj.sampleRate) ?? 24000
                                let start = max(0, Int(Double((value?.playheadSamples ?? 0) - (value?.beatGrid?.firstBeatSample ?? 0)) / beatLength))
                                try dj.setLoop(slot, startBeat: start, lengthBeats: beats)
                            }
                        }
                    }.font(.caption).frame(minWidth: 40, minHeight: 44).background(value?.activeLoop?.lengthBeats == beats ? color.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            }.disabled(value?.assetID == nil || value?.beatGrid == nil)
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    let exists = value?.hotcues.contains { $0.index == index } ?? false
                    Button("\(index + 1)") {
                        session.changeDJ { dj in if exists { try dj.jumpToHotcue(slot, index: index) } else { try dj.setHotcue(slot, index: index, sample: value?.playheadSamples ?? 0) } }
                    }.font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                        .background(color.opacity(exists ? 0.22 : 0.07), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(slot.rawValue.uppercased() + WorkbenchText.t("盘跳点", " hotcue") + " \(index + 1)")
                        .contextMenu {
                            Button(WorkbenchText.t("更新跳点", "Update hotcue")) { session.changeDJ { try $0.setHotcue(slot, index: index, sample: value?.playheadSamples ?? 0) } }
                            Button(WorkbenchText.t("清除跳点", "Clear hotcue"), role: .destructive) { session.changeDJ { try $0.removeHotcue(slot, index: index) } }
                        }
                }
            }.buttonStyle(.plain).disabled(value?.assetID == nil)
        }.allowsHitTesting(!session.djLoading)
    }
    private var mixer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(WorkbenchText.t("双通道混音", "Deck mixer")).font(.caption.weight(.medium))
            HStack {
                Text("A").foregroundStyle(.blue)
                Spacer()
                Text("B").foregroundStyle(.orange)
            }
            MusicValueSlider(title: WorkbenchText.t("左右混合", "Crossfader"), value: session.dj?.crossfader ?? 0.5, range: 0...1, showField: false) { value in session.changeDJ { try $0.setCrossfader(value) } }
                .accessibilityIdentifier("music.dj.crossfader")
            MusicValueSlider(title: WorkbenchText.t("主输出", "Master"), value: session.dj?.masterGain ?? 1, range: 0...2) { gain in session.changeDJ { try $0.setMasterGain(gain) } }
            Divider()
            Label(WorkbenchText.t("预听", "Cue"), systemImage: "headphones").font(.caption)
            Picker(WorkbenchText.t("预听来源", "Cue source"), selection: Binding(get: { session.dj?.cueSource ?? .none }, set: { source in session.changeDJ { try $0.setCueSource(source) } })) {
                Text(WorkbenchText.t("关闭", "Off")).tag(MusicDJSession.CueSource.none)
                Text("A").tag(MusicDJSession.CueSource.deckA)
                Text("B").tag(MusicDJSession.CueSource.deckB)
            }.pickerStyle(.segmented)
            Text(WorkbenchText.t("已保存预听设置；独立输出待接入。", "Cue settings are saved; independent output is pending.")).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.allowsHitTesting(!session.djLoading)
    }
    private func state(_ slot: MusicDJSession.DeckSlot) -> MusicDJSession.Deck? { slot == .a ? session.djPresentationState?.deckA : session.djPresentationState?.deckB }
}
#endif

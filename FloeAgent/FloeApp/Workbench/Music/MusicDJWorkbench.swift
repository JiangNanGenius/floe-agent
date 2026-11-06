// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore

struct MusicDJWorkbench: View {
    @Bindable var session: MusicProjectSession
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text(WorkbenchText.t("双碟打碟", "Dual decks")).font(.headline)
                        Spacer()
                        Button(session.playbackIsActive ? WorkbenchText.t("停止试听", "Stop preview") : WorkbenchText.t("试听混音", "Preview mix"), systemImage: session.playbackIsActive ? "stop.fill" : "play.fill") {
                            if session.playbackIsActive { session.stopPlayback() } else { session.renderDJ() }
                        }.disabled(session.isRendering || session.dj == nil).frame(minHeight: 44)
                    }
                    deckWaveforms
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
                    DisclosureGroup(WorkbenchText.t("试听与输出说明", "Preview and output details")) {
                        Text(WorkbenchText.t("试听会用当前盘位、变速、循环与交叉推杆渲染最多 60 秒音频。实时搓碟、锁调及独立耳机输出仍待接入。", "Preview renders up to 60 seconds using the current positions, rates, loops and crossfader. Live scratching, key lock and independent headphone output are pending."))
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }.padding(16)
            }
        }
        .onAppear { if session.dj == nil { session.changeDJ { _ in } } }
        .accessibilityIdentifier("music.dj")
    }
    private var deckWaveforms: some View {
        VStack(spacing: 3) {
            ForEach([MusicDJSession.DeckSlot.a, .b], id: \.self) { slot in
                HStack(spacing: 8) {
                    Text(slot.rawValue.uppercased()).font(.caption.weight(.bold)).frame(width: 20)
                    if let id = state(slot)?.assetID, let peaks = session.waveforms[id] {
                        MusicWaveformView(peaks: peaks, color: slot == .a ? .blue : .orange).frame(height: 34)
                    } else { Rectangle().fill(Color.secondary.opacity(0.06)).frame(height: 34).overlay { Text(WorkbenchText.t("载入音频", "Load audio")).font(.caption2).foregroundStyle(.secondary) } }
                }.foregroundStyle(slot == .a ? Color.blue : Color.orange)
            }
        }
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
                            session.changeDJ { dj in
                                try dj.loadDeck(slot, asset: asset)
                                let bpm = session.document.tempoMap.segments.first?.bpm ?? 120
                                let beats = max(1, Int(Double(asset.durationSamples.value) / Double(dj.sampleRate) * bpm / 60))
                                try dj.setBeatGrid(slot, bpm: bpm, firstBeatSample: 0, beatCount: beats)
                            }
                        }
                    }
                } label: {
                    HStack { Text(session.document.assets.first { $0.id == value?.assetID }?.name ?? WorkbenchText.t("选择曲目", "Load track")).lineLimit(1); Spacer(); Image(systemName: "chevron.down") }
                        .font(.callout.weight(.medium)).frame(minHeight: 44)
                }
            }
            MusicValueSlider(title: WorkbenchText.t("拍格 BPM", "Beat grid BPM"), value: value?.beatGrid?.bpm ?? 120, range: 40...240) { bpm in
                session.changeDJ { dj in
                    let deck = slot == .a ? dj.deckA : dj.deckB
                    try dj.setBeatGrid(slot, bpm: bpm, firstBeatSample: 0, beatCount: max(1, Int(Double(deck.assetDurationSamples) / Double(dj.sampleRate) * bpm / 60)))
                }
            }.disabled(value?.assetID == nil)
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color(uiColor: .darkGray))
                    ForEach(1..<7) { ring in Circle().stroke(.white.opacity(0.07), lineWidth: 1).padding(CGFloat(ring) * 7) }
                    VStack(spacing: 5) { Text(slot.rawValue.uppercased()).font(.title.weight(.semibold)); Text("Floe").font(.caption2) }.foregroundStyle(.white)
                    Capsule().fill(color).frame(width: 3, height: 17).offset(y: -62)
                }.frame(width: 156, height: 156).contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 4).onEnded { gesture in
                        let sample = (value?.playheadSamples ?? 0) + Int64(gesture.translation.width * 160)
                        session.changeDJ { try $0.seek(slot, sample: max(0, sample)) }
                    })
                    .accessibilityLabel(slot.rawValue.uppercased() + WorkbenchText.t("盘点动", " deck jog"))
                    .accessibilityAdjustableAction { direction in session.changeDJ { try $0.seek(slot, sample: max(0, (value?.playheadSamples ?? 0) + (direction == .increment ? 2400 : -2400))) } }
                VStack {
                    MusicValueSlider(title: WorkbenchText.t("速度", "Rate"), value: (value?.rate ?? 1) * 100 - 100, range: -16...16, suffix: "%") { rate in session.changeDJ { try $0.setRate(slot, rate: 1 + rate / 100) } }
                    Button(WorkbenchText.t("重置速度", "Reset rate")) { session.changeDJ { try $0.setRate(slot, rate: 1) } }.font(.caption).frame(minHeight: 44)
                    Label(WorkbenchText.t("锁调待接入", "Key lock pending"), systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            MusicValueSlider(title: WorkbenchText.t("位置", "Position"), value: Double(value?.playheadSamples ?? 0) / Double(session.document.tempoMap.sampleRate), range: 0...max(0.01, Double(value?.assetDurationSamples ?? 0) / Double(session.document.tempoMap.sampleRate)), suffix: "s") { seconds in
                session.changeDJ { try $0.seek(slot, sample: Int64(seconds * Double($0.sampleRate))) }
            }.disabled(value?.assetID == nil)
            HStack(spacing: 4) {
                Button { session.renderDJ(deck: slot) } label: { Label(WorkbenchText.t("试听", "Preview"), systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
                    .disabled(value?.assetID == nil || session.isRendering)
                Button("CUE") {
                    session.changeDJ { dj in
                        if (slot == .a ? dj.deckA : dj.deckB).cue == nil { try dj.setCue(slot, sample: value?.playheadSamples ?? 0) }
                        else { try dj.jumpToCue(slot) }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .contextMenu { Button(WorkbenchText.t("设置当前起播点", "Set current cue")) { session.changeDJ { try $0.setCue(slot, sample: value?.playheadSamples ?? 0) } } }
                Button("SYNC") { session.changeDJ { try $0.syncDeck(slot, to: slot == .a ? .b : .a) } }.frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(value?.assetID == nil)
            HStack {
                Text(WorkbenchText.t("循环", "Loop")).font(.caption)
                ForEach([1, 2, 4, 8], id: \.self) { beats in
                    Button("\(beats)") {
                        session.changeDJ { dj in
                            if value?.activeLoop?.lengthBeats == beats { try dj.exitLoop(slot) }
                            else {
                                let beatLength = value?.beatGrid?.beatLengthSamples(sampleRate: dj.sampleRate) ?? 24000
                                let start = Int(Double(value?.playheadSamples ?? 0) / beatLength)
                                try dj.setLoop(slot, startBeat: start, lengthBeats: beats)
                            }
                        }
                    }.font(.caption).frame(minWidth: 40, minHeight: 44).background(value?.activeLoop?.lengthBeats == beats ? color.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            }.disabled(value?.assetID == nil)
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    let exists = value?.hotcues.contains { $0.index == index } ?? false
                    Button("\(index + 1)") {
                        session.changeDJ { dj in if exists { try dj.jumpToHotcue(slot, index: index) } else { try dj.setHotcue(slot, index: index, sample: value?.playheadSamples ?? 0) } }
                    }.font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                        .background(color.opacity(exists ? 0.22 : 0.07), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(slot.rawValue.uppercased() + WorkbenchText.t("盘跳点", " hotcue") + " \(index + 1)")
                        .contextMenu { Button(WorkbenchText.t("更新跳点", "Update hotcue")) { session.changeDJ { try $0.setHotcue(slot, index: index, sample: value?.playheadSamples ?? 0) } } }
                }
            }.buttonStyle(.plain).disabled(value?.assetID == nil)
        }
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
        }
    }
    private func state(_ slot: MusicDJSession.DeckSlot) -> MusicDJSession.Deck? { slot == .a ? session.dj?.deckA : session.dj?.deckB }
}
#endif

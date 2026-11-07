// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicNative

struct MusicMixerPanel: View {
    @Bindable var session: MusicProjectSession
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(session.document.tracks.enumerated()), id: \.element.id) { index, track in
                    MusicChannelStrip(name: track.name, subtitle: track.kind == .midi ? "MIDI" : WorkbenchText.t("音频", "Audio"),
                        color: MusicWorkbenchFormat.color(index), strip: track.strip, selected: session.selectedTrack == track.id,
                        onSelect: { session.selectTrack(track.id) }, onChange: { session.edit([.setStrip(track.id, $0)]) })
                }
                ForEach(session.document.buses) { bus in
                    MusicChannelStrip(name: bus.name, subtitle: WorkbenchText.t("辅助通道", "Aux bus"), color: .teal, strip: bus.strip,
                        onChange: { session.edit([.setBusStrip(bus.id, $0)]) })
                }
                VStack {
                    MusicIconButton("plus", WorkbenchText.t("添加混响返回", "Add reverb return")) { session.addReverbBus() }
                    Text(WorkbenchText.t("辅助通道", "Aux bus")).font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 80).padding(.top, 8)
                Spacer(minLength: 20)
                MusicChannelStrip(name: WorkbenchText.t("主输出", "Master"), subtitle: "Stereo Out", color: .primary,
                    strip: session.document.masterStrip, onChange: { session.edit([.setMasterStrip($0)]) })
            }.frame(minHeight: 240, alignment: .top)
        }.background(Color(uiColor: .systemBackground)).accessibilityIdentifier("music.mixer")
    }
}

private struct MusicChannelStrip: View {
    var name: String
    var subtitle: String
    var color: Color
    var strip: MusicStripSettings
    var selected = false
    var onSelect: (() -> Void)? = nil
    var onChange: (MusicStripSettings) -> Void
    var body: some View {
        VStack(spacing: 3) {
            Button { onSelect?() } label: {
                HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(name).lineLimit(1) }
                    .font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 30)
            }.buttonStyle(.plain)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            MusicValueSlider(title: WorkbenchText.t("声像", "Pan"), value: strip.pan, range: -1...1, suffix: "", showField: false) {
                var next = strip; next.pan = $0; onChange(next)
            }.frame(height: 34)
            MusicVerticalFader(value: MusicWorkbenchFormat.decibels(strip.gain), color: color, title: name) {
                var next = strip; next.gain = MusicWorkbenchFormat.gain($0); onChange(next)
            }.frame(height: 104)
            HStack(spacing: 1) {
                Button { var next = strip; next.muted.toggle(); onChange(next) } label: {
                    Text("M").frame(width: 44, height: 44).background(strip.muted ? Color.orange.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.accessibilityLabel(WorkbenchText.t("静音", "Mute") + " " + name)
                Button { var next = strip; next.soloed.toggle(); onChange(next) } label: {
                    Text("S").frame(width: 44, height: 44).background(strip.soloed ? Color.yellow.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.accessibilityLabel(WorkbenchText.t("独奏", "Solo") + " " + name)
            }.buttonStyle(.plain).font(.caption.weight(.semibold))
        }.padding(.horizontal, 7).padding(.vertical, 5).frame(width: 112)
            .background(selected ? Color.accentColor.opacity(0.07) : .clear)
            .overlay(alignment: .trailing) { Divider() }
    }
}

struct MusicVerticalFader: View {
    let value: Double
    var color: Color = .accentColor
    let title: String
    let onCommit: (Double) -> Void
    @State private var draft: Double
    @State private var dragging = false
    init(value: Double, color: Color = .accentColor, title: String, onCommit: @escaping (Double) -> Void) {
        self.value = value; self.color = color; self.title = title; self.onCommit = onCommit
        _draft = State(initialValue: min(12, max(-60, value)))
    }
    var body: some View {
        VStack(spacing: 1) {
            GeometryReader { geometry in
                let travel = max(1, geometry.size.height - 18)
                HStack(spacing: 8) {
                    VStack { Text("+12"); Spacer(); Text("0"); Spacer(); Text("−24"); Spacer(); Text("−60") }
                        .font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 22)
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.secondary.opacity(0.12)).frame(width: 5)
                        Capsule().fill(color.opacity(0.4)).frame(width: 5, height: max(1, (draft + 60) / 72 * travel))
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 28, height: 12)
                            .offset(y: -(draft + 60) / 72 * travel)
                    }.frame(width: 42).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                            dragging = true
                            draft = min(12, max(-60, (1 - Double(gesture.location.y / max(1, geometry.size.height))) * 72 - 60))
                        }.onEnded { _ in dragging = false; onCommit(draft) })
                }
            }
            Text(draft <= -60 ? "−∞ dB" : String(format: "%.1f dB", draft)).font(.caption2.monospacedDigit()).frame(height: 18)
        }
        .onChange(of: value) { _, next in if !dragging { draft = min(12, max(-60, next)) } }
        .accessibilityElement(children: .ignore).accessibilityLabel(title + WorkbenchText.t("音量", " volume"))
        .accessibilityValue(String(format: "%.1f dB", draft))
        .accessibilityAdjustableAction { direction in
            draft = min(12, max(-60, draft + (direction == .increment ? 1 : -1))); onCommit(draft)
        }
    }
}

/// Edits locally while dragging; one transaction is emitted on release.
struct MusicValueSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var showField = true
    let onCommit: (Double) -> Void
    @State private var draft: Double
    @State private var editing = false
    init(title: String, value: Double, range: ClosedRange<Double>, suffix: String = "", showField: Bool = true, onCommit: @escaping (Double) -> Void) {
        self.title = title; self.value = value; self.range = range; self.suffix = suffix; self.showField = showField; self.onCommit = onCommit
        _draft = State(initialValue: min(range.upperBound, max(range.lowerBound, value)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showField {
                HStack {
                    Text(title).font(.caption)
                    Spacer()
                    TextField(title, value: $draft, format: .number.precision(.fractionLength(0...2)))
                        .font(.caption.monospacedDigit()).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 65)
                        .onSubmit { onCommit(draft) }
                    if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Slider(value: $draft, in: range, onEditingChanged: { active in editing = active; if !active { onCommit(draft) } })
                .accessibilityLabel(title).frame(minHeight: showField ? 32 : 28)
        }.onChange(of: value) { _, next in if !editing { draft = min(range.upperBound, max(range.lowerBound, next)) } }
    }
}

struct MusicEffectsInspector: View {
    @Bindable var session: MusicProjectSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let track = session.currentTrack {
                    HStack {
                        Image(systemName: track.kind == .midi ? "pianokeys" : "waveform").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.name).font(.headline)
                            Text(track.kind == .midi ? WorkbenchText.t("乐器通道", "Instrument channel") : WorkbenchText.t("音频通道", "Audio channel")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                    HStack { Text(WorkbenchText.t("效果链", "Effect chain")).font(.caption.weight(.medium)); Spacer(); Text(WorkbenchText.t("输入 → 输出", "Input → Output")).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array(track.effects.enumerated()), id: \.offset) { index, effect in
                        effectView(effect, index: index, track: track)
                        Divider()
                    }
                    Menu {
                        Button(WorkbenchText.t("均衡器", "Equalizer")) { session.addEffect(MusicNativeBuiltins.eq) }
                        Button(WorkbenchText.t("混响", "Reverb")) { session.addEffect(MusicNativeBuiltins.reverb) }
                    } label: { Label(WorkbenchText.t("添加效果", "Add effect"), systemImage: "plus").frame(minHeight: 44) }
                    if let clip = session.currentClip, case .audio = clip.body { clipControls }
                    routing(track)
                    if track.kind == .midi {
                        Divider()
                        instrumentControls(track)
                    }
                    Divider()
                    Button(WorkbenchText.t("在播放头添加音量自动化", "Add volume automation at playhead")) { addAutomation(track) }.font(.caption).frame(minHeight: 44)
                } else {
                    ContentUnavailableView(WorkbenchText.t("选择一个通道", "Select a channel"), systemImage: "slider.horizontal.3")
                }
            }.padding(14)
        }.accessibilityIdentifier("music.effects")
    }
    @ViewBuilder private func instrumentControls(_ track: MusicTrack) -> some View {
        HStack {
            Text(WorkbenchText.t("乐器", "Instrument")).font(.caption.weight(.medium))
            Spacer()
            MusicPresetPickerButton(session: session)
        }
        Text(MusicInstrumentPresentation.name(track.instrument)).font(.callout).foregroundStyle(.secondary)
        if MusicInstrumentPresentation.isEditable(track.instrument) {
            instrumentParameter(WorkbenchText.t("起音", "Attack"), key: "attack", fallback: 0.008, upper: 2, suffix: "s")
            instrumentParameter(WorkbenchText.t("衰减", "Decay"), key: "decay", fallback: 0.15, upper: 2, suffix: "s")
            instrumentParameter(WorkbenchText.t("延音", "Sustain"), key: "sustain", fallback: 1, upper: 1)
            instrumentParameter(WorkbenchText.t("释音", "Release"), key: "release", fallback: 0.08, upper: 4, suffix: "s")
            instrumentParameter(WorkbenchText.t("乐器电平", "Instrument level"), key: "gain", fallback: 0.2, upper: 1)
        } else {
            Text(WorkbenchText.t("选择一个合成音色后可调整声音。", "Choose a synthesized preset to adjust its sound."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func instrumentParameter(_ title: String, key: String, fallback: Double, upper: Double, suffix: String = "") -> some View {
        let value = session.instrumentParameter(key, fallback: fallback)
        return MusicValueSlider(title: title, value: value, range: 0...max(upper, value), suffix: suffix) {
            value in Task { await session.updateInstrument(parameter: key, value: value) }
        }.disabled(!session.canEditMIDI)
    }
    @ViewBuilder private func effectView(_ effect: MusicPluginState, index: Int, track: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Button { replace(index, track: track) { $0.enabled.toggle() } } label: { Image(systemName: "power").foregroundStyle(effect.enabled ? Color.accentColor : .secondary).frame(width: 44, height: 44) }
                    .accessibilityLabel(WorkbenchText.t("旁路效果", "Bypass effect"))
                Text(effect.pluginID == MusicNativeBuiltins.eq ? WorkbenchText.t("均衡器", "Equalizer") : effect.pluginID == MusicNativeBuiltins.reverb ? WorkbenchText.t("混响", "Reverb") : effect.pluginID).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Menu {
                    Button(WorkbenchText.t("上移", "Move up")) { var effects = track.effects; if index > 0 { effects.swapAt(index, index - 1); session.edit([.setEffects(track.id, effects)]) } }.disabled(index == 0)
                    Button(WorkbenchText.t("下移", "Move down")) { var effects = track.effects; if index + 1 < effects.count { effects.swapAt(index, index + 1); session.edit([.setEffects(track.id, effects)]) } }.disabled(index + 1 == track.effects.count)
                    Button(WorkbenchText.t("移除", "Remove"), role: .destructive) { var effects = track.effects; effects.remove(at: index); session.edit([.setEffects(track.id, effects)]) }
                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
            }.buttonStyle(.plain)
            if effect.pluginID == MusicNativeBuiltins.eq {
                MusicEQCurve(effect: effect).frame(height: 72)
                parameter(WorkbenchText.t("频率", "Frequency"), key: "frequency", fallback: 1000, range: 20...20_000, suffix: "Hz", index: index, effect: effect, track: track)
                parameter(WorkbenchText.t("增益", "Gain"), key: "gainDB", fallback: 0, range: -24...24, suffix: "dB", index: index, effect: effect, track: track)
                parameter(WorkbenchText.t("带宽", "Bandwidth"), key: "bandwidth", fallback: 1, range: 0.05...5, suffix: "oct", index: index, effect: effect, track: track)
            } else if effect.pluginID == MusicNativeBuiltins.reverb {
                parameter(WorkbenchText.t("混响量", "Wet mix"), key: "mix", fallback: 0.2, range: 0...1, suffix: "", index: index, effect: effect, track: track)
            } else {
                Text(WorkbenchText.t("已保留此效果的原始设置。", "Original settings are preserved for this effect.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func parameter(_ title: String, key: String, fallback: Double, range: ClosedRange<Double>, suffix: String, index: Int, effect: MusicPluginState, track: MusicTrack) -> some View {
        MusicValueSlider(title: title, value: effect.parameters[key] ?? fallback, range: range, suffix: suffix) { value in replace(index, track: track) { $0.parameters[key] = value } }
    }
    private func replace(_ index: Int, track: MusicTrack, change: (inout MusicPluginState) -> Void) {
        var effects = track.effects; change(&effects[index]); session.edit([.setEffects(track.id, effects)])
    }
    @ViewBuilder private var clipControls: some View {
        if let clip = session.currentClip, case .audio(let payload) = clip.body {
            Divider()
            Text(WorkbenchText.t("片段", "Clip")).font(.caption.weight(.medium))
            MusicValueSlider(title: WorkbenchText.t("片段增益", "Clip gain"), value: MusicWorkbenchFormat.decibels(payload.gain), range: -60...12, suffix: "dB") { value in
                var next = clip; var audio = payload; audio.gain = MusicWorkbenchFormat.gain(value); next.body = .audio(audio); session.edit([.updateClip(next)])
            }
            MusicValueSlider(title: WorkbenchText.t("淡入", "Fade in"), value: Double(payload.fadeInSamples) / Double(session.document.tempoMap.sampleRate), range: 0...max(0.01, Double(payload.durationSamples - payload.fadeOutSamples) / Double(session.document.tempoMap.sampleRate)), suffix: "s") { value in
                var next = clip; var audio = payload; audio.fadeInSamples = Int64(value * Double(session.document.tempoMap.sampleRate)); next.body = .audio(audio); session.edit([.updateClip(next)])
            }
            MusicValueSlider(title: WorkbenchText.t("淡出", "Fade out"), value: Double(payload.fadeOutSamples) / Double(session.document.tempoMap.sampleRate), range: 0...max(0.01, Double(payload.durationSamples - payload.fadeInSamples) / Double(session.document.tempoMap.sampleRate)), suffix: "s") { value in
                var next = clip; var audio = payload; audio.fadeOutSamples = Int64(value * Double(session.document.tempoMap.sampleRate)); next.body = .audio(audio); session.edit([.updateClip(next)])
            }
        }
    }
    private func routing(_ track: MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(WorkbenchText.t("发送与输出", "Sends and output")).font(.caption.weight(.medium))
            ForEach(session.document.buses) { bus in
                MusicValueSlider(title: bus.name, value: track.sends.first(where: { $0.busID == bus.id })?.gain ?? 0, range: 0...2) { gain in
                    var sends = track.sends.filter { $0.busID != bus.id }
                    if gain > 0, let send = try? MusicTrackSend(busID: bus.id, gain: gain) { sends.append(send) }
                    session.edit([.setTrackRouting(track.id, output: track.outputBusID, sends: sends)])
                }
            }
            Menu {
                Button(WorkbenchText.t("主输出", "Master")) { session.edit([.setTrackRouting(track.id, output: MusicBus.masterBusID, sends: track.sends)]) }
                ForEach(session.document.buses) { bus in Button(bus.name) { session.edit([.setTrackRouting(track.id, output: bus.id, sends: track.sends)]) } }
            } label: { Label(WorkbenchText.t("输出", "Output") + " · " + (session.document.buses.first { $0.id == track.outputBusID }?.name ?? WorkbenchText.t("主输出", "Master")), systemImage: "arrow.right").font(.caption).frame(minHeight: 44) }
        }
    }
    private func addAutomation(_ track: MusicTrack) {
        do {
            let sample = Int64(session.playbackPosition * Double(session.document.tempoMap.sampleRate))
            var lane = try session.document.automationLanes.first(where: { $0.ownerID == track.id.rawValue && $0.target == .trackGain })
                ?? MusicAutomationLane(ownerID: track.id.rawValue, target: .trackGain)
            lane.points.removeAll { $0.sample.value == sample }
            lane.points.append(try .init(sample: .init(sample), value: min(1, track.strip.gain)))
            lane.points.sort { $0.sample.value < $1.sample.value }
            session.edit([.upsertAutomationLane(lane)])
        } catch { session.diagnostic = error.localizedDescription }
    }
}

private struct MusicEQCurve: View {
    let effect: MusicPluginState
    var body: some View {
        SwiftUI.Canvas { context, size in
            var center = Path(); center.move(to: CGPoint(x: 0, y: size.height / 2)); center.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(center, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            let frequency = effect.parameters["frequency"] ?? 1000
            let gain = effect.enabled ? effect.parameters["gainDB"] ?? 0 : 0
            let bandwidth = effect.parameters["bandwidth"] ?? 1
            var curve = Path()
            for index in 0...128 {
                let unit = Double(index) / 128
                let hz = 20 * pow(1000, unit)
                let response = gain * exp(-pow(log2(hz / frequency) / max(0.05, bandwidth), 2))
                let point = CGPoint(x: unit * size.width, y: size.height / 2 - response / 48 * size.height)
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }.background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(WorkbenchText.t("均衡器参数曲线", "Equalizer parameter curve"))
    }
}
#endif

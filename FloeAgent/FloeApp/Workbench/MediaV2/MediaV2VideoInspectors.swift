// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2ClipTimingInspector: View {
    @Bindable var session: MediaV2Session
    let track: MediaPreparedTrack
    let clip: MediaPreparedClip
    @State private var start: Double
    @State private var sourceStart: Double
    @State private var sourceDuration: Double
    @State private var speed: Double
    @State private var boundary: Double
    init(session: MediaV2Session, track: MediaPreparedTrack, clip: MediaPreparedClip) {
        self.session = session; self.track = track; self.clip = clip
        _start = State(initialValue: clip.timelineRange.startSeconds)
        _sourceStart = State(initialValue: clip.sourceRange.startSeconds)
        _sourceDuration = State(initialValue: clip.sourceRange.durationSeconds)
        _speed = State(initialValue: clip.speed); _boundary = State(initialValue: clip.timelineRange.startSeconds)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("片段与时间", "Clip and timing")).font(.caption.weight(.semibold))
            MediaV2NumberField(title: WorkbenchText.t("时间线开始", "Timeline start"), value: $start, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("源入点", "Source in"), value: $sourceStart, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("源长度", "Source length"), value: $sourceDuration, suffix: "s")
            Toggle(WorkbenchText.t("本轨波纹修剪", "Ripple this track"), isOn: $session.rippleCurrentTrack).frame(minHeight: 44)
            Button(WorkbenchText.t("应用片段范围", "Apply clip range")) {
                do { session.submit(try session.trimActions(track: track, clip: clip, sourceStart: sourceStart,
                    sourceDuration: sourceDuration, timelineStart: start, ripple: session.rippleCurrentTrack)) }
                catch { session.diagnostic = error.localizedDescription }
            }.frame(minHeight: 44)
            if track.kind == .visual || track.kind == .audio {
                MediaV2NumberField(title: WorkbenchText.t("速度", "Speed"), value: $speed, suffix: "×")
                Button(WorkbenchText.t("应用速度", "Apply speed")) { run("video.speed", value: speed) }.frame(minHeight: 44)
                Text(WorkbenchText.t("原声音调随速度改变。独立音轨可单独调整速度。", "Source-audio pitch follows speed. Independent audio clips can be retimed separately.")).font(.caption2).foregroundStyle(.secondary)
            }
            if session.tool == "video.roll" {
                MediaV2NumberField(title: WorkbenchText.t("相邻剪切点", "Adjacent cut"), value: $boundary, suffix: "s")
                Button(WorkbenchText.t("滚动剪切点", "Roll cut")) {
                    var input = MediaV2ToolInput(); input.start = boundary; run("video.roll", supplied: input)
                }.frame(minHeight: 44)
            }
            HStack {
                Button(WorkbenchText.t("分割", "Split")) { run("video.split") }
                Spacer()
                Button(WorkbenchText.t("复制", "Duplicate")) {
                    var copy = clip; copy.id = UUID(); copy.revision = 0
                    if let range = try? MediaV2Session.range(start: clip.timelineRange.endSeconds, duration: clip.timelineRange.durationSeconds) {
                        copy.timelineRange = range; session.submit([.insertClip(trackID: track.id, clip: copy, index: nil)])
                    }
                }
            }.frame(minHeight: 44)
            Button(WorkbenchText.t("删除片段", "Delete clip"), role: .destructive) {
                session.submit([.removeClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision)])
            }.frame(minHeight: 44)
        }.disabled(track.isLocked || session.saving)
            .onChange(of: clip.revision) { _, _ in
                start = clip.timelineRange.startSeconds; sourceStart = clip.sourceRange.startSeconds
                sourceDuration = clip.sourceRange.durationSeconds; speed = clip.speed
            }
    }
    private func run(_ id: String, value: Double? = nil, supplied: MediaV2ToolInput = .init()) {
        var input = supplied; input.objectID = clip.id; input.number = value; input.expectedRevision = session.document.revision
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

struct MediaV2KeyframeInspector: View {
    @Bindable var session: MediaV2Session
    let clip: MediaPreparedClip
    @State private var property = "scale"
    @State private var localTime = 0.0
    @State private var value = 1.0
    @State private var interpolation = MediaKeyframeInterpolation.linear
    @State private var bezier = MediaCubicBezier()
    private var track: MediaKeyframeTrack? { clip.keyframeTracks.first { $0.property == property || $0.property == "transform." + property } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("关键帧", "Keyframes")).font(.headline)
            Picker(WorkbenchText.t("属性", "Property"), selection: $property) {
                Text(WorkbenchText.t("缩放", "Scale")).tag("scale")
                Text("X").tag("centerX"); Text("Y").tag("centerY")
                Text(WorkbenchText.t("旋转", "Rotation")).tag("rotationDegrees")
                Text(WorkbenchText.t("不透明度", "Opacity")).tag("opacity")
            }
            curve.frame(height: 90).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            MediaV2NumberField(title: WorkbenchText.t("片段内时间", "Local time"), value: $localTime, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("数值", "Value"), value: $value)
            Picker(WorkbenchText.t("插值", "Interpolation"), selection: $interpolation) {
                Text(WorkbenchText.t("线性", "Linear")).tag(MediaKeyframeInterpolation.linear)
                Text(WorkbenchText.t("保持", "Hold")).tag(MediaKeyframeInterpolation.hold)
                Text(WorkbenchText.t("缓入", "Ease in")).tag(MediaKeyframeInterpolation.easeIn)
                Text(WorkbenchText.t("缓出", "Ease out")).tag(MediaKeyframeInterpolation.easeOut)
                Text(WorkbenchText.t("平滑", "Smooth")).tag(MediaKeyframeInterpolation.cubicBezier)
            }
            if interpolation == .cubicBezier {
                MediaV2BezierCurveEditor(curve:$bezier)
                Text(WorkbenchText.t("控制点调整当前关键帧到下一帧的时间变化。", "Handles shape the timing from this keyframe to the next."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(WorkbenchText.t("使用播放头时间", "Use playhead time")) {
                localTime = max(0, min(clip.timelineRange.durationSeconds, session.playhead - clip.timelineRange.startSeconds))
                value = session.keyframeValue(for: property, in: clip)
            }.frame(minHeight: 44)
            Button(WorkbenchText.t("添加/更新关键帧", "Add/update keyframe")) { apply() }.frame(minHeight: 44)
            ForEach(Array((track?.keyframes ?? []).enumerated()), id: \.offset) { _, key in
                HStack {
                    Button {
                        localTime = key.time.seconds; if case .number(let number) = key.value { value = number }
                        interpolation = key.interpolation; bezier = key.curve ?? .init(); session.scrub(clip.timelineRange.startSeconds + key.time.seconds)
                    } label: {
                        HStack { Image(systemName: "diamond.fill"); Text(String(format: "%.3f s", key.time.seconds)).monospacedDigit(); Spacer(); if case .number(let number) = key.value { Text(String(format: "%.3f", number)).monospacedDigit() } }.font(.caption).frame(minHeight: 44)
                    }
                    Button(role: .destructive) { session.removeKeyframe(property: track?.property ?? property, time: key.time) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                }
            }
        }.disabled(session.saving || session.selectedClip?.track.isLocked == true)
            .onAppear {
                value = session.keyframeValue(for: property, in: clip)
                localTime = max(0, min(clip.timelineRange.durationSeconds, session.playhead - clip.timelineRange.startSeconds))
                if session.tool == "video.graph" { interpolation = .cubicBezier }
            }
            .onChange(of: property) { _, _ in value = session.keyframeValue(for: property, in: clip) }
    }
    private var curve: some View {
        SwiftUI.Canvas { context, size in
            guard let track, !track.keyframes.isEmpty else { return }
            let samples = (0...48).compactMap { index -> Double? in
                let time = clip.timelineRange.durationSeconds * Double(index) / 48
                return session.evaluatedKeyframe(track, at: time)
            }
            guard samples.count == 49, let low = samples.min(), let high = samples.max() else { return }
            let span = max(0.0001, high - low)
            let path = Path { path in
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: 8 + (size.width - 16) * Double(index) / 48,
                                        y: size.height - 8 - (size.height - 16) * (sample - low) / span)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }.accessibilityLabel(WorkbenchText.t("当前关键帧插值曲线", "Current keyframe interpolation curve"))
    }
    private func apply() {
        guard localTime.isFinite, localTime >= 0, localTime <= clip.timelineRange.durationSeconds,
              value.isFinite, property != "opacity" || (0...1).contains(value), property != "scale" || value > 0 else { session.diagnostic = MediaV2CommandError.invalidInput.localizedDescription; return }
        var input = MediaV2ToolInput(); input.objectID = clip.id; input.expectedRevision = session.document.revision
        input.start = localTime; input.number = value; input.property = property; input.text = interpolation.rawValue
        if interpolation == .cubicBezier { input.points = [bezier.control1,bezier.control2] }
        let toolID = session.tool == "video.graph" ? "video.graph" : "video.keyframes"
        Task { do { _ = try await session.performTool(toolID, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

struct MediaV2VideoMaskInspector: View {
    @Bindable var session: MediaV2Session
    let clip: MediaPreparedClip
    @State private var kind = ImageSelectionKind.ellipse
    @State private var x = 10.0
    @State private var y = 10.0
    @State private var width = 80.0
    @State private var height = 80.0
    @State private var feather = 0.0
    @State private var inverted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("视频蒙版", "Video mask")).font(.headline)
            Picker(WorkbenchText.t("形状", "Shape"), selection: $kind) { Text(WorkbenchText.t("矩形", "Rectangle")).tag(ImageSelectionKind.rectangle); Text(WorkbenchText.t("椭圆", "Ellipse")).tag(ImageSelectionKind.ellipse) }.pickerStyle(.segmented)
            MediaV2NumberField(title: "X", value: $x, suffix: "%"); MediaV2NumberField(title: "Y", value: $y, suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("宽", "Width"), value: $width, suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("高", "Height"), value: $height, suffix: "%")
            MediaV2NumberField(title: WorkbenchText.t("羽化", "Feather"), value: $feather, suffix: "px")
            Toggle(WorkbenchText.t("反转蒙版", "Invert mask"), isOn: $inverted).frame(minHeight: 44)
            Button(WorkbenchText.t("应用蒙版", "Apply mask")) { apply(remove: false) }.frame(minHeight: 44)
            Button(WorkbenchText.t("移除蒙版", "Remove mask")) { apply(remove: true) }.frame(minHeight: 44).disabled(clip.videoMask == nil)
        }.disabled(session.saving || session.selectedClip?.track.isLocked == true)
            .onAppear {
                guard let mask = clip.videoMask, let shape = mask.shapes.first, shape.points.count == 2 else { return }
                kind = shape.kind; let a = shape.points[0], b = shape.points[1]
                x = min(a.x, b.x) * 100; y = min(a.y, b.y) * 100; width = abs(b.x - a.x) * 100; height = abs(b.y - a.y) * 100
                inverted = mask.inverted; feather = mask.feather * Double(min(session.document.canvas!.width, session.document.canvas!.height))
            }
    }
    private func apply(remove: Bool) {
        guard let selected = session.selectedClip, selected.clip.id == clip.id, let canvas = session.document.canvas else { return }
        var next = clip
        next.videoMask = remove ? nil : .init(shapes: [.init(kind: kind, points: [.init(x: x / 100, y: y / 100), .init(x: (x + width) / 100, y: (y + height) / 100)])],
            feather: feather / Double(min(canvas.width, canvas.height)), inverted: inverted)
        session.submit([.replaceClip(trackID: selected.track.id, clipID: clip.id, expectedRevision: clip.revision, clip: next)])
    }
}

struct MediaV2CaptionInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    @State private var text = ""
    @State private var start = 0.0
    @State private var duration = 3.0
    @State private var shift = 0.0
    @State private var exported: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("字幕", "Captions")).font(.headline)
            TextField(WorkbenchText.t("字幕文字", "Caption text"), text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
            MediaV2NumberField(title: WorkbenchText.t("开始", "Start"), value: $start, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("长度", "Duration"), value: $duration, suffix: "s")
            Button(WorkbenchText.t("应用字幕", "Apply caption")) { apply() }.frame(minHeight: 44)
            Button(WorkbenchText.t("新建下一条", "New caption")) { session.selectedClipID = nil; text = ""; start = session.playhead; duration = 3 }.frame(minHeight: 44)
            Divider()
            MediaV2NumberField(title: WorkbenchText.t("全部字幕偏移", "Shift all captions"), value: $shift, suffix: "s")
            Button(WorkbenchText.t("应用时间偏移", "Apply time shift")) { do { try session.shiftCaptions(by: shift) } catch { session.diagnostic = error.localizedDescription } }.frame(minHeight: 44)
            Button(WorkbenchText.t("导入纯文本 SRT/VTT", "Import plain-text SRT/VTT"), action: onImport).frame(minHeight: 44)
            HStack {
                Button(WorkbenchText.t("导出 SRT", "Export SRT")) { export(.srt) }
                Spacer(); Button(WorkbenchText.t("导出 VTT", "Export VTT")) { export(.vtt) }
            }.frame(minHeight: 44)
            if let exported { ShareLink(item: exported) { Label(WorkbenchText.t("分享字幕文件", "Share captions"), systemImage: "square.and.arrow.up").frame(minHeight: 44) } }
        }.disabled(session.saving)
            .onAppear { sync() }
            .onChange(of: session.selectedClipID) { _, _ in sync() }
    }
    private func sync() {
        if let selected = session.selectedClip, selected.track.kind == .caption {
            text = selected.clip.captionText ?? ""; start = selected.clip.timelineRange.startSeconds; duration = selected.clip.timelineRange.durationSeconds
        } else { text = ""; start = session.playhead; duration = 3 }
    }
    private func apply() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var input = MediaV2ToolInput(); input.expectedRevision = session.document.revision; input.text = text; input.start = start; input.duration = duration
        Task { do { _ = try await session.performTool("video.caption", input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func export(_ format: MediaV2SubtitleCodec.Format) {
        do { exported = try session.exportCaptions(format) } catch { session.diagnostic = error.localizedDescription }
    }
}

struct MediaV2AudioInspector: View {
    @Bindable var session: MediaV2Session
    private var audioTracks: [MediaPreparedTrack] { session.document.trackGraph.tracks.filter { $0.kind == .audio } }
    private var active: MediaPreparedTrack? { audioTracks.first { $0.id == session.selectedTrackID } ?? audioTracks.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("音频", "Audio")).font(.headline)
            if let track = active {
                Picker(WorkbenchText.t("音轨", "Track"), selection: Binding(get: { track.id }, set: { id in if let track = audioTracks.first(where: { $0.id == id }) { session.select(track) } })) {
                    ForEach(audioTracks) { Text($0.name).tag($0.id) }
                }
                MediaV2AudioTrackControls(session: session, track: track).id(track.id)
                if let selected = session.selectedClip, selected.track.kind == .audio {
                    Divider(); MediaV2AudioClipControls(session: session, track: selected.track, clip: selected.clip).id(selected.clip.id)
                } else { Text(WorkbenchText.t("在时间线上选择音频片段可调整淡入淡出与偏移。", "Select an audio clip in the timeline to adjust fades and timing.")).font(.caption).foregroundStyle(.secondary) }
            } else { Text(WorkbenchText.t("导入音频后可混音。", "Import audio to start mixing.")).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
private struct MediaV2AudioTrackControls: View {
    @Bindable var session: MediaV2Session
    let track: MediaPreparedTrack
    @State private var volume: Double
    @State private var muted: Bool
    @State private var name: String
    init(session: MediaV2Session, track: MediaPreparedTrack) {
        self.session = session; self.track = track
        _volume = State(initialValue: track.volume); _muted = State(initialValue: track.isMuted); _name = State(initialValue: track.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(WorkbenchText.t("音轨名称", "Track name"), text: $name).textFieldStyle(.roundedBorder)
            MediaV2NumberField(title: WorkbenchText.t("音轨增益", "Track gain"), value: $volume, suffix: "×")
            Toggle(WorkbenchText.t("静音音轨", "Mute track"), isOn: $muted).frame(minHeight: 44)
            Button(WorkbenchText.t("应用音轨", "Apply track")) {
                session.submit([.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: name, isMuted: muted, isLocked: nil, volume: volume)])
            }.frame(minHeight: 44)
        }.disabled(track.isLocked || session.saving)
            .onChange(of: track.revision) { _, _ in volume = track.volume; muted = track.isMuted; name = track.name }
    }
}
private struct MediaV2AudioClipControls: View {
    @Bindable var session: MediaV2Session
    let track: MediaPreparedTrack
    let clip: MediaPreparedClip
    @State private var volume: Double
    @State private var fadeIn: Double
    @State private var fadeOut: Double
    @State private var start: Double
    @State private var muted: Bool
    init(session: MediaV2Session, track: MediaPreparedTrack, clip: MediaPreparedClip) {
        self.session = session; self.track = track; self.clip = clip
        _volume = State(initialValue: clip.volume); _fadeIn = State(initialValue: clip.fadeIn?.seconds ?? 0)
        _fadeOut = State(initialValue: clip.fadeOut?.seconds ?? 0); _start = State(initialValue: clip.timelineRange.startSeconds); _muted = State(initialValue: clip.isMuted)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("音频片段", "Audio clip")).font(.caption.weight(.semibold))
            MediaV2NumberField(title: WorkbenchText.t("片段增益", "Clip gain"), value: $volume, suffix: "×")
            MediaV2NumberField(title: WorkbenchText.t("开始/同步位置", "Start/sync position"), value: $start, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("淡入", "Fade in"), value: $fadeIn, suffix: "s")
            MediaV2NumberField(title: WorkbenchText.t("淡出", "Fade out"), value: $fadeOut, suffix: "s")
            Toggle(WorkbenchText.t("静音片段", "Mute clip"), isOn: $muted).frame(minHeight: 44)
            Button(WorkbenchText.t("应用音频片段", "Apply audio clip")) {
                do {
                    guard [volume, fadeIn, fadeOut, start].allSatisfy(\.isFinite), volume >= 0, fadeIn >= 0, fadeOut >= 0,
                          fadeIn <= clip.timelineRange.durationSeconds, fadeOut <= clip.timelineRange.durationSeconds else { throw MediaV2CommandError.invalidInput }
                    var next = clip; next.volume = volume; next.isMuted = muted
                    next.fadeIn = try MediaV2Session.time(fadeIn); next.fadeOut = try MediaV2Session.time(fadeOut)
                    next.timelineRange = try MediaV2Session.range(start: start, duration: clip.timelineRange.durationSeconds)
                    session.submit([.replaceClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision, clip: next)])
                } catch { session.diagnostic = error.localizedDescription }
            }.frame(minHeight: 44)
        }.disabled(track.isLocked || session.saving)
            .onChange(of: clip.revision) { _, _ in
                volume = clip.volume; muted = clip.isMuted; start = clip.timelineRange.startSeconds
                fadeIn = clip.fadeIn?.seconds ?? 0; fadeOut = clip.fadeOut?.seconds ?? 0
            }
    }
}
#endif

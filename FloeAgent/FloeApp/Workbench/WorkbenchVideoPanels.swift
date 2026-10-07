// FloeApp — Video workbench: live preview surface, thumbnail timeline with
// playhead/zoom, clip inspector, music track, caption (subtitle) track with
// the existing local transcription service, and export entry.

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Player

/// Session-owned player: the center keeps ONE player model for the whole
/// editing session, so fullscreen, rotation, drawer presentation and panel
/// collapse never replace the AVPlayer, lose the playhead or restart playback.
@MainActor
final class WorkbenchPlayerModel: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    /// Last playback failure reported by the current item, if any.
    @Published private(set) var itemError: String?
    /// Mirrors the playhead into the shared session state (timeline etc.).
    var onTimeChange: ((Double) -> Void)?
    /// Recovery hooks used by the center when an item fails to prepare.
    var onItemFailed: ((String) -> Void)?
    var onItemReady: (() -> Void)?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    init() {
        configurePlayer(player)
    }

    private func configurePlayer(_ player: AVPlayer) {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds.isFinite ? time.seconds : 0
                self.currentTime = seconds
                self.isPlaying = self.player.rate > 0
                self.onTimeChange?(seconds)
            }
        }
    }

    // The periodic observer is owned by the player: when this model and its
    // player are released, AVFoundation tears the observer down with it.

    var hasItem: Bool { player.currentItem != nil }

    func setItem(_ item: AVPlayerItem?) {
        guard player.currentItem !== item else { return }
        statusObservation = nil
        itemError = nil
        player.replaceCurrentItem(with: item)
        guard let item else { return }
        // A failed preparation is otherwise silent: the surface stays black
        // and the play button does nothing. Report it so the center can
        // rebuild the preview (and, in the simulator, the player).
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .failed:
                    let message = item.error?.localizedDescription
                        ?? WorkbenchText.t("播放失败", "Playback failed")
                    self.itemError = message
                    self.onItemFailed?(message)
                case .readyToPlay:
                    self.itemError = nil
                    self.onItemReady?()
                default:
                    break
                }
            }
        }
    }

    /// Recreates the underlying AVPlayer. A player whose first item failed
    /// during app/simulator startup can stay poisoned and fail every later
    /// item; fresh instances prepare the same composition normally.
    func recreatePlayer() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObservation = nil
        player.pause()
        let replacement = AVPlayer()
        configurePlayer(replacement)
        player = replacement
    }

    func seek(_ seconds: Double) {
        let clamped = max(0, seconds)
        if abs(currentTime - clamped) > 0.01 {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }
}

struct WorkbenchVideoSurface: View {
    @ObservedObject var center: WorkbenchCenter

    private var model: WorkbenchPlayerModel { center.playerModel }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                WorkbenchPlayerLayerView(player: model.player)
                if center.isRenderingPreview {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(WorkbenchText.t("正在渲染预览…", "Rendering preview…"))
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    .padding(12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("workbench.preview.render")
                }
                if let message = center.previewError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                        Button(WorkbenchText.t("重试", "Retry")) { center.refreshPreview() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.preview.retry")
                    }
                    .padding()
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }
                if center.showsCaptionSafeArea {
                    SafeAreaGuide(positionY: center.project?.videoTimeline?.captionStyle.positionY ?? 0.88,
                                  alignment: center.project?.videoTimeline?.captionStyle.alignment ?? .center)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 10) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("workbench.video.play")
                Button {
                    step(frames: -1)
                } label: {
                    Image(systemName: "backward.frame")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("workbench.video.frameBack")
                Button {
                    step(frames: 1)
                } label: {
                    Image(systemName: "forward.frame")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("workbench.video.frameForward")
                Text(MediaTimelineMath.timecode(seconds: model.currentTime, frameRate: frameRate))
                    .font(.caption.monospacedDigit())
                    .frame(width: 96, alignment: .leading)
                    .accessibilityIdentifier("workbench.video.timecode")
                Slider(value: Binding(
                    get: { model.currentTime },
                    set: { value in
                        let snapped = center.videoSnapEnabled
                            ? MediaTimelineMath.snap(seconds: value,
                                                     to: MediaTimelineMath.snapCandidates(center.project?.videoTimeline ?? VideoTimeline()),
                                                     tolerance: 0.08)
                            : value
                        center.playheadSeconds = snapped
                        model.seek(snapped)
                    }), in: 0...max(primaryDuration, 0.1))
                    .accessibilityIdentifier("workbench.video.scrub")
                Text(MediaTimelineMath.timecode(seconds: primaryDuration, frameRate: frameRate))
                    .font(.caption.monospacedDigit())
                    .frame(width: 96, alignment: .trailing)
                Toggle(isOn: $center.videoSnapEnabled) {
                    Image(systemName: "magnet")
                }
                .toggleStyle(.button)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("workbench.video.snap")
                Button {
                    center.apply(.setCover(time: center.playheadSeconds))
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("workbench.video.setCover")
                .help(WorkbenchText.t("将播放头位置设为封面", "Set the playhead as the cover frame"))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(.ultraThinMaterial)
        }
        .onChange(of: center.playerItem) { _, item in
            model.setItem(item)
            model.seek(center.playheadSeconds)
        }
        .onAppear {
            model.setItem(center.playerItem)
            if !model.hasItem {
                model.seek(center.playheadSeconds)
            }
        }
        .accessibilityIdentifier("workbench.preview.video")
    }

    private var primaryDuration: Double {
        // The preview item's duration already reflects trims/speed/dissolves.
        if let duration = center.playerItem?.duration.seconds, duration.isFinite, duration > 0 {
            return duration
        }
        return center.project?.videoTimeline?.primaryDuration ?? 0
    }

    private var frameRate: Double {
        center.project?.canvas?.frameRate ?? 30
    }

    private func step(frames: Int) {
        let next = MediaTimelineMath.frameStep(seconds: model.currentTime,
                                               deltaFrames: frames,
                                               frameRate: frameRate,
                                               duration: primaryDuration)
        center.playheadSeconds = next
        model.seek(next)
    }
}

struct WorkbenchPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> WorkbenchPlayerContainerView {
        let view = WorkbenchPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: WorkbenchPlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class WorkbenchPlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Title-safe guide + caption baseline for the current style position, shown
/// only when the user asks for it.
struct SafeAreaGuide: View {
    var positionY: Double
    var alignment: CaptionAlignment

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let lineY = height * CGFloat(min(max(positionY, 0), 1))
            let barWidth = width * 0.3
            let barX: CGFloat = switch alignment {
            case .leading: width * 0.05
            case .center: (width - barWidth) / 2
            case .trailing: width * 0.95 - barWidth
            }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .padding(.horizontal, width * 0.05)
                    .padding(.vertical, height * 0.05)
                Rectangle()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: width, height: 1)
                    .offset(y: lineY)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.yellow.opacity(0.6))
                    .frame(width: barWidth, height: 14)
                    .offset(x: barX, y: lineY - 7)
            }
        }
        .accessibilityIdentifier("workbench.caption.safeAreaOverlay")
        .accessibilityHidden(true)
    }
}

// MARK: - Timeline

/// Symmetric audio waveform rendered from `MediaWaveformSampler` peaks.
private struct WaveformShape: Shape {
    let peaks: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let midY = rect.midY
        let half = rect.height / 2
        let step = rect.width / CGFloat(peaks.count)
        for (index, peak) in peaks.enumerated() {
            let clamped = min(max(peak, 0.02), 1)
            let x = CGFloat(index) * step
            let barWidth = max(step * 0.7, 0.5)
            path.addRect(CGRect(x: x, y: midY - half * CGFloat(clamped),
                                width: barWidth, height: rect.height * CGFloat(clamped)))
        }
        return path
    }
}

struct WorkbenchVideoTimeline: View {
    @ObservedObject var center: WorkbenchCenter
    var compact = false

    private var placed: [PlacedClip] {
        MediaTimelineMath.placeClips(center.project?.videoTimeline?.clips ?? [])
    }

    private var totalDuration: Double {
        placed.last?.timelineEnd ?? 0
    }

    var body: some View {
        VStack(spacing: 4) {
            controls
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        timelineContent
                        playhead(height: geometry.size.height)
                    }
                    .frame(width: max(geometry.size.width, CGFloat(totalDuration) * center.pixelsPerSecond + 40),
                           height: geometry.size.height,
                           alignment: .topLeading)
                }
                .accessibilityIdentifier("workbench.timeline")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                center.apply(.splitClip(id: center.selectedClipID ?? UUID(),
                                        atTimelineSeconds: splitOffset()))
            } label: {
                Label(WorkbenchText.t("分割", "Split"), systemImage: "scissors")
            }
            .disabled(center.selectedClipID == nil)
            .frame(minHeight: 44)
            .accessibilityIdentifier("workbench.timeline.split")
            if let selected = center.selectedClipID {
                Button {
                    center.apply(.duplicateClip(id: selected))
                } label: {
                    Label(WorkbenchText.t("复制", "Duplicate"), systemImage: "plus.square.on.square")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.timeline.duplicate")
                Button(role: .destructive) {
                    center.apply(.removeClip(id: selected))
                    center.selectedClipID = nil
                } label: {
                    Label(WorkbenchText.t("删除", "Delete"), systemImage: "trash")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.timeline.delete")
            }
            Spacer()
            Image(systemName: "minus.magnifyingglass")
            Slider(value: $center.pixelsPerSecond, in: 20...240)
                .frame(width: compact ? 90 : 160)
                .accessibilityIdentifier("workbench.timeline.zoom")
            Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(.bordered)
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            ruler
            clipStrip
            if !compact {
                musicStrip
                captionStrip
            }
        }
        .padding(.top, 2)
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...max(1, Int(totalDuration)), id: \.self) { second in
                Text("\(second)s")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(Double(second) * center.pixelsPerSecond))
            }
        }
        .frame(height: 12, alignment: .topLeading)
    }

    private var clipStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(placed, id: \.clip.id) { item in
                clipView(item)
            }
        }
    }

    private func clipView(_ item: PlacedClip) -> some View {
        let width = max(56, CGFloat(item.duration) * center.pixelsPerSecond)
        let selected = center.selectedClipID == item.clip.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                if item.clip.leadingTransition == .crossDissolve {
                    Image(systemName: "square.on.square.intersection.dashed")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Text(String(format: "%.1fs", item.duration))
                    .font(.system(size: 9))
                if item.clip.isMuted {
                    Image(systemName: "speaker.slash").font(.system(size: 9))
                }
                if item.clip.speed != 1 {
                    Text("\(String(format: "%.2g", item.clip.speed))×")
                        .font(.system(size: 9)).foregroundStyle(.blue)
                }
            }
            ZStack(alignment: .leading) {
                if let thumbs = center.thumbnails[item.clip.id], !thumbs.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(thumbs, id: \.timeSeconds) { thumb in
                            if let image = UIImage(data: thumb.pngData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: width / CGFloat(thumbs.count), height: compact ? 40 : 54)
                                    .clipped()
                            }
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.25))
                        .frame(height: compact ? 40 : 54)
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
        }
        .padding(2)
        .frame(width: width, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { center.selectedClipID = item.clip.id }
        .overlay(alignment: .leading) {
            if selected {
                trimHandle(item: item, edge: .leading, width: width)
            }
        }
        .overlay(alignment: .trailing) {
            if selected {
                trimHandle(item: item, edge: .trailing, width: width)
            }
        }
        .contextMenu {
            Button(WorkbenchText.t("在播放头分割", "Split at playhead")) {
                center.selectedClipID = item.clip.id
                center.apply(.splitClip(id: item.clip.id, atTimelineSeconds: splitOffset()))
            }
            Button(WorkbenchText.t("复制片段", "Duplicate clip")) {
                center.apply(.duplicateClip(id: item.clip.id))
            }
            Button(WorkbenchText.t("在播放头设为封面", "Set cover at playhead")) {
                center.apply(.setCover(time: center.playheadSeconds))
            }
            Button(WorkbenchText.t("删除片段", "Delete clip"), role: .destructive) {
                center.apply(.removeClip(id: item.clip.id))
            }
        }
        .accessibilityIdentifier("workbench.clip.\(item.clip.id.uuidString)")
        .draggable(item.clip.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let sourceID = UUID(uuidString: raw),
                  sourceID != item.clip.id,
                  var current = center.project,
                  let from = current.videoTimeline?.clips.firstIndex(where: { $0.id == sourceID }),
                  let to = current.videoTimeline?.clips.firstIndex(where: { $0.id == item.clip.id }) else { return false }
            var clips = current.videoTimeline?.clips ?? []
            let moved = clips.remove(at: from)
            clips.insert(moved, at: to)
            current.videoTimeline?.clips = clips
            center.apply(.reorderClips(orderedIDs: clips.map(\.id)))
            return true
        }
    }

    private enum TrimEdge { case leading, trailing }

    /// Precise edge trim: a 44pt-wide invisible handle at each clip edge.
    /// Dragging maps screen deltas to source-time deltas through the shared
    /// pixels-per-second scale, quantizes to whole frames (canvas frame rate)
    /// and commits ONE validated updateClip command at drag end, so undo
    /// history records one trim, not a stream of micro-edits.
    @ViewBuilder
    private func trimHandle(item: PlacedClip, edge: TrimEdge, width: CGFloat) -> some View {
        let assetDuration = center.project?.assets
            .first(where: { $0.id == item.clip.assetID })?
            .metadata?.durationSeconds
        let frameRate = center.project?.canvas?.frameRate
        let symbol = edge == .leading ? "chevron.compact.left" : "chevron.compact.right"
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.55))
            .frame(width: 14, height: compact ? 40 : 54)
            .overlay(Image(systemName: symbol).font(.system(size: 10, weight: .bold)))
            .frame(width: 44, height: compact ? 44 : 58)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onEnded { value in
                        let deltaSeconds = Double(value.translation.width / center.pixelsPerSecond)
                        let clip = item.clip
                        let minimumDuration = 0.2
                        switch edge {
                        case .leading:
                            let raw = clip.trimStart + deltaSeconds
                            let upper = clip.trimEnd - minimumDuration
                            let clamped = min(max(raw, 0), upper)
                            let quantized = center.quantizedSourceTime(clamped, frameRate: frameRate)
                            let final = min(max(quantized, 0), upper)
                            guard abs(final - clip.trimStart) > 0.001 else { return }
                            center.apply(.updateClip(id: clip.id, trimStart: final, trimEnd: nil,
                                                     speed: nil, volume: nil, isMuted: nil,
                                                     rotationDegrees: nil, crop: .unchanged,
                                                     leadingTransition: nil, transitionDuration: nil))
                        case .trailing:
                            let raw = clip.trimEnd + deltaSeconds
                            let lower = clip.trimStart + minimumDuration
                            let upper = assetDuration.map { $0 + 0.05 } ?? .infinity
                            let clamped = min(max(raw, lower), upper)
                            let quantized = center.quantizedSourceTime(clamped, frameRate: frameRate)
                            let final = min(max(quantized, lower), upper)
                            guard abs(final - clip.trimEnd) > 0.001 else { return }
                            center.apply(.updateClip(id: clip.id, trimStart: nil, trimEnd: final,
                                                     speed: nil, volume: nil, isMuted: nil,
                                                     rotationDegrees: nil, crop: .unchanged,
                                                     leadingTransition: nil, transitionDuration: nil))
                        }
                    }
            )
            .accessibilityIdentifier("workbench.clip.\(edge == .leading ? "trimStart" : "trimEnd").\(item.clip.id.uuidString)")
    }

    private var musicStrip: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.purple.opacity(0.12)).frame(height: 26)
            ForEach(center.project?.videoTimeline?.music ?? []) { music in
                musicClipView(music)
            }
        }
        .frame(height: 26, alignment: .topLeading)
    }

    private func musicClipView(_ music: MusicClip) -> some View {
        let width = max(40, CGFloat(music.lengthSeconds) * center.pixelsPerSecond)
        return ZStack(alignment: .leading) {
            if let peaks = center.waveforms[music.assetID], !peaks.isEmpty {
                WaveformShape(peaks: peaks)
                    .fill(Color.purple.opacity(0.35 + 0.5 * min(max(music.volume, 0), 1.5) / 1.5))
                    .frame(width: width, height: 20)
                    .overlay(alignment: .leading) {
                        // Fade-in/fade-out visualization: the waveform is
                        // masked by a ramp at each edge (shared timeline math).
                        if music.fadeInSeconds > 0 {
                            LinearGradient(colors: [.white, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(width, CGFloat(music.fadeInSeconds) * center.pixelsPerSecond))
                                .blendMode(.destinationOut)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if music.fadeOutSeconds > 0 {
                            LinearGradient(colors: [.clear, .white],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(width, CGFloat(music.fadeOutSeconds) * center.pixelsPerSecond))
                                .blendMode(.destinationOut)
                        }
                    }
                    .drawingGroup()
            } else {
                Text("♪ \(WorkbenchText.t("音乐", "Music"))")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .frame(width: width, height: 26, alignment: .leading)
            }
            if music.fadeInSeconds > 0 || music.fadeOutSeconds > 0 {
                HStack {
                    if music.fadeInSeconds > 0 {
                        Text("fade").font(.system(size: 7)).foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                    Spacer()
                    if music.fadeOutSeconds > 0 {
                        Text("fade").font(.system(size: 7)).foregroundStyle(.secondary)
                            .padding(.trailing, 2)
                    }
                }
                .frame(width: width, height: 26)
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 26, alignment: .leading)
        .background(Color.purple.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        .offset(x: CGFloat(music.offsetSeconds * center.pixelsPerSecond))
        .accessibilityIdentifier("workbench.music.\(music.id.uuidString)")
        .task { center.loadWaveform(for: music.assetID) }
    }

    private var captionStrip: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.teal.opacity(0.10)).frame(height: 20)
            ForEach(center.project?.videoTimeline?.captions ?? []) { caption in
                Text(caption.text)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: max(30, CGFloat(caption.end - caption.start) * center.pixelsPerSecond),
                           height: 20, alignment: .leading)
                    .background(Color.teal.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: CGFloat(caption.start * center.pixelsPerSecond))
            }
        }
        .frame(height: 20, alignment: .topLeading)
    }

    private func playhead(height: CGFloat) -> some View {
        let x = CGFloat(center.playheadSeconds * center.pixelsPerSecond)
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private func splitOffset() -> Double {
        guard let selected = center.selectedClipID,
              let item = placed.first(where: { $0.clip.id == selected }) else { return 0 }
        return max(0.01, min(center.playheadSeconds - item.timelineStart, item.duration - 0.02))
    }
}

// MARK: - Video properties

struct VideoPropertiesView: View {
    @ObservedObject var center: WorkbenchCenter
    @State private var showMusicImporter = false
    @State private var isTranscribing = false
    @State private var transcriptionMessage: String?
    @State private var newCaptionText = ""
    @State private var canvasWidth: Double = 1280
    @State private var canvasHeight: Double = 720
    @State private var canvasFPS: Double = 30

    private var clip: VideoClip? {
        center.project?.videoTimeline?.clips.first { $0.id == center.selectedClipID }
    }

    private var assetDuration: Double {
        guard let clip, let asset = center.project?.asset(clip.assetID) else { return clip?.trimEnd ?? 10 }
        return asset.metadata?.durationSeconds ?? clip.trimEnd
    }

    var body: some View {
        Group {
            if let clip {
                SectionCard(title: WorkbenchText.t("片段", "Clip")) {
                    CommitSlider(label: WorkbenchText.t("起点", "Trim start"),
                                 value: clip.trimStart, range: 0...max(0.1, clip.trimEnd - 0.05),
                                 identifier: "workbench.clip.trimStart") { value in
                        update(clip: clip, trimStart: value, trimEnd: nil)
                    }
                    CommitSlider(label: WorkbenchText.t("终点", "Trim end"),
                                 value: clip.trimEnd, range: min(clip.trimStart + 0.05, assetDuration)...assetDuration,
                                 identifier: "workbench.clip.trimEnd") { value in
                        update(clip: clip, trimStart: nil, trimEnd: value)
                    }
                    CommitSlider(label: WorkbenchText.t("速度", "Speed"),
                                 value: clip.speed, range: 0.25...4,
                                 identifier: "workbench.clip.speed") { value in
                        update(clip: clip, trimStart: nil, trimEnd: nil, speed: value)
                    }
                    CommitSlider(label: WorkbenchText.t("音量", "Volume"),
                                 value: clip.volume, range: 0...2,
                                 identifier: "workbench.clip.volume") { value in
                        update(clip: clip, trimStart: nil, trimEnd: nil, volume: value)
                    }
                    Toggle(WorkbenchText.t("静音", "Mute"), isOn: Binding(
                        get: { clip.isMuted },
                        set: { value in update(clip: clip, trimStart: nil, trimEnd: nil, isMuted: value) }))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.clip.mute")
                    Picker(WorkbenchText.t("旋转", "Rotation"), selection: Binding(
                        get: { Int(clip.rotationDegrees) },
                        set: { value in update(clip: clip, trimStart: nil, trimEnd: nil, rotation: Double(value)) })) {
                        Text("0°").tag(0)
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workbench.clip.rotation")

                    Menu(WorkbenchText.t("裁剪比例", "Crop preset")) {
                        Button("16:9") { setCrop(clip: clip, aspect: 16.0 / 9.0) }
                        Button("9:16") { setCrop(clip: clip, aspect: 9.0 / 16.0) }
                        Button("1:1") { setCrop(clip: clip, aspect: 1) }
                        Button(WorkbenchText.t("原比例", "Original")) {
                            update(clip: clip, trimStart: nil, trimEnd: nil, crop: .clear)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.clip.crop")
                    if let crop = clip.crop {
                        Text(String(format: "crop x %.2f y %.2f w %.2f h %.2f", crop.x, crop.y, crop.width, crop.height))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(WorkbenchText.t("转场", "Transition"), selection: Binding(
                        get: { clip.leadingTransition },
                        set: { value in update(clip: clip, trimStart: nil, trimEnd: nil, transition: value) })) {
                        Text(WorkbenchText.t("硬切", "Hard cut")).tag(VideoTransitionKind.none)
                        Text(WorkbenchText.t("交叉溶解", "Cross dissolve")).tag(VideoTransitionKind.crossDissolve)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("workbench.clip.transition")
                    if clip.leadingTransition == .crossDissolve {
                        CommitSlider(label: WorkbenchText.t("溶解时长", "Dissolve duration"),
                                     value: clip.transitionDuration, range: 0.1...2,
                                     identifier: "workbench.clip.transitionDuration") { value in
                            update(clip: clip, trimStart: nil, trimEnd: nil, transitionDuration: value)
                        }
                    }
                }
            } else {
                Text(WorkbenchText.t("在时间线上选择一个片段。", "Select a clip on the timeline."))
                    .foregroundStyle(.secondary)
            }

            SectionCard(title: WorkbenchText.t("主音轨", "Primary audio")) {
                CommitSlider(label: WorkbenchText.t("总音量", "Master volume"),
                             value: center.project?.videoTimeline?.primaryVolume ?? 1, range: 0...2,
                             identifier: "workbench.primary.volume") { value in
                    center.apply(.setPrimaryAudio(volume: value, muted: nil))
                }
                Toggle(WorkbenchText.t("静音原声", "Mute original audio"), isOn: Binding(
                    get: { center.project?.videoTimeline?.primaryMuted ?? false },
                    set: { value in center.apply(.setPrimaryAudio(volume: nil, muted: value)) }))
                    .frame(minHeight: 44)
            }

            SectionCard(title: WorkbenchText.t("音乐轨", "Music track")) {
                ForEach(center.project?.videoTimeline?.music ?? []) { music in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(center.project?.asset(music.assetID)?.originalName ?? "music")
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                center.apply(.removeMusic(id: music.id))
                            } label: { Image(systemName: "trash") }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("workbench.music.delete")
                        }
                        CommitSlider(label: WorkbenchText.t("起点偏移", "Offset"),
                                     value: music.offsetSeconds, range: 0...600,
                                     identifier: "workbench.music.offset") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: value, trimStart: nil,
                                                      lengthSeconds: nil, volume: nil,
                                                      fadeInSeconds: nil, fadeOutSeconds: nil))
                        }
                        // Source trim + audible length: the requested length
                        // adjustment was previously unreachable in the UI.
                        let assetDuration = center.project?.asset(music.assetID)?.metadata?.durationSeconds
                            ?? (music.trimStart + music.lengthSeconds)
                        CommitSlider(label: WorkbenchText.t("剪辑起点", "Trim start"),
                                     value: music.trimStart,
                                     range: 0...max(0, assetDuration - music.lengthSeconds),
                                     identifier: "workbench.music.trimStart") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: nil, trimStart: value,
                                                      lengthSeconds: nil, volume: nil,
                                                      fadeInSeconds: nil, fadeOutSeconds: nil))
                        }
                        let minimumLength = max(0.1, music.fadeInSeconds + music.fadeOutSeconds)
                        CommitSlider(label: WorkbenchText.t("时长（秒）", "Length (s)"),
                                     value: music.lengthSeconds,
                                     range: minimumLength...max(minimumLength + 0.1,
                                                                assetDuration - music.trimStart),
                                     identifier: "workbench.music.length") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: nil, trimStart: nil,
                                                      lengthSeconds: value, volume: nil,
                                                      fadeInSeconds: nil, fadeOutSeconds: nil))
                        }
                        CommitSlider(label: WorkbenchText.t("音量", "Volume"),
                                     value: music.volume, range: 0...2,
                                     identifier: "workbench.music.volume") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: nil, trimStart: nil,
                                                      lengthSeconds: nil, volume: value,
                                                      fadeInSeconds: nil, fadeOutSeconds: nil))
                        }
                        CommitSlider(label: WorkbenchText.t("淡入", "Fade in"),
                                     value: music.fadeInSeconds,
                                     range: 0...max(0, music.lengthSeconds - music.fadeOutSeconds),
                                     identifier: "workbench.music.fadeIn") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: nil, trimStart: nil,
                                                      lengthSeconds: nil, volume: nil,
                                                      fadeInSeconds: value, fadeOutSeconds: nil))
                        }
                        CommitSlider(label: WorkbenchText.t("淡出", "Fade out"),
                                     value: music.fadeOutSeconds,
                                     range: 0...max(0, music.lengthSeconds - music.fadeInSeconds),
                                     identifier: "workbench.music.fadeOut") { value in
                            center.apply(.updateMusic(id: music.id, offsetSeconds: nil, trimStart: nil,
                                                      lengthSeconds: nil, volume: nil,
                                                      fadeInSeconds: nil, fadeOutSeconds: value))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    showMusicImporter = true
                } label: {
                    Label(WorkbenchText.t("添加音乐", "Add music"), systemImage: "plus")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("workbench.music.add")
            }

            SectionCard(title: WorkbenchText.t("字幕轨", "Caption track")) {
                ForEach(center.project?.videoTimeline?.captions ?? []) { caption in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(WorkbenchText.t("字幕文本", "Caption text"), text: Binding(
                                get: { caption.text },
                                set: { value in
                                    center.apply(.updateCaption(id: caption.id, start: nil, end: nil, text: value))
                                }))
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                center.apply(.removeCaption(id: caption.id))
                            } label: { Image(systemName: "trash") }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("workbench.caption.delete")
                        }
                        CommitSlider(label: WorkbenchText.t("开始", "Start"),
                                     value: caption.start, range: 0...max(0.1, caption.end - 0.05),
                                     identifier: "workbench.caption.start") { value in
                            center.apply(.updateCaption(id: caption.id, start: value, end: nil, text: nil))
                        }
                        CommitSlider(label: WorkbenchText.t("结束", "End"),
                                     value: caption.end, range: (caption.start + 0.05)...max(caption.start + 0.1,
                                                                                            center.project?.videoTimeline?.primaryDuration ?? 10),
                                     identifier: "workbench.caption.end") { value in
                            center.apply(.updateCaption(id: caption.id, start: nil, end: value, text: nil))
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("workbench.caption.\(caption.id.uuidString)")
                }
                HStack {
                    TextField(WorkbenchText.t("新字幕", "New caption"), text: $newCaptionText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("workbench.caption.new")
                    Button(WorkbenchText.t("添加", "Add")) {
                        let start = center.playheadSeconds
                        let caption = CaptionSegment(start: start, end: start + 2,
                                                     text: newCaptionText, source: .manual)
                        if center.apply(.addCaption(caption)) { newCaptionText = "" }
                    }
                    .disabled(newCaptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }
                Button {
                    Task { await transcribeSelectedClip() }
                } label: {
                    Label(isTranscribing
                          ? WorkbenchText.t("转写中…", "Transcribing…")
                          : WorkbenchText.t("转写所选片段", "Transcribe selected clip"),
                          systemImage: "waveform")
                        .frame(minHeight: 44)
                }
                .disabled(clip == nil || isTranscribing)
                .accessibilityIdentifier("workbench.caption.transcribe")
                if let transcriptionMessage {
                    Text(transcriptionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(WorkbenchText.t("字幕样式", "Caption style"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(WorkbenchText.t("对齐", "Alignment"), selection: Binding(
                    get: { center.project?.videoTimeline?.captionStyle.alignment ?? .center },
                    set: { value in
                        guard var style = center.project?.videoTimeline?.captionStyle else { return }
                        style.alignment = value
                        center.apply(.setCaptionStyle(style))
                    })) {
                    Text(WorkbenchText.t("左对齐", "Leading")).tag(CaptionAlignment.leading)
                    Text(WorkbenchText.t("居中", "Center")).tag(CaptionAlignment.center)
                    Text(WorkbenchText.t("右对齐", "Trailing")).tag(CaptionAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("workbench.caption.alignment")
                Toggle(WorkbenchText.t("限制在安全区内", "Keep inside safe area"), isOn: Binding(
                    get: { center.project?.videoTimeline?.captionStyle.respectsSafeArea ?? false },
                    set: { value in
                        guard var style = center.project?.videoTimeline?.captionStyle else { return }
                        style.respectsSafeArea = value
                        center.apply(.setCaptionStyle(style))
                    }))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.caption.safeArea")
                CommitSlider(label: WorkbenchText.t("垂直位置", "Vertical position"),
                             value: center.project?.videoTimeline?.captionStyle.positionY ?? 0.88,
                             range: 0.4...0.98,
                             identifier: "workbench.caption.position") { value in
                    guard var style = center.project?.videoTimeline?.captionStyle else { return }
                    style.positionY = value
                    center.apply(.setCaptionStyle(style))
                }
                Toggle(WorkbenchText.t("显示安全区参考线", "Show safe-area guide"),
                       isOn: $center.showsCaptionSafeArea)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.caption.safeAreaGuide")
                HStack {
                    Button(WorkbenchText.t("整体提前 0.1s", "Shift earlier 0.1s")) {
                        center.apply(.shiftCaptions(bySeconds: -0.1))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.caption.shiftEarlier")
                    Button(WorkbenchText.t("整体延后 0.1s", "Shift later 0.1s")) {
                        center.apply(.shiftCaptions(bySeconds: 0.1))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workbench.caption.shiftLater")
                }
                .disabled((center.project?.videoTimeline?.captions.isEmpty ?? true))
            }

            SectionCard(title: WorkbenchText.t("视频画布", "Video canvas")) {
                HStack {
                    Text(WorkbenchText.t("宽", "W"))
                    TextField("W", value: $canvasWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text(WorkbenchText.t("高", "H"))
                    TextField("H", value: $canvasHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                CommitSlider(label: WorkbenchText.t("帧率", "Frame rate"),
                             value: canvasFPS, range: 1...120,
                             identifier: "workbench.canvas.fps") { value in
                    canvasFPS = value
                    center.setCanvas(width: Int(canvasWidth), height: Int(canvasHeight), frameRate: value)
                }
                Button(WorkbenchText.t("应用画布尺寸", "Apply canvas size")) {
                    center.setCanvas(width: Int(canvasWidth), height: Int(canvasHeight), frameRate: canvasFPS)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.canvas.apply")
            }
        }
        .fileImporter(isPresented: $showMusicImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await center.importMusic(url: url) }
            }
        }
        .onAppear {
            if let canvas = center.project?.canvas {
                canvasWidth = Double(canvas.width)
                canvasHeight = Double(canvas.height)
                canvasFPS = canvas.frameRate ?? 30
            }
        }
    }

    private func update(clip: VideoClip, trimStart: Double?, trimEnd: Double?, speed: Double? = nil,
                        volume: Double? = nil, isMuted: Bool? = nil, rotation: Double? = nil,
                        crop: OptionalUpdate<NormalizedRect> = .unchanged,
                        transition: VideoTransitionKind? = nil, transitionDuration: Double? = nil) {
        center.apply(.updateClip(id: clip.id, trimStart: trimStart, trimEnd: trimEnd,
                                 speed: speed, volume: volume, isMuted: isMuted,
                                 rotationDegrees: rotation, crop: crop,
                                 leadingTransition: transition,
                                 transitionDuration: transitionDuration))
    }

    private func setCrop(clip: VideoClip, aspect: Double) {
        guard let asset = center.project?.asset(clip.assetID),
              let width = asset.metadata?.width, let height = asset.metadata?.height,
              width > 0, height > 0 else { return }
        let sourceAspect = Double(width) / Double(height)
        var rect: NormalizedRect
        if sourceAspect > aspect {
            let cropWidth = aspect / sourceAspect
            rect = NormalizedRect(x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1)
        } else {
            let cropHeight = sourceAspect / aspect
            rect = NormalizedRect(x: 0, y: (1 - cropHeight) / 2, width: 1, height: cropHeight)
        }
        update(clip: clip, trimStart: nil, trimEnd: nil, crop: .set(rect))
    }

    /// Uses the existing local transcription service and retimes segments
    /// through the clip's speed/trim so captions stay on the unified timeline.
    private func transcribeSelectedClip() async {
        guard let clip, let project = center.project,
              let asset = project.asset(clip.assetID),
              let url = center.resolvedURL(for: asset.id) else { return }
        isTranscribing = true
        transcriptionMessage = nil
        defer { isTranscribing = false }
        do {
            let language = VoiceRecognitionLanguage(
                rawValue: UserDefaults.standard.string(forKey: VoiceRecognitionLanguage.defaultsKey) ?? "") ?? .automatic
            let segments = try await FileSpeechTranscriber.shared.transcribe(url: url, language: language)
            let placed = MediaTimelineMath.placeClips(project.videoTimeline?.clips ?? [])
            guard let item = placed.first(where: { $0.clip.id == clip.id }) else { return }
            var added = 0
            for segment in segments {
                let sourceStart = max(segment.start, clip.trimStart)
                let sourceEnd = min(segment.end, clip.trimEnd)
                guard sourceEnd - sourceStart > 0.2 else { continue }
                let start = item.timelineStart + (sourceStart - clip.trimStart) / clip.speed
                let end = min(item.timelineEnd, item.timelineStart + (sourceEnd - clip.trimStart) / clip.speed)
                guard end > start else { continue }
                let caption = CaptionSegment(start: start, end: end,
                                             text: segment.text, source: .transcription)
                if center.apply(.addCaption(caption)) { added += 1 }
            }
            transcriptionMessage = added == 0
                ? WorkbenchText.t("未识别到语音。", "No speech was recognized.")
                : WorkbenchText.t("已添加 \(added) 条字幕。", "Added \(added) caption(s).")
        } catch {
            transcriptionMessage = error.localizedDescription
        }
    }
}

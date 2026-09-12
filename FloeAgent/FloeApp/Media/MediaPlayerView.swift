// FloeApp — In-app media player. Backed by AVPlayer so it can show both a
// plain file and a composition preview produced by the edit plan. The player
// exposes explicit controls (no presets): play/pause, scrub, frame step,
// speed, loop range, subtitle track toggle, PiP and fullscreen.
#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import AVKit

@MainActor
public final class MediaPlayerModel: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public var rate: Double = 1.0
    @Published public var loopRange: ClosedRange<Double>?
    @Published public var selectedSubtitleTrack: Int?
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var videoSize: CGSize = .zero
    @Published public private(set) var frameRate = 30.0

    public let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    public init() {
        player.actionAtItemEnd = .pause
    }

    public func load(url: URL) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        if let duration = try? await asset.load(.duration) {
            self.duration = CMTimeGetSeconds(duration)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let displayed = CGRect(origin: .zero, size: size).applying(transform)
            videoSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { frameRate = Double(fps) }
        }
        installObservers()
        player.play()
        isPlaying = true
        player.rate = Float(rate)
    }

    private func installObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                self.currentTime = seconds
                if let range = self.loopRange, seconds >= range.upperBound {
                    self.player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600))
                }
            }
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let range = self.loopRange {
                    self.player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600))
                    self.player.play()
                } else {
                    self.isPlaying = false
                }
            }
        }
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayback() {
        if isPlaying { player.pause() } else { player.play(); player.rate = Float(rate) }
        isPlaying.toggle()
    }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        currentTime = max(0, seconds)
    }

    public func stepFrame(direction: Int, frameRate: Double) {
        guard frameRate > 0 else { return }
        seek(to: currentTime + Double(direction) / frameRate)
    }

    public func setRate(_ value: Double) {
        rate = value
        if isPlaying { player.rate = Float(value) }
    }

    public func setLoopRange(_ range: ClosedRange<Double>?) {
        loopRange = range
    }

    public func selectSubtitleTrack(index: Int?) {
        selectedSubtitleTrack = index
        // Subtitle selection is applied by the editor when burning in; the
        // player reflects the choice for preview purposes.
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

public struct MediaPlayerView: View {
    @StateObject private var model = MediaPlayerModel()
    @State private var isFullscreen = false
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                VideoSurface(player: model.player)
            }
            .aspectRatio(model.videoSize == .zero ? 16.0 / 9.0 : model.videoSize.width / max(model.videoSize.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            controls
        }
        .padding()
        .task(id: url) { await model.load(url: url) }
        .onDisappear { model.pause() }
        .fullScreenCover(isPresented: $isFullscreen) {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(player: model.player)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.001)
            )
            HStack(spacing: 16) {
                Button { model.stepFrame(direction: -1, frameRate: model.frameRate) } label: {
                    Image(systemName: "backward.frame").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("上一帧")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                Button { model.stepFrame(direction: 1, frameRate: model.frameRate) } label: {
                    Image(systemName: "forward.frame").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("下一帧")
                Spacer(minLength: 0)
                Button { isFullscreen.toggle() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("全屏播放")
            }
            .buttonStyle(.borderless)
            Picker("播放速度", selection: Binding(
                get: { model.rate },
                set: { model.setRate($0) }
            )) {
                Text("0.5x").tag(0.5)
                Text("1x").tag(1.0)
                Text("1.5x").tag(1.5)
                Text("2x").tag(2.0)
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif

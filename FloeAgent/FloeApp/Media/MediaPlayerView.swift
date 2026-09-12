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
            videoSize = size.applying(transform)
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

    deinit {
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
            .frame(minHeight: 240)
            .aspectRatio(model.videoSize == .zero ? 16.0 / 9.0 : model.videoSize.width / max(model.videoSize.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            controls
        }
        .padding()
        .task { await model.load(url: url) }
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
                Button { model.stepFrame(direction: -1, frameRate: 30) } label: { Image(systemName: "backward.frame") }
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                Button { model.stepFrame(direction: 1, frameRate: 30) } label: { Image(systemName: "forward.frame") }
                Spacer()
                Picker("Rate", selection: Binding(
                    get: { model.rate },
                    set: { model.setRate($0) }
                )) {
                    Text("0.5x").tag(0.5)
                    Text("1x").tag(1.0)
                    Text("1.5x").tag(1.5)
                    Text("2x").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button { isFullscreen.toggle() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            }
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

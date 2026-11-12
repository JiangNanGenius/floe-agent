// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Observation
import SwiftUI

/// Compact audio-only transport for a meeting recording.
///
/// The meeting session owns the `AVPlayer` (and the native audio session that
/// keeps its file playable). This view never creates a second player, waveform
/// or synthetic progress: it observes the handed-in player, exposes native
/// transport controls and removes every observer when the player is replaced
/// or the view goes away.
struct MeetingAudioPlaybackView: View {
    let player: AVPlayer
    let title: String?
    let onClose: () -> Void
    @State private var model = MeetingAudioPlaybackModel()
    @Environment(\.scenePhase) private var scenePhase

    init(player: AVPlayer, title: String? = nil, onClose: @escaping () -> Void) {
        self.player = player
        self.title = title
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(title ?? t("回放", "Playback"), systemImage: "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("meeting.playback.title")
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(model.positionText).foregroundStyle(.primary)
                    Text("/").foregroundStyle(.tertiary)
                    Text(model.durationText).foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(t("播放时间", "Playback time"))
                .accessibilityValue(model.accessibilityPosition)
                .accessibilityIdentifier("meeting.playback.time")
            }

            Slider(value: position, in: sliderRange, onEditingChanged: { editing in
                if editing { model.beginScrubbing() } else { model.endScrubbing() }
            })
            .disabled(!model.canSeek)
            .accessibilityLabel(t("播放位置", "Playback position"))
            .accessibilityValue(model.accessibilityPosition)
            .accessibilityHint(t("上下轻扫可调整播放位置", "Swipe up or down to adjust playback position"))
            .accessibilityIdentifier("meeting.playback.slider")

            HStack(spacing: 4) {
                transportButton(
                    t("后退 15 秒", "Back 15 seconds"),
                    systemImage: "gobackward.15",
                    identifier: "meeting.playback.back15"
                ) { model.skip(by: -15) }
                .disabled(!model.canSeek)
                transportButton(
                    model.isPlaying ? t("暂停", "Pause") : t("播放", "Play"),
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                    identifier: "meeting.playback.playPause",
                    prominent: true
                ) { model.togglePlayback() }
                transportButton(
                    t("前进 15 秒", "Forward 15 seconds"),
                    systemImage: "goforward.15",
                    identifier: "meeting.playback.forward15"
                ) { model.skip(by: 15) }
                .disabled(!model.canSeek)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("关闭播放", "Close playback"))
                .accessibilityIdentifier("meeting.playback.close")
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.playback")
        .onAppear { model.attach(to: player) }
        .onChange(of: ObjectIdentifier(player)) { _, _ in model.attach(to: player) }
        .onDisappear { model.detach() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.pauseForBackground() }
        }
    }

    private var position: Binding<Double> {
        Binding(
            get: { model.displayTime },
            set: { model.updateScrub($0) }
        )
    }

    private var sliderRange: ClosedRange<Double> {
        let upper = model.canSeek ? model.duration : max(model.displayTime, 0.01)
        return 0...max(upper, 0.01)
    }

    private func transportButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(prominent ? .title3.weight(.semibold) : .body)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .background(prominent ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
}

/// Main-actor state for one handed-in meeting player. The model deliberately
/// owns only observation tokens; playback duration, the audio session and the
/// loaded file remain with `MeetingProjectSession`.
@MainActor @Observable
final class MeetingAudioPlaybackModel {
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var isScrubbing = false
    private(set) var scrubTime = 0.0
    private(set) var canSeek = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var durationObservation: NSKeyValueObservation?
    private var pendingSeekTarget: Double?
    @ObservationIgnored private var seekGeneration = 0

    /// The visible playhead. A scrubbed or pending seek value is retained
    /// until AVPlayer confirms the seek so periodic updates cannot snap the
    /// slider back to the old position.
    var displayTime: Double {
        if isScrubbing { return scrubTime }
        if let pendingSeekTarget { return pendingSeekTarget }
        return currentTime
    }

    var positionText: String { Self.timeText(displayTime) }
    var durationText: String { canSeek ? Self.timeText(duration) : "--:--" }
    var accessibilityPosition: String {
        canSeek ? "\(positionText) / \(durationText)" : positionText
    }

    func attach(to player: AVPlayer) {
        guard self.player !== player else { return }
        detach()
        self.player = player
        isPlaying = player.timeControlStatus != .paused
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 { currentTime = seconds }
        refreshTiming()
        installObservers(on: player)
    }

    func detach() {
        tearDownObservers()
        player = nil
        pendingSeekTarget = nil
        seekGeneration &+= 1
        isScrubbing = false
        isPlaying = false
        currentTime = 0
        duration = 0
        canSeek = false
    }

    func beginScrubbing() {
        guard canSeek else { return }
        scrubTime = clamped(displayTime)
        isScrubbing = true
    }

    func updateScrub(_ value: Double) {
        guard canSeek else { return }
        if isScrubbing {
            scrubTime = clamped(value)
        } else {
            // Accessibility and tap-to-seek adjustments arrive without an
            // editing callback; treat each delivered value as one complete
            // seek instead of starting a dangling scrub session.
            seek(to: value)
        }
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        let target = clamped(scrubTime)
        if abs(target - currentTime) < 0.01, pendingSeekTarget == nil { return }
        seek(to: target)
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying || player.timeControlStatus != .paused {
            player.pause()
            isPlaying = false
            return
        }
        if canSeek, displayTime >= duration - 0.25 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func skip(by seconds: Double) {
        guard canSeek, !isScrubbing else { return }
        seek(to: displayTime + seconds)
    }

    func pauseForBackground() {
        player?.pause()
        isPlaying = false
        isScrubbing = false
    }

    private func installObservers(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                self.timeDidAdvance(time)
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus, options: [.initial, .new]
        ) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                let playing = observed.timeControlStatus != .paused
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
        currentItemObservation = player.observe(
            \.currentItem, options: [.new]
        ) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.installItemObservers(for: observed.currentItem)
            }
        }
        // Install the item observers synchronously so an end notification
        // posted immediately after attach cannot race the first KVO callback.
        installItemObservers(for: player.currentItem)
    }

    /// A player may attach before or after its item exists. Item-bound
    /// observers are replaced with the item so a late duration or end event
    /// still reaches this exact player, and a replaced item cannot fire into
    /// the new one.
    private func installItemObservers(for item: AVPlayerItem?) {
        durationObservation?.invalidate()
        durationObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        guard let item else {
            if duration != 0 { duration = 0 }
            if canSeek { canSeek = false }
            return
        }
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                self.refreshTiming()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player, weak item] _ in
            Task { @MainActor in
                guard let self, let player, let item,
                      self.player === player, player.currentItem === item else { return }
                self.playbackDidEnd()
            }
        }
        refreshTiming()
    }

    private func timeDidAdvance(_ time: CMTime) {
        refreshTiming()
        guard !isScrubbing, pendingSeekTarget == nil else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        let next = clamped(seconds)
        if abs(next - currentTime) >= 0.01 { currentTime = next }
    }

    private func refreshTiming() {
        guard let item = player?.currentItem else {
            if duration != 0 { duration = 0 }
            if canSeek { canSeek = false }
            return
        }
        let assetDuration = Self.positiveDuration(item.duration.seconds)
        let forwardEnd = Self.positiveDuration(item.forwardPlaybackEndTime.seconds)
        let effective: Double?
        switch (assetDuration, forwardEnd) {
        case let (asset?, end?): effective = min(asset, end)
        case let (asset?, nil): effective = asset
        case let (nil, end?): effective = end
        case (nil, nil): effective = nil
        }
        guard let effective, effective > 0.001 else {
            if duration != 0 { duration = 0 }
            if canSeek { canSeek = false }
            return
        }
        if duration != effective { duration = effective }
        if !canSeek { canSeek = true }
        if currentTime > effective { currentTime = effective }
    }

    private func seek(to seconds: Double) {
        guard let player, canSeek else { return }
        let target = clamped(seconds)
        let currentTarget = pendingSeekTarget ?? currentTime
        guard abs(target - currentTarget) >= 0.005 else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        pendingSeekTarget = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, let player, self.player === player,
                      self.seekGeneration == generation else { return }
                self.pendingSeekTarget = nil
                let seconds = player.currentTime().seconds
                if seconds.isFinite, seconds >= 0 { self.currentTime = self.clamped(seconds) }
            }
        }
    }

    private func playbackDidEnd() {
        pendingSeekTarget = nil
        seekGeneration &+= 1
        isScrubbing = false
        isPlaying = false
        refreshTiming()
        if canSeek { currentTime = duration }
    }

    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let lower = max(0, seconds)
        guard canSeek else { return lower }
        return min(lower, duration)
    }

    private func tearDownObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
    }

    isolated deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeControlObservation?.invalidate()
        currentItemObservation?.invalidate()
        durationObservation?.invalidate()
    }

    private static func positiveDuration(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
#endif

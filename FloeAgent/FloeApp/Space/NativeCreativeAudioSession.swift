// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import FloeCore
import FloeMusicNative

/// Native creation tools participate in the same last-holder ledger as voice.
/// A retained AVAudioSession category by itself never proves a live owner.
@MainActor final class NativeCreativeAudioSession: MusicAudioAuthority {
    private static var active: [UUID: Bool] = [:]
    static var isActive: Bool { !active.isEmpty }
    static var isRecording: Bool { active.values.contains(true) }
    private let id = UUID()
    private var acquisitions = 0
    private weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }

    func acquirePlayback() throws {
        guard Self.active[id] != true else {
            throw FloeError.validationFailed(IDELanguageRunText.t("请先结束当前录音。", "Finish the current recording first."))
        }
        if Self.active[id] != nil { acquisitions += 1; return }
        let session = AVAudioSession.sharedInstance()
        let prior = FloeAudioSessionOwnership.claim(id)
        do {
            guard !SpeechSessionAdmission.rejectsExclusiveCapture(category: session.category, holdersBeforeClaim: prior) else {
                throw FloeError.validationFailed(IDELanguageRunText.t("请先结束当前录音，再播放音乐。", "Finish the current recording before playing music."))
            }
            if prior == 0 || !SpeechSessionAdmission.isRecordRoute(category: session.category) {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            Self.active[id] = false
            acquisitions = 1
        } catch { _ = FloeAudioSessionOwnership.release(id); throw error }
    }

    func acquireRecording() throws {
        guard Self.active[id] == nil else {
            throw FloeError.validationFailed(IDELanguageRunText.t("请先停止当前播放。", "Stop the current playback first."))
        }
        let prior = FloeAudioSessionOwnership.claim(id)
        do {
            guard prior == 0 else {
                throw FloeError.validationFailed(IDELanguageRunText.t("请先结束其他录音或语音播放。", "Finish the other recording or voice playback first."))
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            Self.active[id] = true
            acquisitions = 1
        } catch { _ = FloeAudioSessionOwnership.release(id); throw error }
    }

    func releasePlayback() {
        guard acquisitions > 0 else { return }
        acquisitions -= 1
        guard acquisitions == 0 else { return }
        guard Self.active.removeValue(forKey: id) != nil else { return }
        let otherSurfaceOwnsSession = environment.map {
            $0.pipAudioService.holdsSharedAudioSession || !$0.backgroundVideoService.audioSessionMayBeReleased
        } ?? false
        if otherSurfaceOwnsSession { _ = FloeAudioSessionOwnership.release(id) }
        else {
            FloeAudioSessionOwnership.releaseAndDeactivateLast(id) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        environment?.pipAudioService.otherAudioOwnerDidRelease()
    }
}
#endif

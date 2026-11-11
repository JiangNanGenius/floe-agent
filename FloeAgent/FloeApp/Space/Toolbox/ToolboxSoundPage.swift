// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeToolboxWorkbenches

/// Sound analysis shares the recording authority used by music and meetings.
@MainActor
private final class ToolboxSoundAudioAccess: ObservableObject {
    private let authority: NativeCreativeAudioSession
    private weak var environment: AppEnvironment?
    private var held = false

    init(environment: AppEnvironment) {
        self.environment = environment
        authority = NativeCreativeAudioSession(environment: environment)
    }

    func acquire() throws {
        guard !held else { return }
        guard let environment, !environment.pipAudioService.holdsSharedAudioSession,
              environment.backgroundVideoService.audioSessionMayBeReleased else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "请先停止画中画或其他音频，再开始声音分析。",
                "Stop Picture in Picture or other audio before starting sound analysis."))
        }
        try authority.acquireRecording()
        held = true
    }

    func release() {
        guard held else { return }
        held = false
        authority.releasePlayback()
    }
}

struct ToolboxSoundPage: View {
    @StateObject private var audio: ToolboxSoundAudioAccess

    @MainActor init(environment: AppEnvironment) {
        _audio = StateObject(wrappedValue: ToolboxSoundAudioAccess(environment: environment))
    }

    var body: some View {
        ToolboxSoundView(acquireAudio: { try audio.acquire() }, releaseAudio: { audio.release() })
    }
}
#endif

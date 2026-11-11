// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import FloeApp

/// NativeCreativeAudioSession ownership rules: a Music recording may keep
/// its own accompaniment/monitoring (same owner, nested playback), other
/// surfaces keep the real last-holder exclusion, and releases balance. Runs
/// on the Simulator; the system audio session is shared, so the suites are
/// serialized.
@Suite("Native creative audio session", .serialized)
@MainActor struct NativeCreativeAudioSessionTests {
    @Test func ownedRecordingMayKeepAccompanimentAndMonitoring() async throws {
        let environment = FloeAgentApp.liveEnvironment
        let recorder = NativeCreativeAudioSession(environment: environment)
        defer { recorder.releasePlayback(); recorder.releasePlayback() }
        try recorder.acquireRecording()
        #expect(NativeCreativeAudioSession.isRecording)
        // Same owner adds playback on top of its own recording: no re-claim,
        // no category fight, no throw.
        try recorder.acquirePlayback()
        #expect(NativeCreativeAudioSession.isActive)
        // Balanced nested release: one release leaves the recording claim.
        recorder.releasePlayback()
        #expect(NativeCreativeAudioSession.isRecording)
        // Second release ends the claim entirely.
        recorder.releasePlayback()
        #expect(!NativeCreativeAudioSession.isActive)
        #expect(!NativeCreativeAudioSession.isRecording)
    }

    @Test func recordingStillRejectsNestedRecording() async throws {
        let environment = FloeAgentApp.liveEnvironment
        let recorder = NativeCreativeAudioSession(environment: environment)
        defer { recorder.releasePlayback() }
        try recorder.acquireRecording()
        await #expect(throws: (any Error).self) {
            try recorder.acquireRecording()
        }
        recorder.releasePlayback()
        #expect(!NativeCreativeAudioSession.isActive)
    }

    @Test func anotherSurfaceCannotPlaybackDuringMusicRecording() async throws {
        let environment = FloeAgentApp.liveEnvironment
        let recorder = NativeCreativeAudioSession(environment: environment)
        let other = NativeCreativeAudioSession(environment: environment)
        defer { other.releasePlayback(); recorder.releasePlayback() }
        try recorder.acquireRecording()
        // A different owner still faces the real exclusion: the recording
        // claim holds the shared ledger.
        await #expect(throws: (any Error).self) {
            try other.acquirePlayback()
        }
        recorder.releasePlayback()
        #expect(!NativeCreativeAudioSession.isActive)
    }
}
#endif

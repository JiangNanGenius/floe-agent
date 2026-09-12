import AVFoundation
import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("AudioRecorderManagerTests", .serialized)
struct AudioRecorderManagerTests {

    // MARK: - Public Methods

    @Test
    func initialStateStartsEmpty() {
        let manager = AudioRecorderManager()

        #expect(manager.recordState == .empty)
        #expect(manager.controlState == .empty)
        #expect(manager.finishedAudio == nil)
        #expect(manager.currentRecordTime == 0)
        #expect(manager.countdownRemaining == 3)
    }

    @Test
    func startRecordingFlowStartsTheCountdownState() {
        let manager = AudioRecorderManager()

        manager.startRecordingFlow(recordMaxTime: 5)

        #expect(manager.controlState == .countdown)
        #expect(manager.countdownRemaining == 3)
        #expect(manager.recordState == .empty)

        manager.cancelRecordingFlow()
    }

    @Test
    func cancelRecordingFlowDuringCountdownResetsTheManager() {
        let manager = AudioRecorderManager()
        manager.startRecordingFlow(recordMaxTime: 5)

        manager.cancelRecordingFlow()

        #expect(manager.controlState == .empty)
        #expect(manager.countdownRemaining == 3)
        #expect(manager.recordState == .empty)
    }

    @Test
    func stopRecordingWithoutAnActiveRecorderLeavesStateUnchanged() {
        let manager = AudioRecorderManager()

        manager.stopRecording()

        #expect(manager.recordState == .empty)
        #expect(manager.controlState == .empty)
        #expect(manager.finishedAudio == nil)
    }

    @Test
    func cancelWithoutAnActiveRecorderLeavesStateUnchanged() {
        let manager = AudioRecorderManager()

        manager.cancel()

        #expect(manager.recordState == .empty)
        #expect(manager.controlState == .empty)
        #expect(manager.finishedAudio == nil)
        #expect(manager.currentRecordTime == 0)
    }

    @Test
    func recordingURLFactoryCreatesUniqueAudioFilesInCachesDirectory() {
        let firstURL = AudioRecorderManager.makeRecordingURL()
        let secondURL = AudioRecorderManager.makeRecordingURL()
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        #expect(firstURL != secondURL)
        #expect(firstURL.pathExtension == "m4a")
        #expect(secondURL.pathExtension == "m4a")
        #expect(firstURL.deletingLastPathComponent() == cachesDirectory)
        #expect(secondURL.deletingLastPathComponent() == cachesDirectory)
    }

    @Test
    func cancellationActionMatchesCurrentFlowRules() {
        #expect(AudioRecorderManager.cancellationAction(for: .empty) == .none)
        #expect(AudioRecorderManager.cancellationAction(for: .countdown) == .resetCountdown)
        #expect(AudioRecorderManager.cancellationAction(for: .record) == .discardRecording)
    }

    @Test
    func startRecordingUsesInjectedDependencies() async throws {
        let recordingURL = URL(fileURLWithPath: "/tmp/injected-recording.m4a")
        let recorder = AudioRecorderDouble(url: recordingURL)
        let tracker = AudioRecorderDependencyTracker(recorder: recorder)
        let manager = AudioRecorderManager(dependencies: tracker.makeDependencies(recordingURL: recordingURL))

        manager.startRecording(recordMaxTime: 7)

        #expect(tracker.configureRecordSessionCallCount == 1)
        #expect(tracker.createdURLs == [recordingURL])
        #expect(recorder.prepareToRecordCallCount == 1)
        #expect(recorder.recordedDurations == [7])
        #expect(manager.controlState == .record)
        #expect(manager.recordState == .recording)
        #expect(manager.finishedAudio == nil)

        manager.cancel()
    }

    @Test
    func stopRecordingFinalizesInjectedRecorderOutput() async throws {
        let recordingURL = URL(fileURLWithPath: "/tmp/injected-stop.m4a")
        let recorder = AudioRecorderDouble(url: recordingURL)
        recorder.currentTime = 1.75

        let tracker = AudioRecorderDependencyTracker(recorder: recorder)
        let manager = AudioRecorderManager(dependencies: tracker.makeDependencies(recordingURL: recordingURL))

        manager.startRecording(recordMaxTime: 7)
        manager.stopRecording()

        let finishedAudio = try #require(manager.finishedAudio)
        #expect(recorder.stopCallCount == 1)
        #expect(finishedAudio.url == recordingURL)
        #expect(abs(finishedAudio.duration - 1.75) < 0.0001)
        #expect(manager.controlState == .empty)
        #expect(manager.recordState == .empty)
    }

    @Test
    func cancelDiscardRemovesTheInjectedRecordingURLAfterPreCleaningThePath() async throws {
        let recordingURL = URL(fileURLWithPath: "/tmp/injected-cancel.m4a")
        let recorder = AudioRecorderDouble(url: recordingURL)
        recorder.currentTime = 2

        let tracker = AudioRecorderDependencyTracker(recorder: recorder)
        let manager = AudioRecorderManager(dependencies: tracker.makeDependencies(recordingURL: recordingURL))

        manager.startRecording(recordMaxTime: 7)
        manager.cancel()

        #expect(recorder.stopCallCount == 1)
        #expect(tracker.removedURLs == [recordingURL, recordingURL])
        #expect(manager.finishedAudio == nil)
        #expect(manager.controlState == .empty)
        #expect(manager.recordState == .empty)
    }

    @Test
    func startRecordingFlowCanAdvanceImmediatelyWithInjectedSleeper() async throws {
        let recordingURL = URL(fileURLWithPath: "/tmp/injected-flow.m4a")
        let recorder = AudioRecorderDouble(url: recordingURL)
        let tracker = AudioRecorderDependencyTracker(recorder: recorder)
        let manager = AudioRecorderManager(dependencies: tracker.makeDependencies(recordingURL: recordingURL))

        manager.startRecordingFlow(recordMaxTime: 4)
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(recorder.recordedDurations == [4])
        #expect(manager.controlState == .record)
        #expect(manager.recordState == .recording)
        #expect(manager.countdownRemaining == 3)

        manager.cancel()
    }

}

private final class AudioRecorderDouble: AudioRecorderControlling {

    // MARK: - Public Properties

    var delegate: AVAudioRecorderDelegate?
    let url: URL
    var currentTime: TimeInterval = .zero
    var isRecording = false
    private(set) var prepareToRecordCallCount = 0
    private(set) var recordCallCount = 0
    private(set) var recordedDurations: [TimeInterval] = []
    private(set) var stopCallCount = 0

    // MARK: - Initializer

    init(url: URL) {
        self.url = url
    }

    // MARK: - Public Methods

    func prepareToRecord() -> Bool {
        prepareToRecordCallCount += 1
        return true
    }

    func record(forDuration duration: TimeInterval) -> Bool {
        recordCallCount += 1
        recordedDurations.append(duration)
        isRecording = true
        return true
    }

    func stop() {
        stopCallCount += 1
        isRecording = false
    }

}

@MainActor
private final class AudioRecorderDependencyTracker {

    // MARK: - Public Properties

    private(set) var configureRecordSessionCallCount = 0
    private(set) var createdURLs: [URL] = []
    private(set) var removedURLs: [URL] = []

    // MARK: - Private Properties

    private let recorder: AudioRecorderDouble

    // MARK: - Initializer

    init(recorder: AudioRecorderDouble) {
        self.recorder = recorder
    }

    // MARK: - Public Methods

    func makeDependencies(recordingURL: URL) -> AudioRecorderManager.Dependencies {
        AudioRecorderManager.Dependencies(
            configureRecordSession: { [weak self] in
                self?.configureRecordSessionCallCount += 1
            },
            makeRecordingURL: { [weak self] in
                self?.createdURLs.append(recordingURL)
                return recordingURL
            },
            makeRecorder: { [weak self] _, _ in
                guard let self else {
                    throw CocoaError(.coderInvalidValue)
                }

                return self.recorder
            },
            sleep: { _ in },
            removeFile: { [weak self] url in
                self?.removedURLs.append(url)
            }
        )
    }

}

// FloeAppTests — Continuous voice conversation: coordinator state machine.
//
// SPDX-License-Identifier: MPL-2.0
//
// Focused regression coverage for the independent continuous-voice session
// (NOT the composer dictation surface). All I/O is faked: no microphone, no
// Speech framework, no audio session, no clock — the kernel is driven with
// scripted transcripts/levels and a virtual clock so the settled product
// rules are pinned exactly:
//   - 900 ms endpointing with the 1.6 s incomplete-phrase extension;
//   - hesitation/noise-only turns never send, short valid turns ("好") do;
//   - barge-in pauses tentatively at the SAME position, confirms only on a
//     valid ASR turn (persistence + ASR), and never cancels on amplitude;
//   - mute physically stops capture, keeps playback, never auto-submits;
//   - background/lock/route loss pause + cancel; resume is manual;
//   - confirmed-final-body-only speech (tool progress / commentary never
//     spoken, no speculative retract/replay);
//   - lossless bounded speech-unit lookahead (16) for very long answers;
//   - every callback is fenced by round token / session generation;
//   - receipts reflect ACTUALLY played frames, interrupted receipts included.
//
// Real microphone, AEC, route changes and iPad acceptance remain the app
// owner's device work; the simulator cannot capture audio by design.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
@testable import FloeApp

// MARK: - Fakes

@MainActor
final class VoiceTestClock: VoiceConversationScheduling {
    final class Timer: VoiceConversationScheduled {
        let deadline: Double
        var action: (@MainActor () -> Void)?
        var cancelled = false
        init(deadline: Double, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { cancelled = true; action = nil }
    }

    private(set) var now: TimeInterval = 0
    private var timers: [Timer] = []

    func schedule(after seconds: Double, action: @escaping @MainActor () -> Void) -> any VoiceConversationScheduled {
        let timer = Timer(deadline: now + seconds, action: action)
        timers.append(timer)
        return timer
    }

    func advance(by seconds: Double) {
        let target = now + seconds
        while true {
            let due = timers
                .filter { !$0.cancelled && $0.deadline <= target }
                .sorted { $0.deadline < $1.deadline }
            guard let first = due.first else { break }
            now = max(now, first.deadline)
            timers.removeAll { $0 === first }
            first.action?()
            first.action = nil
        }
        now = target
    }
}

final class VoiceTestAuth: VoiceConversationAuthorizationProviding, @unchecked Sendable {
    var microphoneGranted = true
    var speechGranted = true
    func requestMicrophoneAccess() async -> Bool { microphoneGranted }
    func requestSpeechRecognitionAccess() async -> Bool { speechGranted }
}

final class VoiceTestStack: VoiceConversationStack, @unchecked Sendable {
    var activateFailure: VoiceConversationFailure?
    var beginFailure: VoiceConversationFailure?
    /// Thrown by EVERY startCapture call on this stack — models a capture
    /// path that never delivers a real buffer (no readiness proof).
    var captureFailure: VoiceConversationFailure?
    /// Scripted stream-end cause returned by transcriptionFailureSnapshot()
    /// after `endTranscriptStream(failure:)`. Cleared by beginTranscription,
    /// mirroring the live stack's fresh-session reset.
    private var scriptedStreamFailure: VoiceConversationFailure?

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var storedTranscripts: AsyncStream<String>
    private var transcriptsSink: AsyncStream<String>.Continuation
    private var storedLevels: AsyncStream<VoiceConversationLevel>
    private var levelsSink: AsyncStream<VoiceConversationLevel>.Continuation
    private var storedPlayedLevels: AsyncStream<VoiceConversationLevel>
    private var playedSink: AsyncStream<VoiceConversationLevel>.Continuation
    let engineEvents: AsyncStream<VoiceConversationEngineEvent>
    private let engineSink: AsyncStream<VoiceConversationEngineEvent>.Continuation
    let systemEvents: AsyncStream<VoiceConversationSystemEvent>
    private let systemSink: AsyncStream<VoiceConversationSystemEvent>.Continuation

    private var epoch = 0
    private var scheduled = 0
    private var completed = 0

    let outputSampleRate: Double = 8_000

    var levels: AsyncStream<VoiceConversationLevel> { lock.withLock { storedLevels } }
    var playedLevels: AsyncStream<VoiceConversationLevel> { lock.withLock { storedPlayedLevels } }
    var transcripts: AsyncStream<String> { lock.withLock { storedTranscripts } }

    init() {
        (storedTranscripts, transcriptsSink) = AsyncStream.makeStream(of: String.self)
        // UNLIKE the live stack's droppable display sampling, the fake
        // delivers EVERY scripted level: the coordinator's recognition-health
        // clocks integrate REAL sample durations, so scripted bursts must
        // arrive complete and exact (newest(1) would silently drop all but
        // the last element of a synchronous test burst).
        (storedLevels, levelsSink) = AsyncStream.makeStream(of: VoiceConversationLevel.self, bufferingPolicy: .unbounded)
        (storedPlayedLevels, playedSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (engineEvents, engineSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (systemEvents, systemSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    func activate() async throws(VoiceConversationFailure) {
        increment("activate")
        if let activateFailure { throw activateFailure }
    }

    /// Async like the production seam: the real stack only returns after a
    /// genuine first tap buffer. The fake returns immediately UNLESS a
    /// scripted `captureFailure` models the dead-path readiness timeout.
    func startCapture() async throws(VoiceConversationFailure) {
        increment("startCapture")
        if let captureFailure { throw captureFailure }
    }

    func stopCapture() { increment("stopCapture") }

    func beginTranscription() async throws(VoiceConversationFailure) {
        let failure: VoiceConversationFailure? = lock.withLock {
            incrementLocked("begin")
            scriptedStreamFailure = nil
            guard beginFailure == nil else { return beginFailure }
            // Fresh stream per ASR session — the coordinator resubscribes
            // after an in-place restart.
            (storedTranscripts, transcriptsSink) = AsyncStream.makeStream(of: String.self)
            return nil
        }
        if let failure { throw failure }
    }

    func finishTranscription() async {
        let sink = lock.withLock { () -> AsyncStream<String>.Continuation in
            incrementLocked("finish")
            return transcriptsSink
        }
        sink.finish()
    }

    func transcriptionFailureSnapshot() -> VoiceConversationFailure? {
        lock.withLock { scriptedStreamFailure }
    }

    @discardableResult
    func scheduleChunk(_ chunk: VoiceConversationAudioChunk) -> Bool {
        let frames = VoiceConversationFrameMath.outputFrames(
            chunkFrames: chunk.frameCount,
            chunkSampleRate: chunk.sampleRate,
            outputSampleRate: outputSampleRate
        )
        lock.lock()
        defer { lock.unlock() }
        guard scheduled - completed + frames <= 400_000 else { return false }
        scheduled += frames
        return true
    }

    func endQueuedAudio() {}
    func pausePlayback() { increment("pause") }
    func resumePlayback() { increment("resume") }

    func stopPlayback() {
        lock.lock()
        epoch += 1
        scheduled = 0
        completed = 0
        incrementLocked("stopPlayback")
        lock.unlock()
        engineSink.yield(.playedFrames(0))
    }

    func deactivate() {
        increment("deactivate")
        lock.withLock {
            levelsSink.finish()
            playedSink.finish()
            engineSink.finish()
            systemSink.finish()
            transcriptsSink.finish()
        }
    }

    // Scripted drives
    func yieldTranscript(_ text: String) { lock.withLock { transcriptsSink }.yield(text) }
    func yieldLevel(_ level: Float, speech: Bool, duration: Double) {
        lock.withLock { levelsSink }.yield(
            VoiceConversationLevel(level: level, isSpeech: speech, duration: duration)
        )
    }
    func yieldPlayedLevel(_ level: Float) {
        lock.withLock { playedSink }.yield(
            VoiceConversationLevel(level: level, isSpeech: level > 0.1, duration: 0.08)
        )
    }
    func yieldSystem(_ event: VoiceConversationSystemEvent) { systemSink.yield(event) }
    func stepPlayed(frames: Int) {
        lock.lock()
        let capturedEpoch = epoch
        completed = min(scheduled, completed + frames)
        let value = completed
        lock.unlock()
        if capturedEpoch == lock.withLock({ epoch }) {
            engineSink.yield(.playedFrames(value))
        }
    }
    func endTranscriptStream(failure: VoiceConversationFailure?) {
        let sink = lock.withLock { () -> AsyncStream<String>.Continuation in
            scriptedStreamFailure = failure
            return transcriptsSink
        }
        sink.finish()
    }

    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    private func increment(_ key: String) { lock.withLock { incrementLocked(key) } }
    private func incrementLocked(_ key: String) { counts[key, default: 0] += 1 }
}

@MainActor
final class VoiceTestDriving: VoiceConversationTurnDriving {
    struct Start { let request: VoiceConversationTurnRequest; let send: VoiceConversationTurnSender }
    private(set) var starts: [Start] = []
    private(set) var cancelled: [VoiceConversationRoundToken] = []
    private(set) var receipts: [VoiceConversationSpeechReceipt] = []

    func startTurn(_ request: VoiceConversationTurnRequest, send: @escaping VoiceConversationTurnSender) {
        starts.append(Start(request: request, send: send))
    }
    func cancelTurn(_ token: VoiceConversationRoundToken) async { cancelled.append(token) }
    func reportSpeech(_ receipt: VoiceConversationSpeechReceipt) async { receipts.append(receipt) }
    func emit(_ token: VoiceConversationRoundToken, _ event: VoiceConversationTurnEvent) {
        starts.first { $0.request.token == token }?.send(event)
    }
    var lastToken: VoiceConversationRoundToken? { starts.last?.request.token }
}

@MainActor
final class VoiceEventLog {
    private(set) var events: [VoiceConversationSpeechEvent] = []
    private var task: Task<Void, Never>?
    func start(_ stream: AsyncStream<VoiceConversationSpeechEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }
    var units: [VoiceConversationSpeechUnit] {
        events.compactMap { if case .unitQueued(let unit) = $0 { return unit }; return nil }
    }
    var completed: [VoiceConversationSpeechUnit] {
        events.compactMap { if case .unitCompleted(let unit) = $0 { return unit }; return nil }
    }
    var roundTextCompleted: Int? {
        for event in events.reversed() {
            if case .roundTextCompleted(_, let count) = event { return count }
        }
        return nil
    }
    var drained: Bool { events.contains { if case .outputDrained = $0 { return true }; return false } }
    var maxOutstanding: Int {
        var live = 0, peak = 0
        for event in events {
            switch event {
            case .unitQueued: live += 1
            case .unitCompleted: live -= 1
            default: break
            }
            peak = max(peak, live)
        }
        return peak
    }
}

@MainActor
private final class VoiceRig {
    let auth = VoiceTestAuth()
    let driving = VoiceTestDriving()
    let clock = VoiceTestClock()
    let log = VoiceEventLog()
    private(set) var stacks: [VoiceTestStack] = []
    var pendingActivateFailure: VoiceConversationFailure?
    /// Applied to the NEXT created stack exactly once (the rebuild scenario:
    /// the first stack's capture never becomes ready, the rebuilt one works).
    var pendingCaptureFailure: VoiceConversationFailure?
    /// Applied to EVERY stack (nothing rebuilds successfully).
    var stickyCaptureFailure: VoiceConversationFailure?
    /// Applied to EVERY stack's activate (a permanently dead audio engine).
    var stickyActivateFailure: VoiceConversationFailure?
    private(set) var coordinator: VoiceConversationCoordinator! = nil

    init(speechNormalizer: @escaping @Sendable (String) -> String = { $0 },
         timing: VoiceConversationCoordinator.Timing = .init()) {
        coordinator = VoiceConversationCoordinator(
            authorization: auth,
            makeStack: { [weak self] in
                let stack = VoiceTestStack()
                if let failure = self?.pendingActivateFailure {
                    stack.activateFailure = failure
                    self?.pendingActivateFailure = nil
                }
                if let failure = self?.pendingCaptureFailure {
                    stack.captureFailure = failure
                    self?.pendingCaptureFailure = nil
                }
                if let failure = self?.stickyCaptureFailure {
                    stack.captureFailure = failure
                }
                if let failure = self?.stickyActivateFailure {
                    stack.activateFailure = failure
                }
                self?.stacks.append(stack)
                return stack
            },
            driving: driving,
            clock: clock,
            diagnostics: nil,
            timing: timing,
            speechNormalizer: speechNormalizer
        )
        log.start(coordinator.speechEvents)
    }

    var stack: VoiceTestStack { stacks.last! }

    func settle(_ milliseconds: UInt64 = 8) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        await Task.yield()
        await Task.yield()
    }

    /// Deterministic cross-task sync: the levels and transcripts streams are
    /// consumed by two independent MainActor tasks, so a blind sleep cannot
    /// pin which one has run. Poll a published product effect instead (each
    /// poll yields the MainActor so pending consumer jobs run); a timeout is a
    /// real test failure, never a silent pass.
    func waitUntil(_ timeoutMilliseconds: UInt64 = 10_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var waited: UInt64 = 0
        while !condition() {
            guard waited < timeoutMilliseconds else { return false }
            await settle(10)
            waited += 10
        }
        return true
    }

    func say(_ text: String) async {
        stack.yieldTranscript(text)
        await settle()
    }

    func answer(_ display: String) async {
        guard let token = coordinator.currentRound else { return }
        driving.emit(token, .answerUpdated(cumulativeText: display))
        await settle()
    }

    /// Production sequence: display text streams first, then the ONE
    /// confirmed final body drives all speech.
    func confirmFinal(_ text: String, display: String = "") async {
        if !display.isEmpty { await answer(display) }
        guard let token = coordinator.currentRound else { return }
        driving.emit(token, .completed(fullText: text))
        await settle()
    }

    /// Plays queued units like the app bridge (one 100-frame chunk each).
    func playQueued() async {
        await settle()
        for unit in log.units {
            let chunk = VoiceConversationAudioChunk(
                samples: [Float](repeating: 0.2, count: 100),
                channelCount: 1,
                sampleRate: 8_000
            )
            _ = coordinator.appendAudio(chunk, to: unit)
            coordinator.endUnit(unit)
        }
        if let token = coordinator.currentRound, let count = log.roundTextCompleted,
           log.units.count >= count {
            coordinator.endRoundAudio(token)
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Continuous voice coordinator state machine")
struct VoiceConversationTests {

    @Test("Happy path: endpoint sends once, confirmed body speaks, receipt is completed")
    func happyPath() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .listening)

        await rig.say("今天天气怎么样")
        #expect(rig.coordinator.stagedTranscript == "今天天气怎么样")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "今天天气怎么样")
        #expect(rig.coordinator.state == .waitingModel)

        // Display commentary must NOT speak; the confirmed body does.
        await rig.answer("正在想你问的天气。")
        #expect(rig.log.units.isEmpty)
        await rig.confirmFinal("今天晴。", display: "正在想你问的天气。")
        #expect(rig.log.units.map(\.text) == ["今天晴。"])
        #expect(rig.coordinator.state == .answering)

        await rig.playQueued()
        rig.stack.stepPlayed(frames: 100)
        await rig.settle()
        #expect(rig.log.completed.count == 1)
        #expect(rig.coordinator.state == .listening)
        await rig.settle(30)
        #expect(rig.driving.receipts.last?.status == .completed)
        #expect(rig.driving.receipts.last?.spokenText == "今天晴。")
    }

    @Test("Incomplete phrasing extends the endpoint window to 1.6 s")
    func incompleteExtension() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("我先查一下，然后")
        rig.clock.advance(by: 1.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        rig.clock.advance(by: 0.7)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("Hesitation-only text never sends; short valid answers do")
    func turnValidity() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("嗯。")
        rig.clock.advance(by: 2.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)
        #expect(rig.coordinator.stagedTranscript.isEmpty)

        await rig.say("好")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "好")
    }

    @Test("send-now bypasses the endpoint and rejects emptiness")
    func sendNow() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        rig.coordinator.sendNow()
        #expect(rig.driving.starts.isEmpty)
        await rig.say("不对")
        rig.coordinator.sendNow()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "不对")
    }

    @Test("Barge-in pauses tentatively; a valid ASR turn cancels exactly and fences late events")
    func bargeInConfirm() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("讲个故事")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("从前。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 50)
        await rig.settle()

        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        rig.stack.yieldLevel(0.6, speech: true, duration: 0.1)
        await rig.settle()
        #expect(rig.coordinator.suspectingSpeech)
        #expect(rig.stack.count("pause") == 1)
        #expect(rig.coordinator.currentRound != nil)   // amplitude alone: no cancel

        await rig.say("等一下")
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.coordinator.stagedTranscript == "等一下")

        if let stale = rig.driving.starts.first?.request.token {
            rig.driving.emit(stale, .answerUpdated(cumulativeText: "迟到"))
        }
        #expect(!rig.coordinator.answerText.contains("迟到"))

        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 2)
        let context = rig.driving.starts.count > 1
            ? rig.driving.starts[1].request.previousInterruptedAnswer : nil
        #expect(context?.answerText == "从前。")
        // A partially played sentence is never claimed as fully heard.
        #expect(context?.spokenText.isEmpty == true)
        #expect((context?.speechFraction ?? 0) > 0)
        await rig.settle(30)
        #expect(rig.driving.receipts.contains { $0.status == .interrupted })
    }

    @Test("False start resumes the same position; long amplitude never cancels")
    func bargeFalseStart() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("念诗")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        // Canonical production shape: the ONE confirmed final body arrives at
        // `.completed` with NO prior display event — its first content is the
        // durable body itself.
        await rig.confirmFinal("床前明月光。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 40)
        await rig.settle()
        // The root invariant: 40 REAL frames of the confirmed body are out of
        // the speaker, so the session must present actual speech playback,
        // never "waiting for model".
        #expect(rig.coordinator.state == .answering)
        #expect(rig.coordinator.currentSpokenText == "床前明月光。")
        let round = rig.coordinator.currentRound
        let progress = rig.coordinator.playingUnitProgress
        #expect(progress?.index == 0)
        #expect(progress?.fraction == 0.4)
        // Setup/projection lifecycles may already have stopped output; the
        // barge pause → false-start resume itself must add no stop/reset.
        let stopBaseline = rig.stack.count("stopPlayback")

        rig.stack.yieldLevel(0.7, speech: true, duration: 0.2)
        await rig.settle()
        #expect(rig.stack.count("pause") == 1)
        #expect(rig.coordinator.state == .answering)     // tentative pause keeps the round
        rig.stack.yieldLevel(0, speech: false, duration: 0.15)
        rig.stack.yieldLevel(0, speech: false, duration: 0.15)
        await rig.settle()
        #expect(rig.stack.count("resume") == 1)
        #expect(rig.stack.count("stopPlayback") == stopBaseline)  // no stop: position kept
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound == round)   // same round
        // Same played position: (tuple is Equatable-free, compare members).
        #expect(rig.coordinator.playingUnitProgress?.index == progress?.index)
        #expect(rig.coordinator.playingUnitProgress?.fraction == progress?.fraction)
        #expect(rig.coordinator.state == .answering)

        for _ in 0..<12 { rig.stack.yieldLevel(0.8, speech: true, duration: 0.1) }
        await rig.settle()
        #expect(rig.driving.cancelled.isEmpty)
        #expect(rig.coordinator.currentRound != nil)
    }

    @Test("Interrupt while waiting for the model cancels exactly and listens")
    func interruptWhileWaiting() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("写长文")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        rig.coordinator.interruptNow()
        await rig.settle(30)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.driving.receipts.isEmpty)   // no audio ever played
    }

    @Test("Background pause retains the draft; resume joins it with the next partial")
    func pauseResume() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("这句话没说完")
        rig.coordinator.pauseForScene(.background)
        await rig.settle(40)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.stagedTranscript == "这句话没说完")
        #expect(rig.stacks.count == 1)

        await rig.coordinator.resume()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        #expect(rig.stacks.count == 2)
        await rig.say("继续说下去")
        #expect(rig.coordinator.stagedTranscript.contains("这句话没说完"))
        #expect(rig.coordinator.stagedTranscript.contains("继续说下去"))
        rig.clock.advance(by: 1.0)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text.contains("继续说下去"))
    }

    @Test("Route loss pauses, cancels generation and never reroutes silently")
    func routeLoss() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("放音乐介绍")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("介绍一。")
        rig.stack.stepPlayed(frames: 10)
        rig.stack.yieldSystem(.routeLost)
        await rig.settle(40)
        #expect(rig.coordinator.state == .paused)
        #expect(rig.coordinator.pausedReason == .routeLost)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.stack.count("resume") == 0)
    }

    @Test("Mute stops capture, keeps the draft, never auto-sends")
    func mute() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("好的")
        await rig.coordinator.setMuted(true)
        await rig.settle()
        #expect(rig.stack.count("stopCapture") == 1)
        #expect(rig.coordinator.stagedTranscript == "好的")
        rig.clock.advance(by: 5.0)
        await rig.settle()
        #expect(rig.driving.starts.isEmpty)

        await rig.coordinator.setMuted(false)
        await rig.settle()
        #expect(rig.stack.count("startCapture") == 2)
        #expect(rig.driving.starts.isEmpty)   // no auto-submit of a muted draft
        await rig.say("好的，明天呢")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "好的，明天呢")
    }

    @Test("end() hands the pending transcript to the host exactly once")
    func endSummary() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        var summary: VoiceConversationSessionSummary?
        rig.coordinator.onSessionEnded = { summary = $0 }
        await rig.say("未发送的草稿")
        rig.coordinator.end()
        await rig.settle(50)
        #expect(rig.coordinator.state == .idle)
        #expect(summary?.pendingTranscript == "未发送的草稿")
        #expect(rig.stack.count("deactivate") == 1)
    }

    @Test("Permission denial fails before any stack exists")
    func permissionDenied() async {
        let rig = VoiceRig()
        rig.auth.microphoneGranted = false
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .failed(.microphonePermissionDenied))
        #expect(rig.stacks.isEmpty)

        let rig2 = VoiceRig()
        rig2.auth.speechGranted = false
        await rig2.coordinator.start()
        #expect(rig2.coordinator.state == .failed(.speechPermissionDenied))
    }

    @Test("Activation failure (simulator/no audio) rebuilds once, then surfaces")
    func activationFailure() async {
        let rig = VoiceRig()
        rig.pendingActivateFailure = .noAudioInput
        await rig.coordinator.start()
        // A one-shot failure is RECOVERED by the single rebuild budget.
        #expect(rig.coordinator.state == .listening)
        #expect(rig.stacks.count == 2)
        #expect(rig.stacks[0].count("deactivate") == 1)

        let dead = VoiceRig()
        dead.stickyActivateFailure = .noAudioInput
        await dead.coordinator.start()
        #expect(dead.coordinator.state == .failed(.noAudioInput))
        #expect(dead.stacks.count == 2)          // exactly one rebuild attempt
        #expect(dead.stacks[1].count("deactivate") == 1)
    }

    // MARK: - Live-input no-response regressions (job 2026-10-23)

    @Test("Dead capture readiness: one full recoverable rebuild, then visible failure")
    func captureReadinessRebuildThenFail() async {
        let rig = VoiceRig()
        rig.stickyCaptureFailure = .noAudioInput
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .failed(.noAudioInput))
        #expect(rig.stacks.count == 2)
        #expect(rig.stacks.allSatisfy { $0.count("deactivate") == 1 })
    }

    @Test("Capture readiness failure rebuilds successfully on the second stack")
    func captureReadinessRebuildRecovers() async {
        let rig = VoiceRig()
        rig.pendingCaptureFailure = .noAudioInput
        await rig.coordinator.start()
        #expect(rig.coordinator.state == .listening)
        #expect(rig.stacks.count == 2)
        #expect(rig.stacks[0].count("deactivate") == 1)
        #expect(rig.stacks[1].count("startCapture") == 1)
    }

    @Test("Model/locale preparation failures are NOT rebuild-recoverable")
    func modelNotReadyFailsWithoutRebuild() async {
        let rig = VoiceRig()
        let first = VoiceTestStack()
        first.beginFailure = .modelNotReady
        let failingCoordinator = VoiceConversationCoordinator(
            authorization: VoiceTestAuth(),
            makeStack: { first },
            driving: rig.driving,
            clock: rig.clock,
            diagnostics: nil,
            timing: .init()
        )
        await failingCoordinator.start()
        #expect(failingCoordinator.state == .failed(.modelNotReady))
        #expect(first.count("begin") == 1)
        #expect(first.count("deactivate") == 1)   // no second build
    }

    @Test("Speech with NO recognition fails visibly inside the limit")
    func voicedWithoutTextFailsVisibly() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // 41 × 0.2 s = 8.2 s of REAL voiced audio, zero transcripts.
        for _ in 0..<41 {
            rig.stack.yieldLevel(0.55, speech: true, duration: 0.2)
        }
        await rig.settle(30)
        #expect(rig.coordinator.state == .failed(.recognizerFailed))
        #expect(rig.stack.count("begin") == 1)   // failed, not silently restarted
    }

    @Test("Transcript text resets the speech-without-recognition clock")
    func voicedClockResetsOnText() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // Both the levels and the transcripts observer are separate MainActor
        // tasks: the two synchronous bursts below are buffered, not consumed.
        // A blind sleep could let the transcript's clock reset land in the
        // MIDDLE of the first burst, so the samples still queued behind it
        // would count against the reset (double-counting one utterance).
        // Fence each side explicitly on published product effects instead:
        // the levels stream is FIFO, so a distinguishable terminal level
        // proves the whole burst was counted before the text is injected.
        for _ in 0..<29 { rig.stack.yieldLevel(0.5, speech: true, duration: 0.2) }   // 5.8 s
        rig.stack.yieldLevel(0.42, speech: true, duration: 0.2)                       // 6 s, sentinel
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.42 })
        await rig.say("你好")
        // consumeTranscript zeroes the speech-without-recognition clock before
        // it publishes the staged text, so this proves the reset is applied.
        #expect(await rig.waitUntil { rig.coordinator.stagedTranscript == "你好" })
        for _ in 0..<29 { rig.stack.yieldLevel(0.5, speech: true, duration: 0.2) }   // +5.8 s voiced
        rig.stack.yieldLevel(0.41, speech: true, duration: 0.2)                       // +6 s, fresh sentinel
        #expect(await rig.waitUntil { rig.coordinator.audioLevel == 0.41 })
        // 6 s of voiced audio since the transcript → below the 8 s cap.
        #expect(rig.coordinator.state == .listening)
        // And the utterance still endpoints normally.
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("Pure silence is legitimate forever: no levels-timeout failure")
    func silenceIsLegitimate() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // 200 silent buffers spanning ~60 s + clock advance far past every
        // failure window. Silence must stay "Listening".
        for _ in 0..<200 { rig.stack.yieldLevel(0, speech: false, duration: 0.3) }
        rig.clock.advance(by: 120)
        await rig.settle(30)
        #expect(rig.coordinator.state == .listening)
        #expect(rig.stack.count("begin") == 1)
        // Speech is still recognized afterwards.
        await rig.say("安静之后说话")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "安静之后说话")
    }

    @Test("Healthy long-silence Apple auto-end renews and still recognizes later speech")
    func silenceRenewalKeepsSessionAlive() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        // Three renewal cycles: ~40 s of silent buffers, then the backend
        // finalizes its stream on its own (no failure). Renewals never
        // count as consecutive failures.
        for _ in 0..<3 {
            for _ in 0..<200 { rig.stack.yieldLevel(0, speech: false, duration: 0.2) }  // 40 s
            rig.stack.endTranscriptStream(failure: nil)
            await rig.settle(30)
            #expect(rig.coordinator.state == .listening)
        }
        #expect(rig.stack.count("begin") == 4)
        // The 60+ s-silence acceptance: speech after renewals is recognized
        // and submitted.
        await rig.say("很久之后说话了")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
        #expect(rig.driving.starts[0].request.text == "很久之后说话了")
    }

    @Test("Speech-with-no-recognition stream deaths are capped at two restarts")
    func textlessSpeechfulRestartsCapped() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        for cycle in 1...3 {
            for _ in 0..<2 { rig.stack.yieldLevel(0.6, speech: true, duration: 0.2) } // 0.4 s voiced
            rig.stack.endTranscriptStream(failure: nil)
            await rig.settle(30)
            if cycle < 3 {
                #expect(rig.coordinator.state == .listening)
                #expect(rig.stack.count("begin") == cycle + 1)
            }
        }
        #expect(rig.coordinator.state == .failed(.recognizerFailed))
        #expect(rig.stack.count("begin") == 3)   // start + exactly two restarts
    }

    @Test("Rapid empty terminations (no speech, no text, short-lived) are capped")
    func rapidEmptyRestartsCapped() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        for cycle in 1...3 {
            for _ in 0..<5 { rig.stack.yieldLevel(0, speech: false, duration: 0.2) }  // 1 s lived
            rig.stack.endTranscriptStream(failure: nil)
            await rig.settle(30)
            if cycle < 3 {
                #expect(rig.coordinator.state == .listening)
            }
        }
        #expect(rig.coordinator.state == .failed(.recognizerFailed))
        #expect(rig.stack.count("begin") == 3)
    }

    @Test("A backend error (server unavailable) fails the session immediately")
    func backendStreamErrorPropagates() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        rig.stack.endTranscriptStream(failure: .recognizerFailed)
        await rig.settle(30)
        #expect(rig.coordinator.state == .failed(.recognizerFailed))
        #expect(rig.stack.count("begin") == 1)   // no silent restart over a dead backend
    }

    @Test("captureStalled (tap stopped firing) fails visibly with no-audio-input")
    func captureStallFailsSession() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        rig.stack.yieldSystem(.captureStalled)
        await rig.settle(30)
        #expect(rig.coordinator.state == .failed(.noAudioInput))
    }

    @Test("A failed session can be explicitly retried with a fresh stack")
    func failedSessionRetryStartsFresh() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        rig.stack.yieldSystem(.captureStalled)
        await rig.settle(30)
        #expect(rig.coordinator.state == .failed(.noAudioInput))
        await rig.coordinator.start()
        await rig.settle()
        #expect(rig.coordinator.state == .listening)
        #expect(rig.stacks.count == 2)
        await rig.say("重试后说话")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        #expect(rig.driving.starts.count == 1)
    }

    @Test("Unmute re-proves readiness: a dead path fails visibly instead of listening")
    func unmuteReadinessFailure() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.coordinator.setMuted(true)
        await rig.settle()
        rig.stack.captureFailure = .noAudioInput
        await rig.coordinator.setMuted(false)
        await rig.settle(30)
        #expect(rig.coordinator.state == .failed(.noAudioInput))
    }

    @Test("ASR stream end restarts transcription in place and keeps the draft")
    func transcriptionRestart() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("你好")
        rig.stack.endTranscriptStream(failure: nil)
        await rig.settle(30)
        #expect(rig.stack.count("begin") == 2)
        #expect(rig.coordinator.state == .listening)
        await rig.say("今天如何")
        #expect(rig.coordinator.stagedTranscript.contains("你好"))
        #expect(rig.coordinator.stagedTranscript.contains("今天如何"))
    }

    @Test("submitText uses the same scheduler; active round is cancelled first")
    func submitText() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        #expect(await rig.coordinator.submitText("") == false)
        #expect(await rig.coordinator.submitText("打字输入") == true)
        #expect(rig.driving.starts.count == 1)

        #expect(await rig.coordinator.submitText("改主意") == true)
        #expect(rig.driving.cancelled.count == 1)
        #expect(rig.driving.starts.count == 2)
        #expect(rig.driving.starts[1].request.text == "改主意")

        rig.coordinator.pauseForScene(.background)
        await rig.settle(40)
        #expect(await rig.coordinator.submitText("安静") == false)
        #expect(rig.driving.starts.count == 2)
    }

    @Test("New session generation fences all prior async callbacks")
    func generationFencing() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("第一轮")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        let old = rig.driving.starts[0].request.token
        rig.coordinator.end()
        await rig.settle(50)
        await rig.coordinator.start()
        rig.driving.emit(old, .answerUpdated(cumulativeText: "旧轮迟到"))
        rig.driving.emit(old, .completed(fullText: "旧轮迟到"))
        #expect(rig.coordinator.answerText.isEmpty)
        #expect(rig.coordinator.stagedTranscript.isEmpty)
    }

    @Test("Played-output amplitude surfaces; caption follows the playing unit")
    func metersAndCaption() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        rig.stack.yieldPlayedLevel(0.42)
        await rig.settle()
        #expect(abs(rig.coordinator.outputLevel - 0.42) < 0.001)

        await rig.say("两句")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("第一句。第二句。")
        await rig.playQueued()
        rig.stack.stepPlayed(frames: 100)
        await rig.settle()
        #expect(rig.coordinator.currentSpokenText == "第二句。")
    }

    @Test("Long answer: lossless bounded lookahead (300 sentences)")
    func longAnswerLookahead() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("长回答")
        rig.clock.advance(by: 0.95)
        await rig.settle()

        var full = ""
        for index in 1...300 { full += "句子\(index)。" }
        await rig.confirmFinal(full)

        #expect(rig.log.maxOutstanding <= 16)
        var iterations = 0
        while iterations < 3_000 {
            iterations += 1
            await rig.playQueued()
            rig.stack.stepPlayed(frames: 100)
            await rig.settle(2)
            if rig.log.drained { break }
        }
        #expect(rig.log.units.count == 300)
        #expect(Set(rig.log.units.map(\.id)).count == 300)
        #expect(rig.log.units.map(\.index) == Array(0..<300))
        #expect(rig.log.units.first?.text == "句子1。")
        #expect(rig.log.roundTextCompleted == 300)
        #expect(rig.log.maxOutstanding <= 16)
        #expect(rig.log.completed.count == 300)
        await rig.settle(30)
        #expect(rig.driving.receipts.last?.status == .completed)
        #expect(rig.driving.receipts.last?.spokenText == full)
    }

    @Test("Capacity rejection recovers; stale and invalid chunks are refused")
    func speechAppendGuards() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("大音频")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("一。二。三。")
        let units = rig.log.units
        #expect(units.count == 3)

        let big = VoiceConversationAudioChunk(
            samples: [Float](repeating: 0.1, count: 200_000),
            channelCount: 1,
            sampleRate: 8_000
        )
        #expect(rig.coordinator.appendAudio(big, to: units[0]) == .accepted)
        #expect(rig.coordinator.appendAudio(big, to: units[1]) == .rejectedOverCapacity)
        rig.stack.stepPlayed(frames: 200_000)
        await rig.settle()
        #expect(rig.coordinator.appendAudio(big, to: units[1]) == .accepted)

        let invalid = VoiceConversationAudioChunk(
            samples: [Float.nan], channelCount: 1, sampleRate: 8_000
        )
        #expect(rig.coordinator.appendAudio(invalid, to: units[2]) == .rejectedInvalidFormat)
        for unit in units { rig.coordinator.endUnit(unit) }
        if let token = rig.coordinator.currentRound {
            rig.coordinator.endRoundAudio(token)
        }
        rig.stack.stepPlayed(frames: 400_000)
        await rig.settle(30)
        let stale = VoiceConversationAudioChunk(
            samples: [0.1], channelCount: 1, sampleRate: 8_000
        )
        #expect(rig.coordinator.appendAudio(stale, to: units[2]) == .rejectedStale)
    }
}

// MARK: - Bounded drain race (voice handoff deadline)

/// Deliberately NONCOOPERATIVE suspension: no cancellation handler; only
/// `release()` wakes it. Models `await stoppedTask.value` behind a drain
/// task that never checks cancellation — the exact shape that made the old
/// `withTaskGroup` join unbounded ("Connecting…" forever).
private final class VoiceDrainSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var releaseCount = 0

    func suspend() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if releaseCount > 0 {
                lock.unlock()
                c.resume()
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        releaseCount += 1
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

private final class VoiceDrainFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class VoiceDrainCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// The exact `ContinuousVoiceScreenSession.boundedJoin` type pattern: a
/// `@MainActor @Sendable` operation handed to the Foundation-only deadline
/// race through a plain `{ await operation() }` hop.
@MainActor
private func voiceBoundedJoinReplica(
    seconds: Double,
    _ operation: @escaping @MainActor @Sendable () async -> Void
) async {
    await VoiceConversationBoundedDrain.race(seconds: seconds) {
        await operation()
    }
}

/// Self-bounding join so a wedged implementation FAILS instead of hanging the
/// test run: the inner race is joined through the race itself with a watchdog.
private func voiceDrainJoinWithWatchdog(
    _ inner: Task<VoiceConversationDrainGate.Outcome, Never>,
    watchdog: Double
) async -> (returned: Bool, outcome: VoiceConversationDrainGate.Outcome?) {
    let gate = await VoiceConversationBoundedDrain.race(seconds: watchdog) { _ = await inner.value }
    guard gate == .completed else { return (false, nil) }
    return (true, await inner.value)
}

@Suite("Bounded drain race (voice handoff deadline)")
private struct VoiceBoundedDrainRaceTests {
    @Test("The gate is exactly-once: only the first event settles it")
    func gateExactlyOnce() {
        let gate = VoiceConversationDrainGate()
        #expect(gate.outcome == nil)
        #expect(gate.resolve(.completed))
        #expect(!gate.resolve(.deadline))
        #expect(!gate.resolve(.cancelled))
        #expect(gate.outcome == .completed)
    }

    @Test("A cooperative drain that finishes first wins before the deadline")
    func completedWins() async {
        let started = ContinuousClock.now
        let outcome = await VoiceConversationBoundedDrain.race(seconds: 30) {}
        #expect(outcome == .completed)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("Deadline returns despite a suspended uncooperative drain; a late release completes exactly once and never re-resolves")
    func deadlineBeatsUncooperativeDrain() async throws {
        let suspension = VoiceDrainSuspension()
        let cancelledAtRelease = VoiceDrainFlagBox()
        let lateCompletions = VoiceDrainCounterBox()
        let started = ContinuousClock.now
        let inner = Task {
            await VoiceConversationBoundedDrain.race(seconds: 0.2) {
                await suspension.suspend()
                cancelledAtRelease.set(Task.isCancelled)
                lateCompletions.increment()
            }
        }
        let joined = await voiceDrainJoinWithWatchdog(inner, watchdog: 5)
        #expect(joined.returned, "watchdog fired: the structured-scope wait regressed (uncooperative drain blocked the join)")
        guard joined.returned, let outcome = joined.outcome else { return }
        #expect(outcome == .deadline)
        #expect(started.duration(to: .now) < .seconds(4), "resolved near the 0.2 s deadline, not the watchdog")
        // Late release of the ABANDONED drain: it must not resume the caller
        // again (a double CheckedContinuation resume would crash the process)
        // and must not flip the settled outcome.
        suspension.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lateCompletions.count == 1)
        #expect(cancelledAtRelease.isSet, "the deadline loser must receive cancellation")
        let restated = await inner.value
        #expect(restated == .deadline, "a late completion cannot re-resolve the race")
    }

    @Test("A cancelled start resolves promptly; the abandoned drain stays fenced and harmless")
    func cancelledStartResolvesPromptly() async throws {
        let suspension = VoiceDrainSuspension()
        let started = ContinuousClock.now
        let racer = Task {
            await VoiceConversationBoundedDrain.race(seconds: 60) { await suspension.suspend() }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        racer.cancel()
        let joined = await voiceDrainJoinWithWatchdog(racer, watchdog: 5)
        #expect(joined.returned, "cancellation must resolve the race promptly, not wait the 60 s deadline")
        #expect(joined.outcome == .cancelled)
        #expect(started.duration(to: .now) < .seconds(4))
        // Teardown: releasing the abandoned drain late must be swallowed by
        // the exactly-once gate (no crash, no re-resolution).
        suspension.release()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test("Cancellation arriving during registration still resolves exactly once")
    func cancellationDuringRegistration() async throws {
        let suspension = VoiceDrainSuspension()
        let racer = Task {
            await VoiceConversationBoundedDrain.race(seconds: 30) { await suspension.suspend() }
        }
        racer.cancel()
        let joined = await voiceDrainJoinWithWatchdog(racer, watchdog: 5)
        #expect(joined.returned)
        if let outcome = joined.outcome {
            #expect(outcome == .cancelled || outcome == .completed)
        }
        suspension.release()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test("MainActor handoff ordering: the synchronous engine stop happens before proceeding, despite the abandoned drain")
    @MainActor func synchronousStopBeforeNewOwnership() async throws {
        let suspension = VoiceDrainSuspension()
        let stopDone = VoiceDrainFlagBox()
        let newOwnerActive = VoiceDrainFlagBox()
        newOwnerActive.set(true)
        let handoff = Task { @MainActor in
            await voiceBoundedJoinReplica(seconds: 0.2) {
                stopDone.set(true)      // the synchronous physical stop
                await suspension.suspend() // trailing async drain, uncooperative
            }
        }
        let gate = await VoiceConversationBoundedDrain.race(seconds: 5) { _ = await handoff.value }
        #expect(gate == .completed, "the MainActor handoff must return at the deadline")
        #expect(stopDone.isSet, "proceeding is only safe because the synchronous stop already ran")
        suspension.release()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(newOwnerActive.isSet, "the late drain tail must not touch the new owner")
    }

    @Test("Degenerate deadlines and repeated stress resolve without deadlock or double resume")
    func edgesAndStress() async throws {
        let zero = await VoiceConversationBoundedDrain.race(seconds: 0) {}
        #expect(zero == .deadline || zero == .completed)
        let negative = await VoiceConversationBoundedDrain.race(seconds: -5) {}
        #expect(negative == .deadline || negative == .completed)
        let nan = await VoiceConversationBoundedDrain.race(seconds: Double.nan) {}
        #expect(nan == .deadline || nan == .completed)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let suspension = VoiceDrainSuspension()
                    let inner = Task {
                        await VoiceConversationBoundedDrain.race(seconds: 0.15) { await suspension.suspend() }
                    }
                    let joined = await voiceDrainJoinWithWatchdog(inner, watchdog: 4)
                    #expect(joined.returned && joined.outcome == .deadline)
                    suspension.release()
                }
                group.addTask {
                    let suspension = VoiceDrainSuspension()
                    let racer = Task {
                        await VoiceConversationBoundedDrain.race(seconds: 30) { await suspension.suspend() }
                    }
                    racer.cancel()
                    let joined = await voiceDrainJoinWithWatchdog(racer, watchdog: 4)
                    #expect(joined.returned)
                    suspension.release()
                }
            }
        }
    }
}
#endif

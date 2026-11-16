import XCTest
import Foundation
import AVFoundation
import FloeCore
@testable import FloeProviders
import FloeSecurity
@testable import FloeApp

final class CloudASRPreloadIntegrationTests: XCTestCase {
    @MainActor
    func testRecognitionStartupReadsOnlySelectedCloudCredential() throws {
        let suite = "floe.asr.startup.selected." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CountingASRKeychain()
        let store = CloudASRSettingsStore(defaults: defaults, keychain: credentials,
                                          legacyKeychain: credentials)
        let selected = try store.addProfile(.openAICompatible(name: "Selected"), credential: "selected-test-key")
        for index in 0..<8 {
            _ = try store.addProfile(.openAICompatible(name: "Other \(index)"), credential: "other-test-key")
        }
        credentials.resetReads()
        let route = store.primaryRouteResolution(method: CloudASRMethod.cloud)
        XCTAssertEqual(route.cloudProfile?.id, selected.id)
        XCTAssertEqual(credentials.readCount, 1, "Startup must not probe unrelated profile credentials")

        credentials.failReads = true
        credentials.resetReads()
        XCTAssertEqual(store.primaryRouteResolution(method: CloudASRMethod.cloud).route, .cloudUnavailable)
        XCTAssertEqual(credentials.readCount, 1, "A locked selected key must not silently switch providers")
    }

    func testDeepSeekContinuousSpeechEmitsCompletedSegmentsBeforeStop() async throws {
        let file = RecordingBatchASR()
        let transcriber = try CloudSpeechTranscriber(
            profile: .deepSeek(), language: .english,
            adapters: CloudSpeechAdapters(file: { _ in file }, live: { _ in nil }),
            credentialProvider: { "synthetic-key" }, localFallback: { nil })
        let collected = Task {
            var values: [String] = []
            for await text in transcriber.transcripts { values.append(text) }
            return values
        }
        for _ in 0..<9 { transcriber.feed(try cloudVoiceBuffer(seconds: 1, voiced: true), at: nil) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, file.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(file.count, 1, "a long utterance must produce a segment before capture stops")
        await transcriber.finishAudio()
        let values = await collected.value
        XCTAssertEqual(values.last, "segment 1 segment 2")
        XCTAssertEqual(file.count, 2)
    }
    func testLiveHypothesisRevisionsReplaceOnlyTheCurrentPartial() {
        let box = CloudLiveEventBox()
        let turn = UUID()
        box.apply(.partial(turnID: turn, itemID: "utterance", delta: "This is.", sequence: 1))
        XCTAssertEqual(box.snapshot().partial, "This is.")
        box.apply(.partialReplacement(turnID: turn, itemID: "utterance",
                                      transcript: "This is a streaming.", sequence: 2))
        XCTAssertEqual(box.snapshot().partial, "This is a streaming.")
        box.apply(.partialReplacement(turnID: turn, itemID: "utterance",
                                      transcript: "This is a streaming test", sequence: 3))
        box.apply(.partial(turnID: turn, itemID: "utterance", delta: ".", sequence: 4))
        XCTAssertEqual(box.snapshot().partial, "This is a streaming test.")
        box.apply(.final(turnID: turn, itemID: "utterance",
                         transcript: "This is a streaming test.", sequence: 5))
        XCTAssertEqual(box.snapshot().final, "This is a streaming test.")
    }

    @MainActor
    func testVolcenginePresetsSelectTheLiveAdapterWithoutChangingBillingRoute() throws {
        for preset in [CloudASRSettingsStore.ProviderPreset.volcengineAgentPlan, .volcenginePayAsYouGo] {
            let profile = preset.makeProfile()
            XCTAssertEqual(profile.billingRoute, preset.route)
            XCTAssertEqual(profile.liveModelID, "bigmodel")
            XCTAssertNotNil(try ASRAdapterFactory.liveAdapter(for: profile))
            XCTAssertEqual(profile.resolvedLiveEndpoint?.contains("/plan/"), preset.route == .agentPlan)
        }
    }

    @MainActor
    func testExplicitFileServicePriorityDoesNotFollowOrChangeDictationSelection() async throws {
        let suite = "floe.asr.file-priority." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CountingASRKeychain()
        let store = CloudASRSettingsStore(defaults: defaults, keychain: credentials,
                                           legacyKeychain: credentials)
        let primary = try store.addProfile(.openAICompatible(name: "Primary"),
                                           credential: "synthetic-primary-token")
        let file = try store.addProfile(.openAICompatible(name: "File preference"),
                                        credential: "synthetic-file-token")
        let fileID = store.serviceID(for: file)
        for method in [VoiceRecognitionPreferences.Method.system, .enhanced] {
            let assistant = AssistantAudioService(
                settings: TTSSettingsService(defaults: defaults, keychain: credentials),
                speech: TTSSpeechService(), defaults: defaults, keychain: credentials,
                cloudASRSettings: store, recognitionMethod: { method })
            await assistant.refreshAvailability()
            assistant.setPriority([fileID], for: .transcription)
            XCTAssertEqual(assistant.service(id: nil, for: .transcription)?.id, fileID)
            XCTAssertEqual(store.primaryProfileID, primary.id,
                           "A file-tool preference must not change the dictation profile")
        }
    }

    @MainActor
    func testOrdinarySettingsRefreshNeverReadsCredentialsOrResetsPreload() async throws {
        let suite = "floe.asr.metadata-refresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CountingASRKeychain()
        let store = CloudASRSettingsStore(defaults: defaults, keychain: credentials,
                                           legacyKeychain: credentials)
        _ = try store.addProfile(.openAICompatible(name: "Synthetic profile"),
                                 credential: "synthetic-not-a-provider-token")
        let coordinator = CloudASRPreloadCoordinator(store: store, defaults: defaults,
            methodProvider: { CloudASRMethod.cloud }, runtime: .disabled)
        credentials.resetReads()
        let identity = coordinator.primaryRouteIdentity()
        XCTAssertFalse(coordinator.isEnabled)
        await coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isEnabled)
        // A locked credential may affect a real recognition request, but not
        // route metadata, an unrelated settings event, or the saved toggle.
        credentials.failReads = true
        for index in 0..<40 {
            defaults.set(index, forKey: "unrelated.fixture.preference")
            _ = await coordinator.syncPrimaryRoute()
            XCTAssertEqual(coordinator.primaryRouteIdentity(), identity)
        }
        XCTAssertEqual(credentials.readCount, 0,
                       "Root settings notifications must not synchronously query Keychain")
        XCTAssertTrue(coordinator.isEnabled)
        await coordinator.setEnabled(false)
    }

    /// Real `VolcengineASRAdapter` + scripted WebSocket transport: the receive
    /// side drops mid-utterance, the adapter reports a transport failure, and
    /// the App transcriber reconnects with the same profile and replays every
    /// captured PCM byte before the final is committed once. No account or
    /// network is used.
    func testRealVolcengineReceiveDisconnectReconnectsWithFullReplay() async throws {
        try await exerciseVolcengineReconnect(stopImmediately: false)
    }

    func testVolcengineReconnectsAndReplaysAfterCaptureStops() async throws {
        try await exerciseVolcengineReconnect(stopImmediately: true)
    }

    private func exerciseVolcengineReconnect(stopImmediately: Bool) async throws {
        let first = ScriptedVolcConnection()
        first.inbox.fail(URLError(.networkConnectionLost))
        let second = ScriptedVolcConnection()
        second.onSend = { [weak second] message in
            guard let second, case .data(let data) = message, data.count >= 8 else { return }
            if data[1] & 0xf0 == 0x20,
               let pcm = try? ASRVendorGzip.decompress(
                    data.subdata(in: 8..<data.count), limit: 1 << 20) {
                second.addAudio(bytes: pcm.count)
            }
            guard data[1] & 0x0f == 0x02 else { return }
            let object: [String: Any] = ["result": ["text": "reconnected final"]]
            guard let json = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys]),
                  let frame = try? VolcengineASRFrame.serverJSON(
                    json, isFinal: true, sequence: -4) else { return }
            second.finalSent = true
            second.inbox.push(.data(frame))
        }
        let transport = ScriptedVolcTransport(connections: [first, second])
        let adapter = VolcengineASRAdapter(webSocketTransport: transport)
        let transcriber = try CloudSpeechTranscriber(
            profile: .volcengine(billingRoute: .agentPlan),
            language: .english,
            adapters: CloudSpeechAdapters(
                file: { _ in UnusedCloudFileAdapter() },
                live: { _ in adapter }),
            credentialProvider: { "synthetic-plan-key" },
            localFallback: { nil },
            recoveryPolicy: .immediate)
        let collected = Task {
            var values: [String] = []
            for await text in transcriber.transcripts { values.append(text) }
            return values
        }

        var expectedBytes = 0
        for _ in 0..<4 {
            let buffer = try cloudVoiceBuffer(seconds: 0.2, voiced: true)
            expectedBytes += Int(buffer.frameLength) * 2
            transcriber.feed(buffer, at: nil)
        }
        for _ in 0..<8 {
            let buffer = try cloudVoiceBuffer(seconds: 0.1, voiced: false)
            expectedBytes += Int(buffer.frameLength) * 2
            transcriber.feed(buffer, at: nil)
        }
        if !stopImmediately {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, second.audioBytes != expectedBytes {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await transcriber.finishAudio()
        XCTAssertEqual(second.audioBytes, expectedBytes,
                       "the replayed request must receive the complete captured PCM")
        let values = await collected.value

        XCTAssertEqual(transport.connectCount, 2,
                       "one real disconnect, one reconnect — never an unbounded loop")
        XCTAssertEqual(values.last, "reconnected final")
        XCTAssertEqual(values.filter { $0.contains("reconnected final") }.count, 1,
                       "the committed final is emitted once")
        XCTAssertNil(transcriber.failure)
        XCTAssertGreaterThanOrEqual(first.cancelCount, 1, "the failed socket is released")
    }
}

private final class RecordingBatchASR: ASRTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func transcribe(_ request: ASRTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        let number = lock.withLock { calls += 1; return calls }
        return ASRTranscriptionResult(text: "segment \(number)", segments: [])
    }
}

private func cloudVoiceBuffer(
    seconds: Double,
    voiced: Bool,
    rate: Double = 16_000
) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: rate,
        channels: 1,
        interleaved: false))
    let frames = AVAudioFrameCount((seconds * rate).rounded())
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        samples[index] = voiced
            ? Float(sin(Double(index) * .pi * 2 * 220 / rate)) * 0.2
            : 0
    }
    return buffer
}

private final class UnusedCloudFileAdapter: ASRTranscribing, @unchecked Sendable {
    func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        throw ASRTranscriptionError.invalidConfiguration(
            "file transcription is not used by this live recovery test")
    }
}

private final class ScriptedVolcInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ASRWebSocketMessage] = []
    private var waiter: CheckedContinuation<ASRWebSocketMessage, Error>?
    private var terminalError: Error?
    private var closed = false

    func push(_ message: ASRWebSocketMessage) {
        let pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            pending = waiter
        } else {
            messages.append(message)
            pending = nil
        }
        lock.unlock()
        pending?.resume(returning: message)
    }

    func fail(_ error: Error) {
        let pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        terminalError = error
        closed = true
        pending = waiter
        waiter = nil
        messages.removeAll()
        lock.unlock()
        pending?.resume(throwing: error)
    }

    func close() {
        let pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        closed = true
        pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    func next() async throws -> ASRWebSocketMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<ASRWebSocketMessage, Error>?
                lock.lock()
                if !messages.isEmpty {
                    immediate = .success(messages.removeFirst())
                } else if let terminalError {
                    immediate = .failure(terminalError)
                } else if closed {
                    immediate = .failure(CancellationError())
                } else {
                    waiter = continuation
                }
                lock.unlock()
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.close()
        }
    }
}

private final class ScriptedVolcConnection: ASRWebSocketConnection, @unchecked Sendable {
    let inbox = ScriptedVolcInbox()
    private let lock = NSLock()
    private var cancelled = false
    private var cancels = 0
    private var audio = 0
    private var final = false
    var onSend: (@Sendable (ASRWebSocketMessage) -> Void)?

    var cancelCount: Int { lock.withLock { cancels } }
    var audioBytes: Int { lock.withLock { audio } }
    var finalSent: Bool {
        get { lock.withLock { final } }
        set { lock.withLock { final = newValue } }
    }
    func addAudio(bytes: Int) { lock.withLock { audio += bytes } }

    func send(_ message: ASRWebSocketMessage) async throws {
        guard !lock.withLock({ cancelled }) else { throw CancellationError() }
        onSend?(message)
    }

    func receive() async throws -> ASRWebSocketMessage {
        try await inbox.next()
    }

    func close() { inbox.close() }

    func cancel() {
        lock.withLock {
            cancelled = true
            cancels += 1
        }
        inbox.close()
    }
}

private final class ScriptedVolcTransport: ASRWebSocketTransport, @unchecked Sendable {
    private let connections: [ScriptedVolcConnection]
    private let lock = NSLock()
    private var used = 0

    init(connections: [ScriptedVolcConnection]) {
        self.connections = connections
    }

    var connectCount: Int { lock.withLock { used } }

    func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        try lock.withLock {
            guard used < connections.count else {
                throw URLError(.cannotConnectToHost)
            }
            let connection = connections[used]
            used += 1
            return connection
        }
    }
}

private final class CountingASRKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var reads = 0
    private var locked = false
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var failReads: Bool {
        get { lock.lock(); defer { lock.unlock() }; return locked }
        set { lock.lock(); defer { lock.unlock() }; locked = newValue }
    }
    func resetReads() { lock.lock(); defer { lock.unlock() }; reads = 0 }
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }; items[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }; reads += 1
        guard !locked, let data = items[account] else { throw KeychainStoreError.itemNotFound }
        return data
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: account)
    }
}

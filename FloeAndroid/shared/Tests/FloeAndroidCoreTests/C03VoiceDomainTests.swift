// SPDX-License-Identifier: MPL-2.0
//
// C03 voice domain tests. SOURCE ONLY — not executed by this package.
// They cover time correspondence, bounded splitting, endpoint/credential
// safety, response normalization and manual-caption preservation. They do not
// invoke a provider, a device, the system recognizer or a TTS engine.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeAndroidWorkbench
import FloePersistence

final class C03VoiceDomainTests: XCTestCase {
    func testTimedSegmentNormalizationPreservesSourceTimeline() {
        XCTAssertNil(C03TimedSegment(start: -1, end: 1, text: "x").normalized())
        XCTAssertNil(C03TimedSegment(start: 2, end: 1, text: "x").normalized())
        XCTAssertNil(C03TimedSegment(start: 0, end: 1, text: "  ").normalized())
        XCTAssertNil(C03TimedSegment(start: .nan, end: 1, text: "x").normalized())
        let value = C03TimedSegment(start: 1.25, end: 3.75, text: "  hello   world ")
            .normalized()
        XCTAssertEqual(value?.start, 1.25)
        XCTAssertEqual(value?.end, 3.75)
        XCTAssertEqual(value?.text, "hello world")
    }

    func testTextSplitterDoesNotDropAuthoredWords() {
        let source = (1...300).map { "word\($0)" }.joined(separator: " ")
        let chunks = C03TextSplitter.split(source, maxCharacters: 120)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 120 })
        XCTAssertEqual(
            source.split(whereSeparator: { $0.isWhitespace }),
            chunks.flatMap { $0.split(whereSeparator: { $0.isWhitespace }) })
    }

    func testEndpointCompositionUsesOpenAIAudioPathOnce() {
        let base = URL(string: "https://api.example.com/v1")!
        XCTAssertEqual(
            C03SpeechEndpoint.audioURL(base: base, path: "/audio/speech")?.absoluteString,
            "https://api.example.com/v1/audio/speech")
        XCTAssertEqual(
            C03SpeechEndpoint.audioURL(
                base: URL(string: "https://api.example.com/proxy")!,
                path: "/audio/transcriptions")?.absoluteString,
            "https://api.example.com/proxy/v1/audio/transcriptions")
        XCTAssertEqual(
            C03SpeechEndpoint.audioURL(
                base: URL(string: "https://api.example.com/v1/audio/speech")!,
                path: "/audio/speech")?.absoluteString,
            "https://api.example.com/v1/audio/speech")
        XCTAssertNil(C03SpeechEndpoint.audioURL(
            base: URL(string: "http://api.example.com/v1")!,
            path: "/audio/speech"))
        XCTAssertNil(C03SpeechEndpoint.audioURL(
            base: URL(string: "https://user:pass@api.example.com/v1")!,
            path: "/audio/speech"))
    }

    func testASRResponseParsingKeepsProviderTimingAndBounds() throws {
        let json = """
        {"text":"Hello world","language":"en",
         "segments":[{"start":0.0,"end":1.5,"text":" Hello "},
                     {"start":1.5,"end":3.0,"text":"world"}]}
        """.data(using: .utf8)!
        let transcript = try C03CloudASRClient.parse(
            json, durationSeconds: 3.0,
            providerName: "Provider", modelDisplayName: "whisper-1")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].start, 0.0)
        XCTAssertEqual(transcript.segments[1].end, 3.0)
        XCTAssertEqual(transcript.segments[0].text, "Hello")
        XCTAssertEqual(transcript.language, "en")
    }

    func testTextOnlyASRReturnsNoFabricatedTiming() throws {
        let json = """
        {"text":"One sentence"}
        """.data(using: .utf8)!
        let transcript = try C03CloudASRClient.parse(
            json, durationSeconds: 12.5,
            providerName: "Provider", modelDisplayName: "whisper-1")
        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.timing, .textOnly)
        XCTAssertEqual(transcript.text, "One sentence")
        // The measured file duration is never converted into a subtitle span.
        XCTAssertThrowsError(try C03SubtitleWritePolicy.validate(transcript)) { error in
            XCTAssertEqual((error as? C03VoiceError)?.code, .needsTiming)
        }
    }

    func testChunkShiftUsesRealSourceOffsetAndClipsAtChunkEnd() {
        let shifted = C03ChunkTimeline.shift(
            [
                C03TimedSegment(start: 0, end: 3, text: "first"),
                C03TimedSegment(start: 59, end: 65, text: "boundary"),
                C03TimedSegment(start: 90, end: 91, text: "outside"),
            ],
            sourceStart: 120,
            sourceDuration: 60)
        XCTAssertEqual(shifted.count, 2)
        XCTAssertEqual(shifted[0].start, 120, accuracy: 0.0001)
        XCTAssertEqual(shifted[0].end, 123, accuracy: 0.0001)
        XCTAssertEqual(shifted[1].start, 179, accuracy: 0.0001)
        XCTAssertEqual(shifted[1].end, 180, accuracy: 0.0001)
    }

    func testChunkMergeDeduplicatesRepeatedBoundaryTextAndCaps() {
        let first = C03TimedSegment(start: 1, end: 2, text: "same")
        let duplicate = C03TimedSegment(start: 1, end: 2, text: "same")
        let second = C03TimedSegment(start: 3, end: 4, text: "next")
        let merged = C03ChunkTimeline.merge(
            [first], [duplicate, second], maxSegments: 2)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.text), ["same", "next"])
    }

    func testChunkedSegmentsStillMapThroughTrimSpeedAndRepeatedClips() {
        let assetID = UUID()
        let shifted = C03ChunkTimeline.shift(
            [C03TimedSegment(start: 2, end: 6, text: "inside")],
            sourceStart: 10,
            sourceDuration: 30)
        let clipA = VideoClip(assetID: assetID, trimStart: 10, trimEnd: 20, speed: 2)
        let clipB = VideoClip(assetID: assetID, trimStart: 10, trimEnd: 20, speed: 1)
        let captions = C03SubtitlePlanner.timedCaptions(
            segments: shifted, assetID: assetID, clips: [clipA, clipB])
        XCTAssertEqual(captions.count, 2)
        XCTAssertEqual(captions[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(captions[0].end, 3, accuracy: 0.0001)
        XCTAssertTrue(captions.allSatisfy { $0.source == .transcription })
    }

    func testCanonicalSettingsDefaultSystemAndLegacySchemaOne() throws {
        let defaultSettings = C03VoiceSettingsWire()
        XCTAssertEqual(defaultSettings.inputEngine, "system")
        XCTAssertEqual(defaultSettings.outputEngine, "system")
        XCTAssertFalse(defaultSettings.cloudInput.configured)

        let legacy: [String: Any] = [
            "schema": 1,
            "outputEngine": "cloud",
            "rate": 1.25,
            "cloudOutput": ["providerID": "p", "modelID": "m",
                            "voiceID": "alloy", "rate": 1.25],
            "transcriptionProviderID": "p",
            "transcriptionModelID": "t",
        ]
        let decoded = try XCTUnwrap(C03VoiceSettingsWire(json: legacy))
        XCTAssertEqual(decoded.inputEngine, "system")
        XCTAssertEqual(decoded.outputEngine, "cloud")
        XCTAssertEqual(decoded.cloudOutput.voiceID, "alloy")
        XCTAssertEqual(decoded.schema, 2)
    }

    func testCanonicalSettingsRejectsFutureSchemaSecretsAndUnreadableCAS() {
        XCTAssertNil(C03VoiceSettingsWire(json: ["schema": 3]))
        XCTAssertNil(C03VoiceSettingsWire(json: [
            "schema": 2, "inputEngine": "system", "apiKey": "sk-secret",
        ]))
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: "{}", expectedRevision: 0),
            .unreadable)
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: nil, expectedRevision: 0),
            .write(nextRevision: 1))
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: nil, expectedRevision: 2),
            .stale(expected: 2, actual: 0))
        let raw = #"{"schema":2,"revision":4,"inputEngine":"system","outputEngine":"system"}"#
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: raw, expectedRevision: 3),
            .stale(expected: 3, actual: 4))
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: raw, expectedRevision: 4),
            .write(nextRevision: 5))
    }

    func testCanonicalSettingsSaveShapeHasNoSecretOrPath() throws {
        var settings = C03VoiceSettingsWire()
        settings.inputEngine = "cloud"
        settings.outputEngine = "cloud"
        settings.cloudInput = C03VoiceSelectionWire(providerID: "p", modelID: "m")
        settings.cloudOutput = C03VoiceSelectionWire(
            providerID: "p", modelID: "m", voiceID: "alloy")
        let object = settings.jsonObject
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.lowercased().contains("apikey"))
        XCTAssertFalse(text.lowercased().contains("secret"))
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains("/root/"))
    }

    func testASRResponseRejectsMalformedJSONWithoutLeakingBody() {
        let data = Data(#"{"access_token":"sensitive","segments":["#.utf8)
        XCTAssertThrowsError(try C03CloudASRClient.parse(
            data, durationSeconds: 1,
            providerName: "Provider", modelDisplayName: "m")) { error in
            let typed = error as? C03VoiceError
            XCTAssertEqual(typed?.code, .invalidResponse)
            XCTAssertFalse(typed?.reason?.contains("sensitive") == true)
        }
    }

    func testTTSWavHeaderIsCanonicalPCM16() {
        let pcm = Data([0, 1, 2, 3, 4, 5])
        let wav = C03CloudTTSClient.wav(pcm: pcm, sampleRate: 24_000)
        XCTAssertGreaterThan(wav.count, pcm.count)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: Data(wav[8..<12]), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: Data(wav[36..<40]), encoding: .ascii), "data")
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    func testSubtitlePlanPreservesManualCaptionsAndReplacesOnlyTranscription() {
        let manual = CaptionSegment(start: 0, end: 1, text: "manual", source: .manual)
        let oldAuto = CaptionSegment(start: 2, end: 3, text: "old", source: .transcription)
        let plan = C03SubtitlePlanner.plan(
            existing: [manual, oldAuto],
            segments: [
                C03TimedSegment(start: 4, end: 5, text: "new"),
                C03TimedSegment(start: 1, end: 2, text: "first"),
            ],
            replaceTranscribed: true)
        XCTAssertEqual(plan.map(\.text), ["manual", "first", "new"])
        XCTAssertEqual(plan.filter { $0.source == .manual }.count, 1)
        XCTAssertEqual(plan.filter { $0.source == .transcription }.count, 2)
        XCTAssertEqual(plan.map(\.start), [0, 1, 4])
    }

    func testTimedCaptionsMapTrimAndSpeedToPlacedTimeline() {
        let assetID = UUID()
        let clip = VideoClip(
            assetID: assetID,
            trimStart: 10,
            trimEnd: 30,
            speed: 2.0)
        let captions = C03SubtitlePlanner.timedCaptions(
            segments: [
                C03TimedSegment(start: 12, end: 16, text: "first"),
                C03TimedSegment(start: 28, end: 32, text: "tail"),
            ],
            assetID: assetID,
            clips: [clip])
        XCTAssertEqual(captions.count, 2)
        XCTAssertEqual(captions[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(captions[0].end, 3.0, accuracy: 0.0001)
        XCTAssertEqual(captions[1].start, 9.0, accuracy: 0.0001)
        XCTAssertEqual(captions[1].end, 10.0, accuracy: 0.0001)
        XCTAssertTrue(captions.allSatisfy { $0.source == .transcription })
    }

    func testSubtitlePlanAppendKeepsExistingTranscription() {
        let oldAuto = CaptionSegment(start: 2, end: 3, text: "old", source: .transcription)
        let plan = C03SubtitlePlanner.plan(
            existing: [oldAuto],
            segments: [C03TimedSegment(start: 1, end: 1.5, text: "new")],
            replaceTranscribed: false)
        XCTAssertEqual(plan.map(\.text), ["new", "old"])
    }

    func testFailureVocabularyNeverCarriesSecretOrURL() {
        let error = C03VoiceError(
            .authentication, "providerAuth", retryable: false)
        XCTAssertEqual(error.code, .authentication)
        XCTAssertFalse(error.reason?.contains("Bearer") == true)
        XCTAssertFalse(error.reason?.contains("sk-") == true)
        // The initializer truncates to 120 characters but never accepts a
        // credential channel; a lane-authored reason is the only text.
        XCTAssertLessThanOrEqual(error.reason?.count ?? 0, 120)
    }

    func testSpeechModelChoiceCarriesNoCredentialValue() {
        let choice = C03SpeechModelChoice(
            providerID: UUID(),
            providerName: "Provider",
            modelID: UUID(),
            remoteModelID: "whisper-1",
            displayName: "Whisper",
            likelyASR: true,
            likelyTTS: false,
            credentialConfigured: true)
        XCTAssertTrue(choice.credentialConfigured)
        let encoded = try? JSONEncoder().encode(choice)
        let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(text.lowercased().contains("apikey"))
        XCTAssertFalse(text.lowercased().contains("secret"))
        XCTAssertFalse(text.contains("Bearer"))
    }

    func testOperationStatesAreTerminalOnlyAfterTerminal() {
        XCTAssertEqual(C03OperationState.running.rawValue, "running")
        XCTAssertEqual(C03OperationState.completed.rawValue, "completed")
        XCTAssertEqual(C03OperationState.failed.rawValue, "failed")
        XCTAssertEqual(C03OperationState.cancelled.rawValue, "cancelled")
    }

    // MARK: - Real SQLite settings CAS (source test; companion patch required)

    func testSQLiteSettingsCASAllowsExactlyOneConcurrentWriter() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteSettingsStore(database: database)
        let key = "voice.settings.cas.fixture"
        let revision0 = #"{"schema":2,"revision":0,"inputEngine":"system"}"#
        let revisionA = #"{"schema":2,"revision":1,"inputEngine":"system","rate":1.1}"#
        let revisionB = #"{"schema":2,"revision":1,"inputEngine":"system","rate":0.9}"#
        try await store.setValue(revision0, forKey: key)

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) {
            group in
            group.addTask {
                (try? await store.compareAndSetValue(
                    revisionA, forKey: key, expectedValue: revision0)) ?? false
            }
            group.addTask {
                (try? await store.compareAndSetValue(
                    revisionB, forKey: key, expectedValue: revision0)) ?? false
            }
            var values: [Bool] = []
            for await result in group { values.append(result) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1,
                       "exactly one CAS writer must commit")
        let final = try await store.value(forKey: key)
        XCTAssertTrue(final == revisionA || final == revisionB)
    }

    func testSQLiteSettingsCASExpectedAbsentHasOneWinner() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteSettingsStore(database: database)
        let key = "voice.settings.cas.absent"

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) {
            group in
            group.addTask {
                (try? await store.compareAndSetValue(
                    "A", forKey: key, expectedValue: nil)) ?? false
            }
            group.addTask {
                (try? await store.compareAndSetValue(
                    "B", forKey: key, expectedValue: nil)) ?? false
            }
            var values: [Bool] = []
            for await result in group { values.append(result) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1,
                       "INSERT OR IGNORE must have exactly one absent-row winner")
        let final = try await store.value(forKey: key)
        XCTAssertTrue(final == "A" || final == "B")
    }

    func testSQLiteSettingsCASMismatchWritesNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteSettingsStore(database: database)
        let key = "voice.settings.cas.mismatch"
        try await store.setValue("original", forKey: key)

        let wrote = try await store.compareAndSetValue(
            "replacement", forKey: key, expectedValue: "different")
        XCTAssertFalse(wrote)
        let original = try await store.value(forKey: key)
        XCTAssertEqual(original, "original")

        // A future/unreadable row is preserved even when the caller claims
        // "absent": INSERT OR IGNORE refuses to replace it.
        try await store.setValue(#"{"schema":99}"#, forKey: key)
        let overwrote = try await store.compareAndSetValue(
            #"{"schema":2}"#, forKey: key, expectedValue: nil)
        XCTAssertFalse(overwrote)
        let preserved = try await store.value(forKey: key)
        XCTAssertEqual(preserved, #"{"schema":99}"#)
    }

    func testSettingsCASRejectsNonExactRevisions() {
        for revision in ["true", "1.5", "-1",
                         "9223372036854775808", "9223372036854775807"] {
            let raw = #"{"schema":2,"revision":\#(revision),"inputEngine":"system"}"#
            XCTAssertEqual(
                C03SettingsCAS.decide(currentRaw: raw, expectedRevision: 0),
                .unreadable,
                "revision \(revision) must not be coerced")
        }
        let valid = #"{"schema":2,"revision":3,"inputEngine":"system"}"#
        XCTAssertEqual(
            C03SettingsCAS.decide(currentRaw: valid, expectedRevision: 3),
            .write(nextRevision: 4))
    }

    // MARK: - Duplicate/cancel-safe chunk ownership (source test)

    func testDuplicateChunkDispatchesProviderOnlyOnce() async throws {
        let fixture = try await makeChunkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = Task {
            try await fixture.domain.applyChunk(
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 2,
                sampleRate: 16_000,
                channels: 1)
        }
        await fixture.gate.waitUntilEntered()
        do {
            _ = try await fixture.domain.applyChunk(
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 2,
                sampleRate: 16_000,
                channels: 1)
            XCTFail("duplicate in-flight chunk must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .busy)
        }
        let dispatchCount = await fixture.gate.dispatchCount
        XCTAssertEqual(dispatchCount, 1,
                       "the duplicate must not dispatch a second provider call")
        await fixture.gate.release()
        let accepted = try await first.value
        XCTAssertEqual(accepted, 1)
    }

    func testOutOfOrderChunkDoesNotDispatch() async throws {
        let fixture = try await makeChunkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            _ = try await fixture.domain.applyChunk(
                operationID: fixture.operation,
                chunkIndex: 1,
                sourceStart: 0,
                sourceDuration: 2,
                sampleRate: 16_000,
                channels: 1)
            XCTFail("out-of-order chunk must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
        }
        let dispatchCount = await fixture.gate.dispatchCount
        XCTAssertEqual(dispatchCount, 0)
    }

    func testCancelledLateChunkResultCannotResurrect() async throws {
        let fixture = try await makeChunkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = Task {
            try await fixture.domain.applyChunk(
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 2,
                sampleRate: 16_000,
                channels: 1)
        }
        await fixture.gate.waitUntilEntered()
        let cancellation = Task {
            await fixture.domain.cancelTranscription(fixture.operation)
        }
        await waitForCancelRequested(fixture.domain, fixture.operation)
        await fixture.gate.release()
        _ = try? await first.value
        await cancellation.value

        let status = try await fixture.domain.asrStatus(fixture.operation)
        XCTAssertEqual(status.state, .cancelled)
        do {
            _ = try await fixture.domain.asrPage(
                fixture.operation, offset: 0, limit: 10)
            XCTFail("a cancelled operation must not expose a late transcript")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testFinishAfterCancelIsRefused() async throws {
        let fixture = try await makeChunkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.gate.release()
        let accepted = try await fixture.domain.applyChunk(
            operationID: fixture.operation,
            chunkIndex: 0,
            sourceStart: 0,
            sourceDuration: 2,
            sampleRate: 16_000,
            channels: 1)
        XCTAssertEqual(accepted, 1)
        await fixture.domain.cancelTranscription(fixture.operation)
        do {
            _ = try await fixture.domain.finishChunks(
                operationID: fixture.operation,
                totalChunks: 1,
                sourceDuration: 2)
            XCTFail("finish after cancel must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let finalStatus = try await fixture.domain.asrStatus(fixture.operation)
        XCTAssertEqual(finalStatus.state, .cancelled)
    }

    func testRootStopOwnsInflightWorkUntilRealSettlement() async throws {
        let fixture = try await makeChunkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = Task {
            try await fixture.domain.applyChunk(
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 2,
                sampleRate: 16_000,
                channels: 1)
        }
        await fixture.gate.waitUntilEntered()
        let done = C03DoneFlag()
        let stop = Task {
            await fixture.domain.cancelAll()
            await done.markDone()
        }
        await waitForCancelRequested(fixture.domain, fixture.operation)
        try await Task.sleep(nanoseconds: 100_000_000)
        let rootStopFinished = await done.value()
        XCTAssertFalse(rootStopFinished,
                       "RootStop must await the real provider task")
        let stillOwned = await fixture.domain.hasASROperationForTesting(
            fixture.operation)
        XCTAssertTrue(stillOwned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path),
                      "staging must remain owned until settlement")

        await fixture.gate.release()
        await stop.value
        _ = try? await first.value
        let retained = await fixture.domain.hasASROperationForTesting(
            fixture.operation)
        XCTAssertFalse(retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    func testCleanupDoesNotEscapeOwnedVoiceRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c03-r3-owned-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("c03-r3-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let marker = outside.appendingPathComponent("must-remain.txt")
        try Data("keep".utf8).write(to: marker)
        let gate = C03FakeASRGate()
        let domain = C03VoiceDomain(
            asrTranscriber: { route, file, language in
                try await gate.transcribe(route, file, language)
            },
            epochFence: { $0 == 7 },
            ownedVoiceRoot: { root })
        let operation = await domain.installChunkedOperationForTesting(
            epoch: 7,
            owner: C03VoiceOwner(taskID: UUID()),
            stagingURL: outside,
            sourceDuration: 60)
        await domain.cancelTranscription(operation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "cleanup must never delete outside the owned Voice root")
    }

    // MARK: - Fixtures

    private struct C03ChunkFixture: Sendable {
        var domain: C03VoiceDomain
        var gate: C03FakeASRGate
        var operation: String
        var root: URL
        var staging: URL
    }

    private func makeChunkFixture() async throws -> C03ChunkFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c03-r3-\(UUID().uuidString)", isDirectory: true)
        let staging = root
            .appendingPathComponent("Voice/ASR/fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        let wav = C03CloudTTSClient.wav(
            pcm: Data(repeating: 0x11, count: 256), sampleRate: 16_000)
        try wav.write(to: staging.appendingPathComponent("chunk-00000.wav"))
        let gate = C03FakeASRGate()
        let domain = C03VoiceDomain(
            asrTranscriber: { route, file, language in
                try await gate.transcribe(route, file, language)
            },
            epochFence: { $0 == 7 },
            ownedVoiceRoot: { root })
        let operation = await domain.installChunkedOperationForTesting(
            epoch: 7,
            owner: C03VoiceOwner(taskID: UUID()),
            stagingURL: staging,
            sourceDuration: 60,
            expectedChunks: 1,
            language: "en")
        return C03ChunkFixture(
            domain: domain, gate: gate, operation: operation,
            root: root, staging: staging)
    }

    private func waitForCancelRequested(
        _ domain: C03VoiceDomain,
        _ operation: String
    ) async {
        for _ in 0..<200 {
            if await domain.cancelRequestedForTesting(operation) { return }
            await Task.yield()
        }
        XCTFail("the cancel fence was not set")
    }
}

private actor C03DoneFlag {
    private var done = false
    func markDone() { done = true }
    func value() -> Bool { done }
}

private actor C03FakeASRGate {
    private(set) var dispatchCount = 0
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private let transcript = C03Transcript(
        segments: [C03TimedSegment(start: 0, end: 1, text: "fixture")],
        language: "en",
        providerName: "Fixture",
        modelDisplayName: "fixture",
        text: "fixture",
        timing: .providerSegments)

    func transcribe(
        _ route: C03ResolvedSpeechRoute,
        _ file: C03MediaFile,
        _ language: String?
    ) async throws -> C03Transcript {
        _ = route
        _ = file
        _ = language
        dispatchCount += 1
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }
        return transcript
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            if entered {
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// Meeting cloud-ASR domain tests. SOURCE ONLY — not executed by this package.
//
// They cover the independent meeting/material identity binding, real chunk
// offsets, rejection of a mismatched caller and cleanup after finish/cancel.
// No provider, device, G09 project, task owner or local model is used.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class MeetingVoiceDomainTests: XCTestCase {
    private let epoch: UInt64 = 7

    func testCanonicalMeetingIdentifierIsStrict() {
        let canonical = UUID().uuidString.lowercased()
        XCTAssertTrue(C03VoiceDomain.isCanonicalMeetingIdentifier(canonical))
        XCTAssertFalse(C03VoiceDomain.isCanonicalMeetingIdentifier(
            canonical.uppercased()))
        XCTAssertFalse(C03VoiceDomain.isCanonicalMeetingIdentifier(
            "11111111-1111-4111-8111-11111111111"))
        XCTAssertFalse(C03VoiceDomain.isCanonicalMeetingIdentifier(
            "../11111111-1111-4111-8111-111111111111"))
        XCTAssertFalse(C03VoiceDomain.isCanonicalMeetingIdentifier(""))
    }

    func testMismatchedMeetingOrMaterialIsRefusedBeforeDispatch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherMeeting = UUID().uuidString.lowercased()
        let otherMaterial = UUID().uuidString.lowercased()

        do {
            _ = try await fixture.domain.applyMeetingChunk(
                meetingID: otherMeeting,
                materialID: fixture.materialID,
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 1,
                sampleRate: 16_000,
                channels: 1)
            XCTFail("a different meeting id must not use this operation")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
            XCTAssertEqual(error.reason, "meetingIdentityMismatch")
        }
        do {
            _ = try await fixture.domain.applyMeetingChunk(
                meetingID: fixture.meetingID,
                materialID: otherMaterial,
                operationID: fixture.operation,
                chunkIndex: 0,
                sourceStart: 0,
                sourceDuration: 1,
                sampleRate: 16_000,
                channels: 1)
            XCTFail("a different material id must not use this operation")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
        }
        let dispatches = await fixture.gate.dispatchCount()
        XCTAssertEqual(dispatches, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.staging.appendingPathComponent("chunk-00000.wav").path))
    }

    func testRealSourceOffsetIsPreservedAndFinishCleansStaging() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let count = try await fixture.domain.applyMeetingChunk(
            meetingID: fixture.meetingID,
            materialID: fixture.materialID,
            operationID: fixture.operation,
            chunkIndex: 0,
            sourceStart: 10.0,
            sourceDuration: 30.0,
            sampleRate: 16_000,
            channels: 1)
        XCTAssertEqual(count, 1)
        let dispatches = await fixture.gate.dispatchCount()
        XCTAssertEqual(dispatches, 1)

        do {
            _ = try await fixture.domain.meetingASRPage(
                meetingID: fixture.meetingID,
                materialID: UUID().uuidString.lowercased(),
                operationID: fixture.operation,
                offset: 0,
                limit: 10)
            XCTFail("page for another material must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
        }
        let page = try await fixture.domain.meetingASRPage(
            meetingID: fixture.meetingID,
            materialID: fixture.materialID,
            operationID: fixture.operation,
            offset: 0,
            limit: 10)
        XCTAssertEqual(page.segments.count, 1)
        XCTAssertEqual(page.segments[0].start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(page.segments[0].end, 11.0, accuracy: 0.0001)

        do {
            _ = try await fixture.domain.finishMeetingChunks(
                meetingID: fixture.meetingID,
                materialID: UUID().uuidString.lowercased(),
                operationID: fixture.operation,
                totalChunks: 1,
                sourceDuration: 60)
            XCTFail("finish for another material must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
        }
        let finished = try await fixture.domain.finishMeetingChunks(
            meetingID: fixture.meetingID,
            materialID: fixture.materialID,
            operationID: fixture.operation,
            totalChunks: 1,
            sourceDuration: 60)
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))

        do {
            _ = try await fixture.domain.writeSubtitles(
                operationID: fixture.operation,
                expectedRevision: 0,
                replaceTranscribed: true,
                opID: "meeting-not-subtitle")
            XCTFail("a meeting transcript must not write G09 subtitles")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
            XCTAssertEqual(error.reason, "meetingOperationNotSubtitle")
        }
    }

    func testFinishRequiresCompleteChunkSet() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await fixture.domain.finishMeetingChunks(
                meetingID: fixture.meetingID,
                materialID: fixture.materialID,
                operationID: fixture.operation,
                totalChunks: 1,
                sourceDuration: 60)
            XCTFail("no chunk was uploaded yet")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
            XCTAssertEqual(error.reason, "chunkSetIncomplete")
        }
    }

    func testCancelRequiresMatchingIdentityAndDropsStaging() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try await fixture.domain.cancelMeetingTranscription(
                meetingID: UUID().uuidString.lowercased(),
                materialID: fixture.materialID,
                operationID: fixture.operation)
            XCTFail("cancel for another meeting must be refused")
        } catch let error as C03VoiceError {
            XCTAssertEqual(error.code, .invalidSelection)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))

        try await fixture.domain.cancelMeetingTranscription(
            meetingID: fixture.meetingID,
            materialID: fixture.materialID,
            operationID: fixture.operation)
        let status = try await fixture.domain.asrStatus(fixture.operation)
        XCTAssertEqual(status.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        let dispatches = await fixture.gate.dispatchCount()
        XCTAssertEqual(dispatches, 0)
    }

    // MARK: - Fixtures

    private struct Fixture {
        var domain: C03VoiceDomain
        var gate: MeetingFakeASRGate
        var meetingID: String
        var materialID: String
        var operation: String
        var root: URL
        var staging: URL
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-asr-\(UUID().uuidString)", isDirectory: true)
        let staging = root
            .appendingPathComponent("Voice/MeetingASR/fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        let wav = C03CloudTTSClient.wav(
            pcm: Data(repeating: 0x11, count: 256), sampleRate: 16_000)
        try wav.write(to: staging.appendingPathComponent("chunk-00000.wav"))
        let gate = MeetingFakeASRGate()
        let domain = C03VoiceDomain(
            asrTranscriber: { route, file, language in
                try await gate.transcribe(route, file, language)
            },
            epochFence: { $0 == 7 },
            ownedVoiceRoot: { root })
        let meetingID = UUID().uuidString.lowercased()
        let materialID = UUID().uuidString.lowercased()
        let operation = await domain.installMeetingOperationForTesting(
            epoch: epoch,
            meetingID: meetingID,
            materialID: materialID,
            stagingURL: staging,
            sourceDuration: 60,
            expectedChunks: 1,
            language: "en")
        return Fixture(
            domain: domain,
            gate: gate,
            meetingID: meetingID,
            materialID: materialID,
            operation: operation,
            root: root,
            staging: staging)
    }
}

private actor MeetingFakeASRGate {
    private var dispatches = 0
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
        dispatches += 1
        return transcript
    }

    func dispatchCount() -> Int { dispatches }
}

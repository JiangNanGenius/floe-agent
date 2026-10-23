// FloeProvidersTests — captured-layout fixtures for the Volcengine Agent Plan
// speech frame codec and stream lifecycle.
//
// The fixtures reproduce the byte layout observed in the verified plan-stream
// capture (Local/Private/speech-performance-20261023/volc-speech-investigation/
// run-1/RESULT.json, 2026-10-24):
//
//   WithEvent frame = header(4) | event int32 | session_id u32 + 36B uuid |
//                     payload_size u32 | payload
//
// Every head byte pair below (11 94 10 00 for FullServerResponse+WithEvent JSON,
// 11 B4 00 00 for AudioOnlyServer+WithEvent raw) is the observed wire value.
// The session id is a synthetic UUID; no credential, token or live request is
// involved anywhere in this file.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

// MARK: - Fixture construction

private let syntheticSessionID = "6f6d76d2-0b8f-4c4f-9f0e-2b9b9d4a1c37" // 36-byte uuid shape

private func beU32(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func lengthPrefixed(_ string: String) -> [UInt8] {
    let utf8 = Array(string.utf8)
    return beU32(UInt32(utf8.count)) + utf8
}

/// Exactly one WithEvent server frame in the captured field order.
private func serverFrame(
    typeAndFlags: UInt8,
    serialAndCompression: UInt8,
    event: Int,
    sessionID: String?,
    connectID: String?,
    payload: Data
) -> Data {
    var bytes: [UInt8] = [0x11, typeAndFlags, serialAndCompression, 0x00]
    bytes += beU32(UInt32(bitPattern: Int32(event)))
    if let sessionID { bytes += lengthPrefixed(sessionID) }
    if let connectID { bytes += lengthPrefixed(connectID) }
    bytes += beU32(UInt32(payload.count))
    bytes += [UInt8](payload)
    return Data(bytes)
}

/// Observed FullServerResponse head: type 0b1001, WithEvent, JSON, no compression.
private func jsonEvent(
    _ event: Int, payload: String, sessionID: String? = syntheticSessionID
) -> Data {
    serverFrame(
        typeAndFlags: (0b1001 << 4) | 0b0100,
        serialAndCompression: 0b0001 << 4,
        event: event, sessionID: sessionID, connectID: nil,
        payload: Data(payload.utf8))
}

/// Observed AudioOnlyServer head: type 0b1011, WithEvent, raw serialization.
private func audioEvent(
    _ audio: Data, event: Int = 352, sessionID: String? = syntheticSessionID
) -> Data {
    serverFrame(
        typeAndFlags: (0b1011 << 4) | 0b0100,
        serialAndCompression: 0,
        event: event, sessionID: sessionID, connectID: nil, payload: audio)
}

// MARK: - Codec + lifecycle fixtures

@Suite("Volcengine plan wire fixtures")
struct VolcPlanWireFixtureTests {
    @Test func audioFrameKeepsFullPayloadAfterSessionIDField() throws {
        // Captured frame[2]: 11 B4 00 00 | 352 | 00 00 00 24 | uuid36 |
        // 00 00 46 50 | 18,000 audio bytes. The pre-fix decoder read the
        // session-length word as the payload size, so the "audio" was the 36
        // uuid bytes and all real audio bytes were dropped.
        let audio = Data((0..<18_000).map { UInt8($0 % 251) })
        let frame = try VolcSpeechFrame.decode(audioEvent(audio))
        guard case .serverAudio(let payload, let event) = frame else {
            Issue.record("expected serverAudio"); return
        }
        #expect(event == 352)
        #expect(payload == audio)
        #expect(payload.count == 18_000)
        #expect(payload != Data(syntheticSessionID.utf8))
    }

    @Test func sentenceEventsDecodeAlignedJSON() throws {
        let body = #"{"phonemes":[],"text":"local check","words":[]}"#
        guard case .serverJSON(let startPayload, let startEvent) =
            try VolcSpeechFrame.decode(jsonEvent(350, payload: body)) else {
            Issue.record("expected serverJSON(350)"); return
        }
        #expect(startEvent == 350)
        #expect(String(data: startPayload, encoding: .utf8) == body)

        guard case .serverJSON(let endPayload, let endEvent) =
            try VolcSpeechFrame.decode(jsonEvent(351, payload: body)) else {
            Issue.record("expected serverJSON(351)"); return
        }
        #expect(endEvent == 351)
        #expect(String(data: endPayload, encoding: .utf8) == body)
    }

    @Test func sessionFinishedTerminatesFromHeaderEventNotPayload() throws {
        // Captured frame[9]: event 152 with payload exactly `{}`. The old loop
        // only looked for the substring "Finish" in the JSON body and missed
        // it, waiting until the server close surfaced as a transport error.
        let frame = try VolcSpeechFrame.decode(jsonEvent(152, payload: "{}"))
        guard case .serverJSON(let payload, let event) = frame else {
            Issue.record("expected serverJSON(152)"); return
        }
        #expect(event == 152)
        #expect(String(data: payload, encoding: .utf8) == "{}")
        #expect(VolcengineSpeechAdapter.planFrameOutcome(frame) == .finish)
    }

    @Test func payloadThatMentionsFinishDoesNotEndTheSession() throws {
        let frame = try VolcSpeechFrame.decode(
            jsonEvent(351, payload: #"{"event":"Finished","text":"ok"}"#))
        #expect(VolcengineSpeechAdapter.planFrameOutcome(frame) == .continueSession)
    }

    @Test func sessionFailedPropagatesProviderCode() throws {
        let withCode = try VolcSpeechFrame.decode(
            jsonEvent(153, payload: #"{"code":45000001,"conn_id":"trace-42"}"#))
        #expect(VolcengineSpeechAdapter.planFrameOutcome(withCode)
            == .reject(code: 45_000_001, logID: "trace-42"))

        let bare = try VolcSpeechFrame.decode(jsonEvent(153, payload: "{}"))
        #expect(VolcengineSpeechAdapter.planFrameOutcome(bare)
            == .reject(code: 153, logID: nil))
    }

    @Test func binaryErrorFramePropagatesCodeAndSanitizedTrace() throws {
        // type 0b1111 without WithEvent: header | error_code | payload size.
        let payload = Data(#"{"conn_id":"conn-7","message":"denied"}"#.utf8)
        var bytes: [UInt8] = [0x11, 0b1111 << 4, 0b0001 << 4, 0x00]
        bytes += beU32(UInt32(bitPattern: 45_000_002))
        bytes += beU32(UInt32(payload.count))
        bytes += [UInt8](payload)
        let frame = try VolcSpeechFrame.decode(Data(bytes))
        guard case .serverError(let code, let decoded) = frame else {
            Issue.record("expected serverError"); return
        }
        #expect(code == 45_000_002)
        #expect(decoded == payload)
        #expect(VolcengineSpeechAdapter.planFrameOutcome(frame)
            == .reject(code: 45_000_002, logID: "conn-7"))
    }

    @Test func errorFrameWithEventSkipsSessionFields() throws {
        // protocols.py reader order for WithEvent Error frames: error code,
        // then event/session_id/connect_id, then the payload size.
        let payload = Data(#"{"code":45000003}"#.utf8)
        var bytes: [UInt8] = [0x11, (0b1111 << 4) | 0b0100, 0b0001 << 4, 0x00]
        bytes += beU32(UInt32(bitPattern: 45_000_003))
        bytes += beU32(UInt32(bitPattern: 153))
        bytes += lengthPrefixed(syntheticSessionID)
        bytes += beU32(UInt32(payload.count))
        bytes += [UInt8](payload)
        let frame = try VolcSpeechFrame.decode(Data(bytes))
        guard case .serverError(let code, let decoded) = frame else {
            Issue.record("expected serverError"); return
        }
        #expect(code == 45_000_003)
        #expect(decoded == payload)
    }

    @Test func connectionEventsUseTheirOwnFieldSet() throws {
        // event 50 (ConnectionStarted): no session_id, connect_id present.
        let started = try VolcSpeechFrame.decode(serverFrame(
            typeAndFlags: (0b1001 << 4) | 0b0100, serialAndCompression: 0b0001 << 4,
            event: 50, sessionID: nil,
            connectID: "8d5a3f3e-1111-2222-3333-444455556666",
            payload: Data("{}".utf8)))
        guard case .serverJSON(let startedPayload, let startedEvent) = started else {
            Issue.record("expected serverJSON(50)"); return
        }
        #expect(startedEvent == 50)
        #expect(String(data: startedPayload, encoding: .utf8) == "{}")

        // event 52 (ConnectionFinished): session_id then connect_id.
        let finished = try VolcSpeechFrame.decode(serverFrame(
            typeAndFlags: (0b1001 << 4) | 0b0100, serialAndCompression: 0b0001 << 4,
            event: 52, sessionID: syntheticSessionID,
            connectID: "8d5a3f3e-1111-2222-3333-444455556666",
            payload: Data("{}".utf8)))
        guard case .serverJSON(let finishedPayload, let finishedEvent) = finished else {
            Issue.record("expected serverJSON(52)"); return
        }
        #expect(finishedEvent == 52)
        #expect(String(data: finishedPayload, encoding: .utf8) == "{}")
    }

    @Test func malformedWithEventFieldsFailClosed() {
        // Declared session_id longer than the remaining bytes.
        var truncated = [UInt8]([0x11, 0xB4, 0x00, 0x00]) + beU32(352) + beU32(36)
        truncated += [UInt8](syntheticSessionID.utf8.prefix(10))
        #expect(throws: VolcSpeechFrame.DecodeError.truncated) {
            try VolcSpeechFrame.decode(Data(truncated))
        }
        // An absurd session_id size trips the frame ceiling before any read.
        let oversized = [UInt8]([0x11, 0xB4, 0x00, 0x00]) + beU32(352) + beU32(0x7FFF_FFFF)
        #expect(throws: VolcSpeechFrame.DecodeError.oversized) {
            try VolcSpeechFrame.decode(Data(oversized))
        }
        // Session field complete but no payload size word follows.
        let noPayloadSize = [UInt8]([0x11, 0xB4, 0x00, 0x00]) + beU32(352)
            + lengthPrefixed(syntheticSessionID)
        #expect(throws: VolcSpeechFrame.DecodeError.truncated) {
            try VolcSpeechFrame.decode(Data(noPayloadSize))
        }
    }

    @Test func clientFinishNowCarriesEventAndSessionField() {
        // Pre-fix layout was 11 14 10 00 | 00 00 00 02 | "{}": flag WithEvent
        // with no event field, so a server would read the payload size as the
        // event and the body as a session length. One FullClientRequest now
        // completes the flow and this frame is no longer sent, but its
        // encoding must still be structurally valid.
        let bytes = [UInt8](VolcSpeechFrame.clientFinish(Data("{}".utf8)).encoded())
        #expect(bytes[0] == 0x11)
        #expect(bytes[1] == (0b0001 << 4) | 0b0100)   // flag nibble preserved
        #expect(bytes[2] == (0b0001 << 4))            // JSON, no compression
        #expect(Array(bytes[4..<8]) == beU32(102))    // FinishSession event
        #expect(Array(bytes[8..<12]) == beU32(0))     // empty session_id field
        #expect(Array(bytes[12..<16]) == beU32(2))    // payload size
        #expect(String(decoding: bytes[16...], as: UTF8.self) == "{}")
    }

    @Test func serverFixturesWithEventsRoundTrip() throws {
        let audio = Data((0..<4_096).map { UInt8($0 % 256) })
        let audioFrame = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverAudio(audio, event: 352).encoded())
        guard case .serverAudio(let audioPayload, let audioEvent) = audioFrame else {
            Issue.record("expected serverAudio"); return
        }
        #expect(audioPayload == audio)
        #expect(audioEvent == 352)

        let finished = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverJSON(Data("{}".utf8), event: 152).encoded())
        #expect(VolcengineSpeechAdapter.planFrameOutcome(finished) == .finish)

        let connection = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverJSON(Data("{}".utf8), event: 50).encoded())
        #expect(VolcengineSpeechAdapter.planFrameOutcome(connection) == .continueSession)
    }

    @Test func audioFramesResolveToStreamChunks() throws {
        let frame = try VolcSpeechFrame.decode(audioEvent(Data([1, 2, 3])))
        #expect(VolcengineSpeechAdapter.planFrameOutcome(frame) == .audio(Data([1, 2, 3])))
    }
}

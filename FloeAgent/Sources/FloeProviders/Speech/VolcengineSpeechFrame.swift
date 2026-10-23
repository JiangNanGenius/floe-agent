// FloeProviders — Volcengine Doubao speech WebSocket binary frame codec.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure encode/decode for the documented binary protocol used by
// wss://openspeech.bytedance.com/api/v3/plan/tts/unidirectional/stream (and
// its pay-as-you-go sibling). Layout (all integers big-endian):
//
//   byte 0    : protocol version (0b0001) | header size (0b0001 → 4 bytes)
//   byte 1    : message type | message-type specific flags
//   byte 2    : serialization method (0b0001 JSON / 0b0000 raw) | compression
//               (0b0000 none / 0b0001 gzip)
//   byte 3    : reserved 0x00
//   optional  : present per flags — for WithEvent frames (0b0100) a 4-byte
//               event code, then protocol string fields, then the payload
//               size; for Error frames type 0b1111 a 4-byte error code (and
//               the same event fields when flagged WithEvent)
//   payload size (4 bytes) + payload
//
//   WithEvent string fields, in order (official protocols.py reader order,
//   confirmed against the 2026-10-24 plan-stream capture):
//     session_id : length-prefixed u32 + bytes, omitted only for the
//                  connection-lifecycle events 1 (StartConnection),
//                  2 (FinishConnection), 50 (ConnectionStarted) and
//                  51 (ConnectionFailed);
//     connect_id : length-prefixed u32 + bytes, present for events
//                  50, 51 and 52 (ConnectionFinished).
//
// Client full-request frames: type 0b0001, flags 0 (send text) / 0b100
// (finish), JSON serialization, no compression. Server frames: audio-only
// 0b1011, JSON 0b1001, error 0b1111 (4-byte error code), flags 0b0100 means a
// 4-byte event field follows the header. The plan TTS unidirectional flow
// answers one FullClientRequest with audio events 352 and closes with a
// FullServerResponse event 152 whose payload is only `{}` (the terminal event
// lives in the header, never in the JSON body).

import Foundation

public enum VolcSpeechFrame: Sendable, Hashable {
    /// Full client request: JSON payload.
    case clientRequest(Data)
    /// Client "finish sending text" marker (empty JSON payload allowed).
    case clientFinish(Data)
    /// Server audio frame (raw container bytes as configured in the request).
    case serverAudio(Data, event: Int?)
    /// Server JSON frame (ack, task events; payload parsed by the session).
    case serverJSON(Data, event: Int?)
    /// Server error frame: numeric code + optional JSON payload.
    case serverError(code: Int, Data)

    public enum MessageType: UInt8, Sendable, Hashable {
        case fullClientRequest = 0b0001
        case fullServerResponse = 0b1001
        case audioOnlyResponse = 0b1011
        case serverError = 0b1111
    }

    static let protocolVersion: UInt8 = 0b0001
    static let headerSize: UInt8 = 0b0001
    static let serialJSON: UInt8 = 0b0001
    static let serialRaw: UInt8 = 0b0000
    static let compressionNone: UInt8 = 0b0000
    /// Message-type flag: a 4-byte event code (and its string fields) precede
    /// the payload size.
    static let withEventFlag: UInt8 = 0b0100
    /// Events whose WithEvent frames omit the session_id field.
    static let sessionlessEvents: Set<Int> = [1, 2, 50, 51]
    /// Events whose WithEvent frames carry a connect_id field.
    static let connectIDEvents: Set<Int> = [50, 51, 52]
    /// Official upstream FinishSession event (structured `.clientFinish`).
    static let finishSessionEvent: Int32 = 102

    // MARK: Encoding (client → server)

    public func encoded() -> Data {
        var out = Data()
        switch self {
        case .clientRequest(let payload):
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            out.append((Self.MessageType.fullClientRequest.rawValue << 4) | 0x00)
            out.append((Self.serialJSON << 4) | Self.compressionNone)
            out.append(0x00)
            out.appendBigEndianUInt32(UInt32(payload.count))
            out.append(payload)
        case .clientFinish(let payload):
            // WithEvent requires the 4-byte event field before any string
            // field or payload size. The plan unidirectional flow never sends
            // this frame (a single FullClientRequest completes a session), so
            // this encoding exists only for protocol-complete fixtures and
            // carries FinishSession (102) with an empty session_id field.
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            out.append((Self.MessageType.fullClientRequest.rawValue << 4) | Self.withEventFlag)
            out.append((Self.serialJSON << 4) | Self.compressionNone)
            out.append(0x00)
            out.appendBigEndianUInt32(UInt32(bitPattern: Self.finishSessionEvent))
            out.appendBigEndianUInt32(0) // empty session_id
            out.appendBigEndianUInt32(UInt32(payload.count))
            out.append(payload)
        case .serverAudio(let payload, let event), .serverJSON(let payload, let event):
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            let type = self.kind == .serverAudioFrame
                ? MessageType.audioOnlyResponse
                : MessageType.fullServerResponse
            let flags: UInt8 = event != nil ? Self.withEventFlag : 0
            out.append((type.rawValue << 4) | flags)
            let serial = self.kind == .serverAudioFrame ? Self.serialRaw : Self.serialJSON
            out.append((serial << 4) | Self.compressionNone)
            out.append(0x00)
            if let event {
                out.appendBigEndianUInt32(UInt32(bitPattern: Int32(event)))
                // The wire always repeats the WithEvent string fields here; a
                // zero-length marker keeps synthetic server fixtures symmetric
                // with `decode` (real server frames carry a 36-byte uuid).
                if !Self.sessionlessEvents.contains(event) {
                    out.appendBigEndianUInt32(0) // empty session_id
                }
                if Self.connectIDEvents.contains(event) {
                    out.appendBigEndianUInt32(0) // empty connect_id
                }
            }
            out.appendBigEndianUInt32(UInt32(payload.count))
            out.append(payload)
        case .serverError(let code, let payload):
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            out.append((MessageType.serverError.rawValue << 4) | 0b1111)
            out.append((Self.serialJSON << 4) | Self.compressionNone)
            out.append(0x00)
            out.appendBigEndianUInt32(UInt32(bitPattern: Int32(code)))
            out.appendBigEndianUInt32(UInt32(payload.count))
            out.append(payload)
        }
        return out
    }

    private enum Kind {
        case clientRequestPayload, clientFinishMarker, serverAudioFrame, serverJSONFrame, serverErrorFrame
    }

    private var kind: Kind {
        switch self {
        case .clientRequest: return .clientRequestPayload
        case .clientFinish: return .clientFinishMarker
        case .serverAudio: return .serverAudioFrame
        case .serverJSON: return .serverJSONFrame
        case .serverError: return .serverErrorFrame
        }
    }

    // MARK: Decoding (server → client)

    public enum DecodeError: Error, Sendable, Hashable {
        case truncated
        case badVersion
        case badMessageType
        case oversized
    }

    /// Decodes exactly one complete frame; `.truncated` means feed more bytes.
    public static func decode(_ data: Data) throws -> VolcSpeechFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw DecodeError.truncated }
        let version = bytes[0] >> 4
        guard version == protocolVersion else { throw DecodeError.badVersion }
        let headerWords = bytes[0] & 0x0F
        guard headerWords == headerSize else { throw DecodeError.badVersion }
        let messageType = MessageType(rawValue: bytes[1] >> 4)
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        guard compression == compressionNone else {
            // gzip responses are not requested; treat as protocol violation
            throw DecodeError.badMessageType
        }
        var offset = 4
        var event: Int?
        var errorCode: Int?
        if let messageType {
            switch messageType {
            case .fullClientRequest:
                break // never expected from server
            case .fullServerResponse, .audioOnlyResponse:
                if flags == Self.withEventFlag {
                    let headerEvent = try readEvent(bytes, &offset)
                    event = headerEvent
                    // Real server frames repeat the event in the header and
                    // then carry session_id (and connect_id) before the payload
                    // size; skipping those fields is what keeps the payload and
                    // every audio byte aligned.
                    try skipWithEventFields(bytes, &offset, event: headerEvent)
                }
            case .serverError:
                guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
                errorCode = Int(bigEndianWords: bytes[offset..<offset + 4])
                offset += 4
                if flags == Self.withEventFlag {
                    // protocols.py reader order for Error frames: error code,
                    // then the same event/session_id/connect_id block.
                    let failedEvent = try readEvent(bytes, &offset)
                    try skipWithEventFields(bytes, &offset, event: failedEvent)
                }
            }
        }
        guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
        let payloadSize = Int(UInt32(bigEndianWords: bytes[offset..<offset + 4]))
        offset += 4
        guard payloadSize >= 0, payloadSize <= TTSSpeechLimits.maxWSFrameBytes else {
            throw DecodeError.oversized
        }
        guard bytes.count >= offset + payloadSize else { throw DecodeError.truncated }
        let payload = Data(bytes[offset..<offset+payloadSize])
        guard let messageType else { throw DecodeError.badMessageType }
        switch messageType {
        case .audioOnlyResponse: return .serverAudio(payload, event: event)
        case .fullServerResponse: return .serverJSON(payload, event: event)
        case .serverError: return .serverError(code: errorCode ?? -1, payload)
        case .fullClientRequest: throw DecodeError.badMessageType
        }
    }

    // MARK: Optional header field readers

    private static func readEvent(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
        let value = Int(bigEndianWords: bytes[offset..<offset + 4])
        offset += 4
        return value
    }

    /// Skips the WithEvent string fields that precede the payload size.
    private static func skipWithEventFields(
        _ bytes: [UInt8], _ offset: inout Int, event: Int
    ) throws {
        if !sessionlessEvents.contains(event) {
            try skipLengthPrefixedField(bytes, &offset)
        }
        if connectIDEvents.contains(event) {
            try skipLengthPrefixedField(bytes, &offset)
        }
    }

    /// Skips one u32 length-prefixed byte string (session_id / connect_id).
    private static func skipLengthPrefixedField(_ bytes: [UInt8], _ offset: inout Int) throws {
        guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
        let size = Int(UInt32(bigEndianWords: bytes[offset..<offset + 4]))
        if size > TTSSpeechLimits.maxWSFrameBytes { throw DecodeError.oversized }
        offset += 4
        guard bytes.count >= offset + size else { throw DecodeError.truncated }
        offset += size
    }
}

extension Int {
    fileprivate init(bigEndianWords words: ArraySlice<UInt8>) {
        var value: UInt32 = 0
        for byte in words.prefix(4) { value = (value << 8) | UInt32(byte) }
        self = Int(Int32(bitPattern: value))
    }
}

extension UInt32 {
    fileprivate init(bigEndianWords words: ArraySlice<UInt8>) {
        var value: UInt32 = 0
        for byte in words.prefix(4) { value = (value << 8) | UInt32(byte) }
        self = value
    }
}

extension Data {
    fileprivate mutating func appendBigEndianUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

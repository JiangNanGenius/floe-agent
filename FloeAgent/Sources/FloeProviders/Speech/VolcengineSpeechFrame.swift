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
//   optional  : present per flags — 4-byte event code, or 4-byte error code
//   payload size (4 bytes) + payload
//
// Client full-request frames: type 0b0001, flags 0 (send text) / 0b100
// (finish), JSON serialization, no compression. Server frames: audio-only
// 0b1011, JSON 0b1001, error 0b1111 (4-byte error code), flags 0b0100 means a
// 4-byte event field follows the header.

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
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            out.append((Self.MessageType.fullClientRequest.rawValue << 4) | 0b0100)
            out.append((Self.serialJSON << 4) | Self.compressionNone)
            out.append(0x00)
            out.appendBigEndianUInt32(UInt32(payload.count))
            out.append(payload)
        case .serverAudio(let payload, let event), .serverJSON(let payload, let event):
            out.append((Self.protocolVersion << 4) | Self.headerSize)
            let type = self.kind == .serverAudioFrame
                ? MessageType.audioOnlyResponse
                : MessageType.fullServerResponse
            let flags: UInt8 = event != nil ? 0b0100 : 0
            out.append((type.rawValue << 4) | flags)
            let serial = self.kind == .serverAudioFrame ? Self.serialRaw : Self.serialJSON
            out.append((serial << 4) | Self.compressionNone)
            out.append(0x00)
            if let event { out.appendBigEndianUInt32(UInt32(bitPattern: Int32(event))) }
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
                if flags == 0b0100 {
                    guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
                    event = Int(bigEndianWords: bytes[offset..<offset + 4])
                    offset += 4
                }
            case .serverError:
                guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
                errorCode = Int(bigEndianWords: bytes[offset..<offset + 4])
                offset += 4
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

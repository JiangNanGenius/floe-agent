// FloeProviders — Volcengine v3 SAUC binary frame codec.
//
// SPDX-License-Identifier: MPL-2.0
//
// Wire layout (all integers big-endian), from the official
// `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` protocol:
//
//   byte 0  protocol version (0b0001) | header size in 4-byte words (0b0001)
//   byte 1  message type (4) | message-type-specific flags (4)
//   byte 2  serialization (4) | compression (4)
//   byte 3  reserved
//   [optional 4-byte sequence when flags is 0b0001 or 0b0011]
//   4-byte payload size | payload
//
// Client full request: type 0b0001, flags 0, JSON + gzip.
// Client audio: type 0b0010, flags 0 (normal) or 0b0010 (final negative
// packet), raw + gzip. The documented client message flow does not carry a
// sequence number; server responses may carry one depending on their flags.
// Server result: type 0b1001, JSON + gzip. Server error: type 0b1111 with a
// 4-byte error code before the 4-byte payload size.

import Foundation
import FloeCore

enum VolcengineASRFrame {
    enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnlyRequest = 0b0010
        case fullServerResponse = 0b1001
        case serverAck = 0b1011
        case serverError = 0b1111
    }

    enum Flags: UInt8 {
        case none = 0b0000
        case positiveSequence = 0b0001
        case negativeSequence = 0b0010
        case negativeWithSequence = 0b0011

        var carriesSequence: Bool {
            self == .positiveSequence || self == .negativeWithSequence
        }

        var isFinal: Bool {
            self == .negativeSequence || self == .negativeWithSequence
        }
    }

    enum Decoded: Sendable, Hashable {
        case json(Data, isFinal: Bool, sequence: Int?)
        case ack(sequence: Int?)
        case error(code: Int, Data)
    }

    enum CodecError: Error, Sendable, Hashable {
        case truncated
        case badVersion
        case badMessageType
        case badCompression
        case oversized
    }

    static let protocolVersion: UInt8 = 0b0001
    static let headerWords: UInt8 = 0b0001
    static let serialJSON: UInt8 = 0b0001
    static let serialRaw: UInt8 = 0b0000
    static let compressionNone: UInt8 = 0b0000
    static let compressionGzip: UInt8 = 0b0001
    static let maximumFrameBytes = 32 * 1024 * 1024

    // MARK: - Client encoding

    static func clientFullRequest(_ json: Data) throws -> Data {
        let payload = try ASRVendorGzip.compress(json)
        var output = Data([headerByte(), 0x10, (serialJSON << 4) | compressionGzip, 0x00])
        appendUInt32(UInt32(payload.count), to: &output)
        output.append(payload)
        return output
    }

    static func clientAudio(_ pcm: Data, isLast: Bool) throws -> Data {
        let payload = try ASRVendorGzip.compress(pcm)
        let flags: UInt8 = isLast ? Flags.negativeSequence.rawValue : Flags.none.rawValue
        var output = Data([
            headerByte(),
            (MessageType.audioOnlyRequest.rawValue << 4) | flags,
            (serialRaw << 4) | compressionGzip,
            0x00,
        ])
        appendUInt32(UInt32(payload.count), to: &output)
        output.append(payload)
        return output
    }

    // Test fixtures. Server frames are decoded by the same reader used for a
    // real connection, so the tests exercise the production parser.
    static func serverJSON(_ json: Data, isFinal: Bool, sequence: Int?) throws -> Data {
        let payload = try ASRVendorGzip.compress(json)
        let flags: Flags
        if isFinal {
            flags = sequence == nil ? .negativeSequence : .negativeWithSequence
        } else {
            flags = sequence == nil ? .none : .positiveSequence
        }
        var output = Data([
            headerByte(),
            (MessageType.fullServerResponse.rawValue << 4) | flags.rawValue,
            (serialJSON << 4) | compressionGzip,
            0x00,
        ])
        if let sequence, flags.carriesSequence {
            appendInt32(Int32(sequence), to: &output)
        }
        appendUInt32(UInt32(payload.count), to: &output)
        output.append(payload)
        return output
    }

    static func serverError(code: Int, json: Data) -> Data {
        var output = Data([
            headerByte(),
            MessageType.serverError.rawValue << 4,
            (serialJSON << 4) | compressionNone,
            0x00,
        ])
        appendUInt32(UInt32(truncatingIfNeeded: code), to: &output)
        appendUInt32(UInt32(json.count), to: &output)
        output.append(json)
        return output
    }

    // MARK: - Decoding

    static func decode(
        _ data: Data,
        maximumEventBytes: Int
    ) throws -> Decoded {
        guard data.count >= 8 else { throw CodecError.truncated }
        if data.count > maximumFrameBytes { throw CodecError.oversized }
        let bytes = [UInt8](data)
        let version = bytes[0] >> 4
        let words = bytes[0] & 0x0f
        guard version == protocolVersion, words >= headerWords else {
            throw CodecError.badVersion
        }
        let headerBytes = Int(words) * 4
        guard headerBytes >= 4, headerBytes <= 64 else {
            throw CodecError.badVersion
        }
        guard let type = MessageType(rawValue: bytes[1] >> 4),
              let flags = Flags(rawValue: bytes[1] & 0x0f) else {
            throw CodecError.badMessageType
        }
        let compression = bytes[2] & 0x0f
        guard compression == compressionNone || compression == compressionGzip else {
            throw CodecError.badCompression
        }
        var offset = headerBytes
        var sequence: Int?
        if flags.carriesSequence {
            guard offset + 4 <= bytes.count else { throw CodecError.truncated }
            sequence = Int(readInt32(bytes, at: offset))
            offset += 4
        }
        switch type {
        case .fullServerResponse, .serverAck:
            guard offset + 4 <= bytes.count else { throw CodecError.truncated }
            let size = try readSize(bytes, at: offset)
            offset += 4
            guard offset + size <= bytes.count else { throw CodecError.truncated }
            guard offset + size == bytes.count else {
                throw CodecError.badMessageType
            }
            let raw = Data(bytes[offset..<(offset + size)])
            let payload = try decompressed(
                raw,
                compression: compression,
                maximumEventBytes: maximumEventBytes)
            if type == .serverAck {
                return .ack(sequence: sequence)
            }
            return .json(payload, isFinal: flags.isFinal, sequence: sequence)
        case .serverError:
            guard offset + 4 <= bytes.count else { throw CodecError.truncated }
            let code = Int(readUInt32(bytes, at: offset))
            offset += 4
            guard offset + 4 <= bytes.count else { throw CodecError.truncated }
            let size = try readSize(bytes, at: offset)
            offset += 4
            guard offset + size <= bytes.count else { throw CodecError.truncated }
            guard offset + size == bytes.count else {
                throw CodecError.badMessageType
            }
            let raw = Data(bytes[offset..<(offset + size)])
            let payload = try decompressed(
                raw,
                compression: compression,
                maximumEventBytes: maximumEventBytes)
            return .error(code: code, payload)
        case .fullClientRequest, .audioOnlyRequest:
            throw CodecError.badMessageType
        }
    }

    private static func decompressed(
        _ payload: Data,
        compression: UInt8,
        maximumEventBytes: Int
    ) throws -> Data {
        guard payload.count <= maximumFrameBytes else {
            throw CodecError.oversized
        }
        if compression == compressionNone {
            guard payload.count <= maximumEventBytes else {
                throw CodecError.oversized
            }
            return payload
        }
        do {
            return try ASRVendorGzip.decompress(
                payload, limit: maximumEventBytes)
        } catch let error as ASRTranscriptionError {
            switch error {
            case .responseTooLarge:
                throw CodecError.oversized
            default:
                throw CodecError.badCompression
            }
        } catch {
            throw CodecError.badCompression
        }
    }

    // MARK: - Byte helpers

    private static func headerByte() -> UInt8 {
        (protocolVersion << 4) | headerWords
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        appendUInt32(UInt32(bitPattern: value), to: &data)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(bytes, at: offset))
    }

    private static func readSize(_ bytes: [UInt8], at offset: Int) throws -> Int {
        let value = readUInt32(bytes, at: offset)
        guard value <= UInt32(maximumFrameBytes) else { throw CodecError.oversized }
        return Int(value)
    }
}

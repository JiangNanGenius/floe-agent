// FloeProviders — shared, wire-independent support for the vendor ASR
// adapters (Volcengine / Alibaba).
//
// SPDX-License-Identifier: MPL-2.0
//
// This file intentionally contains only bounded codecs and input inspection:
// gzip framing used by the Volcengine binary protocol, audio container
// detection/validation, endpoint path composition and JSON value helpers.
// Provider sessions and request shapes live in the two adapter files. No
// credential, provider response body or endpoint user info is ever included
// in an error or a log.

import Foundation
import FloeCore

#if canImport(Compression)
import Compression
#endif

// MARK: - Gzip (RFC 1952) used by the Volcengine v3 binary protocol

enum ASRVendorGzip {
    static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]

    static func compress(_ input: Data) throws -> Data {
        #if canImport(Compression)
        var output = Data(header)
        if input.isEmpty {
            // A valid DEFLATE encoding of an empty block. The final audio
            // packet is allowed to carry no PCM bytes.
            output.append(contentsOf: [0x03, 0x00])
            var crc: UInt32 = 0
            var size: UInt32 = 0
            withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
            withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
            return output
        }
        // Deflate worst-case overhead is small for the 200 ms PCM frames and
        // the bounded JSON configuration. Keep a generous, explicit cap.
        let capacity = input.count + input.count / 8 + 1_024
        var encoded = Data(count: capacity)
        let written = encoded.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(
                    to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the audio frame")
        }
        output.append(encoded.prefix(written))
        var crc = crc32(input).littleEndian
        var size = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
        #else
        throw ASRTranscriptionError.invalidConfiguration(
            "gzip framing is unavailable on this platform")
        #endif
    }

    static func decompress(_ input: Data, limit: Int) throws -> Data {
        #if canImport(Compression)
        guard limit > 0 else { throw ASRTranscriptionError.responseTooLarge }
        let bytes = [UInt8](input)
        guard bytes.count >= 18,
              bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw ASRTranscriptionError.providerRejected
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else {
                throw ASRTranscriptionError.providerRejected
            }
            let extra = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
            guard extra >= 0, offset + extra <= bytes.count else {
                throw ASRTranscriptionError.providerRejected
            }
            offset += extra
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else {
                throw ASRTranscriptionError.providerRejected
            }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else {
                throw ASRTranscriptionError.providerRejected
            }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset <= bytes.count - 8 else {
            throw ASRTranscriptionError.providerRejected
        }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        // Allocate one byte beyond the allowed event so an exactly-limit
        // payload still fits; a payload that is too large cannot be presented
        // as a complete transcript.
        let capacity = limit + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            deflated.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(
                    to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, deflated.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else {
            throw ASRTranscriptionError.responseTooLarge
        }
        guard written <= limit else {
            throw ASRTranscriptionError.responseTooLarge
        }
        return output.prefix(written)
        #else
        throw ASRTranscriptionError.invalidConfiguration(
            "gzip framing is unavailable on this platform")
        #endif
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xedb8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xffff_ffff
    }
}

// MARK: - Bounded JSON helpers

enum ASRVendorJSON {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// The documented Volcengine `result` shape is normally an object; some
    /// relays wrap it in a single-element list. Accept either without letting
    /// the ambiguity reach a caller.
    static func resultObject(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any], array.count == 1 {
            return array.first as? [String: Any]
        }
        return nil
    }
}

// MARK: - Audio input inspection

enum ASRVendorAudioFormat: String, Sendable, Hashable {
    case pcm
    case wav
    case mp3
    case oggOpus = "ogg"

    var mimeType: String {
        switch self {
        case .pcm: return "audio/L16"
        case .wav: return "audio/wav"
        case .mp3: return "audio/mpeg"
        case .oggOpus: return "audio/ogg"
        }
    }
}

struct ASRVendorAudioInput: Sendable {
    let data: Data
    let format: ASRVendorAudioFormat
    /// Known container sample rate. MP3 without a parseable frame header and
    /// OGG/Opus intentionally leave this nil; the adapters use the documented
    /// provider default in that case.
    let sampleRate: Int?
    let channelCount: Int?
    let durationSeconds: Double?
    let mimeType: String
}

enum ASRVendorAudioSpec {
    static let volcengine =
        "supported audio: 16 kHz mono PCM16 WAV or raw PCM, MP3, or OGG/Opus; "
        + "convert M4A/AAC/FLAC or other containers to WAV or PCM first"
    static let alibaba =
        "supported audio: PCM16 mono WAV, MP3, or OGG/Opus; "
        + "convert M4A/AAC/FLAC or other containers to WAV first"
}

enum ASRVendorAudioDetector {
    static let maximumContainerScanBytes = 8 * 1024 * 1024

    static func inspect(
        _ data: Data,
        filename: String,
        mimeType: String,
        provider: ASRProviderKind
    ) throws -> ASRVendorAudioInput {
        guard !data.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration("audio file is empty")
        }
        let lowerName = filename.lowercased()
        let lowerMIME = mimeType.lowercased()
        let bytes = [UInt8](data.prefix(min(data.count, 16)))

        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
            let info = try parseWAV(data, provider: provider)
            return ASRVendorAudioInput(
                data: data,
                format: .wav,
                sampleRate: info.sampleRate,
                channelCount: info.channels,
                durationSeconds: info.durationSeconds,
                mimeType: "audio/wav")
        }
        if bytes.count >= 4,
           bytes[0] == 0x4f, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            let info = try parseOGG(data, provider: provider)
            return ASRVendorAudioInput(
                data: data,
                format: .oggOpus,
                sampleRate: info.sampleRate,
                channelCount: info.channels,
                durationSeconds: info.durationSeconds,
                mimeType: "audio/ogg")
        }
        if looksLikeMP3(bytes, lowerName: lowerName) {
            let info = parseMP3(data)
            return ASRVendorAudioInput(
                data: data,
                format: .mp3,
                sampleRate: info.sampleRate,
                channelCount: nil,
                durationSeconds: info.durationSeconds,
                mimeType: "audio/mpeg")
        }
        if isExplicitPCM(lowerName: lowerName, lowerMIME: lowerMIME) {
            guard provider == .volcengine else {
                throw ASRTranscriptionError.invalidConfiguration(
                    ASRVendorAudioSpec.alibaba)
            }
            guard data.count % 2 == 0 else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "raw PCM16 audio must contain an even number of bytes")
            }
            let rate = 16_000
            let duration = Double(data.count) / Double(rate * 2)
            return ASRVendorAudioInput(
                data: data,
                format: .pcm,
                sampleRate: rate,
                channelCount: 1,
                durationSeconds: duration,
                mimeType: "audio/L16")
        }
        throw ASRTranscriptionError.invalidConfiguration(
            provider == .volcengine ? ASRVendorAudioSpec.volcengine : ASRVendorAudioSpec.alibaba)
    }

    private struct WAVInfo {
        let sampleRate: Int
        let channels: Int
        let durationSeconds: Double
    }

    private static func parseWAV(_ data: Data, provider: ASRProviderKind) throws -> WAVInfo {
        guard data.count >= 44 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV file is truncated; provide a complete PCM16 WAV file")
        }
        let bytes = [UInt8](data)
        var offset = 12
        var formatTag: UInt16?
        var channels: UInt16?
        var sampleRate: UInt32?
        var bits: UInt16?
        var dataSize: UInt32?
        while offset + 8 <= bytes.count {
            let identifier = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = uint32LE(bytes, at: offset + 4)
            offset += 8
            let chunkSize = Int(size)
            guard chunkSize >= 0, offset + chunkSize <= bytes.count else {
                break
            }
            if identifier == "fmt ", chunkSize >= 16 {
                formatTag = uint16LE(bytes, at: offset)
                channels = uint16LE(bytes, at: offset + 2)
                sampleRate = uint32LE(bytes, at: offset + 4)
                bits = uint16LE(bytes, at: offset + 14)
                if formatTag == 0xfffe, chunkSize >= 40 {
                    // WAVE_FORMAT_EXTENSIBLE: the first two bytes of the
                    // SubFormat GUID are the underlying format tag.
                    formatTag = uint16LE(bytes, at: offset + 24)
                }
            } else if identifier == "data" {
                dataSize = size
            }
            offset += chunkSize
            if chunkSize % 2 == 1, offset < bytes.count { offset += 1 }
        }
        guard let formatTag, formatTag == 1 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV audio must be uncompressed PCM16; convert it to PCM16 WAV first")
        }
        guard let channels, channels == 1 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV audio must be mono; convert it to mono PCM16 WAV first")
        }
        guard let sampleRate, let bits, bits == 16 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV audio must be 16-bit PCM; convert it to PCM16 WAV first")
        }
        guard let dataSize, dataSize > 0 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV file contains no audio data")
        }
        if provider == .volcengine, sampleRate != 16_000 {
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine transcription requires 16 kHz audio; resample to 16 kHz first")
        }
        let rate = Int(sampleRate)
        guard rate >= 8_000, rate <= 48_000 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "WAV sample rate is not supported; use 16 kHz audio")
        }
        let duration = Double(dataSize) / Double(rate * 2)
        return WAVInfo(
            sampleRate: rate,
            channels: Int(channels),
            durationSeconds: duration)
    }

    private struct MP3Info {
        let sampleRate: Int?
        let durationSeconds: Double?
    }

    private static func looksLikeMP3(_ bytes: [UInt8], lowerName: String) -> Bool {
        if bytes.count >= 3,
           bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { // ID3
            return true
        }
        if bytes.count >= 2, bytes[0] == 0xff, (bytes[1] & 0xe0) == 0xe0 {
            return true
        }
        return lowerName.hasSuffix(".mp3")
    }

    private static func parseMP3(_ data: Data) -> MP3Info {
        let bytes = [UInt8](data)
        var offset = 0
        if bytes.count >= 10,
           bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6] & 0x7f) << 21)
                | (Int(bytes[7] & 0x7f) << 14)
                | (Int(bytes[8] & 0x7f) << 7)
                | Int(bytes[9] & 0x7f)
            offset = min(bytes.count, 10 + size)
        }
        guard offset + 4 <= bytes.count else { return MP3Info(sampleRate: nil, durationSeconds: nil) }
        while offset + 4 <= bytes.count {
            if bytes[offset] == 0xff, (bytes[offset + 1] & 0xe0) == 0xe0 {
                break
            }
            offset += 1
        }
        guard offset + 4 <= bytes.count else { return MP3Info(sampleRate: nil, durationSeconds: nil) }
        let header = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let versionBits = (header >> 19) & 0x3
        let layerBits = (header >> 17) & 0x3
        let bitrateIndex = Int((header >> 12) & 0xf)
        let rateIndex = Int((header >> 10) & 0x3)
        let padding = Int((header >> 9) & 0x1)
        guard layerBits == 0b01 else { // Layer III
            return MP3Info(sampleRate: nil, durationSeconds: nil)
        }
        let sampleRates: [Int]
        let bitrateTable: [Int]
        let samplesPerFrame: Int
        switch versionBits {
        case 0b11: // MPEG 1
            sampleRates = [44_100, 48_000, 32_000]
            bitrateTable = [0, 32, 40, 48, 56, 64, 80, 96,
                            112, 128, 160, 192, 224, 256, 320]
            samplesPerFrame = 1_152
        case 0b10: // MPEG 2
            sampleRates = [22_050, 24_000, 16_000]
            bitrateTable = [0, 8, 16, 24, 32, 40, 48, 56,
                            64, 80, 96, 112, 128, 144, 160]
            samplesPerFrame = 576
        case 0b00: // MPEG 2.5
            sampleRates = [11_025, 12_000, 8_000]
            bitrateTable = [0, 8, 16, 24, 32, 40, 48, 56,
                            64, 80, 96, 112, 128, 144, 160]
            samplesPerFrame = 576
        default:
            return MP3Info(sampleRate: nil, durationSeconds: nil)
        }
        guard rateIndex < sampleRates.count,
              bitrateIndex > 0, bitrateIndex < bitrateTable.count else {
            return MP3Info(sampleRate: nil, durationSeconds: nil)
        }
        let sampleRate = sampleRates[rateIndex]
        let bitrate = bitrateTable[bitrateIndex] * 1_000
        let frameBytes: Int
        if versionBits == 0b11 {
            frameBytes = 144 * bitrate / sampleRate + padding
        } else {
            frameBytes = 72 * bitrate / sampleRate + padding
        }
        guard frameBytes > 4 else {
            return MP3Info(sampleRate: sampleRate, durationSeconds: nil)
        }
        var frames = 0
        var cursor = offset
        while cursor + frameBytes <= bytes.count, frames < 1_000_000 {
            frames += 1
            cursor += frameBytes
        }
        guard frames > 0 else {
            return MP3Info(sampleRate: sampleRate, durationSeconds: nil)
        }
        let duration = Double(frames * samplesPerFrame) / Double(sampleRate)
        return MP3Info(sampleRate: sampleRate, durationSeconds: duration)
    }

    private struct OGGInfo {
        let sampleRate: Int?
        let channels: Int?
        let durationSeconds: Double?
    }

    private static func parseOGG(_ data: Data, provider: ASRProviderKind) throws -> OGGInfo {
        let head = [UInt8](data.prefix(min(data.count, 8 * 1024)))
        guard let marker = find(head, [0x4f, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "OGG audio must contain an Opus stream; convert it to OGG/Opus or WAV")
        }
        var channels: Int?
        var inputRate: Int?
        if marker + 16 <= head.count {
            channels = Int(head[marker + 9])
            inputRate = Int(head[marker + 12])
                | (Int(head[marker + 13]) << 8)
                | (Int(head[marker + 14]) << 16)
                | (Int(head[marker + 15]) << 24)
        }
        let bytes = [UInt8](data)
        var duration: Double?
        // Opus granules are always at 48 kHz. The final Ogg page carries the
        // total granule position for the stream.
        if bytes.count >= 27 {
            var index = bytes.count - 27
            while index >= 0 {
                if bytes[index] == 0x4f, bytes[index + 1] == 0x67,
                   bytes[index + 2] == 0x67, bytes[index + 3] == 0x53 {
                    let granule = uint64LE(bytes, at: index + 6)
                    if granule > 0, granule < UInt64(1 << 40) {
                        duration = Double(granule) / 48_000
                    }
                    break
                }
                index -= 1
            }
        }
        if provider == .volcengine, let inputRate, inputRate != 16_000,
           inputRate != 48_000 {
            // The provider only accepts a 16 kHz rate field for compressed
            // input; the Opus decoder itself is always 48 kHz. Keep the
            // documented 16 kHz hint below.
        }
        return OGGInfo(
            sampleRate: 16_000,
            channels: channels.map { max(1, $0) },
            durationSeconds: duration)
    }

    private static func isExplicitPCM(lowerName: String, lowerMIME: String) -> Bool {
        lowerName.hasSuffix(".pcm") || lowerName.hasSuffix(".raw")
            || lowerMIME.contains("audio/l16")
            || lowerMIME.contains("audio/pcm")
            || lowerMIME.contains("application/x-pcm")
    }

    private static func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        var index = 0
        while index <= last {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private static func uint16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func uint64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}

// MARK: - Provider-timed segment builder

struct ASRVendorSegmentBuilder {
    static let maximumSegments = 10_000
    static let maximumWords = 10_000
    static let maximumTranscriptCharacters = 2_000_000
    static let maximumMediaSeconds = 24.0 * 60 * 60

    private var entries: [ASRTranscriptionSegment] = []
    private var keys = Set<String>()
    private(set) var wordCount = 0

    mutating func add(
        startMilliseconds: Double?,
        endMilliseconds: Double?,
        text rawText: String
    ) throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.maximumTranscriptCharacters else {
            throw ASRTranscriptionError.responseTooLarge
        }
        guard let start = startMilliseconds, let end = endMilliseconds,
              start.isFinite, end.isFinite,
              start >= 0, end > start,
              start <= Self.maximumMediaSeconds * 1_000,
              end <= Self.maximumMediaSeconds * 1_000 else {
            return
        }
        guard entries.count < Self.maximumSegments else {
            throw ASRTranscriptionError.responseTooLarge
        }
        let key = "\(start)|\(end)|\(text)"
        guard keys.insert(key).inserted else { return }
        entries.append(ASRTranscriptionSegment(
            start: start / 1_000,
            end: end / 1_000,
            text: text))
    }

    /// Parse a provider `words` array. Word timing is bounded and validated;
    /// the shared result exposes segment timing only, so words are used as a
    /// fallback span when an utterance omits its own start/end.
    mutating func spanFromWords(_ rawWords: Any?) -> (start: Double, end: Double)? {
        guard let words = ASRVendorJSON.array(rawWords) else { return nil }
        var first: Double?
        var last: Double?
        for raw in words {
            guard wordCount < Self.maximumWords else { return nil }
            wordCount += 1
            guard let word = ASRVendorJSON.dictionary(raw),
                  let start = ASRVendorJSON.double(word["begin_time"])
                    ?? ASRVendorJSON.double(word["start_time"]),
                  let end = ASRVendorJSON.double(word["end_time"]),
                  start.isFinite, end.isFinite, start >= 0, end >= start else {
                continue
            }
            if first == nil || start < first! { first = start }
            if last == nil || end > last! { last = end }
        }
        guard let first, let last, last > first else { return nil }
        return (first, last)
    }

    func segments() -> [ASRTranscriptionSegment] {
        entries.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }
}

// MARK: - Endpoint composition

enum ASRVendorEndpoint {
    static func httpsComponents(_ raw: String) throws -> URLComponents {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "transcription endpoint is required")
        }
        if let problem = ASREndpointRules.httpsProblem(for: value) {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "transcription endpoint is not a valid HTTPS URL")
        }
        if components.user != nil || components.password != nil {
            throw ASRTranscriptionError.invalidConfiguration(
                "endpoint credentials belong in the API key field, not in the URL")
        }
        components.fragment = nil
        return components
    }

    static func webSocketComponents(_ raw: String) throws -> URLComponents {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live transcription endpoint is required")
        }
        if let problem = ASREndpointRules.webSocketProblem(for: value) {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "wss" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live transcription endpoint is not a valid WebSocket URL")
        }
        if components.user != nil || components.password != nil {
            throw ASRTranscriptionError.invalidConfiguration(
                "endpoint credentials belong in the API key field, not in the URL")
        }
        components.scheme = "wss"
        components.fragment = nil
        return components
    }

    /// Append the documented path only when the configured endpoint is a bare
    /// host/base. A full configured path (including a reverse-proxy prefix) is
    /// preserved exactly once.
    static func composePath(
        _ components: inout URLComponents,
        baseSuffixes: [String],
        fullPath: String
    ) {
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" {
            components.percentEncodedPath = fullPath
            return
        }
        if path.hasSuffix(fullPath) { return }
        for suffix in baseSuffixes where path.hasSuffix(suffix) {
            components.percentEncodedPath = path + String(fullPath.dropFirst(suffix.count))
            return
        }
        components.percentEncodedPath = path
    }
}

// MARK: - Small concurrency helpers

/// Minimal sendable flag used by the file collector's timeout race. It is
/// intentionally not a general-purpose synchronization primitive.
final class ASRVendorLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ASRVendorLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment(limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value < limit else { return false }
        value += 1
        return true
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Holds the currently active bounded timeout task for a file replay. The
/// cancellation handler can cancel whichever phase (send or final drain) is
/// active without racing a later phase assignment.
final class ASRVendorTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ newTask: Task<Void, Never>) {
        lock.lock()
        let old = task
        task = newTask
        lock.unlock()
        old?.cancel()
    }

    func cancel() {
        lock.lock()
        let old = task
        task = nil
        lock.unlock()
        old?.cancel()
    }
}

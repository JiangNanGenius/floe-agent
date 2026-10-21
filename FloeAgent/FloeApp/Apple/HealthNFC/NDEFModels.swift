// FloeApp — bounded, pure NDEF decoding.
//
// CoreNFC hands us tag records; this file never touches the reader session.
// It validates TNF/type/encoding, preserves bounded raw provenance and never
// opens, executes or forwards a URL. Keeping it Foundation-only makes the
// malformed/bounded/type/URL cases testable without hardware.

#if canImport(UIKit) && canImport(CoreNFC)
import Foundation
import CryptoKit

struct NDEFRawRecord: Sendable, Equatable {
    var typeNameFormat: UInt8
    var type: Data
    var identifier: Data?
    var payload: Data
}

struct NDEFDecodingLimits: Sendable, Equatable {
    var maxRecords: Int = 32
    var maxBytesPerRecord: Int = 8 * 1_024
    var maxTotalBytes: Int = 32 * 1_024
    var maxTextCharacters: Int = 1_024
    var maxURITextCharacters: Int = 1_024
    var maxDeclaredTypeCharacters: Int = 256
    var maxIdentifierCharacters: Int = 512
    var maxRawPrefixBytes: Int = 96
}

enum NDEFRecordKind: String, Sendable, Equatable {
    case text
    case uri
    case mime
    case external
    case empty
    case unknown
}

struct NDEFDecodedRecord: Sendable, Equatable {
    var index: Int
    var kind: NDEFRecordKind
    var tnf: UInt8
    var declaredType: String?
    var identifier: String?
    var text: String?
    var language: String?
    var uri: String?
    var mimeType: String?
    var payloadByteCount: Int
    var rawPrefixHex: String
    var rawSHA256: String
    var valueTruncated: Bool
    var payloadTruncated: Bool
    var issues: [String]
}

struct NDEFDecodedMessage: Sendable, Equatable {
    var records: [NDEFDecodedRecord]
    var reportedRecordCount: Int
    var omittedRecords: Int
    var totalPayloadBytes: Int
    var truncated: Bool
}

enum NDEFDecoder {
    // NFC Forum URI RTD identifier-code prefixes (0x00...0x23).
    private static let uriPrefixes: [UInt8: String] = [
        0x00: "",
        0x01: "http://www.",
        0x02: "https://www.",
        0x03: "http://",
        0x04: "https://",
        0x05: "tel:",
        0x06: "mailto:",
        0x07: "ftp://anonymous:anonymous@",
        0x08: "ftp://ftp.",
        0x09: "ftps://",
        0x0A: "sftp://",
        0x0B: "smb://",
        0x0C: "nfs://",
        0x0D: "ftp://",
        0x0E: "dav://",
        0x0F: "news:",
        0x10: "telnet://",
        0x11: "imap:",
        0x12: "rtsp://",
        0x13: "urn:",
        0x14: "pop:",
        0x15: "sip:",
        0x16: "sips:",
        0x17: "tftp:",
        0x18: "btspp://",
        0x19: "btl2cap://",
        0x1A: "btgoep://",
        0x1B: "tcpobex://",
        0x1C: "irdaobex://",
        0x1D: "file://",
        0x1E: "urn:epc:id:",
        0x1F: "urn:epc:tag:",
        0x20: "urn:epc:pat:",
        0x21: "urn:epc:raw:",
        0x22: "urn:epc:",
        0x23: "urn:nfc:"
    ]

    static func decode(
        _ input: [NDEFRawRecord],
        limits: NDEFDecodingLimits = NDEFDecodingLimits()
    ) -> NDEFDecodedMessage {
        let totalPayloadBytes = input.reduce(0) { $0 + $1.payload.count }
        var decoded: [NDEFDecodedRecord] = []
        var runningBytes = 0
        for (index, record) in input.enumerated() {
            guard index < limits.maxRecords else { continue }
            guard runningBytes + record.payload.count <= limits.maxTotalBytes else {
                continue
            }
            runningBytes += record.payload.count
            decoded.append(decodeOne(record, index: index, limits: limits))
        }
        let omitted = input.count - decoded.count
        let truncated = omitted > 0
            || decoded.contains { $0.valueTruncated || $0.payloadTruncated }
        return NDEFDecodedMessage(
            records: decoded,
            reportedRecordCount: input.count,
            omittedRecords: omitted,
            totalPayloadBytes: totalPayloadBytes,
            truncated: truncated
        )
    }

    private static func decodeOne(
        _ record: NDEFRawRecord,
        index: Int,
        limits: NDEFDecodingLimits
    ) -> NDEFDecodedRecord {
        var issues: [String] = []
        let payload = record.payload
        let payloadBytes = [UInt8](payload)
        var declaredType: String?
        if !record.type.isEmpty {
            declaredType = asciiStringBound(
                record.type,
                limit: limits.maxDeclaredTypeCharacters,
                issues: &issues
            )
        }
        var identifier: String?
        if let identifierData = record.identifier, !identifierData.isEmpty {
            if let value = String(data: identifierData, encoding: .utf8) {
                if value.count > limits.maxIdentifierCharacters {
                    identifier = String(value.prefix(limits.maxIdentifierCharacters))
                    issues.append("identifierTruncated")
                } else {
                    identifier = value
                }
            } else {
                issues.append("identifierInvalid")
            }
        }

        var decoded = NDEFDecodedRecord(
            index: index,
            kind: .unknown,
            tnf: record.typeNameFormat,
            declaredType: declaredType,
            identifier: identifier,
            text: nil,
            language: nil,
            uri: nil,
            mimeType: nil,
            payloadByteCount: payload.count,
            rawPrefixHex: hexPrefix(payload, limit: limits.maxRawPrefixBytes),
            rawSHA256: sha256(payload),
            valueTruncated: false,
            payloadTruncated: payload.count > limits.maxBytesPerRecord,
            issues: issues
        )
        if decoded.declaredType?.isEmpty == true { decoded.declaredType = nil }

        switch record.typeNameFormat {
        case 0x00:
            decoded.kind = .empty
            if !payload.isEmpty { decoded.issues.append("emptyTNFWithPayload") }
        case 0x01:
            guard let type = decoded.declaredType, !type.isEmpty else {
                decoded.issues.append("wellKnownTypeEmpty")
                return decoded
            }
            switch type {
            case "T":
                decoded.kind = .text
                decodeText(payloadBytes, limits: limits, into: &decoded)
            case "U":
                decoded.kind = .uri
                decodeURI(payloadBytes, limits: limits, into: &decoded)
            default:
                decoded.issues.append("wellKnownTypeUnsupported")
            }
        case 0x02:
            decoded.kind = .mime
            var typeIssues: [String] = []
            decoded.mimeType = asciiStringBound(
                record.type,
                limit: limits.maxDeclaredTypeCharacters,
                issues: &typeIssues
            )
            decoded.issues.append(contentsOf: typeIssues)
            if decoded.mimeType == nil || decoded.mimeType?.isEmpty == true {
                decoded.issues.append("mimeTypeInvalid")
            }
        case 0x03:
            decoded.kind = .uri
            decodeAbsoluteURI(payloadBytes, limits: limits, into: &decoded)
        case 0x04:
            decoded.kind = .external
            if decoded.declaredType == nil || decoded.declaredType?.isEmpty == true {
                decoded.issues.append("externalTypeEmpty")
            }
        case 0x05:
            decoded.kind = .unknown
            decoded.issues.append("tnfUnknown")
        case 0x06:
            decoded.kind = .unknown
            decoded.issues.append("tnfUnchanged")
        default:
            decoded.kind = .unknown
            decoded.issues.append("tnfReserved")
        }
        return decoded
    }

    // MARK: Text RTD

    private static func decodeText(
        _ payload: [UInt8],
        limits: NDEFDecodingLimits,
        into record: inout NDEFDecodedRecord
    ) {
        guard let status = payload.first else {
            record.issues.append("textPayloadEmpty")
            return
        }
        let isUTF16 = status & 0x80 != 0
        let languageLength = Int(status & 0x3F)
        if status & 0x40 != 0 { record.issues.append("textStatusReservedBit") }
        guard payload.count >= 1 + languageLength else {
            record.issues.append("textLanguageLengthExceeded")
            return
        }
        if languageLength > 0 {
            let languageData = Data(payload[1..<(1 + languageLength)])
            var issues: [String] = []
            if let language = asciiStringBound(
                languageData,
                limit: 64,
                issues: &issues
            ) {
                record.language = language
                if language.isEmpty { record.issues.append("textLanguageEmpty") }
            } else {
                record.issues.append("textLanguageInvalid")
            }
            record.issues.append(contentsOf: issues)
        }
        let textData = Data(payload[(1 + languageLength)..<payload.count])
        var issues: [String] = []
        let decoded: String?
        if isUTF16 {
            decoded = utf16String(textData, issues: &issues)
        } else {
            decoded = utf8String(textData, issueCode: "textInvalidUTF8", issues: &issues)
        }
        record.issues.append(contentsOf: issues)
        guard let decoded else { return }
        record.valueTruncated = decoded.count > limits.maxTextCharacters
        record.text = record.valueTruncated
            ? String(decoded.prefix(limits.maxTextCharacters))
            : decoded
    }

    // MARK: URI RTD

    private static func decodeURI(
        _ payload: [UInt8],
        limits: NDEFDecodingLimits,
        into record: inout NDEFDecodedRecord
    ) {
        guard let code = payload.first else {
            record.issues.append("uriPayloadEmpty")
            return
        }
        guard let prefix = uriPrefixes[code] else {
            record.issues.append("uriPrefixUnsupported")
            return
        }
        let suffixData = Data(payload.dropFirst())
        var issues: [String] = []
        guard let suffix = utf8String(
            suffixData,
            issueCode: "uriInvalidUTF8",
            issues: &issues
        ) else {
            record.issues.append(contentsOf: issues)
            return
        }
        record.issues.append(contentsOf: issues)
        finishURI(prefix + suffix, limits: limits, into: &record)
    }

    private static func decodeAbsoluteURI(
        _ payload: [UInt8],
        limits: NDEFDecodingLimits,
        into record: inout NDEFDecodedRecord
    ) {
        var issues: [String] = []
        guard let value = utf8String(
            Data(payload),
            issueCode: "uriInvalidUTF8",
            issues: &issues
        ) else {
            record.issues.append(contentsOf: issues)
            return
        }
        record.issues.append(contentsOf: issues)
        finishURI(value, limits: limits, into: &record)
    }

    private static func finishURI(
        _ value: String,
        limits: NDEFDecodingLimits,
        into record: inout NDEFDecodedRecord
    ) {
        record.valueTruncated = value.count > limits.maxURITextCharacters
        let bounded = record.valueTruncated
            ? String(value.prefix(limits.maxURITextCharacters))
            : value
        record.uri = bounded
        if URLComponents(string: bounded)?.scheme == nil {
            record.issues.append("uriNotAbsolute")
        }
    }

    // MARK: Decoding helpers

    private static func utf8String(
        _ data: Data,
        issueCode: String,
        issues: inout [String]
    ) -> String? {
        guard let value = String(data: data, encoding: .utf8) else {
            issues.append(issueCode)
            return nil
        }
        return value
    }

    private static func utf16String(
        _ data: Data,
        issues: inout [String]
    ) -> String? {
        let decoded: String?
        if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
        } else {
            issues.append("textUTF16MissingBOM")
            decoded = String(data: data, encoding: .utf16)
        }
        if decoded == nil { issues.append("textInvalidUTF16") }
        return decoded
    }

    private static func asciiStringBound(
        _ data: Data,
        limit: Int,
        issues: inout [String]
    ) -> String? {
        guard let value = String(data: data, encoding: .ascii) else {
            issues.append("asciiTypeInvalid")
            return nil
        }
        if value.count > limit {
            issues.append("asciiTypeTruncated")
            return String(value.prefix(limit))
        }
        return value
    }

    private static func hexPrefix(_ data: Data, limit: Int) -> String {
        data.prefix(max(0, limit)).map {
            String(format: "%02x", Int($0))
        }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", Int($0))
        }.joined()
    }
}

enum NDEFOutput {
    /// Renders bounded records for the model. Record text is quoted/escaped
    /// and capped; no URL is opened and no payload is executed.
    static func render(
        _ message: NDEFDecodedMessage,
        limits: NDEFDecodingLimits = NDEFDecodingLimits(),
        sessionTimeoutSeconds: Int? = nil
    ) -> String {
        var rows: [String] = []
        for record in message.records {
            rows.append(render(record))
        }

        var shownRows: [String] = []
        var used = 0
        for row in rows {
            if used + row.count + 1 > 3_600, !shownRows.isEmpty { break }
            shownRows.append(row)
            used += row.count + 1
        }
        let summaryTruncated = shownRows.count < rows.count
        var header = [
            "status=ok",
            "capability=nfc",
            "kind=ndef",
            "tagCount=1",
            "recordCount=\(message.records.count)",
            "reportedRecordCount=\(message.reportedRecordCount)",
            "omittedRecords=\(message.omittedRecords)",
            "totalPayloadBytes=\(message.totalPayloadBytes)",
            "truncated=\(message.truncated)",
            "limits=\"records:\(limits.maxRecords),bytes:\(limits.maxTotalBytes),recordBytes:\(limits.maxBytesPerRecord)\"",
            "summaryRows=\(shownRows.count)",
            "summaryTruncated=\(summaryTruncated)",
            "autoOpened=false",
            "execution=none"
        ]
        if let sessionTimeoutSeconds {
            header.append("sessionSeconds=\(sessionTimeoutSeconds)")
        }
        var joinedHeader = header.joined(separator: " ")
        if !shownRows.isEmpty {
            joinedHeader += "\n" + shownRows.joined(separator: "\n")
        }
        return joinedHeader
    }

    private static func render(_ record: NDEFDecodedRecord) -> String {
        var fields = [
            "record[\(record.index)]",
            "kind=\(record.kind.rawValue)",
            "tnf=\(record.tnf)"
        ]
        if let type = record.declaredType, !type.isEmpty {
            fields.append("type=\"\(quote(type, limit: 128))\"")
        }
        if let identifier = record.identifier, !identifier.isEmpty {
            fields.append("id=\"\(quote(identifier, limit: 128))\"")
        }
        fields.append("bytes=\(record.payloadByteCount)")
        switch record.kind {
        case .text:
            if let text = record.text {
                fields.append("text=\"\(quote(text, limit: 2_048))\"")
            }
            if let language = record.language {
                fields.append("language=\"\(quote(language, limit: 64))\"")
            }
            if let text = record.text {
                fields.append("chars=\(text.count)")
            }
        case .uri:
            if let uri = record.uri {
                fields.append("uri=\"\(quote(uri, limit: 2_048))\"")
                if let scheme = URLComponents(string: uri)?.scheme {
                    fields.append("scheme=\"\(quote(scheme, limit: 32))\"")
                }
            }
            fields.append("autoOpened=false")
        case .mime:
            if let mimeType = record.mimeType {
                fields.append("mimeType=\"\(quote(mimeType, limit: 256))\"")
            }
            fields.append("sha256=\(record.rawSHA256)")
            fields.append("rawPrefixHex=\"\(record.rawPrefixHex)\"")
        case .external:
            fields.append("sha256=\(record.rawSHA256)")
            fields.append("rawPrefixHex=\"\(record.rawPrefixHex)\"")
        case .empty:
            break
        case .unknown:
            fields.append("sha256=\(record.rawSHA256)")
            fields.append("rawPrefixHex=\"\(record.rawPrefixHex)\"")
        }
        if record.kind == .text || record.kind == .uri {
            // Even a decoded text/URI record keeps bounded raw provenance so
            // an invalid/truncated value is not silently normalized away.
            fields.append("sha256=\(record.rawSHA256)")
            fields.append("rawPrefixHex=\"\(record.rawPrefixHex)\"")
        }
        if record.valueTruncated { fields.append("valueTruncated=true") }
        if record.payloadTruncated { fields.append("payloadTruncated=true") }
        if !record.issues.isEmpty {
            fields.append("issues=\"\(record.issues.joined(separator: ","))\"")
        }
        return fields.joined(separator: " ")
    }

    private static func quote(_ value: String, limit: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, limit))
        var count = 0
        for character in value {
            if count >= limit {
                result += "…"
                break
            }
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let scalar = character.unicodeScalars.first,
                   scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u{%04X}", Int(scalar.value))
                } else {
                    result.append(character)
                }
            }
            count += 1
        }
        return result
    }
}
#endif

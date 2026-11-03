// SPDX-License-Identifier: MPL-2.0
//
// Bounded MIME reader (Android port). HTML is inert text and never rendered
// or fetched; attachments keep their original bytes. Charset decoding uses a
// fixed portable IANA mapping because Android Foundation has no
// CoreFoundation charset converter.

import Foundation

/// A bounded MIME reader. HTML is returned as inert text, never rendered or
/// allowed to fetch remote images. Attachments keep their original bytes.
public struct MailDecodedMessage: Sendable {
    public var subject: String
    public var from: String
    public var to: String
    public var date: String
    public var text: String
    public var html: String
    public var attachments: [MailAttachment]
}

public enum MailMIME {
    public static func decode(_ data: Data) throws -> MailDecodedMessage {
        guard data.count <= 16_000_000 else { throw MailFailure.responseTooLarge }
        var count = 0
        var result = MailDecodedMessage(subject: "", from: "", to: "", date: "", text: "", html: "", attachments: [])
        let headers = try split(data).0
        result.subject = decodeHeader(headers["subject"] ?? "")
        result.from = decodeHeader(headers["from"] ?? "")
        result.to = decodeHeader(headers["to"] ?? "")
        result.date = headers["date"] ?? ""
        try part(data, depth: 0, count: &count, result: &result)
        return result
    }
    private static func split(_ data: Data) throws -> ([String: String], Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)), separator.lowerBound <= 65_536 else { throw MailFailure.invalidMessage }
        let headerText = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        var unfolded: [String] = []
        for line in headerText.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !unfolded.isEmpty else { throw MailFailure.invalidMessage }
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else { unfolded.append(line) }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { throw MailFailure.invalidMessage }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw MailFailure.invalidMessage }
            // Duplicate structural headers are ambiguous and fail closed.
            if headers[name] != nil, ["content-type", "content-transfer-encoding", "content-disposition"].contains(name) { throw MailFailure.invalidMessage }
            if headers[name] == nil { headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        return (headers, Data(data[separator.upperBound...]))
    }
    private static func parameter(_ name: String, in header: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let found = MailClient.matches("(?:^|;)\\s*" + escaped + #"=(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))"#, header)
        guard let values = found.first else { return nil }
        return (values[0].isEmpty ? values[1] : values[0]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
    private static func part(_ data: Data, depth: Int, count: inout Int, result: inout MailDecodedMessage) throws {
        count += 1
        guard depth <= 8, count <= 100 else { throw MailFailure.responseTooLarge }
        let (headers, body) = try split(data)
        let type = headers["content-type"] ?? "text/plain"
        let mediaType = type.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: type), !boundary.isEmpty, boundary.utf8.count <= 70,
                  !boundary.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MailFailure.invalidMessage }
            let marker = Data(("--" + boundary).utf8)
            let prefixed = Data("\r\n".utf8) + body
            let delimiter = Data("\r\n".utf8) + marker
            var start: Data.Index?; var cursor = prefixed.startIndex; var closed = false
            while cursor < prefixed.endIndex, let range = prefixed.range(of: delimiter, in: cursor..<prefixed.endIndex) {
                let suffix = prefixed[range.upperBound...]
                let isClose = suffix.starts(with: Data("--".utf8))
                let isOpen = suffix.starts(with: Data("\r\n".utf8))
                cursor = range.upperBound
                guard isClose || isOpen else { continue }
                if let start { try part(Data(prefixed[start..<range.lowerBound]), depth: depth + 1, count: &count, result: &result) }
                if isClose { closed = true; break }
                start = range.upperBound + 2
            }
            guard closed else { throw MailFailure.invalidMessage }
            return
        }
        let decoded: Data
        switch headers["content-transfer-encoding"]?.lowercased() ?? "7bit" {
        case "base64":
            let compact = body.filter { ![9, 10, 13, 32].contains($0) }
            guard let value = Data(base64Encoded: compact) else { throw MailFailure.invalidMessage }; decoded = value
        case "quoted-printable": decoded = try quotedPrintable(body)
        case "7bit", "8bit", "binary": decoded = body
        default: throw MailFailure.invalidMessage
        }
        let disposition = headers["content-disposition"] ?? ""
        var filename = parameter("filename*", in: disposition).flatMap { raw -> String? in
            let pieces = raw.components(separatedBy: "'")
            guard pieces.count == 3, pieces[0].lowercased() == "utf-8" else { return nil }
            return pieces[2].removingPercentEncoding
        } ?? parameter("filename", in: disposition) ?? parameter("name", in: type)
        filename = filename.map(decodeHeader)
        if disposition.lowercased().hasPrefix("attachment") || filename != nil || !["text/plain", "text/html"].contains(mediaType) {
            result.attachments.append(.init(filename: String((filename ?? "attachment-\(result.attachments.count + 1)").prefix(180)), data: decoded))
        } else {
            let content = string(decoded, charset: parameter("charset", in: type) ?? "utf-8")
            if mediaType == "text/html" { result.html += content + "\n" }
            else { result.text += content + "\n" }
        }
    }
    /// Deliberately small, deterministic charset table. Unknown or invalid
    /// names fall back to UTF-8 with replacement, which preserves the bytes as
    /// inert text rather than guessing a locale-dependent encoding.
    static func string(_ data: Data, charset: String) -> String {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        let encoding: String.Encoding?
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii", "": encoding = .utf8
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2", "latin-2": encoding = .isoLatin2
        case "windows-1250", "cp1250": encoding = .windowsCP1250
        case "windows-1251", "cp1251": encoding = .windowsCP1251
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "windows-1253", "cp1253": encoding = .windowsCP1253
        case "windows-1254", "cp1254": encoding = .windowsCP1254
        case "utf-16", "utf16": encoding = .utf16
        case "utf-16le", "utf16le": encoding = .utf16LittleEndian
        case "utf-16be", "utf16be": encoding = .utf16BigEndian
        default: encoding = nil
        }
        if let encoding, let text = String(data: data, encoding: encoding) { return text }
        return String(decoding: data, as: UTF8.self)
    }
    private static func quotedPrintable(_ data: Data) throws -> Data {
        let bytes = Array(data); var output = Data(); var index = 0
        while index < bytes.count {
            if bytes[index] != 61 { output.append(bytes[index]); index += 1; continue }
            guard index + 2 < bytes.count else { throw MailFailure.invalidMessage }
            if bytes[index + 1] == 13 && bytes[index + 2] == 10 { index += 3; continue }
            guard let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { throw MailFailure.invalidMessage }
            output.append(value); index += 3
        }
        return output
    }
    private static func decodeHeader(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return text }
        let original = text as NSString
        var output = ""; var cursor = 0; var previousWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)) {
            let charset = original.substring(with: match.range(at: 1))
            let encoding = original.substring(with: match.range(at: 2)).uppercased()
            let encoded = original.substring(with: match.range(at: 3))
            let bytes = encoding == "B" ? Data(base64Encoded: encoded) : try? quotedPrintable(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8))
            let gap = original.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // RFC 2047: whitespace between adjacent encoded words is not content.
            if !(previousWasEncoded && bytes != nil && gap.allSatisfy(\.isWhitespace)) { output += gap }
            output += bytes.map { string($0, charset: charset) } ?? original.substring(with: match.range)
            previousWasEncoded = bytes != nil
            cursor = NSMaxRange(match.range)
        }
        output += original.substring(from: cursor)
        return output
    }
}

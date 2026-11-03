// SPDX-License-Identifier: MPL-2.0
//
// Explicit RDP server-certificate decisions.
//
// Android has no Apple Security/SecTrust equivalent in the Swift runtime, so
// this implementation deliberately does NOT auto-accept a certificate from a
// system CA or from "first use". It parses the leaf certificate FreeRDP
// presents, verifies its structure and validity window, computes the exact
// SHA-256 fingerprint over the DER leaf, and accepts only when the user has
// already approved that exact fingerprint. Everything else produces a
// challenge the App must show to the user; a changed pin is never downgraded
// or silently replaced.
//
// This is stricter than the iOS donor's optional system-trust path: Android
// has no trust prompt at handshake time, and TOFU auto-success is explicitly
// forbidden by the product contract.

import Foundation
import FloeCore

public enum RDPCertificateChallengeKind: String, Sendable, Equatable {
    case firstUse
    case changed
    case expired
    case notYetValid
}

public struct RDPCertificateChallenge: Sendable, Equatable {
    public let fingerprintSHA256: String
    public let subject: String
    public let host: String
    public let port: Int
    public let notBefore: Date?
    public let notAfter: Date?
    public let kind: RDPCertificateChallengeKind
    public let reason: String

    public init(
        fingerprintSHA256: String,
        subject: String,
        host: String,
        port: Int,
        notBefore: Date?,
        notAfter: Date?,
        kind: RDPCertificateChallengeKind,
        reason: String
    ) {
        self.fingerprintSHA256 = fingerprintSHA256
        self.subject = subject
        self.host = host
        self.port = port
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.kind = kind
        self.reason = reason
    }
}

public struct RDPCertificateEvaluation: Sendable, Equatable {
    public let accepted: Bool
    public let fingerprintSHA256: String
    public let subject: String
    public let reason: String
    public let notBefore: Date?
    public let notAfter: Date?
    public let challengeKind: RDPCertificateChallengeKind?

    public init(
        accepted: Bool,
        fingerprintSHA256: String,
        subject: String,
        reason: String,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        challengeKind: RDPCertificateChallengeKind? = nil
    ) {
        self.accepted = accepted
        self.fingerprintSHA256 = fingerprintSHA256
        self.subject = subject
        self.reason = reason
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.challengeKind = challengeKind
    }
}

public enum RDPCertificateTrust {
    public static let maximumPEMBytes = 256 * 1_024
    public static let maximumCertificates = 16
    public static let maximumDERBytes = 64 * 1_024

    /// Evaluates the leaf certificate. `pinnedSHA256` is an exact leaf-DER
    /// SHA-256 identity previously approved by the user; a nil or malformed
    /// pin never authorizes the connection.
    public static func evaluate(
        pem: Data,
        hostname: String,
        port: Int,
        pinnedSHA256: String?,
        now: Date = Date()
    ) -> RDPCertificateEvaluation {
        let invalid = RDPCertificateEvaluation(
            accepted: false,
            fingerprintSHA256: "",
            subject: "",
            reason: "Invalid certificate payload"
        )
        guard !hostname.isEmpty, hostname.utf8.count <= 255,
              pem.count <= maximumPEMBytes,
              let leaf = leafCertificateDER(pem: pem) else {
            return invalid
        }
        let fingerprint = FloeDigest.sha256Hex(leaf)
        guard let parsed = parseLeaf(der: leaf) else {
            return RDPCertificateEvaluation(
                accepted: false,
                fingerprintSHA256: fingerprint,
                subject: "",
                reason: "The RDP server certificate could not be parsed"
            )
        }
        if let notBefore = parsed.notBefore, now < notBefore {
            return RDPCertificateEvaluation(
                accepted: false,
                fingerprintSHA256: fingerprint,
                subject: parsed.subject,
                reason: "The RDP server certificate is not valid yet",
                notBefore: parsed.notBefore,
                notAfter: parsed.notAfter,
                challengeKind: .notYetValid
            )
        }
        if let notAfter = parsed.notAfter, now > notAfter {
            return RDPCertificateEvaluation(
                accepted: false,
                fingerprintSHA256: fingerprint,
                subject: parsed.subject,
                reason: "The RDP server certificate has expired",
                notBefore: parsed.notBefore,
                notAfter: parsed.notAfter,
                challengeKind: .expired
            )
        }
        let normalizedPin = normalizePin(pinnedSHA256)
        guard let normalizedPin else {
            return RDPCertificateEvaluation(
                accepted: false,
                fingerprintSHA256: fingerprint,
                subject: parsed.subject,
                reason: "Confirm this RDP server certificate before connecting",
                notBefore: parsed.notBefore,
                notAfter: parsed.notAfter,
                challengeKind: .firstUse
            )
        }
        if normalizedPin == fingerprint {
            return RDPCertificateEvaluation(
                accepted: true,
                fingerprintSHA256: fingerprint,
                subject: parsed.subject,
                reason: "Matches the approved certificate fingerprint",
                notBefore: parsed.notBefore,
                notAfter: parsed.notAfter
            )
        }
        return RDPCertificateEvaluation(
            accepted: false,
            fingerprintSHA256: fingerprint,
            subject: parsed.subject,
            reason: "The RDP server certificate differs from the approved fingerprint",
            notBefore: parsed.notBefore,
            notAfter: parsed.notAfter,
            challengeKind: .changed
        )
    }

    /// Normalizes an explicitly approved leaf fingerprint. A malformed value
    /// is rejected rather than treated as "no pin" (which would still be
    /// rejected) or as a match.
    public static func normalizePin(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }) else {
            return nil
        }
        return normalized
    }

    // MARK: - PEM

    static func leafCertificateDER(pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var blocks: [Data] = []
        var cursor = text.startIndex
        while blocks.count < maximumCertificates,
              let beginRange = text.range(of: begin, range: cursor..<text.endIndex) {
            guard let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
                return nil
            }
            let body = text[beginRange.upperBound..<endRange.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard !body.isEmpty,
                  let der = Data(base64Encoded: body),
                  !der.isEmpty,
                  der.count <= maximumDERBytes else {
                return nil
            }
            blocks.append(der)
            cursor = endRange.upperBound
        }
        return blocks.first
    }

    // MARK: - Minimal DER leaf parse

    struct ParsedLeaf: Sendable, Equatable {
        let subject: String
        let notBefore: Date?
        let notAfter: Date?
    }

    private struct DERReader {
        let bytes: [UInt8]
        var offset: Int = 0

        var isAtEnd: Bool { offset >= bytes.count }

        func peekTag() -> UInt8? {
            guard offset < bytes.count else { return nil }
            return bytes[offset]
        }

        mutating func readTLV() -> (tag: UInt8, value: ArraySlice<UInt8>)? {
            guard offset + 2 <= bytes.count else { return nil }
            let tag = bytes[offset]
            var length = Int(bytes[offset + 1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, offset + 2 + count <= bytes.count else { return nil }
                length = 0
                for index in 0..<count {
                    length = (length << 8) | Int(bytes[offset + 2 + index])
                }
                header = 2 + count
            }
            guard length >= 0, offset + header + length <= bytes.count else { return nil }
            let start = offset + header
            let end = start + length
            offset = end
            return (tag, bytes[start..<end])
        }

        static func readConstructed(
            _ value: ArraySlice<UInt8>,
            expectedTag: UInt8
        ) -> DERReader? {
            var reader = DERReader(bytes: Array(value))
            guard let item = reader.readTLV(), item.tag == expectedTag else { return nil }
            return DERReader(bytes: Array(item.value))
        }
    }

    private static func parseLeaf(der: Data) -> ParsedLeaf? {
        var outer = DERReader(bytes: [UInt8](der))
        guard let certificate = outer.readTLV(),
              certificate.tag == 0x30,
              outer.isAtEnd else {
            return nil
        }
        var certificateReader = DERReader(bytes: Array(certificate.value))
        guard let tbs = certificateReader.readTLV(), tbs.tag == 0x30 else { return nil }
        var tbsReader = DERReader(bytes: Array(tbs.value))
        // Optional version [0] EXPLICIT.
        if tbsReader.peekTag() == 0xA0 {
            guard tbsReader.readTLV() != nil else { return nil }
        }
        // serialNumber, signature algorithm, issuer.
        for _ in 0..<3 {
            guard tbsReader.readTLV() != nil else { return nil }
        }
        // validity
        guard let validity = tbsReader.readTLV(), validity.tag == 0x30 else { return nil }
        // subject
        guard let subject = tbsReader.readTLV(), subject.tag == 0x30 else { return nil }

        var validityReader = DERReader(bytes: Array(validity.value))
        guard let notBeforeItem = validityReader.readTLV(),
              let notAfterItem = validityReader.readTLV() else {
            return nil
        }
        let notBefore = parseTime(tag: notBeforeItem.tag, bytes: Array(notBeforeItem.value))
        let notAfter = parseTime(tag: notAfterItem.tag, bytes: Array(notAfterItem.value))
        let subjectString = parseSubject(Array(subject.value)) ?? "certificate"
        return ParsedLeaf(subject: subjectString, notBefore: notBefore, notAfter: notAfter)
    }

    private static func parseSubject(_ bytes: [UInt8]) -> String? {
        var reader = DERReader(bytes: bytes)
        while let set = reader.readTLV() {
            guard set.tag == 0x31 else { continue }
            var setReader = DERReader(bytes: Array(set.value))
            while let sequence = setReader.readTLV() {
                guard sequence.tag == 0x30 else { continue }
                var sequenceReader = DERReader(bytes: Array(sequence.value))
                guard let oid = sequenceReader.readTLV(), oid.tag == 0x06,
                      Array(oid.value) == [0x55, 0x04, 0x03],
                      let value = sequenceReader.readTLV() else {
                    continue
                }
                let text: String?
                switch value.tag {
                case 0x0C, 0x13, 0x16:
                    text = String(bytes: value.value, encoding: .utf8)
                case 0x1E:
                    text = decodeUTF16BE(Array(value.value))
                default:
                    text = nil
                }
                if let text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let bounded = String(trimmed.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0)
                    }.prefix(256))
                    if !bounded.isEmpty { return bounded }
                }
            }
        }
        return nil
    }

    private static func decodeUTF16BE(_ bytes: [UInt8]) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func parseTime(tag: UInt8, bytes: [UInt8]) -> Date? {
        guard let text = String(bytes: bytes, encoding: .ascii) else { return nil }
        let digits = text.filter(\.isNumber)
        let isUTC = tag == 0x17
        guard tag == 0x17 || tag == 0x18 else { return nil }
        let year: Int
        let remainder: Substring
        if isUTC {
            guard digits.count >= 10 else { return nil }
            let yearText = digits.prefix(2)
            guard let shortYear = Int(yearText) else { return nil }
            year = shortYear >= 50 ? 1900 + shortYear : 2000 + shortYear
            remainder = digits.dropFirst(2)
        } else {
            guard digits.count >= 12 else { return nil }
            let yearText = digits.prefix(4)
            guard let fullYear = Int(yearText) else { return nil }
            year = fullYear
            remainder = digits.dropFirst(4)
        }
        guard remainder.count >= 8 else { return nil }
        let monthStart = remainder.startIndex
        let monthEnd = remainder.index(monthStart, offsetBy: 2)
        let dayEnd = remainder.index(monthEnd, offsetBy: 2)
        let hourEnd = remainder.index(dayEnd, offsetBy: 2)
        let minuteEnd = remainder.index(hourEnd, offsetBy: 2)
        guard let month = Int(remainder[monthStart..<monthEnd]),
              let day = Int(remainder[monthEnd..<dayEnd]),
              let hour = Int(remainder[dayEnd..<hourEnd]),
              let minute = Int(remainder[hourEnd..<minuteEnd]) else {
            return nil
        }
        var second = 0
        if remainder.count >= 12 {
            let secondStart = minuteEnd
            let secondEnd = remainder.index(secondStart, offsetBy: 2)
            guard let value = Int(remainder[secondStart..<secondEnd]) else { return nil }
            second = value
        }
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date
    }
}

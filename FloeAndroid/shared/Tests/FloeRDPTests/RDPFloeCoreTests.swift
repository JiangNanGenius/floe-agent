// SPDX-License-Identifier: MPL-2.0
//
// FloeRDP deterministic tests (authored, NOT RUN in this lane). The real
// FreeRDP handshake/frame path requires the Android ARM64 native prefix and
// is covered by the pending device/App qualification; these tests cover the
// exact pixel conversion, frame bounds, key table and explicit certificate
// parsing/fingerprint policy that do not need a socket.

import Foundation
import Testing
@testable import FloeRDP

private let floeTestCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIC5zCCAc+gAwIBAgIJAM3aAAPQu2OaMA0GCSqGSIb3DQEBCwUAMCAxHjAcBgNV
BAMMFWZsb2UtcmRwLXRlc3QuZXhhbXBsZTAeFw0yNjExMDEyMDI1MDhaFw0zNjEw
MjkyMDI1MDhaMCAxHjAcBgNVBAMMFWZsb2UtcmRwLXRlc3QuZXhhbXBsZTCCASIw
DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK9lVl+6/RU5CDz0wH4gdTePodqg
wvLnfSnMOqIs+v7BCbcVJ8znBxhaF/hEcWv1qRlif1DWTB8txPRU5kiP2kGFMBgA
zUEdyyWov7nk/QwQEGJFQ0PnjENnF4kGm8Yvip3mS2DpCAqwcujImqsVea+pMNpo
OZwhUiQRYgqfKws296/SJQldacHtUf+rlnnFSbxdCtGUMNWeZpbMUCZXDFxVGRX2
8chvOPw+8cEMPzsTMzZU0WnGFrmC/NKzRa4u5mQt2OPFQvbOnWgpEtwYpITl2oTs
3gB4m7zWHqZ8ohPMvQV6Zu3fZ+Z+MeV7nwREA49ngVKzN2lYVTf9jlweiLUCAwEA
AaMkMCIwIAYDVR0RBBkwF4IVZmxvZS1yZHAtdGVzdC5leGFtcGxlMA0GCSqGSIb3
DQEBCwUAA4IBAQBY3rp88qxRgLQ9Lah9A0TyzRQ4jHGl4AWHXZn8ehjYNznEfymo
DQaOkmlRxu00fMfEs536y9wuwSB6QzUuJGwsZvBFExUOy2DGl7NrCfeLQmpEhts9
6Fm79Tb3SIcOIa9C4u8aXwjhFMRIw5CzOX7TlJ0tN0yoGXJ1R79OBSicPGwGTF4C
eJN3JGQc8pisY7O32VKcJz44CNIWwshzh8IIszPMV7LH6c7GoXbPVxEU8zAePMfG
d6d1losAcRzVV9YMWx9yR8O9qcEtr2Lq4dy9YS8fS57MrIM/pQSvaeXFdzr7aHKd
9/2tbeOaO/psIVpBg1IktIsQiKEINVWddvJV
-----END CERTIFICATE-----
"""

@Suite("FloeRDP frames, input and explicit certificate trust")
struct RDPFloeCoreTests {
    @Test("BGRA32 with row padding becomes tightly packed RGBA8")
    func pixelConversion() throws {
        // 2x2 BGRA with a 12-byte stride (4 bytes of padding per row).
        var source = Data(count: 24)
        for row in 0..<2 {
            for column in 0..<2 {
                let offset = row * 12 + column * 4
                source[offset] = UInt8(10 + row * 2 + column)      // B
                source[offset + 1] = UInt8(20 + row * 2 + column)  // G
                source[offset + 2] = UInt8(30 + row * 2 + column)  // R
                source[offset + 3] = 255                           // A
            }
        }
        let rgba = try #require(RDPFloePixelFormat.rgbaFromBGRA(
            source,
            width: 2,
            height: 2,
            stride: 12
        ))
        #expect(rgba.count == 16)
        #expect(Array(rgba[0..<4]) == [30, 20, 10, 255])
        #expect(Array(rgba[12..<16]) == [33, 23, 13, 255])
    }

    @Test("Frame bounds reject oversized or truncated buffers")
    func frameBounds() {
        #expect(RDPFloeFrameBounds.validate(width: 0, height: 1) != nil)
        #expect(RDPFloeFrameBounds.validate(width: 4097, height: 1) != nil)
        #expect(RDPFloeFrameBounds.validate(width: 4096, height: 4096) == nil)
        #expect(RDPFloeFrameBounds.validate(width: 4096, height: 4097) != nil)
        let short = Data(count: 4)
        #expect(RDPFloePixelFormat.rgbaFromBGRA(
            short, width: 2, height: 2, stride: 8
        ) == nil)
    }

    @Test("Named keys map to real RDP scancodes")
    func keyTable() {
        #expect(RDPFloeKey.scancode(named: "Return")?.scancode == 0x1C)
        #expect(RDPFloeKey.scancode(named: "Delete")?.extended == true)
        #expect(RDPFloeKey.scancode(named: "F12")?.scancode == 0x58)
        #expect(RDPFloeKey.scancode(named: "not-a-key") == nil)
        #expect(RDPFloeKey.modifierEvents("control", down: true)?.count == 1)
    }

    @Test("An unapproved certificate produces an explicit first-use challenge")
    func certificateRequiresExplicitPin() throws {
        let evaluation = RDPCertificateTrust.evaluate(
            pem: Data(floeTestCertificatePEM.utf8),
            hostname: "floe-rdp-test.example",
            port: 3389,
            pinnedSHA256: nil,
            now: try date(2026, 11, 2)
        )
        #expect(!evaluation.accepted)
        #expect(evaluation.fingerprintSHA256 ==
            "3438db16937ffe898200f634bb30e5d914e058f7514e5dd8205a68cd35a1a81c")
        #expect(evaluation.subject == "floe-rdp-test.example")
        #expect(evaluation.challengeKind == .firstUse)
        #expect(evaluation.notBefore != nil)
        #expect(evaluation.notAfter != nil)
    }

    @Test("Only the exact approved fingerprint is accepted")
    func certificatePinMatchAndMismatch() throws {
        let accepted = RDPCertificateTrust.evaluate(
            pem: Data(floeTestCertificatePEM.utf8),
            hostname: "floe-rdp-test.example",
            port: 3389,
            pinnedSHA256: "3438DB16937FFE898200F634BB30E5D914E058F7514E5DD8205A68CD35A1A81C",
            now: try date(2026, 11, 2)
        )
        #expect(accepted.accepted)
        #expect(accepted.challengeKind == nil)
        let mismatch = RDPCertificateTrust.evaluate(
            pem: Data(floeTestCertificatePEM.utf8),
            hostname: "floe-rdp-test.example",
            port: 3389,
            pinnedSHA256: String(repeating: "0", count: 64),
            now: try date(2026, 11, 2)
        )
        #expect(!mismatch.accepted)
        #expect(mismatch.challengeKind == .changed)
        #expect(mismatch.fingerprintSHA256 ==
            "3438db16937ffe898200f634bb30e5d914e058f7514e5dd8205a68cd35a1a81c")
    }

    @Test("Expired and malformed certificates are refused even with a matching pin")
    func certificateExpiryAndMalformed() throws {
        let expired = RDPCertificateTrust.evaluate(
            pem: Data(floeTestCertificatePEM.utf8),
            hostname: "floe-rdp-test.example",
            port: 3389,
            pinnedSHA256: "3438db16937ffe898200f634bb30e5d914e058f7514e5dd8205a68cd35a1a81c",
            now: try date(2040, 1, 1)
        )
        #expect(!expired.accepted)
        #expect(expired.challengeKind == .expired)
        let malformed = RDPCertificateTrust.evaluate(
            pem: Data("not a certificate".utf8),
            hostname: "floe-rdp-test.example",
            port: 3389,
            pinnedSHA256: "3438db16937ffe898200f634bb30e5d914e058f7514e5dd8205a68cd35a1a81c",
            now: try date(2026, 11, 2)
        )
        #expect(!malformed.accepted)
        #expect(malformed.fingerprintSHA256.isEmpty)
    }

    @Test("Malformed pins never authorize a connection")
    func malformedPin() {
        #expect(RDPCertificateTrust.normalizePin("abc") == nil)
        #expect(RDPCertificateTrust.normalizePin(String(repeating: "g", count: 64)) == nil)
        #expect(RDPCertificateTrust.normalizePin(
            "34:38:db:16:93:7f:fe:89:82:00:f6:34:bb:30:e5:d9:14:e0:58:f7:51:4e:5d:d8:20:5a:68:cd:35:a1:a8:1c"
        ) == "3438db16937ffe898200f634bb30e5d914e058f7514e5dd8205a68cd35a1a81c")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(components.date)
    }
}

import Foundation
import XCTest
@testable import FloeDesktopSync

final class IncrementalAuthenticationPrimitiveTests: XCTestCase {
    func testHMACSHA256MatchesRFC4231TestCaseTwo() throws {
        let key = Array("Jefe".utf8)
        let message = Array("what do ya want for nothing?".utf8)
        let code = HMACSHA256.authenticationCode(key: key, message: message)
        XCTAssertEqual(
            code.map { String(format: "%02x", $0) }.joined(),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
        XCTAssertTrue(HMACSHA256.isValid(tag: code, key: key, message: message))
        var tampered = code
        tampered[0] ^= 0x01
        XCTAssertFalse(HMACSHA256.isValid(tag: tampered, key: key, message: message))
        XCTAssertFalse(HMACSHA256.isValid(tag: code, key: key, message: message + [0x00]))
        XCTAssertFalse(HMACSHA256.isValid(tag: Array(code.dropLast()), key: key, message: message))
    }

    func testProofKeyAndTagValidation() throws {
        XCTAssertThrowsError(
            try SyncProofKey(rawRepresentation: [UInt8](repeating: 0x01, count: 31))
        ) { error in
            XCTAssertEqual(error as? SyncStoreError, .invalidAuthenticationKey)
        }
        let key = try SyncProofKey(rawRepresentation: [UInt8](repeating: 0x02, count: 32))
        XCTAssertFalse(key.description.contains("0202"))
        XCTAssertTrue(key.description.contains("redacted"))
        XCTAssertThrowsError(
            try IncrementalAuthenticationTag(validating: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        )
        XCTAssertThrowsError(
            try IncrementalAuthenticationTag(validating: "hmac-sha256:zzzz")
        )
        let tag = IncrementalAuthenticationTag.compute(key: key, message: [0x01])
        XCTAssertEqual(tag, try IncrementalAuthenticationTag(validating: tag.description))
        XCTAssertNotEqual(tag, IncrementalAuthenticationTag.compute(key: key, message: [0x02]))
        XCTAssertThrowsError(
            try HMACIncrementalAuthenticator.PeerKey(
                peerDeviceID: try TestIDs.device(1),
                keyID: "bad key id",
                key: key
            )
        )
        XCTAssertThrowsError(
            try HMACIncrementalAuthenticator(
                peerKeys: [
                    try .init(
                        peerDeviceID: try TestIDs.device(1),
                        keyID: "dup",
                        key: key
                    ),
                    try .init(
                        peerDeviceID: try TestIDs.device(2),
                        keyID: "dup",
                        key: key
                    )
                ]
            )
        )
    }

    func testAuthenticationResultRejectsUnboundedEvidence() throws {
        let digest = ContentDigest.compute([0x01])
        XCTAssertThrowsError(
            try IncrementalAuthenticationResult(
                peerDeviceID: try TestIDs.device(1),
                authenticationDigest: digest,
                evidence: String(repeating: "x", count: 129)
            )
        )
        XCTAssertThrowsError(
            try IncrementalAuthenticationResult(
                peerDeviceID: try TestIDs.device(1),
                authenticationDigest: digest,
                evidence: "bad\nlabel"
            )
        )
        XCTAssertNoThrow(
            try IncrementalAuthenticationResult(
                peerDeviceID: try TestIDs.device(1),
                authenticationDigest: digest,
                evidence: "hmac-sha256:key-1"
            )
        )
    }

    func testDifferentPeersCannotShareTheSameEffectiveHMACKey() throws {
        let first = try TestIDs.device(3)
        let second = try TestIDs.device(4)
        let raw = [UInt8](repeating: 0x31, count: 32)
        let key = try SyncProofKey(rawRepresentation: raw)
        let zeroPadded = try SyncProofKey(rawRepresentation: raw + [UInt8](repeating: 0, count: 32))
        let longRaw = [UInt8](repeating: 0x53, count: 80)
        let long = try SyncProofKey(rawRepresentation: longRaw)
        let hashedLong = try SyncProofKey(rawRepresentation: SHA256.digest(longRaw))
        let different = try SyncProofKey(rawRepresentation: [UInt8](repeating: 0x77, count: 32))

        // Distinct key IDs do not separate peers holding the same secret.
        // HMAC also regards a zero-padded short key and a hashed long key as
        // the same effective key, even though their raw byte arrays differ.
        for (left, right) in [(key, key), (key, zeroPadded), (long, hashedLong)] {
            let entries = [
                try HMACIncrementalAuthenticator.PeerKey(peerDeviceID: first, keyID: "first", key: left),
                try HMACIncrementalAuthenticator.PeerKey(peerDeviceID: second, keyID: "second", key: right)
            ]
            XCTAssertThrowsError(try HMACIncrementalAuthenticator(peerKeys: entries)) { error in
                guard case .some(.invalidAuthenticationProof(_)) = error as? SyncStoreError else {
                    return XCTFail("Expected an authentication configuration error")
                }
            }
        }

        // Reusing an equivalent key under two IDs for the same peer is safe
        // for peer attribution and remains allowed during key-ID migration.
        XCTAssertNoThrow(try HMACIncrementalAuthenticator(peerKeys: [
            try .init(peerDeviceID: first, keyID: "first", key: key),
            try .init(peerDeviceID: first, keyID: "first-rotated", key: zeroPadded),
            try .init(peerDeviceID: second, keyID: "second", key: different)
        ]))
    }
}

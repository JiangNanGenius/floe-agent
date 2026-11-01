import CryptoKit
import XCTest
@testable import FloeIOSAutomation

final class EnvelopeContractTests: XCTestCase {
    func testReleasedRequestAndResponseVectors() throws {
        // Vector from the released Bridge source test suite, generated
        // independently with Python's hashlib/hmac for the pinned v1 wire.
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0..<16).map(UInt8.init))
        let timestamp = 1_700_000_000
        let plaintext = Data(#"{"id":1,"jsonrpc":"2.0","method":"device_info"}"#.utf8)

        let request = try IOSBridgeEnvelope.sealRequest(
            plaintext,
            key: key,
            nonce: nonce,
            timestamp: timestamp
        )
        let object = try XCTUnwrap(request.objectValue)
        XCTAssertEqual(object["v"], .int(1))
        XCTAssertEqual(object["tok"]?.stringValue, "630dcd29")
        XCTAssertEqual(object["ts"], .int(1_700_000_000))
        XCTAssertEqual(object["nonce"]?.stringValue, "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(
            object["ct"]?.stringValue,
            "LBWCQvXPN3n1VJyojcZyCT+qamW0x3ZEeZftn9zQ5NohSRVhTnMrexYNVUnnbeo="
        )
        XCTAssertEqual(
            object["tag"]?.stringValue,
            "59519f46ceec95fbc41aad96b85098cae37fc8e91f4f63b5228bcc672fb0d0fe"
        )

        let opened = try IOSBridgeEnvelope.openRequest(request, key: key)
        XCTAssertEqual(opened.plaintext, plaintext)
        XCTAssertEqual(opened.parsed.nonceHex, "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(opened.parsed.timestamp, timestamp)

        let responsePlaintext = Data(
            #"{"id":1,"jsonrpc":"2.0","result":{"ok":true}}"#.utf8
        )
        let sealed = try IOSBridgeEnvelope.sealResponse(
            responsePlaintext,
            key: key,
            nonce: nonce
        )
        let responseObject = try XCTUnwrap(sealed.objectValue)
        XCTAssertEqual(
            responseObject["ct"]?.stringValue,
            "LWca1EWiHk4JimI4eCduEwxp3qSclaRMXU5BQkcw6Yo8vWPtRDu1cZH3okaD"
        )
        XCTAssertEqual(
            responseObject["tag"]?.stringValue,
            "d8c8bbce687a80a243893a2507821623f37b76d0abd24246c2e301a2b211fbc1"
        )
        XCTAssertEqual(
            try IOSBridgeEnvelope.openResponse(
                sealed,
                key: key,
                expectedNonceHex: IOSBridgeEnvelope.hexLowercase(nonce)
            ),
            responsePlaintext
        )
    }

    func testStrictEnvelopeRejection() throws {
        let key = Data(repeating: 7, count: 32)
        let nonce = Data(repeating: 9, count: 16)
        let good = try IOSBridgeEnvelope.sealRequest(
            Data("{}".utf8),
            key: key,
            nonce: nonce,
            timestamp: 1_700_000_000
        )
        var object = try XCTUnwrap(good.objectValue)

        object["tok"] = .string("630DCD29")
        XCTAssertThrowsError(try IOSBridgeEnvelope.parseRequest(.object(object))) { error in
            XCTAssertEqual((error as? IOSBridgeEnvelope.Failure)?.code, "bad_envelope")
        }

        object = try XCTUnwrap(good.objectValue)
        object["ts"] = .double(1_700_000_000.5)
        XCTAssertThrowsError(try IOSBridgeEnvelope.parseRequest(.object(object)))

        object = try XCTUnwrap(good.objectValue)
        object["ct"] = .string("!!!!")
        XCTAssertThrowsError(try IOSBridgeEnvelope.parseRequest(.object(object)))

        object = try XCTUnwrap(good.objectValue)
        object["tag"] = .string(String(repeating: "0", count: 64))
        let parsed = try IOSBridgeEnvelope.parseRequest(.object(object))
        XCTAssertThrowsError(try IOSBridgeEnvelope.openRequest(.object(object), key: key)) { error in
            XCTAssertEqual((error as? IOSBridgeEnvelope.Failure)?.code, "auth_failed")
        }
        XCTAssertEqual(parsed.tokenID, IOSBridgeEnvelope.tokenID(for: key))

        let response = try IOSBridgeEnvelope.sealResponse(
            Data("{}".utf8),
            key: key,
            nonce: nonce
        )
        XCTAssertThrowsError(
            try IOSBridgeEnvelope.openResponse(
                response,
                key: key,
                expectedNonceHex: String(repeating: "0", count: 32)
            )
        )
    }

    func testCiphertextAndResponseCaps() throws {
        let key = Data(repeating: 1, count: 32)
        let nonce = Data(repeating: 2, count: 16)
        let request = try IOSBridgeEnvelope.sealRequest(
            Data(repeating: 0x41, count: 64),
            key: key,
            nonce: nonce,
            timestamp: 1_700_000_000
        )
        XCTAssertThrowsError(
            try IOSBridgeEnvelope.parseRequest(request, maxCiphertextBytes: 8)
        )
        let response = try IOSBridgeEnvelope.sealResponse(
            Data(repeating: 0x42, count: 64),
            key: key,
            nonce: nonce
        )
        XCTAssertThrowsError(
            try IOSBridgeEnvelope.openResponse(
                response,
                key: key,
                expectedNonceHex: IOSBridgeEnvelope.hexLowercase(nonce),
                maxCiphertextBytes: 8
            )
        )
    }

    func testNonCanonicalResponseBase64IsRejected() throws {
        let key = Data(repeating: 3, count: 32)
        let nonce = Data(repeating: 4, count: 16)
        let sealed = try IOSBridgeEnvelope.sealResponse(
            Data("{}".utf8),
            key: key,
            nonce: nonce
        )
        var object = try XCTUnwrap(sealed.objectValue)
        object["ct"] = .string((object["ct"]?.stringValue ?? "") + "\n")
        XCTAssertThrowsError(
            try IOSBridgeEnvelope.openResponse(
                .object(object),
                key: key,
                expectedNonceHex: IOSBridgeEnvelope.hexLowercase(nonce)
            )
        )
    }

    func testX25519WrapAndUnwrap() throws {
        let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
        let clientPublic = clientPrivate.publicKey.rawRepresentation
        let key = testKey(9)
        let wrapped = try FixtureCrypto.wrapKey(key: key, clientPublicKey: clientPublic)
        let devicePublic = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: wrapped.devicePublicKey
        )
        let shared = try clientPrivate.sharedSecretFromKeyAgreement(with: devicePublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let unwrapped = try XCTUnwrap(
            IOSBridgeEnvelope.unwrapKey(
                tokenCiphertext: wrapped.tokenCiphertext,
                sharedSecret: sharedData,
                clientPublicKey: clientPublic,
                devicePublicKey: wrapped.devicePublicKey
            )
        )
        XCTAssertEqual(unwrapped, key)
        XCTAssertEqual(IOSBridgeEnvelope.tokenID(for: unwrapped), IOSBridgeEnvelope.tokenID(for: key))

        let wrongPrivate = Curve25519.KeyAgreement.PrivateKey()
        let wrongShared = try wrongPrivate.sharedSecretFromKeyAgreement(with: devicePublic)
        let wrongData = wrongShared.withUnsafeBytes { Data($0) }
        let wrongKey = IOSBridgeEnvelope.unwrapKey(
            tokenCiphertext: wrapped.tokenCiphertext,
            sharedSecret: wrongData,
            clientPublicKey: clientPublic,
            devicePublicKey: wrapped.devicePublicKey
        )
        XCTAssertNotEqual(wrongKey, key)
    }

    func testTokenIDFingerprintAndRandom() throws {
        let key = Data((0..<32).map(UInt8.init))
        XCTAssertEqual(IOSBridgeEnvelope.tokenID(for: key), "630dcd29")
        XCTAssertEqual(IOSBridgeEnvelope.fingerprint(publicKey: key).count, 8)
        let random = try XCTUnwrap(IOSBridgeEnvelope.randomBytes(16))
        XCTAssertEqual(random.count, 16)
        XCTAssertEqual(IOSBridgeEnvelope.randomBytes(0), Data())
        XCTAssertNil(IOSBridgeEnvelope.randomBytes(-1))
    }
}

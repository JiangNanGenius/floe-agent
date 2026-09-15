// SPDX-License-Identifier: MPL-2.0
#if canImport(Security)
import Foundation
import Testing
@testable import FloeVNC

@Suite("RDP certificate identity")
struct RDPCertificateTrustTests {
    // Generated self-signed public test certificate; its private key is discarded.
    private let pem = Data("""
-----BEGIN CERTIFICATE-----
MIICwDCCAagCCQDYHP956HPbADANBgkqhkiG9w0BAQsFADAiMSAwHgYDVQQDDBdG
bG9lIFN5bnRoZXRpYyBSRFAgVGVzdDAeFw0yNjA5MTUxNDUyMDZaFw0yNjA5MTYx
NDUyMDZaMCIxIDAeBgNVBAMMF0Zsb2UgU3ludGhldGljIFJEUCBUZXN0MIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxvXHt6M0Y+kY7ispctBNMzCFH9s/
F7BQt570WVLNBHaht5DaOp4Zh8oMqmbIDqMAscMc3ztQBfA/ssXX31psGPeWrpCt
hmiE6HJztBBSoWseJgYNL72f/Rtxa97kCI/EJZo0HDIx3Z8/UM8KHUnKtVhk8CoD
/9V76KnhumKutJExmiA73QY8ni7gukCTJwKIzQ0F85Ut+QQgS0a55Sqbi7Qux/Xl
9z9AbeAA9SMjgRXfFJtxkpfx4WdX3/uysT7LRt0H3KIfxT7Z71DANoZXzCvNQ7FY
oI8m6P+PExWnoKPz8bYmtQ+lyfBFxJiLe0ceObSHM99Co4zxn5Qt8Neq5QIDAQAB
MA0GCSqGSIb3DQEBCwUAA4IBAQBs7kf1wKUsyrDAHMlsBoYwBpIZ8zmnHtoc6bJu
lrv4sNlzG8qiyAUtEt/9zX1WJovpk23i2tjiocUIe/Jfx3hGMznSnlf0KQVMyRFh
Igkm7cM6+l+mq/NbeFF8fMScGqr8lW9B55YB9XwU0XcKyVjm7vyxYItvhBfrz57K
5Pq6DxZeSX/cl6wnDeA33TH6IL90o4wr277cPuyxYDInjsddyTsAyyKpge3ahZQ8
hZATD3LSlgY6pOIoglcWBkuUQp8hpVuiIciiQ65Xu/ezjUJd8bF01kKPK2UzoE+Z
ZKyqThsr/JV2lLQtH3cjfYeURsATfso72z6qeIzaH4qHQSrA
-----END CERTIFICATE-----
""".utf8)

    @Test("Unknown self-signed certificate needs explicit confirmation")
    func requiresConfirmation() {
        let result = RDPCertificateTrust.evaluate(pem: pem, hostname: "localhost", pinnedSHA256: nil)
        #expect(!result.accepted)
        #expect(result.fingerprintSHA256.count == 64)
    }
    @Test("Explicit leaf pin accepts exactly that identity, even after fixture expiry")
    func exactPin() {
        let identity = RDPCertificateTrust.evaluate(pem: pem, hostname: "localhost", pinnedSHA256: nil).fingerprintSHA256
        #expect(identity.count == 64)
        let accepted = RDPCertificateTrust.evaluate(pem: pem, hostname: "localhost", pinnedSHA256: identity.uppercased())
        #expect(accepted.accepted)
        let changed = RDPCertificateTrust.evaluate(pem: pem, hostname: "localhost", pinnedSHA256: String(repeating: "0", count: 64))
        #expect(!changed.accepted)
        #expect(changed.fingerprintSHA256 == identity)
    }
    @Test("Malformed chains and malformed pins never bypass validation")
    func malformed() {
        for pin in ["short", String(repeating: "z", count: 64)] {
            #expect(!RDPCertificateTrust.evaluate(pem: pem, hostname: "localhost", pinnedSHA256: pin).accepted)
        }
        for bad in [Data(), Data("garbage".utf8), Data(repeating: 65, count: 256 * 1024 + 1)] {
            let result = RDPCertificateTrust.evaluate(pem: bad, hostname: "localhost", pinnedSHA256: nil)
            #expect(!result.accepted)
            #expect(result.fingerprintSHA256.isEmpty)
        }
    }
}
#endif

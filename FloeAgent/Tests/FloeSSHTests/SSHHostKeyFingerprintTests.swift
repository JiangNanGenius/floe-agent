import Testing
@testable import FloeSSH

@Suite("FloeSSH host key fingerprints")
struct SSHHostKeyFingerprintTests {
    @Test("Fingerprint hashes the decoded OpenSSH key blob")
    func computesStandardFingerprint() throws {
        let parsed = try #require(SSHHostKeyFingerprint.parse(
            openSSH: "ssh-ed25519 YWJj validation-comment"
        ))
        #expect(parsed.keyType == "ssh-ed25519")
        #expect(parsed.fingerprintSHA256 == "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }

    @Test("Normalization accepts standard display variants")
    func normalizesDisplayVariants() {
        #expect(SSHHostKeyFingerprint.normalize(" SHA256:abc=\n") == "abc")
        #expect(SSHHostKeyFingerprint.normalize("sha256:abc") == "abc")
    }

    @Test("Malformed keys are rejected")
    func rejectsMalformedKey() {
        #expect(SSHHostKeyFingerprint.parse(openSSH: "ssh-ed25519 not-base64!") == nil)
    }
}

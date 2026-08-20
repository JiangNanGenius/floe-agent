import Testing
@testable import FloeSecurity

@Suite("Secret ingress scanner")
struct SecretIngressScannerTests {
    @Test("Replaces labelled password and token values")
    func labelledSecrets() {
        let input = "账号 alice\n密码: correct horse battery staple\nAPI_KEY=sk-live-secret"
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 2)
        #expect(!result.sanitizedText.contains("correct horse battery staple"))
        #expect(!result.sanitizedText.contains("sk-live-secret"))
        #expect(result.sanitizedText.contains("⟨credential:"))
    }

    @Test("Private key blocks never remain in persisted text")
    func privateKey() {
        let input = """
        请连接服务器
        -----BEGIN OPENSSH PRIVATE KEY-----
        ZmFrZS1zZWNyZXQ=
        -----END OPENSSH PRIVATE KEY-----
        """
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 1)
        #expect(!result.sanitizedText.contains("OPENSSH PRIVATE KEY"))
        #expect(result.captures.first?.label == "private key")
    }
}

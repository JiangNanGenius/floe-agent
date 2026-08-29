import Testing
@testable import FloeSecurity

@Suite("Secret ingress scanner")
struct SecretIngressScannerTests {
    @Test("Replaces labelled password and token values")
    func labelledSecrets() {
        let input = "账号 alice\n密码: \"correct horse battery staple\"\nAPI_KEY=sk-live-secret"
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 2)
        #expect(!result.sanitizedText.contains("correct horse battery staple"))
        #expect(!result.sanitizedText.contains("sk-live-secret"))
        #expect(result.sanitizedText.contains("密码:"))
        #expect(result.sanitizedText.contains("API_KEY="))
        #expect(result.sanitizedText.contains("⟨credential:"))
    }

    @Test("Captures explicit English and Chinese is/为 password wording")
    func explicitIsWording() {
        let input = "SSH password is ssh-secret\nVNC 密码为vnc-密码"
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 2)
        #expect(!result.sanitizedText.contains("ssh-secret"))
        #expect(!result.sanitizedText.contains("vnc-密码"))
        #expect(result.captures.map(\.label) == ["SSH password", "VNC password"])
    }

    @Test("Captures quoted passwords containing spaces")
    func quotedPassword() {
        let input = "password: \"correct horse battery staple\""
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 1)
        #expect(!result.sanitizedText.contains("correct horse battery staple"))
    }

    @Test("Leaves password-related prose without a supplied value intact")
    func avoidsFalsePositives() {
        let input = "密码是什么？\npassword is required\n请打开 password manager\n密码是你设置的\n密码是 abc123 然后连接"
        let result = SecretIngressScanner.scan(input)
        #expect(result.captures.count == 1)
        #expect(result.sanitizedText.contains("密码是你设置的"))
        #expect(result.sanitizedText.contains("然后连接"))
        #expect(!result.sanitizedText.contains("abc123"))
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

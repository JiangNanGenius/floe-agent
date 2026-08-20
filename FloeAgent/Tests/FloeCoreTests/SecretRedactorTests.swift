// FloeCoreTests — Secret redaction contract. Secrets must never reach logs,
// errors or persisted diagnostics unmasked.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.SecretRedactor")
struct SecretRedactorTests {

    @Test("Bearer tokens are masked")
    func bearerMasked() {
        let input = "Authorization: Bearer sk-live-abcdef1234567890 failed"
        let output = SecretRedactor.redact(input)
        #expect(!output.contains("sk-live-abcdef1234567890"))
        #expect(output.contains(SecretRedactor.replacement))
    }

    @Test("OpenAI-style sk- keys are masked")
    func openAIKeyMasked() {
        let input = "invalid key sk-abcdefghijklmnop"
        let output = SecretRedactor.redact(input)
        #expect(!output.contains("sk-abcdefghijklmnop"))
    }

    @Test("x-api-key header values are masked")
    func apiKeyHeaderMasked() {
        let input = #"{"x-api-key": "sk-ant-abc12345678"}"#
        let output = SecretRedactor.redact(input)
        #expect(!output.contains("sk-ant-abc12345678"))
    }

    @Test("Explicit verbatim secret is masked everywhere it appears")
    func verbatimSecretMasked() {
        let secret = "hunter2-super-secret"
        let input = "connect failed: password is hunter2-super-secret; retry hunter2-super-secret"
        let output = SecretRedactor.redact(input, secret: secret)
        #expect(!output.contains(secret))
    }

    @Test("Non-secret text is left intact")
    func plainTextIntact() {
        let input = "rate limit exceeded, retry after 30 seconds"
        #expect(SecretRedactor.redact(input) == input)
    }

    @Test("Empty and nil secrets are no-ops beyond pattern redaction")
    func emptySecretNoOp() {
        let input = "nothing to hide"
        #expect(SecretRedactor.redact(input, secret: nil) == input)
        #expect(SecretRedactor.redact(input, secret: "") == input)
    }
}

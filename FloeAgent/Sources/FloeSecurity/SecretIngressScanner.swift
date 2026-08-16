import Foundation

public struct CapturedSecret: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var value: Data
    public var placeholder: String

    public init(id: UUID = UUID(), label: String, value: Data) {
        self.id = id
        self.label = label
        self.value = value
        self.placeholder = "⟨credential:\(id.uuidString)⟩"
    }
}

public struct SecretIngressResult: Sendable, Hashable {
    public var sanitizedText: String
    public var captures: [CapturedSecret]
}

/// Conservative local ingress scanner. It only captures explicit credential
/// labels and PEM private-key blocks; ambiguous prose is left untouched.
public enum SecretIngressScanner {
    public static func scan(_ text: String) -> SecretIngressResult {
        var sanitized = text
        var captures: [CapturedSecret] = []
        let patterns = [
            #"(?is)-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#,
            #"(?i)\b(password|passwd|passphrase|密码|口令|api[-_ ]?key|token|secret)\s*[:=：]\s*([^\s,，;；]{4,})"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            while true {
                let range = NSRange(sanitized.startIndex..., in: sanitized)
                guard let match = expression.firstMatch(in: sanitized, range: range),
                      let matchRange = Range(match.range, in: sanitized) else { break }
                let full = String(sanitized[matchRange])
                let value: String
                let label: String
                if match.numberOfRanges >= 3,
                   let labelRange = Range(match.range(at: 1), in: sanitized),
                   let valueRange = Range(match.range(at: 2), in: sanitized) {
                    label = String(sanitized[labelRange])
                    value = String(sanitized[valueRange])
                } else {
                    label = "private key"
                    value = full
                }
                guard let data = value.data(using: .utf8) else { break }
                let capture = CapturedSecret(label: label, value: data)
                captures.append(capture)
                // Replace the complete labelled assignment. Replacing only
                // its value leaves `password: <placeholder>` matching this
                // same expression forever and can hang message submission.
                sanitized.replaceSubrange(matchRange, with: capture.placeholder)
            }
        }
        return SecretIngressResult(sanitizedText: sanitized, captures: captures)
    }
}

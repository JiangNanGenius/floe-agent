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
        self.placeholder = Self.placeholder(for: id)
    }

    public static func placeholder(for id: UUID) -> String {
        "⟨credential:\(id.uuidString)⟩"
    }
}

public struct SecretIngressResult: Sendable, Hashable {
    public var sanitizedText: String
    public var captures: [CapturedSecret]
}

/// Conservative local ingress scanner. It only captures explicit credential
/// labels and PEM private-key blocks; ambiguous prose is left untouched.
public enum SecretIngressScanner {
    private static let labelledSecretPattern = #"(?is)(?<![\p{L}\p{N}_])(password|passwd|passphrase|密码|口令|api[-_ ]?key|token|secret)\s*(?:(?:is)\s+|(?:为|是)\s*|[:=：]\s*)"#
    private static let quotedValuePattern = labelledSecretPattern + #"["“‘]([^\r\n"”’]{4,256})["”’]"#
    private static let unquotedValuePattern = labelledSecretPattern + #"([^\r\n,，;；。.!?！？…]{4,})"#
    private static let nonSecretValues: Set<String> = [
        "blank", "empty", "example", "missing", "none", "null", "optional",
        "required", "same", "unchanged", "unknown", "whatever"
    ]

    public static func credentialID(from placeholder: String) -> UUID? {
        let prefix = "⟨credential:"
        guard placeholder.hasPrefix(prefix), placeholder.hasSuffix("⟩") else { return nil }
        return UUID(uuidString: String(placeholder.dropFirst(prefix.count).dropLast()))
    }

    public static func scan(_ text: String) -> SecretIngressResult {
        var sanitized = text
        var captures: [CapturedSecret] = []
        let patterns = [
            #"(?is)-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#,
            quotedValuePattern,
            unquotedValuePattern
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            var searchLocation = 0
            while true {
                let range = NSRange(
                    location: searchLocation,
                    length: sanitized.utf16.count - searchLocation
                )
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
                let capturedValue = label == "private key"
                    ? value
                    : value.trimmingCharacters(in: .whitespacesAndNewlines)
                if match.numberOfRanges >= 3,
                   label != "private key",
                   Self.nonSecretValues.contains(capturedValue.lowercased()) {
                    // Phrases such as "password is required" describe a
                    // form or policy, not a credential. Leave them intact.
                    searchLocation = NSMaxRange(match.range)
                    continue
                }
                guard let data = capturedValue.data(using: .utf8) else { break }
                let capture = CapturedSecret(label: label, value: data)
                captures.append(capture)
                // Replace the complete labelled assignment. Replacing only
                // its value leaves `password: <placeholder>` matching this
                // same expression forever and can hang message submission.
                sanitized.replaceSubrange(matchRange, with: capture.placeholder)
                searchLocation = 0
            }
        }
        return SecretIngressResult(sanitizedText: sanitized, captures: captures)
    }
}

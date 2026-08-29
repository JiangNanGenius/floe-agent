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
    // Unquoted credentials stop at whitespace so a request such as
    // "密码是 abc 然后连接" keeps the action text. Credentials containing
    // spaces remain supported through the quoted form above.
    private static let unquotedValuePattern = labelledSecretPattern + #"([^\s\r\n,，;；。.!?！？…]{4,256})"#
    private static let nonSecretValues: Set<String> = [
        "blank", "empty", "example", "missing", "none", "null", "optional",
        "required", "same", "unchanged", "unknown", "whatever",
        "你设置的", "我设置的", "之前那个", "还是之前的", "没有设置", "不正确"
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
                if label != "private key", capturedValue.contains("⟨credential:") {
                    searchLocation = NSMaxRange(match.range)
                    continue
                }
                if match.numberOfRanges >= 3,
                   label != "private key",
                   Self.nonSecretValues.contains(capturedValue.lowercased()) {
                    // Phrases such as "password is required" describe a
                    // form or policy, not a credential. Leave them intact.
                    searchLocation = NSMaxRange(match.range)
                    continue
                }
                guard let data = capturedValue.data(using: .utf8) else { break }
                let semanticLabel = label == "private key"
                    ? label
                    : contextualLabel(baseLabel: label, text: sanitized, matchRange: match.range)
                let capture = CapturedSecret(label: semanticLabel, value: data)
                captures.append(capture)
                if match.numberOfRanges >= 3,
                   label != "private key",
                   let valueRange = Range(match.range(at: 2), in: sanitized) {
                    // Preserve the user's wording and only replace the secret
                    // value. This keeps intent such as "VNC 密码是 …" visible
                    // beside the secure card instead of making the message
                    // appear rewritten by the app.
                    sanitized.replaceSubrange(valueRange, with: capture.placeholder)
                    searchLocation = match.range(at: 2).location + capture.placeholder.utf16.count
                } else {
                    sanitized.replaceSubrange(matchRange, with: capture.placeholder)
                    searchLocation = match.range.location + capture.placeholder.utf16.count
                }
            }
        }
        return SecretIngressResult(sanitizedText: sanitized, captures: captures)
    }

    /// Keeps enough non-secret intent beside an opaque credential card for a
    /// later model turn to find the right card. The raw value is never copied
    /// into this metadata.
    private static func contextualLabel(
        baseLabel: String,
        text: String,
        matchRange: NSRange
    ) -> String {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: matchRange)
        let line = nsText.substring(with: lineRange).lowercased()
        let normalized = baseLabel.lowercased()

        if line.contains("vnc") {
            return normalized.contains("token") || normalized.contains("key")
                ? "VNC credential"
                : "VNC password"
        }
        if line.contains("ssh") || line.contains("远程主机") {
            return normalized.contains("key") || normalized.contains("private")
                ? "SSH private key"
                : "SSH password"
        }
        if line.contains("api") || normalized.contains("api") {
            return "Provider API key"
        }
        if line.contains("网站") || line.contains("后台") || line.contains("登录") {
            return "Website password"
        }
        return baseLabel
    }
}

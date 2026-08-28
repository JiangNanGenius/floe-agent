// FloeCore — Secret redaction for logs, errors and diagnostics.
// See docs/ALPHA_DAILY_PLAN.md: never persist or log raw API keys, passwords
// or private-key passphrases. This helper scrubs bearer tokens, x-api-key
// values and common credential shapes from arbitrary text before it reaches
// a log or error surface.

import Foundation

/// Redacts credential-shaped substrings from text destined for logs or
/// user-facing error output. Value type; no state.
public enum SecretRedactor {

    /// A conservative replacement token that preserves the fact that a value
    /// was present without revealing it.
    public static let replacement = "⟨redacted⟩"

    /// Returns `text` with common credential shapes masked. This is
    /// defense-in-depth: secrets should never reach these surfaces in the
    /// first place, but any that slip through are masked here.
    public static func redact(_ text: String) -> String {
        var result = text
        // Bearer tokens: "Bearer <token>".
        result = replace(#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, in: result, with: "Bearer \(replacement)")
        // x-api-key / api_key / apikey header values in serialized form.
        result = replace(#"(?i)(x-api-key|api[-_]?key|authorization)["'\s:=]+[A-Za-z0-9._\-]+"#,
                         in: result, with: "$1 \(replacement)")
        // OpenAI-style keys (sk-...), Anthropic (sk-ant-...).
        result = replace(#"\bsk-[A-Za-z0-9\-]{8,}"#, in: result, with: replacement)
        // Generic long hex/base64 secrets (>= 32 chars) that follow "key"/"token"/"secret".
        result = replace(#"(?i)(key|token|secret|password|passphrase)["'\s:=]+[A-Za-z0-9+/=_\-]{16,}"#,
                         in: result, with: "$1 \(replacement)")
        // JSON tool arguments may legitimately contain short VNC passwords.
        // Redact the value by field name regardless of length so timeline
        // diagnostics never echo it back.
        result = replace(
            #"(?i)(["']?(?:password|passwd|passphrase)["']?\s*:\s*["'])[^"']*(["'])"#,
            in: result,
            with: "$1\(replacement)$2"
        )
        return result
    }

    /// Redacts an explicit secret value wherever it appears verbatim.
    /// Use when the concrete secret is known at the call site.
    public static func redact(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return redact(text) }
        return redact(text.replacingOccurrences(of: secret, with: replacement))
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}

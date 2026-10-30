// FloeAgentRuntime — persistence-boundary scrubbing for explicit secret
// tool arguments.
//
// Browser/Cookie work legitimately puts `Cookie` and `Authorization` header
// values inside a tool request. The live request must keep those exact bytes
// (the user authorized the read), but durable evidence must not: checkpoints,
// run-event payloads and logs are long-lived and may be exported. This
// sanitizer returns a COPY for persistence and never mutates the live
// `ToolCall`, so the real dispatch is unchanged.
//
// Scope is deliberately narrow: only header/argument names whose value is a
// credential. It does not try to be a general secret scanner and does not
// depend on a global registry.

import Foundation
import FloeModels

public enum ToolArgumentSanitizer {
    /// Case-insensitive names whose value is a credential when found in a
    /// tool-argument object. For a container value (cookie object/array or a
    /// storage setter) the credential child is masked while metadata such as
    /// name/domain/path/expires/area is preserved.
    static let sensitiveNames: Set<String> = [
        "cookie", "cookies", "set-cookie",
        "authorization", "proxy-authorization",
        "x-api-key", "api-key", "x-auth-token",
        "access_token", "refresh_token", "id_token"
    ]

    /// Containers whose `value` is credential material even though the
    /// container key itself (`storage`, `localStorage`, …) is metadata.
    static let credentialContainerNames: Set<String> = [
        "storage", "localstorage", "sessionstorage", "cookiestorage", "storagearea"
    ]

    public static func redactedArgumentsJSON(
        _ data: Data,
        toolName: String? = nil
    ) -> Data {
        let storageSetter = isBrowserStorageSetter(toolName)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return Data(redactedText(String(decoding: data, as: UTF8.self)).utf8)
        }
        let scrubbed = scrub(
            object,
            credentialContext: false,
            storageSetter: storageSetter
        )
        guard JSONSerialization.isValidJSONObject(scrubbed),
              let encoded = try? JSONSerialization.data(
                withJSONObject: scrubbed,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return Data(redactedText(String(decoding: data, as: UTF8.self)).utf8)
        }
        return encoded
    }

    public static func redactedArgumentText(
        _ text: String,
        toolName: String? = nil
    ) -> String {
        String(decoding: redactedArgumentsJSON(Data(text.utf8), toolName: toolName), as: UTF8.self)
    }

    /// True when the arguments contain a credential-shaped key/container.
    /// Used to mark a pending operation as not safely replayable from a
    /// redacted checkpoint; it never mutates the call or logs the value.
    public static func containsSensitiveValues(
        _ data: Data,
        toolName: String? = nil
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            let lowered = String(decoding: data, as: UTF8.self).lowercased()
            return sensitiveNames.contains { lowered.contains("\"\($0)\"") }
        }
        let storageSetter = isBrowserStorageSetter(toolName)
            && (object as? [String: Any]).map {
                ($0["action"] as? String)?.lowercased() == "set"
            } == true
        return containsSensitive(
            object,
            credentialContext: false,
            storageSetter: storageSetter
        )
    }

    private static func isBrowserStorageSetter(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let canonical = toolName.lowercased().replacingOccurrences(of: "_", with: ".")
        return canonical == "browser.storage"
    }

    /// Copy of a call suitable for a checkpoint, event payload or log. The
    /// caller keeps and dispatches the original call.
    public static func sanitizedForPersistence(_ call: ToolCall) -> ToolCall {
        var copy = call
        copy.argumentsJSON = redactedArgumentsJSON(
            call.argumentsJSON,
            toolName: call.toolName
        )
        return copy
    }

    private static func containsSensitive(
        _ value: Any,
        credentialContext: Bool,
        storageSetter: Bool
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let name = dictionary["name"] as? String,
               sensitiveNames.contains(name.lowercased()), dictionary["value"] != nil {
                return true
            }
            if storageSetter,
               (dictionary["action"] as? String)?.lowercased() == "set",
               dictionary["value"] != nil {
                return true
            }
            for (key, child) in dictionary {
                let lowered = key.lowercased()
                if sensitiveNames.contains(lowered) { return true }
                if credentialContainerNames.contains(lowered) {
                    if child is [String: Any] || child is [Any] { return true }
                    if let encoded = child as? String,
                       let parsed = parseNestedJSON(encoded) {
                        if containsSensitive(
                            parsed,
                            credentialContext: true,
                            storageSetter: false
                        ) { return true }
                    }
                }
                if (lowered == "headers" || lowered == "header"),
                   let encoded = child as? String,
                   let parsed = parseNestedJSON(encoded) {
                    if containsSensitive(
                        parsed,
                        credentialContext: false,
                        storageSetter: false
                    ) { return true }
                }
                if credentialContext,
                   lowered == "value" || lowered == "token" || lowered == "secret" {
                    return true
                }
                if containsSensitive(
                    child,
                    credentialContext: credentialContext,
                    storageSetter: storageSetter
                ) {
                    return true
                }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains {
                containsSensitive(
                    $0,
                    credentialContext: credentialContext,
                    storageSetter: storageSetter
                )
            }
        }
        return false
    }

    private static func scrub(
        _ value: Any,
        credentialContext: Bool,
        storageSetter: Bool
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count)
            // Header-list shape: [{"name":"Cookie","value":"..."}]
            let headerName = (dictionary["name"] as? String)?.lowercased()
            let isCredentialHeader = headerName.map(sensitiveNames.contains) ?? false
            let isStorageSet = storageSetter
                && (dictionary["action"] as? String)?.lowercased() == "set"
            for (key, child) in dictionary {
                let lowered = key.lowercased()
                if isCredentialHeader, lowered == "value" {
                    result[key] = "[redacted]"
                    continue
                }
                if isStorageSet, lowered == "value" {
                    // Actual browser.storage shape:
                    // {action:"set", key:"foo", value:"SECRET"}. Keep the
                    // action/key metadata; only the stored value is secret.
                    result[key] = "[redacted]"
                    continue
                }
                // headers/cookies may themselves be JSON-encoded STRINGS in
                // the actual browser tool contract. Parse and scrub that
                // nested document without changing its string shape.
                if (lowered == "headers" || lowered == "header"),
                   let encoded = child as? String {
                    if let parsed = parseNestedJSON(encoded) {
                        result[key] = encodeNestedJSON(
                            scrub(parsed, credentialContext: false, storageSetter: false)
                        )
                    } else {
                        result[key] = redactedText(encoded)
                    }
                    continue
                }
                if lowered == "cookies",
                   let encoded = child as? String {
                    if let parsed = parseNestedJSON(encoded) {
                        result[key] = encodeNestedJSON(
                            scrub(parsed, credentialContext: true, storageSetter: false)
                        )
                    } else {
                        result[key] = redactedText(encoded)
                    }
                    continue
                }
                if sensitiveNames.contains(lowered) {
                    // Raw cookie/authorization strings are redacted whole;
                    // object/array cookie values keep metadata and mask only
                    // their credential leaf.
                    if child is [String: Any] || child is [Any] {
                        result[key] = scrub(
                            child,
                            credentialContext: true,
                            storageSetter: false
                        )
                    } else {
                        result[key] = "[redacted]"
                    }
                    continue
                }
                if credentialContainerNames.contains(lowered),
                   child is [String: Any] || child is [Any] {
                    result[key] = scrub(
                        child,
                        credentialContext: true,
                        storageSetter: false
                    )
                    continue
                }
                if credentialContext,
                   lowered == "value" || lowered == "token" || lowered == "secret" {
                    // Cookie/storage entry: keep name/domain/path/expires,
                    // mask the secret value whatever its JSON type.
                    result[key] = "[redacted]"
                    continue
                }
                // A raw header line ("Cookie: S=...") is also a credential.
                if (lowered == "header" || lowered == "headers" || lowered == "raw"),
                   let line = child as? String,
                   let colon = line.firstIndex(of: ":"),
                   sensitiveNames.contains(line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
                    result[key] = "[redacted]"
                    continue
                }
                result[key] = scrub(
                    child,
                    credentialContext: credentialContext,
                    storageSetter: storageSetter
                )
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map {
                scrub(
                    $0,
                    credentialContext: credentialContext,
                    storageSetter: storageSetter
                )
            }
        }
        return value
    }

    private static func parseNestedJSON(_ value: String) -> Any? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else { return nil }
        return object
    }

    private static func encodeNestedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return "[redacted]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fallback for malformed JSON: conservative pattern replacement so a
    /// secret never reaches a checkpoint simply because the JSON was invalid.
    private static func redactedText(_ text: String) -> String {
        let pattern = #"(?i)("(?:cookie|cookies|set-cookie|authorization|proxy-authorization|x-api-key|api-key|x-auth-token)"\s*:\s*")((?:\\.|[^"\\])*)(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1[redacted]$3"
        )
    }
}

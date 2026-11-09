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
// Scope is deliberately narrow: header/argument names whose value is a
// credential, plus the exact phone.act setText inputs. It does not try to be
// a general secret scanner and does not depend on a global registry.
//
// Phone sensitive input (conservative v1 rule): the Android host learns
// whether the target node is a protected field only at dispatch, which is
// AFTER the tool request and checkpoint copies are written, and a dispatcher
// can reject the call AFTER persistence. So for `phone.act`, ANY root-level
// `text` or `sensitiveText` key is credential material REGARDLESS of the
// declared action (a missing or invalid action must not leave a leaked
// value), matched case-insensitively. Any malformed/unparseable or
// non-object phone.act payload is omitted WHOLE rather than substring
// scanned, because escaped key names and field order must never evade the
// rule. Ordinary phone actions without text stay replayable and unrelated
// document/file tools are never blanket-redacted. The live dispatch copy
// always keeps the exact bytes.

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

    /// The Android platform tool that carries text input. The legacy
    /// underscore alias is normalised exactly like the browser helper, so a
    /// wire name accepted by the dispatcher can never escape this rule.
    /// Only this tool is affected; document, file and chat tools keep
    /// ordinary text persistence behaviour.
    static func isPhoneActTool(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let canonical = toolName.lowercased().replacingOccurrences(of: "_", with: ".")
        return canonical == "phone.act"
    }

    /// Conservative phone.act rule: any root-level `text`/`sensitiveText`
    /// key (case-insensitive) is a credential regardless of the declared
    /// action, and any NON-OBJECT parsed phone.act payload fails closed as
    /// sensitive so it is omitted whole. Malformed bytes are handled by the
    /// callers before structural scrubbing is possible.
    static func phoneTextInputRequested(_ object: Any, toolName: String?) -> Bool {
        guard isPhoneActTool(toolName) else { return false }
        guard let dictionary = object as? [String: Any] else { return true }
        return dictionary.keys.contains {
            let lowered = $0.lowercased()
            return lowered == "text" || lowered == "sensitivetext"
        }
    }

    public static func redactedArgumentsJSON(
        _ data: Data,
        toolName: String? = nil
    ) -> Data {
        let storageSetter = isBrowserStorageSetter(toolName)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            // A truncated credential container cannot be scrubbed structurally:
            // its nested value or header-list entry may lack a closing quote.
            // Persist only an omission marker; dispatch still uses the original.
            if containsSensitiveValues(data, toolName: toolName) {
                return Data(#"{"_redacted":"Malformed credential arguments omitted"}"#.utf8)
            }
            return Data(redactedText(String(decoding: data, as: UTF8.self)).utf8)
        }
        if isPhoneActTool(toolName), object as? [String: Any] == nil {
            // A non-object phone.act document (array or fragment) cannot be
            // scrubbed field-wise: omit the whole payload instead of
            // persisting it unchanged.
            return Data(#"{"_redacted":"Phone text input arguments omitted"}"#.utf8)
        }
        let phoneText = phoneTextInputRequested(object, toolName: toolName)
        let scrubbed = scrub(
            object,
            credentialContext: false,
            storageSetter: storageSetter,
            sensitivePhoneText: phoneText
        )
        guard JSONSerialization.isValidJSONObject(scrubbed),
              let encoded = try? JSONSerialization.data(
                withJSONObject: scrubbed,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            if phoneText {
                // A phone text argument that cannot be re-encoded must never
                // fall back to pattern substitution over the raw payload.
                return Data(#"{"_redacted":"Phone text input arguments omitted"}"#.utf8)
            }
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
            if isPhoneActTool(toolName) {
                // Malformed or partial phone.act bytes are omitted whole:
                // escaped key names and field order must never evade the
                // detection by substring scanning.
                return true
            }
            let lowered = String(decoding: data, as: UTF8.self).lowercased()
            return isBrowserStorageSetter(toolName)
                || sensitiveNames.contains { lowered.contains("\"\($0)\"") }
        }
        if phoneTextInputRequested(object, toolName: toolName) {
            return true
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
        storageSetter: Bool,
        sensitivePhoneText: Bool = false
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
                if sensitivePhoneText, lowered == "text" || lowered == "sensitivetext" {
                    // phone.act shape (action-agnostic): {action?,
                    // nodeRef:"n3", text|sensitiveText:"SECRET", ...}.
                    // Keep the action/ref/id metadata; mask only the typed
                    // value. The flag is consumed at this arguments root —
                    // recursion below passes the default false, so nested
                    // documents under other tools are never blanket-
                    // redacted.
                    result[key] = "[redacted]"
                    continue
                }
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
    /// The closing quote is optional because a truncated payload can end in
    /// the middle of the credential value; without that arm the old pattern
    /// left the whole unterminated secret intact.
    private static func redactedText(_ text: String) -> String {
        let pattern = #"(?i)("(?:cookie|cookies|set-cookie|authorization|proxy-authorization|x-api-key|api-key|x-auth-token|access_token|refresh_token|id_token)"\s*:\s*")((?:\\.|[^"\\])*)("?)"#
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

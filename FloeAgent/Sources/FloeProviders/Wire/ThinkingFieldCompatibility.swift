// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One response owner's request-level compatibility budget. Only a concrete
/// transport rejection can remove this one optional top-level vendor field.
/// This never changes saved capabilities, messages, tools or runtime retries.
struct ThinkingFieldCompatibility {
    private(set) var hasRetried = false
    private(set) var observedStreamEvent = false

    mutating func observeStreamEvent() { observedStreamEvent = true }

    mutating func replacementRequest(_ request: URLRequest, status: Int, body: String) -> URLRequest? {
        guard !Task.isCancelled, !hasRetried, !observedStreamEvent,
              Self.rejectsRootThinking(status: status, body: body),
              let original = request.httpBody,
              var object = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              object.removeValue(forKey: "thinking") != nil,
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        var replacement = request
        replacement.httpBody = encoded
        // The transport recomputes this after the single-field projection.
        replacement.setValue(nil, forHTTPHeaderField: "Content-Length")
        hasRetried = true
        return replacement
    }

    static func rejectsRootThinking(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422, body.utf8.count <= 4_096,
              let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return false }
        let envelope = (root["error"] as? [String: Any]) ?? root
        if let value = envelope["path"] ?? root["path"] {
            guard let path = value as? [Any], path.isEmpty else { return false }
        }
        if let value = envelope["issues"] ?? root["issues"] {
            guard let issues = value as? [[String: Any]], !issues.isEmpty else { return false }
            return issues.allSatisfy { issue in
                (issue["code"] as? String) == "unrecognized_keys"
                    && (issue["keys"] as? [String]) == ["thinking"]
                    && (issue["path"] as? [Any])?.isEmpty == true
            }
        }
        // The supplied screenshot also shows the flattened root-only form.
        // Match that complete controlled message, never a substring in tool
        // schemas, arguments, examples, or an unrelated validation failure.
        if let details = (envelope["details"] ?? root["details"]) as? [String: Any],
           details.count == 1,
           let errors = details["_errors"] as? [String],
           errors == ["Unrecognized key(s) in object: 'thinking'"] { return true }
        let code = (envelope["code"] as? String) ?? ""
        return (envelope["param"] as? String) == "thinking"
            && ["unsupported_parameter", "unknown_parameter", "unrecognized_parameter"].contains(code)
    }
}

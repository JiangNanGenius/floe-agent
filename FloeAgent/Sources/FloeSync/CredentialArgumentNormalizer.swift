import Foundation
import FloeCore
import FloePersistence
import FloeSecurity

/// Captures raw credentials in arbitrarily nested tool arguments before the
/// approval, audit, checkpoint, or tool-execution layers can observe them.
/// The returned JSON contains only opaque Floe credential references.
public enum CredentialArgumentNormalizer {
    public static func normalize(
        _ argumentsJSON: Data,
        toolName: String,
        vault: CredentialVaultService,
        owner: CredentialOwner = .vault
    ) async throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any]
        else { return argumentsJSON }
        let sensitiveKeys = Set([
            "credentialinput", "password", "passwd", "passphrase",
            "apikey", "api_key", "token", "secret"
        ])
        var changed = false

        func normalizeValue(_ value: Any, path: [String]) async throws -> Any {
            if let dictionary = value as? [String: Any] {
                var result = dictionary
                for key in dictionary.keys.sorted() {
                    guard let child = dictionary[key] else { continue }
                    let lower = key.lowercased()
                    let childPath = path + [key]
                    if sensitiveKeys.contains(lower), let raw = child as? String {
                        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !secret.isEmpty,
                              SecretIngressScanner.credentialID(from: secret) == nil else { continue }
                        let normalizedPath = childPath.joined(separator: ".").lowercased()
                        let normalizedTool = toolName.lowercased()
                        let kind: CredentialKind
                        if normalizedTool.hasPrefix("vnc.") || normalizedPath.contains("vnc") {
                            kind = .vncPassword
                        } else if normalizedTool.hasPrefix("ssh.") {
                            kind = lower.contains("key") ? .sshPrivateKey : .sshPassword
                        } else if lower.contains("apikey") || lower == "api_key" {
                            kind = .providerAPIKey
                        } else if lower.contains("password") || lower == "passwd" || lower == "passphrase" {
                            kind = .websitePassword
                        } else {
                            kind = .genericToken
                        }
                        let handle = try await vault.capture(
                            Data(secret.utf8),
                            kind: kind,
                            owner: owner,
                            label: "Tool credential for \(toolName).\(childPath.joined(separator: "."))",
                            origin: "model-tool-call"
                        )
                        result[key] = CapturedSecret.placeholder(for: handle.id)
                        changed = true
                    } else {
                        result[key] = try await normalizeValue(child, path: childPath)
                    }
                }
                return result
            }
            if let array = value as? [Any] {
                var result: [Any] = []
                result.reserveCapacity(array.count)
                for (index, child) in array.enumerated() {
                    result.append(try await normalizeValue(child, path: path + [String(index)]))
                }
                return result
            }
            return value
        }

        let normalized = try await normalizeValue(object, path: [])
        guard changed else { return argumentsJSON }
        return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }
}

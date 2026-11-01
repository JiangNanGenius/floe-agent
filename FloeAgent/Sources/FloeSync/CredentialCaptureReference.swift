import Foundation
import FloePersistence
import FloeSecurity

/// Run-bound provenance written by `CredentialArgumentNormalizer` when it
/// replaces a raw credential argument with an opaque reference. Consumers
/// (credential cards, skill configuration) use it to prove that a reference
/// was produced for THIS run, tool and argument path instead of accepting any
/// model-typed credential identifier.
public enum CredentialCaptureReference {
    public static let originPrefix = "model-tool-call:"
    public static let referencePrefix = "⟨credential:"

    public static func origin(
        toolName: String,
        fieldPath: String,
        runID: UUID?
    ) -> String {
        let base = "\(originPrefix)\(toolName).\(fieldPath)"
        guard let runID else { return base }
        return "\(base)#run=\(runID.uuidString)"
    }

    /// Exact match only. A missing run id or path can never authorize a
    /// reference.
    public static func isAuthorizedCapture(
        _ record: CredentialRecord,
        runID: UUID,
        toolName: String,
        fieldPath: String?
    ) -> Bool {
        guard let fieldPath else { return false }
        return record.origin == origin(toolName: toolName, fieldPath: fieldPath, runID: runID)
    }

    public static func credentialID(from value: String) -> UUID? {
        SecretIngressScanner.credentialID(from: value)
    }

    public static func looksLikeReference(_ value: String) -> Bool {
        value.hasPrefix(referencePrefix)
    }
}

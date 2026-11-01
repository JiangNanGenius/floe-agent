import Foundation
import FloeCore
import FloePersistence
import FloeSecurity

public enum CredentialCardError: Error, Sendable, Equatable, LocalizedError {
    case invalidLabel
    case missingSecret
    case credentialNotFound
    case notVaultOwned
    case unauthorizedReference
    case kindMismatch
    case credentialInUse
    case invalidReference

    public var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "Credential label must be 1...200 characters."
        case .missingSecret:
            "A secret value is required."
        case .credentialNotFound:
            "That credential does not exist."
        case .notVaultOwned:
            "Only vault credential cards can be changed by this tool."
        case .unauthorizedReference:
            "The credential reference was not produced for this run; provide the secret value again."
        case .kindMismatch:
            "The captured credential kind does not match the requested kind."
        case .credentialInUse:
            "This credential is bound to a skill configuration. Unbind it there before deleting or replacing it."
        case .invalidReference:
            "The credential reference is malformed."
        }
    }
}

public struct CredentialCardCreateInput: Sendable, Equatable {
    public var label: String
    public var kind: CredentialKind
    /// Raw value or a run-bound `⟨credential:id⟩` capture.
    public var secret: String?
    public var hostID: UUID?

    public init(label: String, kind: CredentialKind, secret: String?, hostID: UUID? = nil) {
        self.label = label
        self.kind = kind
        self.secret = secret
        self.hostID = hostID
    }
}

public struct CredentialCardUpdateInput: Sendable, Equatable {
    public var id: UUID
    public var label: String?
    /// Raw value or a run-bound `⟨credential:id⟩` capture.
    public var secret: String?

    public init(id: UUID, label: String? = nil, secret: String? = nil) {
        self.id = id
        self.label = label
        self.secret = secret
    }
}

public struct CredentialCardMutation: Sendable, Equatable {
    public let id: UUID
    public let reference: String
    public let changed: [String]
    public let cleanupWarning: String?

    public init(id: UUID, changed: [String], cleanupWarning: String? = nil) {
        self.id = id
        self.reference = CapturedSecret.placeholder(for: id)
        self.changed = changed
        self.cleanupWarning = cleanupWarning
    }
}

/// Secret-free credential-card lifecycle. The service is the single
/// implementation behind `credential.manage`: raw one-time input and
/// run-bound normalizer captures are consumed consistently for create and
/// update, a typed reference is never stored as a secret, and task-scoped
/// conversation/workspace credentials are never mutated or promoted.
public struct CredentialCardService: Sendable {
    public static let toolName = "credential.manage"

    private let records: CredentialStore
    private let vault: CredentialVaultService
    /// When present, skill-bound credentials are hidden from ordinary card
    /// management and cannot be replaced/deleted underneath a profile.
    private let skillConfigurationStore: SkillConfigurationStore?

    public init(
        records: CredentialStore,
        vault: CredentialVaultService,
        skillConfigurationStore: SkillConfigurationStore? = nil
    ) {
        self.records = records
        self.vault = vault
        self.skillConfigurationStore = skillConfigurationStore
    }

    public func list() async throws -> [SecureCredentialCard] {
        let cards = try await records.cards(owner: .vault)
        guard let skillConfigurationStore else { return cards }
        let bound = try await skillConfigurationStore.boundCredentialIDs()
        return cards.filter { !bound.contains($0.id) }
    }

    public func create(
        _ input: CredentialCardCreateInput,
        runID: UUID,
        captureFieldPath: String = "secret"
    ) async throws -> CredentialCardMutation {
        let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 200 else {
            throw CredentialCardError.invalidLabel
        }
        guard let secret = input.secret, !secret.isEmpty else {
            throw CredentialCardError.missingSecret
        }
        if CredentialCaptureReference.looksLikeReference(secret) {
            let capture = try await authorizedCapture(
                secret,
                runID: runID,
                captureFieldPath: captureFieldPath
            )
            guard capture.kind == input.kind || capture.kind == .genericToken else {
                throw CredentialCardError.kindMismatch
            }
            try await vault.adoptCapturedCredential(
                CredentialHandle(id: capture.id),
                kind: input.kind,
                owner: .vault,
                label: label,
                hostID: input.hostID,
                origin: Self.toolName
            )
            return CredentialCardMutation(
                id: capture.id,
                changed: ["label", "kind", "owner"]
            )
        }
        guard let data = secret.data(using: .utf8), !data.isEmpty else {
            throw CredentialCardError.missingSecret
        }
        let handle = try await vault.capture(
            data,
            kind: input.kind,
            owner: .vault,
            label: label,
            hostID: input.hostID,
            origin: Self.toolName
        )
        return CredentialCardMutation(
            id: handle.id,
            changed: ["label", "kind", "secret"]
        )
    }

    public func update(
        _ input: CredentialCardUpdateInput,
        runID: UUID,
        captureFieldPath: String = "secret"
    ) async throws -> CredentialCardMutation {
        guard let record = try await records.record(id: input.id) else {
            throw CredentialCardError.credentialNotFound
        }
        guard record.owner == .vault else {
            throw CredentialCardError.notVaultOwned
        }
        try await requireNotBound(input.id)

        let label = input.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLabel = label?.isEmpty == false
        let hasSecret = input.secret?.isEmpty == false
        guard hasLabel || hasSecret else {
            throw CredentialCardError.missingSecret
        }
        var changed: [String] = []
        if let label, hasLabel {
            guard label.count <= 200 else { throw CredentialCardError.invalidLabel }
            try await vault.updateLabel(CredentialHandle(id: input.id), label: label)
            changed.append("label")
        }
        var cleanupWarning: String?
        if let secret = input.secret, hasSecret {
            if CredentialCaptureReference.looksLikeReference(secret) {
                let capture = try await authorizedCapture(
                    secret,
                    runID: runID,
                    captureFieldPath: captureFieldPath
                )
                guard capture.kind == record.kind || capture.kind == .genericToken else {
                    throw CredentialCardError.kindMismatch
                }
                let bytes = try await vault.resolveForApprovedUse(CredentialHandle(id: capture.id))
                try await vault.replaceSecret(CredentialHandle(id: input.id), secret: bytes)
                do {
                    try await vault.delete(CredentialHandle(id: capture.id))
                } catch {
                    cleanupWarning = "A temporary credential capture could not be removed."
                }
            } else {
                guard let data = secret.data(using: .utf8), !data.isEmpty else {
                    throw CredentialCardError.missingSecret
                }
                try await vault.replaceSecret(CredentialHandle(id: input.id), secret: data)
            }
            changed.append("secret")
        }
        return CredentialCardMutation(
            id: input.id,
            changed: changed,
            cleanupWarning: cleanupWarning
        )
    }

    public func delete(id: UUID) async throws {
        guard let record = try await records.record(id: id) else {
            throw CredentialCardError.credentialNotFound
        }
        guard record.owner == .vault else {
            throw CredentialCardError.notVaultOwned
        }
        try await requireNotBound(id)
        try await vault.delete(CredentialHandle(id: id))
    }

    private func requireNotBound(_ credentialID: UUID) async throws {
        guard let skillConfigurationStore else { return }
        let references = try await skillConfigurationStore.bindingReferences(credentialID: credentialID)
        guard references.isEmpty else { throw CredentialCardError.credentialInUse }
    }

    /// A reference is consumable only when the normalizer produced it for
    /// exactly this run, tool and argument path. Anything else (for example a
    /// model-typed card id or another task's captured secret) is refused
    /// instead of being copied or stored as literal text.
    private func authorizedCapture(
        _ reference: String,
        runID: UUID,
        captureFieldPath: String
    ) async throws -> CredentialRecord {
        guard let id = CredentialCaptureReference.credentialID(from: reference) else {
            throw CredentialCardError.invalidReference
        }
        guard let record = try await vault.metadata(CredentialHandle(id: id)) else {
            throw CredentialCardError.credentialNotFound
        }
        guard CredentialCaptureReference.isAuthorizedCapture(
            record,
            runID: runID,
            toolName: Self.toolName,
            fieldPath: captureFieldPath
        ) else {
            throw CredentialCardError.unauthorizedReference
        }
        return record
    }
}

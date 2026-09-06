#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import FloePersistence
import FloeSync
import FloeTools

/// Independent credential-card management. Lists secret-free cards and
/// performs create/update/delete through the credential vault. Raw secrets
/// are accepted only as one-time setup input and are never returned; the
/// stable ⟨credential:id⟩ reference is what other tools consume.
struct CredentialManageTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String
        /// Credential UUID for update/delete.
        var id: String?
        /// Display label for create/update.
        var label: String?
        /// providerAPIKey, sshPassword, sshPrivateKey, vncPassword,
        /// websitePassword or genericToken (create only).
        var kind: String?
        /// One-time secret for create/update; never returned afterwards.
        var secret: String?
        /// Optional paired-host UUID the credential belongs to.
        var hostID: String?
    }

    static let name = "credential.manage"
    static let toolDescription = "Manage credential cards directly: list (secret-free metadata only), create (label + kind + one-time secret), update (id + new label and/or replacement secret), delete (id). Returns the stable ⟨credential:id⟩ reference for use wherever a credentialInput is accepted. Secrets are stored in the device Keychain and never returned."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","create","update","delete"]},"id":{"type":"string","description":"Credential UUID (update/delete)"},"label":{"type":"string","maxLength":200},"kind":{"type":"string","enum":["providerAPIKey","sshPassword","sshPrivateKey","vncPassword","websitePassword","genericToken"]},"secret":{"type":"string","description":"One-time setup/replacement secret; never returned"},"hostID":{"type":"string","description":"Optional paired-host UUID"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let vault: CredentialVaultService
    private let store: CredentialStore

    init(vault: CredentialVaultService, store: CredentialStore) {
        self.vault = vault
        self.store = store
    }

    func validate(_ args: Arguments) throws {
        guard ["list", "create", "update", "delete"].contains(args.action) else {
            throw FloeError.validationFailed("action must be list, create, update or delete")
        }
        if args.action == "create" {
            guard let label = args.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                throw FloeError.validationFailed("create requires a non-empty label")
            }
            guard let kind = args.kind, CredentialKind(rawValue: kind) != nil else {
                throw FloeError.validationFailed("create requires a valid kind")
            }
            guard let secret = args.secret, !secret.isEmpty else {
                throw FloeError.validationFailed("create requires a secret (stored in Keychain, never returned)")
            }
        }
        if ["update", "delete"].contains(args.action) {
            guard let id = args.id, UUID(uuidString: id) != nil else {
                throw FloeError.validationFailed("\(args.action) requires a credential UUID")
            }
        }
        if args.action == "update" {
            let hasLabel = args.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasSecret = args.secret?.isEmpty == false
            guard hasLabel || hasSecret else {
                throw FloeError.validationFailed("update requires a new label and/or a replacement secret")
            }
        }
        if let hostID = args.hostID, UUID(uuidString: hostID) == nil {
            throw FloeError.validationFailed("hostID must be a UUID")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil else {
            throw FloeError.validationFailed("Credential management requires approval")
        }
        switch args.action {
        case "list": return try await list()
        case "create": return try await create(args)
        case "update": return try await update(args)
        default: return try await delete(args)
        }
    }

    private func list() async throws -> ToolExecutionOutput {
        let cards = try await store.cards()
        let rows: [[String: Any]] = cards.map { card in
            var row: [String: Any] = [
                "id": card.id.uuidString,
                "reference": card.reference,
                "kind": card.kind.rawValue,
                "owner": card.owner.kindName,
                "label": card.label
            ]
            if let hostID = card.hostID { row["hostID"] = hostID.uuidString }
            if let origin = card.origin { row["origin"] = origin }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["credentials": rows], options: [.sortedKeys])
        return Self.output(String(decoding: data, as: UTF8.self))
    }

    private func create(_ args: Arguments) async throws -> ToolExecutionOutput {
        let handle = try await vault.capture(
            Data(args.secret!.utf8),
            kind: CredentialKind(rawValue: args.kind!)!,
            owner: .vault,
            label: args.label!.trimmingCharacters(in: .whitespacesAndNewlines),
            hostID: args.hostID.flatMap(UUID.init(uuidString:)),
            origin: "credential.manage"
        )
        return Self.output("status=ok action=create id=\(handle.id.uuidString) reference=⟨credential:\(handle.id.uuidString)⟩ secretReturned=false")
    }

    private func update(_ args: Arguments) async throws -> ToolExecutionOutput {
        let handle = CredentialHandle(id: UUID(uuidString: args.id!)!)
        var changed: [String] = []
        if let label = args.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            try await vault.updateLabel(handle, label: label)
            changed.append("label")
        }
        if let secret = args.secret, !secret.isEmpty {
            try await vault.replaceSecret(handle, secret: Data(secret.utf8))
            changed.append("secret")
        }
        return Self.output("status=ok action=update id=\(handle.id.uuidString) changed=\(changed.joined(separator: ","))")
    }

    private func delete(_ args: Arguments) async throws -> ToolExecutionOutput {
        let handle = CredentialHandle(id: UUID(uuidString: args.id!)!)
        try await vault.delete(handle)
        return Self.output("status=ok action=delete id=\(handle.id.uuidString)")
    }

    private static func output(_ text: String) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: 0)
    }
}

@MainActor
func registerCredentialManageTool(vault: CredentialVaultService, store: CredentialStore, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(CredentialManageTool.self)
    registry.register(CredentialManageTool(vault: vault, store: store))
}
#endif

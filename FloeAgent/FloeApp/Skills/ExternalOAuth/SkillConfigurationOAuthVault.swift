import Foundation
import FloeSync

/// Uses only the existing source/install, owned-credential and revision/CAS
/// service. It neither stores raw bytes itself nor invents a Keychain service.
struct SkillConfigurationOAuthVault: ExternalOAuthVaultPersistence {
    let service: SkillConfigurationService
    let skillID: String
    let installationID: String
    let profile: String
    let target: String
    let requirements: SkillConfigRequirements
    /// The existing native operation/lease and installed-Skill authority,
    /// rechecked before any credential access; there is no permissive default.
    let validateAccess: @Sendable () async throws -> Void

    func snapshot() async throws -> ExternalOAuthVaultSnapshot {
        try await validateAccess()
        let status = try await service.inspect(skillID: skillID, profile: profile, target: target, requirements: requirements)
        guard status.installed, !status.sourceChanged, status.installation?.configurationAllowed == true,
              status.installation?.installationID == installationID else { throw ExternalOAuthFailure.storageUnavailable }
        do {
            let value = try await service.readConnectionPayload(skillID: skillID, profile: profile, target: target,
                fieldKey: "connection", connectionKind: "oauth.external", requirements: requirements)
            guard value.installationID == installationID, value.revision == status.revision else {
                throw ExternalOAuthFailure.storageUnavailable
            }
            try await validateAccess()
            return ExternalOAuthVaultSnapshot(installationID: installationID, revision: value.revision,
                credentialID: value.credentialID, payload: value.payload)
        } catch SkillConfigurationError.credentialMissing(let field) where field == "connection" {
            return ExternalOAuthVaultSnapshot(installationID: installationID, revision: status.revision,
                credentialID: nil, payload: nil)
        }
    }

    func save(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot {
        try await requireExpected(expected)
        let result = try await service.saveConnectionPayload(skillID: skillID, profile: profile, target: target,
            fieldKey: "connection", connectionKind: "oauth.external", payload: data,
            reason: expected.credentialID == nil ? .initialSetup : .rekey, requirements: requirements,
            expectedCredentialID: expected.credentialID, expectedRevision: expected.revision)
        let after = try await snapshot()
        guard after.credentialID == result.credentialID, after.revision == result.revision else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        return after
    }

    func refresh(_ data: Data, replacing expected: ExternalOAuthVaultSnapshot) async throws -> ExternalOAuthVaultSnapshot {
        try await requireExpected(expected)
        guard let credentialID = expected.credentialID, let revision = expected.revision else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        let result = try await service.refreshConnectionPayload(skillID: skillID, profile: profile, target: target,
            fieldKey: "connection", connectionKind: "oauth.external", payload: data, requirements: requirements,
            expectedCredentialID: credentialID, expectedRevision: revision)
        let after = try await snapshot()
        guard after.credentialID == result.credentialID, after.revision == result.revision else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        return after
    }

    private func requireExpected(_ value: ExternalOAuthVaultSnapshot) async throws {
        let current = try await snapshot()
        guard current.installationID == value.installationID, current.revision == value.revision,
              current.credentialID == value.credentialID, current.payload == value.payload else {
            throw ExternalOAuthFailure.storageUnavailable
        }
    }
}

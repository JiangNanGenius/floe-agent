#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence
import FloeSkills
import FloeSync

/// Uses the real installed row/configuration service and SkillsCenter's
/// existing signed-authority provider. No grant is created by this adapter.
@MainActor
struct NativeExternalOAuthAccessAuthorizer {
    let skills: SQLiteSkillStore
    let configuration: SkillConfigurationService
    let runtimeAuthority: @Sendable (String) async -> SkillRuntimeComponentAuthority?
    let requirements: @MainActor @Sendable (SkillConfigurationRequirements) throws -> SkillConfigRequirements

    func authorize(_ request: SkillConfigurationConnectionRequest) async throws -> NativeExternalOAuthAppIntegration.Access {
        guard NativeExternalOAuthAppIntegration.supports(request),
              let row = try await skills.skill(id: request.skillID), row.status == "enabled",
              let authority = await runtimeAuthority(request.skillID),
              let bytes = authority.packageFiles["floe.json"],
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: bytes), manifest.id == row.id,
              let declaration = manifest.configuration, declaration.fields.count == 1,
              declaration.fields[0].key == "connection", declaration.fields[0].kind == .connection,
              declaration.fields[0].connectionKind == NativeExternalOAuthAppIntegration.connectionKind else {
            throw FloeError.unauthorized
        }
        let requirements = try requirements(declaration)
        let status = try await configuration.inspect(skillID: request.skillID, profile: request.scope.profile,
            target: request.scope.target, requirements: requirements)
        guard let installation = status.installation, status.installed, !status.sourceChanged,
              installation.configurationAllowed, installation.reviewedDigest == authority.contentDigest,
              await runtimeAuthority(request.skillID) == authority else { throw FloeError.unauthorized }
        return .init(installationID: installation.installationID, requirements: requirements, authority: authority)
    }
}
#endif

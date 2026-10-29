#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeSkills
import FloeTools

/// The tool receives only metadata and reviewed package bytes from the
/// existing native center. No model-provided publisher or grant is accepted.
@MainActor
struct SkillHubAppBridge: SkillHubCatalogProviding, SkillHubInstalling, SkillMacOriginalInstalling {
    let center: SkillsCenter
    func install(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> SkillHubInstallReceipt {
        try await center.installHubSkill(request, context: context)
    }
    func installMacOriginal(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> MacOriginalSkillInstallReceipt {
        try await center.installMacOriginalSkill(request, context: context)
    }
    func verifiedCatalogEntries() async throws -> [SkillHubCatalogEntry] {
        try await center.verifiedHubCatalogEntries()
    }
    func verifiedCatalogEntries(context: ToolContext) async throws -> [SkillHubCatalogEntry] {
        try await center.verifiedHubCatalogEntries(context: context)
    }
    func verifiedCatalogDetail(id: String) async throws -> SkillHubCatalogDetail? {
        try await center.verifiedHubCatalogDetail(id: id)
    }
    func verifiedCatalogDetail(id: String, context: ToolContext) async throws -> SkillHubCatalogDetail? {
        try await center.verifiedHubCatalogDetail(id: id, context: context)
    }
}
#endif

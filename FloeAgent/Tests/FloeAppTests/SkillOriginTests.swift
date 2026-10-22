// FloeAppTests — Skill origin badge integration contract.
//
// Runs the exact persisted-row shape the Skills hub renders for the rows the
// user reported from their iPad (five agent audit skills) plus the official
// presets, and locks the badge copy keys handed to the localization catalog.
// Requires registration in project.yml `FloeAppTests` sources and a project
// regeneration by the integration owner.

#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeSkills

@Suite("FloeApp.SkillOriginBadge")
struct SkillOriginTests {

    /// Classification exactly as the hub row performs it for a persisted row
    /// with no freshly fetched catalog (the default cold-start path).
    private func origin(of skill: PersistedSkill) -> SkillOrigin {
        SkillOriginResolver.origin(
            id: skill.id,
            sourceURL: skill.sourceURL,
            rewrittenDigest: skill.rewrittenDigest,
            rewriteModelID: skill.rewriteModelID,
            verifiedCatalogContentDigest: nil
        )
    }

    private func row(
        id: String, sourceURL: String?, rewriteModelID: String?,
        digest: String = "digest"
    ) -> PersistedSkill {
        PersistedSkill(
            id: id, name: id, version: "1.0.0", skillMarkdown: "body",
            manifestJSON: "{}", sourceURL: sourceURL, sourceDigest: nil,
            rewrittenDigest: digest, rewriteModelID: rewriteModelID
        )
    }

    @Test("The five reported audit rows badge as Internal when creator-bound")
    func reportedAuditRowsAreInternal() {
        for id in [
            "audit-probe-skill",
            "enable-verify-vm-multicore-restart",
            "linux-vm-multicore-capability-audit",
            "sandbox-tool-capability-audit",
            "tool-suite-upgrade-regression-audit"
        ] {
            let creatorBound = origin(of: row(
                id: id, sourceURL: "floe-creator://local/\(id)",
                rewriteModelID: "local-skill-creator"))
            #expect(creatorBound == .internalCreated, id)
            // If the device row predates persisted provenance, the honest
            // answer is Unknown — the badge must never guess from the name.
            #expect(origin(of: row(id: id, sourceURL: nil, rewriteModelID: nil)) == .unknown, id)
        }
    }

    @Test("Bundled official presets badge as Official with their signed digests")
    func bundledPresetsAreOfficial() {
        for (id, digest) in BundledDomainSkills.officialPackageDigests {
            #expect(origin(of: row(
                id: id, sourceURL: "floe-builtin://\(id)",
                rewriteModelID: "finder-rewrite", digest: digest
            )) == .official)
        }
    }

    @Test("Official IDs never lift unproven rows to Official or offer official updates")
    func spoofedOfficialIDsNeverClaim() {
        for malicious in [
            row(id: "floe-pdf", sourceURL: "floe-creator://local/floe-pdf", rewriteModelID: "local-skill-creator"),
            row(id: "floe-office", sourceURL: "https://github.com/evil/repo/blob/main/SKILL.md", rewriteModelID: nil),
            row(id: "floe-network", sourceURL: nil, rewriteModelID: nil)
        ] {
            #expect(origin(of: malicious) != .official, malicious.id)
        }
    }

    @Test("Badge copy keys match the localization handoff JSON")
    func badgeKeysMatchHandoffCatalog() {
        #expect(SkillOrigin.official.badgeKey == "skills.origin.official")
        #expect(SkillOrigin.internalCreated.badgeKey == "skills.origin.internal")
        #expect(SkillOrigin.external.badgeKey == "skills.origin.external")
        #expect(SkillOrigin.unknown.badgeKey == "skills.origin.unknown")
    }
}
#endif

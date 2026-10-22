// FloeSkillsTests — truthful skill origin badge classification.
//
// Covers the exact certainty contract for the hub badge: app-bundled presets,
// signature-verified official hub content, reviewed official upgrades,
// on-device creator rows (the five audit skills reported from the user's
// iPad), external imports, legacy unknowns and spoofed official IDs. Origin
// must also survive instruction updates and catalog movement.

import Foundation
import Testing
@testable import FloeSkills

@Suite("FloeSkills.SkillOriginResolver")
struct SkillOriginResolverTests {
    private let commit = "0123456789abcdef0123456789abcdef01234567"
    private var officialHubURL: String {
        "https://github.com/\(OfficialSkillHub.owner)/\(OfficialSkillHub.repository)/blob/\(commit)/skill-hub/catalog.json"
    }
    private func bundledDigest(for id: String) -> String {
        BundledDomainSkills.officialPackageDigests[id]!
    }

    // MARK: - Official: bound to trusted content, never to an ID alone

    @Test("Bundled hub-official preset matches the signed package digest")
    func bundledOfficialPreset() {
        for id in ["floe-pdf", "floe-office", "floe-network", "floe-video"] {
            #expect(SkillOriginResolver.origin(
                id: id, sourceURL: "floe-builtin://\(id)",
                rewrittenDigest: bundledDigest(for: id), rewriteModelID: "finder-rewrite"
            ) == .official)
        }
    }

    @Test("Bundled hub-official preset with foreign bytes is unknown, never Official")
    func bundledOfficialDigestMismatch() {
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: "floe-builtin://floe-pdf",
            rewrittenDigest: String(repeating: "f", count: 64), rewriteModelID: "finder-rewrite"
        ) == .unknown)
    }

    @Test("Hidden app-bundled guides classify as official presets")
    func hiddenBundledPreset() {
        #expect(SkillOriginResolver.origin(
            id: "floe-python", sourceURL: "floe-builtin://floe-python",
            rewrittenDigest: "any", rewriteModelID: "finder-rewrite"
        ) == .official)
    }

    @Test("A builtin-looking URL for an ID the app does not bundle is unknown")
    func spoofedBuiltinSchemeForForeignID() {
        #expect(SkillOriginResolver.origin(
            id: "audit-probe-skill", sourceURL: "floe-builtin://audit-probe-skill",
            rewrittenDigest: bundledDigest(for: "floe-pdf"), rewriteModelID: "local-skill-creator"
        ) == .unknown)
    }

    @Test("Reviewed official upgrade keeps Official through its immutable commit binding")
    func reviewedOfficialUpgrade() {
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: officialHubURL,
            rewrittenDigest: "unrelated-but-signed-then",
            rewriteModelID: "github-reviewed-\(commit)"
        ) == .official)
        // The catalog later moves to a newer version: the commit binding still
        // proves the installed bytes came from the signed feed at review time.
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: officialHubURL,
            rewrittenDigest: "unrelated-but-signed-then",
            rewriteModelID: "github-reviewed-\(commit)",
            verifiedCatalogContentDigest: bundledDigest(for: "floe-pdf")
        ) == .official)
    }

    @Test("Official commit URL without the matching reviewed label cannot claim Official")
    func reviewedLabelMismatch() {
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: officialHubURL,
            rewrittenDigest: "x", rewriteModelID: "github-reviewed-\(String(repeating: "a", count: 40))"
        ) == .external)
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: officialHubURL, rewrittenDigest: "x", rewriteModelID: nil
        ) == .external)
    }

    @Test("Installed bytes equal to the verified catalog entry are Official")
    func verifiedCatalogDigestBinding() {
        let digest = bundledDigest(for: "floe-office")
        #expect(SkillOriginResolver.origin(
            id: "floe-office", sourceURL: nil, rewrittenDigest: digest, rewriteModelID: nil,
            verifiedCatalogContentDigest: digest
        ) == .official)
    }

    @Test("Spoofed official IDs from community sources are never Official")
    func spoofedOfficialID() {
        // Same path layout, attacker-owned repository.
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf",
            sourceURL: "https://github.com/evil-owner/floe-agent/blob/\(commit)/skill-hub/catalog.json",
            rewrittenDigest: "x", rewriteModelID: "github-reviewed-\(commit)"
        ) == .external)
        // Same repository owner, different repository.
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf",
            sourceURL: "https://github.com/\(OfficialSkillHub.owner)/other-repo/blob/\(commit)/skill-hub/catalog.json",
            rewrittenDigest: "x", rewriteModelID: "github-reviewed-\(commit)"
        ) == .external)
        // Known official ID with a creator binding is honestly Internal, not Official.
        #expect(SkillOriginResolver.origin(
            id: "floe-pdf", sourceURL: "floe-creator://local/floe-pdf",
            rewrittenDigest: "x", rewriteModelID: "local-skill-creator"
        ) == .internalCreated)
        // Verified catalog membership alone (digest mismatch) never lifts an ID.
        #expect(SkillOriginResolver.origin(
            id: "floe-network", sourceURL: nil, rewrittenDigest: "x", rewriteModelID: nil,
            verifiedCatalogContentDigest: bundledDigest(for: "floe-network")
        ) == .unknown)
    }

    @Test("Official-source binding mirrors acceptsBundledUpgrade's URL rules")
    func bindingParityWithBundledUpgradeGate() {
        let digest = bundledDigest(for: "floe-pdf")
        for url in [officialHubURL, "floe-builtin://floe-pdf", "https://github.com/other/floe-agent/blob/\(commit)/skill-hub/catalog.json", nil] {
            let allowedByUpgradeGate = OfficialSkillHub.acceptsBundledUpgrade(
                id: "floe-pdf", sourceURL: url, installedVersion: "1.0.0",
                bundledVersion: "9.9.9", sourceDigest: digest, installedDigest: digest)
            let resolverOfficial = SkillOriginResolver.origin(
                id: "floe-pdf", sourceURL: url, rewrittenDigest: digest,
                rewriteModelID: "github-reviewed-\(commit)")
            // Anything the bundled gate trusts for offline advance must be
            // classifiable as provable official content here too.
            if allowedByUpgradeGate {
                #expect(resolverOfficial == .official, "url \(url ?? "nil")")
            }
        }
    }

    // MARK: - Internal: on-device creation through the reviewed creator pipeline

    @Test("Creator-bound audit rows tag as Internal")
    func creatorRowsAreInternal() {
        for id in [
            "audit-probe-skill",
            "enable-verify-vm-multicore-restart",
            "linux-vm-multicore-capability-audit",
            "sandbox-tool-capability-audit",
            "tool-suite-upgrade-regression-audit"
        ] {
            #expect(SkillOriginResolver.origin(
                id: id, sourceURL: "floe-creator://local/\(id)",
                rewrittenDigest: "digest", rewriteModelID: "local-skill-creator"
            ) == .internalCreated)
        }
    }

    @Test("Internal tag survives instruction updates and whitespace in stored URLs")
    func internalStabilityAcrossUpdates() {
        #expect(SkillOriginResolver.origin(
            id: "audit-probe-skill", sourceURL: "floe-creator://local/audit-probe-skill",
            rewrittenDigest: "after-instruction-update", rewriteModelID: "local-skill-creator"
        ) == .internalCreated)
        #expect(SkillOriginResolver.origin(
            id: "audit-probe-skill", sourceURL: " floe-creator://local/audit-probe-skill ",
            rewrittenDigest: "x", rewriteModelID: "instruction-update"
        ) == .internalCreated)
    }

    @Test("Creator-looking URL pointing at a different ID is not trusted as Internal")
    func inconsistentCreatorURL() {
        #expect(SkillOriginResolver.origin(
            id: "audit-probe-skill", sourceURL: "floe-creator://local/some-other-skill",
            rewrittenDigest: "x", rewriteModelID: "local-skill-creator"
        ) == .unknown)
    }

    // MARK: - External: imported or downloaded sources

    @Test("Finder, folder and community GitHub installs tag as External")
    func externalSources() {
        #expect(SkillOriginResolver.origin(
            id: "community-skill", sourceURL: "https://skills.example.com/community-skill.json",
            rewrittenDigest: "x", rewriteModelID: "0F2C4E8A-1234-4C0D-9B44-ABCDEF012345"
        ) == .external)
        #expect(SkillOriginResolver.origin(
            id: "traditional-import", sourceURL: "floe-folder://local/traditional-import",
            rewrittenDigest: "x", rewriteModelID: "finder-rewrite"
        ) == .external)
        #expect(SkillOriginResolver.origin(
            id: "community-skill",
            sourceURL: "https://github.com/some-owner/some-repo/blob/\(commit)/skills/community-skill/SKILL.md",
            rewrittenDigest: "x", rewriteModelID: "github-reviewed-\(commit)"
        ) == .external)
    }

    // MARK: - Unknown: legacy or unprovable bindings

    @Test("Legacy and malformed bindings are Unknown, never guessed")
    func unknownBindings() {
        for url in [nil, "", "   ", "not a url", "file:///Users/me/skill", "http://example.com/skill.json", "floe-builtin://floe-pdf"] {
            let origin = SkillOriginResolver.origin(
                id: "legacy-skill", sourceURL: url, rewrittenDigest: "x", rewriteModelID: nil)
            #expect(origin == .unknown, "url \(url ?? "nil")")
        }
    }

    // MARK: - Badge copy contract

    @Test("Badge keys match the localization catalog handed to integration")
    func badgeKeysAreStable() {
        #expect(SkillOrigin.official.badgeKey == "skills.origin.official")
        #expect(SkillOrigin.internalCreated.rawValue == "internal")
        #expect(SkillOrigin.internalCreated.badgeKey == "skills.origin.internal")
        #expect(SkillOrigin.external.badgeKey == "skills.origin.external")
        #expect(SkillOrigin.unknown.badgeKey == "skills.origin.unknown")
        #expect(Set(SkillOrigin.allCases.map(\.badgeKey)) == [
            "skills.origin.official", "skills.origin.internal",
            "skills.origin.external", "skills.origin.unknown"
        ])
    }
}

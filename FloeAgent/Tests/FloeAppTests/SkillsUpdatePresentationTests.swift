// FloeAppTests — installed-row update action truth.
//
// Build 290 showed a blue "Update" on every installed skill row because the
// fallback label ignored whether any newer version was proven. These cases
// pin the pure presentation seam: an update label exists exactly when the
// signed catalog offers a newer official version; rows with a genuinely
// checkable remote source offer the localized check; creator, folder-import,
// bundled-off-catalog and unprovenance local rows offer no update
// affordance. The classifier keeps the "nothing newer" check result distinct
// from real integrity failures, which must still surface. Presentation
// policy only: the upgrade transaction guard itself is unchanged.
// Requires registration in project.yml `FloeAppTests` sources
// (`- path: Tests/FloeAppTests/SkillsUpdatePresentationTests.swift`) and a
// project regeneration by the integration owner before these cases execute.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeSkills
@testable import FloeApp

@Suite("FloeApp.SkillsUpdatePresentation")
@MainActor
struct SkillsUpdatePresentationTests {
    private let hub: Set<String> = ["floe-office", "floe-pdf", "floe-network", "floe-video"]

    private func action(
        skillID: String = "floe-office",
        availableVersion: String? = nil,
        origin: SkillOrigin,
        sourceURL: String? = nil,
        hasGitHubUpgradeSource: Bool = false
    ) -> SkillUpdateRowAction {
        skillUpdateRowAction(
            skillID: skillID,
            availableVersion: availableVersion,
            origin: origin,
            sourceURL: sourceURL,
            hubSkillIDs: hub,
            hasGitHubUpgradeSource: hasGitHubUpgradeSource
        )
    }

    @Test func onlyNewerSignedCatalogVersionOffersUpdateLabel() {
        // The genuine update case: verified availability wins over every
        // other presentation input.
        #expect(action(availableVersion: "1.6.0", origin: .official) == .update(toVersion: "1.6.0"))
        // Without proven availability nothing may claim an update, whatever
        // the origin or recorded source is.
        #expect(action(availableVersion: nil, origin: .official) != .update(toVersion: "1.6.0"))
        #expect(action(availableVersion: nil, origin: .external,
                       sourceURL: "https://github.com/o/r/blob/main/SKILL.md") != .update(toVersion: "1.6.0"))
    }

    @Test func currentOfficialHubRowOffersCheckNotUpdate() {
        // Installed version already at or above the catalog entry: honest
        // localized check action, no version promise, no misleading update.
        #expect(action(skillID: "floe-office", origin: .official) == .check)
        #expect(action(skillID: "floe-office", origin: .unknown,
                       sourceURL: "https://github.com/JiangNanGenius/floe-agent/blob/"
                       + "0123456789012345678901234567890123456789/skill-hub/SKILL.md") == .check)
    }

    @Test func bundledOfficialRowOutsideCatalogHasNoAction() {
        // App-bundled guides change with app releases; with the catalog not
        // publishing the ID there is no remote to check, so no affordance.
        #expect(action(skillID: "floe-legacy-guide", origin: .official) == .noAction)
    }

    @Test func communityRowWithKnownGitHubSourceOffersCheck() {
        // A completed reviewed upgrade or a github.com install binding is a
        // checkable known source and keeps access to review, check and
        // explicit rollback.
        #expect(action(skillID: "office-documents", origin: .external,
                       hasGitHubUpgradeSource: true) == .check)
        #expect(action(skillID: "office-documents", origin: .external,
                       sourceURL: "https://github.com/someone/office-documents/blob/main/SKILL.md") == .check)
    }

    @Test func creatorFolderImportAndLocalRowsHaveNoUpdateAffordance() {
        // The reported misleading rows: internal creator skills and local or
        // unknown provenance must never show update or check actions.
        #expect(action(skillID: "my-guide", origin: .internalCreated,
                       sourceURL: "floe-creator://local/my-guide") == .noAction)
        #expect(action(skillID: "imported-tool", origin: .external,
                       sourceURL: "floe-folder://local/Imported Tool") == .noAction)
        #expect(action(skillID: "legacy-row", origin: .unknown, sourceURL: nil) == .noAction)
        #expect(action(skillID: "finder-fetch", origin: .external,
                       sourceURL: "https://example.com/skills/tool.json") == .noAction)
    }

    @Test func nothingNewerCheckResultIsRecognizedWithoutSilencingFailures() {
        // Only the version-the-installed-row-already-meets outcome maps to
        // the polite already-latest state; the guard still rejects the
        // downgrade and every real failure remains visible as an error.
        #expect(SkillsCenter.checkFoundNothingNewer(SkillUpgradeError.versionRegression))
        #expect(!SkillsCenter.checkFoundNothingNewer(SkillUpgradeError.identityChanged))
        #expect(!SkillsCenter.checkFoundNothingNewer(SkillUpgradeError.localConflict))
        #expect(!SkillsCenter.checkFoundNothingNewer(SkillUpgradeError.hashMismatch("SKILL.md")))
        #expect(!SkillsCenter.checkFoundNothingNewer(OfficialSkillHub.Failure.immutableVersion))
        #expect(!SkillsCenter.checkFoundNothingNewer(OfficialSkillHub.Failure.signature))
        #expect(!SkillsCenter.checkFoundNothingNewer(NSError(domain: "network", code: 1)))
    }
}
#endif

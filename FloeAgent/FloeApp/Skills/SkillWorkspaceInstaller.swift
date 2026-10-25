// FloeApp — App-side bridge from `skill.install` to the reviewed installer.
//
// The tool plans a complete package from the run's own workspace. This bridge
// stages the plan's exact bytes into a fresh private directory (independent of
// the workspace and of Floe's installed Skills store) and hands that copy to
// the SAME `SkillsCenter` install transaction used by Finder and folder
// imports. Nothing here executes a package script, starts an interpreter or
// grants a capability.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeSkills

@MainActor
struct SkillWorkspaceInstaller: SkillWorkspaceInstalling {
    private let center: SkillsCenter

    init(center: SkillsCenter) {
        self.center = center
    }

    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        try Task.checkCancellation()
        let package = try SkillWorkspaceInstallStaging.stage(plan)
        defer {
            // The install transaction copies the staged bytes into its own
            // managed location before returning, so this private source copy
            // never outlives the call.
            try? FileManager.default.removeItem(at: package.rootURL.deletingLastPathComponent())
        }
        try Task.checkCancellation()
        return try await center.installWorkspaceSkillPackage(
            at: package.rootURL,
            sourceURL: plan.sourceURL,
            expectedCanonicalDigest: package.canonicalSHA256,
            replaceExisting: plan.isReplacement,
            expectedInstalledDigest: plan.expectedDigest
        )
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGameBuildKit

/// Route-aware tool readiness for the game build/export surface.
///
/// `providedTools` means "this prerequisite is satisfied for the selected
/// route set": either a verified local resource/SDK, or a real user-configured
/// CI route whose template installs that tool. It never means a paid developer
/// account, subscription or funding state.
///
/// The missing list is computed from the routes actually selected, not from
/// prerequisites that no selected route uses. This mirrors the coordinator's
/// target-aware gate and avoids reporting an unrelated native/Android SDK.
struct GameBuildToolReadiness: Sendable, Equatable {
    /// Tool ids a reviewed CI workflow supplies when a real repository and
    /// credential are configured. The workflows are part of the build kit; no
    /// local installation is implied by this set.
    static let ciProvidedToolIDs: Set<String> = [
        "unity-editor", "unity-webgl-module", "unity-windows-module",
        "unity-macos-module", "unity-ios-module",
        "cocos-creator", "android-sdk", "android-ndk",
        "gdevelop-sdk", "python3",
        "godot-editor", "godot-export-templates",
        "node-lts",
    ]

    let provided: Set<String>
    let ciConfigured: Bool
    let notes: [String]

    static func requiredToolIDs(routes: [GameBuildRoute],
                                selectedRouteIDs: Set<String>) -> Set<String> {
        let selected = selectedRouteIDs.isEmpty
            ? Set(routes.filter(\.enabledByDefault).map(\.id))
            : selectedRouteIDs
        return Set(routes
            .filter { selected.contains($0.id) }
            .flatMap(\.requires))
    }

    func missingPrerequisites(in plan: GameBuildCapabilityPlan,
                              selectedRouteIDs: Set<String>) -> [GameBuildPrerequisite] {
        let required = Self.requiredToolIDs(routes: plan.routes,
                                            selectedRouteIDs: selectedRouteIDs)
        return plan.prerequisites.filter {
            $0.required && required.contains($0.tool.id) && !provided.contains($0.tool.id)
        }
    }

    var summary: String {
        ciConfigured
            ? "GitHub Actions routing is configured; reviewed CI tool prerequisites are available."
            : "No GitHub Actions routing is configured; CI-only routes report their real missing prerequisite."
    }
}

/// Result of a plan-aware build. `missingPrerequisites` is diagnostic output
/// from the exact selected routes; a build that succeeded has none.
struct GameBuildRunResult: Sendable {
    let outcome: GameBuildOutcome
    let selectedRouteIDs: Set<String>
    let missingPrerequisites: [String]
}
#endif

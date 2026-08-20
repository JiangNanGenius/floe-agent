// FloeApp — Onboarding view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// First-run setup: no Floe account. The only requirement is one provider
// plus one model. Honest empty state thereafter; the sheet dismisses once
// a provider+model is configured.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

/// View model for first-run onboarding.
@MainActor
final class OnboardingViewModel: ObservableObject {

    let center: ConversationCenter

    init(center: ConversationCenter) {
        self.center = center
    }

    /// True once a provider+model pair exists (onboarding complete).
    var isConfigured: Bool {
        center.hasConfiguredProvider
    }

    func load() async {
        await center.reload()
    }

    func markSkipped() async {
        ConversationCenter.persistOnboardingSkippedMarker(true)
        var preferences = center.modelPreferences
        preferences.onboardingStatus = .skipped
        try? await center.saveModelPreferences(preferences)
    }
}
#endif

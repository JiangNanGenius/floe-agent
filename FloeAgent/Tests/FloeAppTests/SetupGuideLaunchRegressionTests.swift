// SPDX-License-Identifier: MPL-2.0
// The actual launch seam must not infer completed setup from model availability.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTestSupport
@testable import FloeApp

@Suite("FloeApp.SetupGuideLaunch", .serialized)
@MainActor
struct SetupGuideLaunchRegressionTests {
    private func configuredEnvironment() async throws -> (AppEnvironment, ModelProfile) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        return (environment, model)
    }

    @Test("A synced usable model may become the default but never completes an unseen guide")
    func configuredModelDoesNotSkipGuide() async throws {
        let (environment, model) = try await configuredEnvironment()
        var preferences = try await environment.configurationStore.preferences()
        preferences.onboardingStatus = .unseen
        preferences.defaultAgentModelID = nil
        try await environment.configurationStore.savePreferences(preferences)

        let center = environment.conversationCenter
        await center.reconcileOnboardingForLaunch()
        #expect(center.availableAgentModels.contains(where: { $0.id == model.id }))
        #expect(center.modelPreferences.onboardingStatus == .unseen)
        // Launch reconciliation is model routing, not a setup decision: with
        // no stored default the existing resolver legitimately repairs it from
        // the single usable picker model. Only an explicit Finish or Skip may
        // change the guide's own status.
        #expect(center.modelPreferences.defaultAgentModelID == model.id)
        let saved = try await environment.configurationStore.preferences()
        #expect(saved.onboardingStatus == .unseen)
        #expect(saved.onboardingStatus != .completed)
        #expect(saved.onboardingStatus != .skipped)
        #expect(saved.defaultAgentModelID == model.id)
    }

    @Test("Launch preserves explicit completed and skipped choices")
    func existingOutcomesRemain() async throws {
        let (environment, model) = try await configuredEnvironment()
        for status in [OnboardingStatus.completed, .skipped] {
            var preferences = try await environment.configurationStore.preferences()
            preferences.onboardingStatus = status
            preferences.defaultAgentModelID = model.id
            try await environment.configurationStore.savePreferences(preferences)
            await environment.conversationCenter.reconcileOnboardingForLaunch()
            #expect(environment.conversationCenter.modelPreferences.onboardingStatus == status)
            #expect(environment.conversationCenter.modelPreferences.defaultAgentModelID == model.id)
        }
    }
}
#endif

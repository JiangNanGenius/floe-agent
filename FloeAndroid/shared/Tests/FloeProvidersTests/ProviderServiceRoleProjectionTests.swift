// SPDX-License-Identifier: MPL-2.0
//
// Provider service-role projection ↔ adapter-discovery contract.
//
// AUTHORED ONLY: NOT compiled, NOT executed by this package; Main's
// serialized qualification lane runs these against the real toolchain
// (this test target needs the additive Package.swift entry delivered with
// the out-of-scope native projection patch — see HANDOFF.md).
//
// Device evidence (Samsung, signed Alpha25 candidate02): the ArkPlanImageQA
// provider saved through the IMAGE purpose reopened with the conversation
// purpose because the `config.providers.list` summary carried no roles.
// The saved model row itself was correct: capabilities 8|16 = 24 persist,
// and the FloeProviders adapter layer derives its routes from exactly those
// persisted surface bits. These tests pin that discoverable binding: the
// role the list projection reports must be the role the adapter layer
// actually serves. SECRET-FREE.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import XCTest

final class ProviderServiceRoleProjectionTests: XCTestCase {

    private let providerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func arkProvider(enabled: Bool = true) -> ProviderProfile {
        ProviderProfile(
            id: providerID,
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!,
            displayName: "ArkPlanImageQA",
            isEnabled: enabled,
        )
    }

    /// The EXACT row the Android editor stages and the native save persists
    /// for the observed flow: Seedream on the Ark Plan endpoint.
    private func seedreamRow(isEnabled: Bool = true) -> ModelProfile {
        ModelProfile(
            providerID: providerID,
            remoteModelID: "doubao-seedream-5.0-flash",
            displayName: "SeedreamFlashQA",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.imageGeneration, .imageEditing],
            isEnabled: isEnabled,
            isHiddenFromPrimaryPicker: true,
        )
    }

    func testPersistedImageRowProjectsImageRoleAndResolvesAsPublicCandidate() throws {
        let row = seedreamRow()
        // The projection role comes from the SAME persisted bits the
        // adapters consume — never from a name or preset.
        XCTAssertEqual(ProviderServiceRoles.derive(from: [row]), ["image"])
        // The public selection path (image.models → image.generate) accepts
        // the row by its remote id, exactly as image.models advertised it.
        let resolved = try ImageModelRouteResolver.resolve(
            selection: "doubao-seedream-5.0-flash", models: [row])
        XCTAssertEqual(resolved.id, row.id)
    }

    func testImageRowNeverBindsVideoSurface() {
        let row = seedreamRow()
        XCTAssertFalse(row.supportsVideoGenerationSurface)
        // Video usability additionally requires an adapter-backed provider;
        // the surface predicate alone already refuses the image row.
        XCTAssertFalse(VideoModelRegistry.isUsable(
            model: row, provider: arkProvider()))
    }

    func testPersistedVideoRowProjectsVideoRoleAndBindsVideoSurface() {
        let row = ModelProfile(
            providerID: providerID,
            remoteModelID: "seedance-2.5",
            displayName: "SeedanceQA",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.videoGeneration],
            isEnabled: true,
            isHiddenFromPrimaryPicker: true,
        )
        XCTAssertEqual(ProviderServiceRoles.derive(from: [row]), ["video"])
        XCTAssertTrue(row.supportsVideoGenerationSurface)
    }

    func testChatRowStaysConversationAndOutOfMediaDiscovery() {
        let row = ModelProfile(
            providerID: providerID,
            remoteModelID: "doubao-agent",
            displayName: "AgentQA",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools, .approval],
            isEnabled: true,
        )
        XCTAssertEqual(ProviderServiceRoles.derive(from: [row]), ["conversation"])
        XCTAssertFalse(row.supportsImageGenerationSurface)
        XCTAssertFalse(row.supportsVideoGenerationSurface)
        // The pre-existing SamsungCloudQA/ArkAgentPlanQA chat providers keep
        // their conversation binding and never enter media discovery.
    }

    func testDisabledProviderRowKeepsProjectionRole() {
        // alpha25-070: the provider itself was disabled while its row must
        // remain discoverable under its real role (list shows 已停用).
        let provider = arkProvider(enabled: false)
        XCTAssertFalse(provider.isEnabled)
        XCTAssertEqual(ProviderServiceRoles.derive(from: [seedreamRow()]), ["image"])
    }
}

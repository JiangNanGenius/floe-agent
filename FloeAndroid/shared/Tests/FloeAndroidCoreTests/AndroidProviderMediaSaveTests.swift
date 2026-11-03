// SPDX-License-Identifier: MPL-2.0
//
// Role roundtrip regressions for the provider media save/reopen flow.
//
// Device evidence (Samsung, signed Alpha25 candidate02): an Ark Plan image
// provider saved successfully (staged Seedream row, IMAGE capabilities
// 8|16 = 24) but the reopened editor showed the conversation purpose,
// because the `config.providers.list` projection carried no service roles
// and every reader collapsed to the conversation default. The save side was
// verified correct — the role lives in the persisted model rows and the
// runtime image.models/video.models discovery derives its routes from
// exactly those bits (G09R2GenerationService.resolveRoute). These tests pin
// the canonical derivation (FloeModels ProviderServiceRoles) so the list
// projection emits the REAL backend roles: image AND video roundtrip,
// multi-role providers, disabled-row preservation and empty-provider
// visibility. SECRET-FREE: no credential value appears anywhere here.

import Foundation
import FloeCore
import FloeModels
import XCTest

final class AndroidProviderMediaSaveTests: XCTestCase {

    private func makeModel(
        capabilities: ModelCapabilities,
        useSurfaces: ModelUseSurfaces? = nil,
        isEnabled: Bool = true,
        providerID: UUID = UUID(),
    ) -> ModelProfile {
        ModelProfile(
            providerID: providerID,
            remoteModelID: "model.qa",
            displayName: "ModelQA",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: capabilities,
            useSurfaces: useSurfaces,
            isEnabled: isEnabled,
            isHiddenFromPrimaryPicker: false,
        )
    }

    // The EXACT staged Seedream row the Android editor persists for an
    // image-role manual/official add: IMAGE_GENERATION|IMAGE_EDITING (24),
    // no explicit use surfaces.
    private let imageCapabilities: ModelCapabilities =
        [.imageGeneration, .imageEditing]
    private let videoCapabilities: ModelCapabilities = [.videoGeneration]
    private let chatCapabilities: ModelCapabilities = [.text, .tools, .approval]

    func testImageModelDerivesImageRoleOnly() {
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: imageCapabilities),
        ])
        XCTAssertEqual(roles, ["image"])
    }

    func testVideoModelDerivesVideoRoleOnly() {
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: videoCapabilities),
        ])
        XCTAssertEqual(roles, ["video"])
    }

    func testChatModelDerivesConversationRoleOnly() {
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: chatCapabilities),
        ])
        XCTAssertEqual(roles, ["conversation"])
    }

    func testMixedModelSetDerivesEveryServedRoleInCanonicalOrder() {
        // One provider whose rows span all three surfaces must report all
        // three roles in the canonical conversation/image/video order, so
        // the App lists it in every section it serves (iOS list parity).
        let providerID = UUID()
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: videoCapabilities, providerID: providerID),
            makeModel(capabilities: imageCapabilities, providerID: providerID),
            makeModel(capabilities: chatCapabilities, providerID: providerID),
        ])
        XCTAssertEqual(roles, ["conversation", "image", "video"])
    }

    func testDisabledModelRowsStillBindTheirRole() {
        // iOS groups on the COMPLETE persisted model set
        // (ConversationCenter.configuredModelsByProvider): a disabled row
        // keeps its role binding — alpha25-070 disabled the QA provider and
        // it must remain discoverable under its real role.
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: imageCapabilities, isEnabled: false),
        ])
        XCTAssertEqual(roles, ["image"])
    }

    func testExplicitMediaUseSurfacesStayAuthoritative() {
        // A stale synced row carrying chat/approval surfaces alongside media
        // capabilities must still derive ONLY the media role
        // (ModelProfile.effectiveUseSurfaces strips chat surfaces from media
        // models — a reference-image input is not visual understanding).
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(
                capabilities: imageCapabilities,
                useSurfaces: [.chatAgent, .imageGeneration],
            ),
        ])
        XCTAssertEqual(roles, ["image"])
    }

    func testEmptyModelSetDefaultsToConversation() {
        // A provider with no models yet stays visible in the conversation
        // section while it is being configured (iOS parity); this is also
        // the App reader's absent-field default.
        XCTAssertEqual(ProviderServiceRoles.derive(from: []), ["conversation"])
    }

    func testCapabilityExhaustedModelSetStillDefaultsToConversation() {
        // Defensive fallback: rows whose capabilities derive NO surface
        // must not make the provider vanish from every section.
        let roles = ProviderServiceRoles.derive(from: [
            makeModel(capabilities: []),
        ])
        XCTAssertEqual(roles, ["conversation"])
    }

    func testVideoRoundtripWithHiddenMediaRow() {
        // Media rows are staged hidden from the primary picker; hiding must
        // not affect the role derivation (the surface predicates never read
        // isHiddenFromPrimaryPicker).
        let model = makeModel(capabilities: videoCapabilities)
            .copyForRoleTest(isHiddenFromPrimaryPicker: true)
        let roles = ProviderServiceRoles.derive(from: [model])
        XCTAssertEqual(roles, ["video"])
    }
}

private extension ModelProfile {
    func copyForRoleTest(isHiddenFromPrimaryPicker: Bool) -> ModelProfile {
        var copy = self
        copy.isHiddenFromPrimaryPicker = isHiddenFromPrimaryPicker
        return copy
    }
}

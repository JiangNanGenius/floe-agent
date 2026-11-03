// SPDX-License-Identifier: MPL-2.0
//
// FloeModels — provider service-role derivation for the secret-free
// `config.providers.list` summary projection.
//
// The provider editor's chosen purpose (conversation / image / video) is
// persisted ONLY through the saved model rows' capability bits and use
// surfaces (the ORIGINAL FloeCore surface predicates:
// ModelProfile.supportsChatAgentSurface / supportsImageGenerationSurface /
// supportsVideoGenerationSurface, ModelProfile.swift:215-267). The providers
// table has no role column and the save candidate's
// `serviceRoleIsConversation` boolean is a save-time scalar, not durable
// state. This helper is the ONE place that maps a provider's complete
// persisted model set onto its wire service roles, mirroring the iOS
// provider list exactly (FloeApp ProviderListViewModel.swift:40-68 — same
// predicates, same empty-provider conversation visibility, disabled rows
// included because configuredModelsByProvider carries every persisted row).
// Nothing here invents authority from provider names, presets or kinds.

import Foundation
import FloeCore

/// One provider service role as carried by the additive secret-free
/// `serviceRoles` projection member (unknown to older App readers, which
/// keep their conversation-only default).
public enum ProviderServiceRoleWire: String, Sendable, Codable, CaseIterable {
    case conversation
    case image
    case video
}

public enum ProviderServiceRoles {
    /// The canonical wire ordering of the projection array.
    public static let wireOrder: [ProviderServiceRoleWire] = [
        .conversation, .image, .video,
    ]

    /**
     * Derives the `serviceRoles` wire array for ONE provider from its
     * COMPLETE persisted model set (enabled and disabled rows alike — the
     * iOS list groups on `configuredModelsByProvider`, which carries every
     * persisted row, ConversationCenter.swift:1303).
     *
     * Rules (exact iOS parity):
     *  - conversation: the provider has NO models yet (kept visible while
     *    being configured) OR at least one model supports the chat-agent
     *    surface;
     *  - image: at least one model supports the image-generation surface;
     *  - video: at least one model supports the video-generation surface;
     *  - defensive fallback: a model set whose rows derive NO surface
     *    (exhausted/empty capability rows) still reports conversation so the
     *    provider stays visible and editable, matching the App reader's
     *    documented absent-field default.
     *
     * The derivation never consults provider names, preset ids, endpoints or
     * kinds, and never filters by `isEnabled` (a disabled provider's role
     * binding must survive its disabled state, exactly like the iOS list).
     */
    public static func derive(from models: [ModelProfile]) -> [String] {
        var roles: [String] = []
        if models.isEmpty || models.contains(where: { $0.supportsChatAgentSurface }) {
            roles.append(ProviderServiceRoleWire.conversation.rawValue)
        }
        if models.contains(where: { $0.supportsImageGenerationSurface }) {
            roles.append(ProviderServiceRoleWire.image.rawValue)
        }
        if models.contains(where: { $0.supportsVideoGenerationSurface }) {
            roles.append(ProviderServiceRoleWire.video.rawValue)
        }
        if roles.isEmpty {
            roles.append(ProviderServiceRoleWire.conversation.rawValue)
        }
        return roles
    }
}

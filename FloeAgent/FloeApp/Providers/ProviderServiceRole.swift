#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore

/// Product role selected before configuring a provider. Wire protocol and
/// credentials remain provider properties; this role only supplies honest
/// model-capability defaults and section grouping.
enum ProviderServiceRole: String, CaseIterable, Identifiable {
    case conversation
    case image
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: FloeL10n.l("providers.provider_service_role.chat_model")
        case .image: FloeL10n.l("providers.provider_service_role.image_generation_and_editing")
        case .video: FloeL10n.l("providers.provider_service_role.video_generation_extra")
        }
    }

    var icon: String {
        switch self {
        case .conversation: "bubble.left.and.text.bubble.right"
        case .image: "photo.on.rectangle.angled"
        case .video: "video.badge.plus"
        }
    }

    var defaultCapabilities: ModelCapabilities {
        switch self {
        case .conversation: [.text, .tools, .approval]
        case .image: [.imageGeneration, .imageEditing]
        case .video: [.videoGeneration]
        }
    }

    var managedCapabilities: ModelCapabilities {
        switch self {
        case .conversation: .text
        case .image: [.imageGeneration, .imageEditing]
        case .video: .videoGeneration
        }
    }

    var defaultUseSurfaces: ModelUseSurfaces {
        switch self {
        case .conversation: [.chatAgent, .approval]
        case .image: .imageGeneration
        case .video: .videoGeneration
        }
    }

    static func infer(from models: [ModelProfile]) -> ProviderServiceRole {
        if models.contains(where: \.supportsChatAgentSurface) { return .conversation }
        if models.contains(where: \.supportsVideoGenerationSurface) { return .video }
        return .image
    }
}
#endif

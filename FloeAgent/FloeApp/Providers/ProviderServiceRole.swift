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
        case .conversation: "对话模型"
        case .image: "图片生成与编辑"
        case .video: "视频生成（Extra）"
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
        if models.contains(where: { $0.effectiveUseSurfaces.contains(.chatAgent) }) { return .conversation }
        if models.contains(where: { $0.effectiveUseSurfaces.contains(.videoGeneration) }) { return .video }
        return .image
    }
}
#endif

// FloeProviders — Alibaba Model Studio (DashScope) endpoint identity and
// request-family routing.
//
// The Model Studio product has three connection shapes that must never share
// credentials or request bodies silently:
//
//   * Pay-as-you-go (PAYG): the public `dashscope.aliyuncs.com` root, a
//     `{WorkspaceId}.{region}.maas.aliyuncs.com` workspace host, or a
//     regional DashScope host. Chat uses `/compatible-mode/v1`; native
//     image/video calls live on `/api/v1`.
//   * Token Plan Personal Edition: the dedicated
//     `token-plan.cn-beijing.maas.aliyuncs.com` host. Its OpenAI-compatible
//     chat root is `/compatible-mode/v1`; image/video models are invoked on
//     the native `/api/v1` routes (`multimodal-generation/generation`,
//     `video-generation/video-synthesis`, `tasks/{id}`).
//   * Coding Plan: `coding.dashscope.aliyuncs.com/v1`, a distinct chat-only
//     subscription. It is deliberately excluded here.
//
// These helpers are pure. They choose a wire family; they never rewrite the
// saved provider URL or its credential.
//
// Official references verified 2026-10-30:
// * PAYG Qwen Image 3.0/2.1 OpenAI-compatible images/generations with the
//   extended `image` field (no multipart /images/edits):
//   https://help.aliyun.com/zh/model-studio/qwen-image-generation-and-editing-api-reference
// * PAYG Wan 3.0 video task API:
//   https://help.aliyun.com/zh/model-studio/wan3-video-generation-api-reference
// * Token Plan multimodal generation:
//   https://help.aliyun.com/zh/model-studio/token-plan-multimodal-gen

import Foundation
import FloeCore

/// Identity and URL helpers for the Alibaba Model Studio surface.
public enum AlibabaEndpointIdentity {

    /// True for the dedicated Token Plan Personal Edition gateway. The
    /// billing endpoint remains the credential/identity authority; this
    /// helper additionally recognises the documented host shape so request
    /// routing cannot fall back to PAYG by accident.
    public static func isTokenPlan(_ url: URL) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        guard ProviderBillingEndpoint.resolve(url) == .alibabaTokenPlan || host.hasPrefix("token-plan.") else {
            return false
        }
        return TokenPlanPath.isDocumented(url.path)
    }

    /// True for a PAYG/workspace DashScope connection. Coding Plan and the
    /// Token Plan gateway are distinct subscriptions and are excluded.
    public static func isPayAsYouGo(_ url: URL) -> Bool {
        guard let host = normalizedHost(url), !isTokenPlan(url) else { return false }
        guard !host.hasPrefix("coding."), !host.hasPrefix("token-plan.") else { return false }
        if host == "dashscope.aliyuncs.com"
            || host == "dashscope-intl.aliyuncs.com"
            || host == "dashscope-us.aliyuncs.com" {
            return true
        }
        // Workspace-specific Beijing/Singapore/US/EU/JP/HK hosts use
        // `{WorkspaceId}.{region}.maas.aliyuncs.com`.
        return host.hasSuffix(".maas.aliyuncs.com")
    }

    /// OpenAI-compatible chat root for a PAYG connection. The native API root
    /// (`/api/v1`) and a bare workspace host are normalized to the documented
    /// compatible-mode path; a custom proxy path is preserved.
    public static func compatibleModeRoot(baseURL: URL) -> URL {
        let trimmed = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == "compatible-mode/v1"
            || trimmed.hasSuffix("/compatible-mode/v1") {
            return baseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if trimmed == "api/v1" {
            components?.path = "/compatible-mode/v1"
        } else if trimmed.hasSuffix("/api/v1") {
            let prefix = String(trimmed.dropLast("api/v1".count))
            components?.path = "/" + prefix + "compatible-mode/v1"
        } else if trimmed.isEmpty, let host = baseURL.host?.lowercased(),
                  host.hasSuffix("aliyuncs.com") {
            components?.path = "/compatible-mode/v1"
        } else {
            return baseURL
        }
        return components?.url ?? baseURL
    }

    /// Native DashScope API root (`.../api/v1`). Shared with the existing
    /// video routing contract.
    public static func nativeAPIRoot(baseURL: URL) -> URL {
        VideoEndpointRouting.dashScopeAPIRoot(baseURL: baseURL)
    }

    /// Scheme/host/port normalisation shared by the endpoint helpers.
    static func normalizedHost(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private enum TokenPlanPath {
        static func isDocumented(_ path: String) -> Bool {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed == "compatible-mode/v1" || trimmed == "apps/anthropic/v1"
        }
    }
}

/// Concrete image request family for one Model Studio connection/model.
public enum AlibabaImageWireRoute: String, Sendable, Equatable {
    /// PAYG Qwen Image 3.0/2.1: OpenAI-compatible
    /// `POST {compatible-mode}/images/generations` with the top-level
    /// `image` extension field. `/images/edits` and multipart are never used.
    case openAICompatible
    /// Synchronous native multimodal generation:
    /// `POST {root}/api/v1/services/aigc/multimodal-generation/generation`.
    /// Token Plan image models and PAYG Wan 2.6/2.7 image families use it.
    case nativeMultimodal
    /// Legacy asynchronous `text2image/image-synthesis` task API for older
    /// text-to-image-only models.
    case nativeTask

    public static func resolve(
        provider: ProviderProfile,
        modelRemoteID: String
    ) -> AlibabaImageWireRoute {
        let model = modelRemoteID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Token Plan publishes image generation only through the native
        // multimodal route (token-plan-multimodal-gen, 2026-10-30).
        if AlibabaEndpointIdentity.isTokenPlan(provider.baseURL) {
            return .nativeMultimodal
        }
        if isOpenAICompatibleImageModel(model) {
            return .openAICompatible
        }
        if isNativeMultimodalImageModel(model) {
            return .nativeMultimodal
        }
        return .nativeTask
    }

    static func isOpenAICompatibleImageModel(_ model: String) -> Bool {
        let prefixes = [
            "qwen-image-3.0", "qwen-image-3-0",
            "qwen-image-2.1", "qwen-image-2-1"
        ]
        return prefixes.contains { model.hasPrefix($0) }
    }

    static func isNativeMultimodalImageModel(_ model: String) -> Bool {
        let prefixes = [
            "qwen-image-2.0", "qwen-image-2-0",
            "wan2.6-image", "wan2.7-image"
        ]
        return prefixes.contains { model.hasPrefix($0) }
    }
}

/// Concrete video request family for one Model Studio model.
public enum AlibabaVideoWireRoute: String, Sendable, Equatable {
    /// Wan 3.0: `input.media` first frame, ratio/resolution/duration/audio.
    case wan3
    /// Wan 2.7: ratio/resolution/duration, first-frame support is handled by
    /// the existing family guard.
    case wan27
    /// HappyHorse text-to-video: ratio/resolution/duration.
    case happyHorseText
    /// HappyHorse image-to-video/reference: `input.media[type=first_frame]`,
    /// resolution/duration (the aspect ratio follows the source image).
    case happyHorseImage
    /// Older Wan models keep their existing size/seed parameter mapping.
    case legacy

    public static func resolve(modelRemoteID: String) -> AlibabaVideoWireRoute {
        let model = modelRemoteID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model.hasPrefix("wan3.0-") || model.hasPrefix("wan3-0-") {
            return .wan3
        }
        if model.hasPrefix("wan2.7-") || model.hasPrefix("wan2-7-") {
            return .wan27
        }
        if model.hasPrefix("happyhorse-") {
            return model.contains("-t2v") ? .happyHorseText : .happyHorseImage
        }
        return .legacy
    }

    public var isHappyHorse: Bool {
        self == .happyHorseText || self == .happyHorseImage
    }
}

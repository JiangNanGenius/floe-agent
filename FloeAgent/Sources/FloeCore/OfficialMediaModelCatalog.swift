import Foundation

/// Versioned, product-owned presets for official first-party endpoints. The
/// remote IDs remain editable because providers retire model revisions.
public enum OfficialMediaModelCatalog {
    public static let manifestVersion = 2
    public static let verifiedAt = ISO8601DateFormatter().date(from: "2026-08-29T00:00:00Z")!

    public static let models: [MediaModelDescriptor] = [
        .init(id: "openai.gpt-image-2", provider: .openAI, kind: .image,
              remoteModelID: "gpt-image-2", displayName: "GPT Image 2",
              supportedAspectRatios: ["1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16"],
              supportedResolutions: ["1K"], supportedQualities: ["low", "medium", "high"],
              defaultResolution: "1K", defaultQuality: "medium", maximumReferenceAssets: 16,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),

        .init(id: "google.nano-banana", provider: .googleGemini, kind: .image,
              remoteModelID: "gemini-2.5-flash-image", displayName: "Nano Banana",
              supportedAspectRatios: ["1:1", "2:3", "3:2", "3:4", "4:3", "9:16", "16:9"],
              supportedResolutions: ["1K"], defaultResolution: "1K", maximumReferenceAssets: 3,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "google.nano-banana-2-lite", provider: .googleGemini, kind: .image,
              remoteModelID: "gemini-3.1-flash-lite-image", displayName: "Nano Banana 2 Lite",
              supportedAspectRatios: ["1:1", "2:3", "3:2", "3:4", "4:3", "9:16", "16:9"],
              supportedResolutions: ["1K", "2K", "4K"], defaultResolution: "2K", maximumReferenceAssets: 3,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "google.nano-banana-2", provider: .googleGemini, kind: .image,
              remoteModelID: "gemini-3.1-flash-image", displayName: "Nano Banana 2",
              supportedAspectRatios: ["1:1", "2:3", "3:2", "3:4", "4:3", "9:16", "16:9"],
              supportedResolutions: ["1K", "2K", "4K"], defaultResolution: "2K", maximumReferenceAssets: 14,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "google.nano-banana-pro", provider: .googleGemini, kind: .image,
              remoteModelID: "gemini-3-pro-image", displayName: "Nano Banana Pro",
              supportedAspectRatios: ["1:1", "2:3", "3:2", "3:4", "4:3", "9:16", "16:9"],
              supportedResolutions: ["1K", "2K", "4K"], defaultResolution: "2K", maximumReferenceAssets: 14,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "google.gemini-omni-flash-video", provider: .googleGemini, kind: .video,
              remoteModelID: "gemini-omni-flash-preview", displayName: "Gemini Omni Flash",
              supportedAspectRatios: ["16:9", "9:16"], supportedDurations: [3, 4, 5, 6, 7, 8, 9, 10],
              supportedQualities: ["720p"], maximumReferenceAssets: 1,
              supportsAudio: true,
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "google.veo-3.1", provider: .googleGemini, kind: .video,
              remoteModelID: "veo-3.1-generate-preview", displayName: "Veo 3.1",
              supportedAspectRatios: ["16:9", "9:16"], supportedDurations: [4, 6, 8],
              supportedQualities: ["720p", "1080p", "4K"], maximumReferenceAssets: 3,
              supportsAudio: true, verifiedAt: verifiedAt, manifestVersion: manifestVersion),

        .init(id: "volcengine.seedream", provider: .volcengineArk, kind: .image,
              remoteModelID: "doubao-seedream-4-0-250828", displayName: "Seedream 4.0",
              supportedAspectRatios: ["1:1", "4:3", "3:4", "16:9", "9:16"],
              supportedResolutions: ["1K", "2K", "4K"], defaultResolution: "2K", maximumReferenceAssets: 10,
              supportsWatermark: true, supportsSeed: true, supportsPromptOptimization: true,
              region: "cn-beijing", verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "volcengine.seedance", provider: .volcengineArk, kind: .video,
              remoteModelID: "doubao-seedance-2-0-260128", displayName: "Seedance 2.0",
              supportedAspectRatios: ["16:9", "4:3", "1:1", "3:4", "9:16", "21:9"],
              supportedDurations: Array(4...15),
              supportedQualities: ["480p", "720p", "1080p"], maximumReferenceAssets: 1,
              supportsAudio: true, supportsWatermark: true, supportsSeed: true,
              supportsPromptOptimization: true, region: "cn-beijing",
              verifiedAt: verifiedAt, manifestVersion: manifestVersion),

        .init(id: "alibaba.qwen-image", provider: .alibabaModelStudio, kind: .image,
              remoteModelID: "qwen-image-3.0-pro", displayName: "Qwen Image 3.0 Pro",
              supportedAspectRatios: ["1:1", "4:3", "3:4", "16:9", "9:16"],
              supportedResolutions: ["1K", "2K"], defaultResolution: "2K", maximumReferenceAssets: 3,
              supportsWatermark: true, supportsSeed: true, supportsPromptOptimization: true,
              region: "cn-beijing", verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "alibaba.wan-image", provider: .alibabaModelStudio, kind: .image,
              remoteModelID: "wan2.7-image-pro", displayName: "Wan Image 2.7 Pro",
              supportedAspectRatios: ["1:1", "4:3", "3:4", "16:9", "9:16"],
              supportedResolutions: ["1K", "2K", "4K"], defaultResolution: "2K", maximumReferenceAssets: 9,
              supportsWatermark: true, supportsSeed: true,
              region: "cn-beijing", verifiedAt: verifiedAt, manifestVersion: manifestVersion),
        .init(id: "alibaba.wan-video", provider: .alibabaModelStudio, kind: .video,
              remoteModelID: "wan3.0-video", displayName: "Wan Video 3.0",
              supportedAspectRatios: ["16:9", "9:16", "1:1"], supportedDurations: [5, 10],
              supportedQualities: ["480p", "720p", "1080p"], maximumReferenceAssets: 1,
              supportsAudio: true, supportsWatermark: true, supportsSeed: true,
              region: "cn-beijing", verifiedAt: verifiedAt, manifestVersion: manifestVersion)
    ]

    public static func models(provider: MediaProviderFamily, kind: MediaKind) -> [MediaModelDescriptor] {
        models.filter { $0.provider == provider && $0.kind == kind && !$0.isDeprecated }
    }
}

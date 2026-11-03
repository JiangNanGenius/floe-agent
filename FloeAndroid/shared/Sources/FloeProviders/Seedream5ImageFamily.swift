// FloeProviders — Documented Seedream 5.0 image-family limits.
//
// The public Agent Plan image identifiers live in ProviderCatalog.json. This
// file is the small compiled contract that knows their documented parameter
// families; it never declares candidate model ids (the catalog stays the only
// source of seeds and the PAYG manifest is never merged into a plan).
//
// Official references verified 2026-10-30:
// * Agent Plan visual models:
//   https://ark.volcengine.com/region:cn-beijing/docs/agent-plan-personal-visual-models
// * Seedream 5.0 pro / flash tutorial:
//   https://ark.volcengine.com/region:cn-beijing/docs/seedream-5-0-pro
// * Image generation API:
//   https://ark.volcengine.com/region:cn-beijing/docs/image-generation-api
//
// Seedream 5.0 pro and flash both generate exactly one image per request and
// only accept the 1K/1.5K/2K resolution tiers; `sequential_image_generation`
// is unsupported for them. Seedream 5.0 lite keeps grouped generation and the
// existing 2K/3K/4K product tiers.

import Foundation

enum Seedream5ImageFamily: String, Sendable, Equatable {
    case pro
    case flash
    case lite

    /// Resolves either official spelling (`5.0` or `5-0`) and tolerates a
    /// provider revision suffix (`-260628`, `-260915`). The provider-facing
    /// identifier is never rewritten.
    static func resolve(_ remoteModelID: String?) -> Seedream5ImageFamily? {
        guard let remoteModelID else { return nil }
        let normalized = remoteModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
        guard normalized.contains("seedream-5-0") else { return nil }
        if normalized.contains("seedream-5-0-pro") { return .pro }
        if normalized.contains("seedream-5-0-flash") { return .flash }
        if normalized.contains("seedream-5-0-lite") { return .lite }
        return nil
    }

    /// Official resolution tiers. `1.5K` is valid for pro/flash only.
    var supportedResolutions: [String] {
        switch self {
        case .pro, .flash: ["1K", "1.5K", "2K"]
        case .lite: ["2K", "3K", "4K"]
        }
    }

    /// The product's existing Seedream aspect set. The upstream API also
    /// documents 3:2, 2:3 and 21:9; those are not exposed by the current image
    /// tool contract and are deliberately not promised here.
    var supportedAspectRatios: [String] {
        ["1:1", "4:3", "3:4", "16:9", "9:16"]
    }

    var defaultResolution: String { "2K" }

    /// Pro/flash generate one image; lite keeps grouped generation.
    var supportsBatchGeneration: Bool {
        switch self {
        case .pro, .flash: false
        case .lite: true
        }
    }

    var maximumOutputImages: Int {
        supportsBatchGeneration ? 4 : 1
    }
}

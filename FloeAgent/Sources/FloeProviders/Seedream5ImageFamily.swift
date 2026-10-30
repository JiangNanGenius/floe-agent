// FloeProviders — Documented Seedream 5.0 image-family limits.
//
// The public Agent Plan image identifiers live in ProviderCatalog.json. This
// file is the small compiled contract that knows their documented parameter
// families; it never declares candidate model ids (the catalog stays the only
// source of seeds and the PAYG manifest is never merged into a plan).
//
// Official references verified 2026-10-31:
// * Agent Plan visual models (pro/flash only; lite is not a plan model):
//   https://ark.volcengine.com/region:cn-beijing/docs/agent-plan-personal-visual-models
// * Agent Plan AFP billing table (pro/flash only):
//   https://console.volcengine.com/ark/region%3Acn-beijing/docs/agent-plan-personal-afp-credits-billing-rules
// * Seedream 5.0 pro / flash tutorial:
//   https://ark.volcengine.com/region:cn-beijing/docs/seedream-5-0-pro
// * Image generation API:
//   https://ark.volcengine.com/region:cn-beijing/docs/image-generation-api
//
// Seedream 5.0 pro and flash both generate exactly one image per request and
// only accept the 1K/1.5K/2K resolution tiers; `sequential_image_generation`
// is unsupported for them. Seedream 5.0 lite keeps grouped generation and the
// existing 2K/3K/4K product tiers, but it is a PAYG model and must never be
// offered as an Agent Plan candidate.

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

    /// The reviewed Agent Plan visual-model table currently publishes pro and
    /// flash. Lite is a pay-as-you-go model: an actual plan request returned
    /// `UnsupportedModel`, so it must not remain a plan candidate or fall back
    /// silently to flash.
    var isAvailableOnAgentPlan: Bool { self != .lite }

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

    /// Native images returned from one HTTP request. Pro/flash are documented
    /// as single-image generation; lite keeps grouped generation.
    var maximumOutputImages: Int {
        supportsBatchGeneration ? 4 : 1
    }

    /// Product-level candidate cap for one `image.generate` request. When the
    /// native limit is one, the image service fulfils the remaining candidates
    /// with bounded single-image requests instead of dropping them or
    /// pretending the provider produced a batch.
    var maximumCandidateCount: Int { 4 }

    var supportsBatchGeneration: Bool {
        switch self {
        case .pro, .flash: false
        case .lite: true
        }
    }

    var countStrategy: String {
        supportsBatchGeneration ? "nativeBatch" : "sequentialSingleImageRequests"
    }

    /// Official resolution/aspect mapping from the image-generation API. A
    /// missing option is rejected instead of silently substituting 1:1.
    func nativeSize(aspect: String, resolution: String) -> String? {
        Self.nativeSizes[self]?[resolution]?[aspect]
    }

    /// Image-generation API method 2 (`WIDTHxHEIGHT`) bounds. The API accepts
    /// either a tier or a pixel size, never both; an invalid pixel size is
    /// rejected locally instead of being sent and failing after billing.
    func isValidNativeSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        guard ratio >= 1.0 / 16.0, ratio <= 16.0 else { return false }
        let pixels = width * height
        switch self {
        case .pro, .flash:
            return (921_600...4_624_220).contains(pixels)
        case .lite:
            return (3_686_400...16_777_216).contains(pixels)
        }
    }

    private static let nativeSizes: [Seedream5ImageFamily: [String: [String: String]]] = [
        .pro: [
            "1K": [
                "1:1": "1024x1024", "4:3": "1152x864", "3:4": "864x1152",
                "16:9": "1424x800", "9:16": "800x1424",
                "3:2": "1248x832", "2:3": "832x1248", "21:9": "1568x672"
            ],
            "1.5K": [
                "1:1": "1536x1536", "4:3": "1792x1344", "3:4": "1344x1792",
                "16:9": "2048x1152", "9:16": "1152x2048",
                "3:2": "1872x1248", "2:3": "1248x1872", "21:9": "2352x1008"
            ],
            "2K": [
                "1:1": "2048x2048", "4:3": "2368x1776", "3:4": "1776x2368",
                "16:9": "2816x1584", "9:16": "1584x2816",
                "3:2": "2496x1664", "2:3": "1664x2496", "21:9": "3136x1344"
            ]
        ],
        .flash: [
            "1K": [
                "1:1": "1024x1024", "4:3": "1152x864", "3:4": "864x1152",
                "16:9": "1424x800", "9:16": "800x1424",
                "3:2": "1248x832", "2:3": "832x1248", "21:9": "1568x672"
            ],
            "1.5K": [
                "1:1": "1536x1536", "4:3": "1792x1344", "3:4": "1344x1792",
                "16:9": "2048x1152", "9:16": "1152x2048",
                "3:2": "1872x1248", "2:3": "1248x1872", "21:9": "2352x1008"
            ],
            "2K": [
                "1:1": "2048x2048", "4:3": "2368x1776", "3:4": "1776x2368",
                "16:9": "2816x1584", "9:16": "1584x2816",
                "3:2": "2496x1664", "2:3": "1664x2496", "21:9": "3136x1344"
            ]
        ],
        .lite: [
            "2K": [
                "1:1": "2048x2048", "4:3": "2304x1728", "3:4": "1728x2304",
                "16:9": "2848x1600", "9:16": "1600x2848",
                "3:2": "2496x1664", "2:3": "1664x2496", "21:9": "3136x1344"
            ],
            "3K": [
                "1:1": "3072x3072", "4:3": "3456x2592", "3:4": "2592x3456",
                "16:9": "4096x2304", "9:16": "2304x4096",
                "3:2": "3744x2496", "2:3": "2496x3744", "21:9": "4704x2016"
            ],
            "4K": [
                "1:1": "4096x4096", "4:3": "4704x3520", "3:4": "3520x4704",
                "16:9": "5504x3040", "9:16": "3040x5504",
                "3:2": "4992x3328", "2:3": "3328x4992", "21:9": "6240x2656"
            ]
        ]
    ]
}

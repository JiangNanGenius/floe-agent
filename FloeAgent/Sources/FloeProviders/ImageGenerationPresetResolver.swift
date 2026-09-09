import Foundation
import FloeCore

/// Converts the product's aspect-ratio and resolution controls into the
/// provider-native `size` value. Keeping this at the adapter boundary prevents
/// UI labels such as `16:9` from leaking into incompatible wire fields.
public enum ImageGenerationPresetResolver {
    public struct ParameterContract: Codable, Sendable {
        public var verifiedModel: Bool
        public var aspectRatio: [String]
        public var resolution: [String]
        public var quality: [String]
        public var defaultAspectRatio: String
        public var defaultResolution: String?
        public var defaultQuality: String?
        public var minimumCount: Int
        public var maximumCount: Int
        public var maximumReferenceImages: Int
        public var nativeSizeOverride: Bool
        /// These provider features are not accepted by the current image tool.
        public var unavailableControls: [String]
    }

    public static func parameterContract(
        provider: ProviderProfile, model: ModelProfile, operation: RemoteImageOperation
    ) -> ParameterContract {
        let family: MediaProviderFamily? = switch provider.kind {
        case .openAI: .openAI
        case .googleGemini: .googleGemini
        case .volcengineArk: .volcengineArk
        case .alibabaStudio: .alibabaModelStudio
        default: nil
        }
        let descriptor = OfficialMediaModelCatalog.models.first {
            $0.provider == family && $0.kind == .image && $0.remoteModelID == model.remoteModelID
        }
        let adapter = ImageProviderAdapterFactory().adapter(for: provider)
        let resolutions = (descriptor?.supportedResolutions ?? []).filter {
            !(provider.kind == .alibabaStudio && operation != .generate && $0 == "4K")
        }
        return ParameterContract(
            verifiedModel: descriptor != nil,
            aspectRatio: descriptor?.supportedAspectRatios ?? [], resolution: resolutions,
            quality: descriptor?.supportedQualities ?? [], defaultAspectRatio: "1:1",
            defaultResolution: descriptor?.defaultResolution,
            defaultQuality: descriptor?.defaultQuality,
            minimumCount: 1, maximumCount: min(4, adapter?.maximumOutputImages(modelRemoteID: model.remoteModelID) ?? 1),
            maximumReferenceImages: operation == .generate ? 0 : ImageReferenceCapabilityResolver.maximumReferenceImages(provider: provider, model: model),
            nativeSizeOverride: provider.kind != .googleGemini,
            unavailableControls: ["seed", "watermark", "promptOptimization"]
        )
    }

    public static func applyingDefaults(
        _ selection: ImageGenerationSelection, provider: ProviderProfile, model: ModelProfile,
        operation: RemoteImageOperation
    ) -> ImageGenerationSelection {
        let contract = parameterContract(provider: provider, model: model, operation: operation)
        return ImageGenerationSelection(
            aspectRatio: selection.aspectRatio ?? contract.defaultAspectRatio,
            resolution: selection.resolution ?? contract.defaultResolution,
            quality: selection.quality ?? contract.defaultQuality,
            nativeSizeOverride: selection.nativeSizeOverride)
    }

    public static func validateSelection(
        _ selection: ImageGenerationSelection, provider: ProviderProfile, model: ModelProfile,
        operation: RemoteImageOperation, count: Int, referenceCount: Int
    ) throws {
        let contract = parameterContract(provider: provider, model: model, operation: operation)
        guard (contract.minimumCount...max(contract.minimumCount, contract.maximumCount)).contains(count),
              referenceCount >= 0, referenceCount <= contract.maximumReferenceImages else {
            throw RemoteImageError.requestFailed("Image count or reference count exceeds this model's limit; inspect image.models.")
        }
        for (value, allowed, label) in [
            (selection.aspectRatio, contract.aspectRatio, "aspectRatio"),
            (selection.resolution?.uppercased(), contract.resolution, "resolution"),
            (selection.quality?.lowercased(), contract.quality, "quality")
        ] {
            if let value, !allowed.contains(value) {
                throw RemoteImageError.requestFailed("Unsupported or unverified \(label)=\(value) for \(model.remoteModelID); inspect image.models.")
            }
        }
        if let size = selection.nativeSizeOverride {
            let parts = size.replacingOccurrences(of: "*", with: "x").split(separator: "x")
            guard contract.nativeSizeOverride, parts.count == 2,
                  let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0, width <= 8192, height <= 8192 else {
                throw RemoteImageError.requestFailed("Invalid or unsupported native image size")
            }
        }
        _ = try nativeSize(provider: provider.kind, modelRemoteID: model.remoteModelID, operation: operation, selection: selection)
        _ = try normalizedQuality(selection.quality, provider: provider.kind, modelRemoteID: model.remoteModelID)
    }

    public static func defaultResolution(provider: ProviderKind, modelRemoteID: String?) -> String {
        let model = modelRemoteID?.lowercased() ?? ""
        if provider == .openAI { return "1K" }
        if provider == .googleGemini, model.contains("2.5-flash-image") { return "1K" }
        return "2K"
    }

    public static func nativeSize(
        provider: ProviderKind,
        modelRemoteID: String?,
        operation: RemoteImageOperation,
        selection: ImageGenerationSelection
    ) throws -> String? {
        if let override = cleaned(selection.nativeSizeOverride), !isAspectRatio(override) {
            return provider == .alibabaStudio
                ? override.replacingOccurrences(of: "x", with: "*")
                : override.replacingOccurrences(of: "*", with: "x")
        }
        let aspect = cleaned(selection.aspectRatio)
            ?? cleaned(selection.nativeSizeOverride).flatMap { isAspectRatio($0) ? $0 : nil }
            ?? "1:1"
        guard supportedAspects.contains(aspect) else {
            throw RemoteImageError.requestFailed("当前图片模型不支持画面比例 \(aspect)。")
        }
        let resolution = cleaned(selection.resolution)?.uppercased()
            ?? defaultResolution(provider: provider, modelRemoteID: modelRemoteID)
        guard (["1K", "2K", "4K"].contains(resolution) || (provider == .volcengineArk && ["1.5K", "3K"].contains(resolution))) else {
            throw RemoteImageError.requestFailed("当前图片模型不支持分辨率 \(resolution)。")
        }

        switch provider {
        case .openAI:
            return openAISize(aspect: aspect, resolution: resolution)
        case .volcengineArk:
            let model = modelRemoteID?.lowercased() ?? ""
            if model.contains("seedream-5-0") {
                let allowed = model.contains("-pro") ? ["1K", "1.5K", "2K"] : ["2K", "3K", "4K"]
                guard allowed.contains(resolution) else { throw RemoteImageError.requestFailed("所选 Seedream 模型不支持分辨率 \(resolution)。") }
            }
            return volcengineSize(aspect: aspect, resolution: resolution)
        case .alibabaStudio:
            if operation != .generate, resolution == "4K" {
                throw RemoteImageError.requestFailed("阿里云图片编辑最高支持 2K，请降低分辨率后重试。")
            }
            let model = modelRemoteID?.lowercased() ?? ""
            if resolution == "4K", !model.contains("wan2.7-image-pro") {
                throw RemoteImageError.requestFailed("所选阿里云图片模型不支持 4K。")
            }
            return alibabaSize(aspect: aspect, resolution: resolution)
        case .googleGemini:
            return nil
        case .anthropic, .local, .custom:
            return nil
        }
    }

    public static func normalizedQuality(_ quality: String?, provider: ProviderKind, modelRemoteID: String? = nil) throws -> String? {
        guard let value = cleaned(quality)?.lowercased() else { return nil }
        guard provider == .openAI else { return nil }
        let model = modelRemoteID?.lowercased() ?? ""
        let isImage25 = ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst"].contains {
            model == $0 || model.hasPrefix($0 + "-")
        }
        let allowed = isImage25
            ? ["low", "medium", "high", "xhigh", "max", "auto"]
            : ["low", "medium", "high", "auto"]
        guard allowed.contains(value) else {
            throw RemoteImageError.requestFailed("OpenAI 图片质量参数无效：\(value)。")
        }
        return value
    }

    private static let supportedAspects = Set(["1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16"])

    private static func openAISize(aspect: String, resolution: String) -> String {
        // GPT Image 2 accepts arbitrary WIDTHxHEIGHT values divisible by 16.
        let oneK = [
            "1:1": "1024x1024", "3:2": "1536x1024", "2:3": "1024x1536",
            "4:3": "1344x1008", "3:4": "1008x1344",
            "16:9": "1536x864", "9:16": "864x1536"
        ]
        // The catalog currently exposes 1K for OpenAI, but keeping a bounded
        // higher-tier table makes restored metadata deterministic.
        let scale = resolution == "4K" ? 2.5 : resolution == "2K" ? 1.5 : 1.0
        guard scale != 1, let raw = oneK[aspect] else { return oneK[aspect] ?? "1024x1024" }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return raw }
        let width = min(3_840, max(256, Int((parts[0] * scale) / 16) * 16))
        let height = min(2_160, max(256, Int((parts[1] * scale) / 16) * 16))
        return "\(width)x\(height)"
    }

    private static func volcengineSize(aspect: String, resolution: String) -> String {
        let tables: [String: [String: String]] = [
            "1K": [
                "1:1": "1024x1024", "3:2": "1536x1024", "2:3": "1024x1536",
                "4:3": "1184x888", "3:4": "888x1184",
                "16:9": "1376x768", "9:16": "768x1376"
            ],
            "2K": [
                "1:1": "2048x2048", "3:2": "2496x1664", "2:3": "1664x2496",
                "4:3": "2304x1728", "3:4": "1728x2304",
                "16:9": "2560x1440", "9:16": "1440x2560"
            ],
            "4K": [
                "1:1": "4096x4096", "3:2": "4992x3328", "2:3": "3328x4992",
                "4:3": "4694x3520", "3:4": "3520x4694",
                "16:9": "5404x3040", "9:16": "3040x5404"
            ]
        ]
        if resolution == "1.5K" || resolution == "3K", let base = tables["2K"]?[aspect] {
            let factor = resolution == "1.5K" ? 0.75 : 1.5
            return base.split(separator: "x").compactMap { Double($0) }.map { String(Int(($0 * factor / 8).rounded()) * 8) }.joined(separator: "x")
        }
        return tables[resolution]?[aspect] ?? "2048x2048"
    }

    private static func alibabaSize(aspect: String, resolution: String) -> String {
        let tables: [String: [String: String]] = [
            "1K": [
                "1:1": "1328*1328", "3:2": "1664*1104", "2:3": "1104*1664",
                "4:3": "1472*1104", "3:4": "1104*1472",
                "16:9": "1664*928", "9:16": "928*1664"
            ],
            "2K": [
                "1:1": "2048*2048", "3:2": "2688*1792", "2:3": "1792*2688",
                "4:3": "2368*1728", "3:4": "1728*2368",
                "16:9": "2688*1536", "9:16": "1536*2688"
            ],
            "4K": [
                "1:1": "4096*4096", "3:2": "4992*3328", "2:3": "3328*4992",
                "4:3": "4694*3520", "3:4": "3520*4694",
                "16:9": "5404*3040", "9:16": "3040*5404"
            ]
        ]
        return tables[resolution]?[aspect] ?? "2048*2048"
    }

    private static func cleaned(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func isAspectRatio(_ value: String) -> Bool {
        value.range(of: #"^\d{1,2}:\d{1,2}$"#, options: .regularExpression) != nil
    }
}

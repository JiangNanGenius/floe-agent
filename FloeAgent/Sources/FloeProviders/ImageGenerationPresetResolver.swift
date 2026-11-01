import Foundation
import FloeCore

/// Where a media parameter contract came from. This is deliberately a catalog
/// fact, not an account probe: a reviewed identifier can still be unavailable
/// to a specific plan, region or key, so the product must not present
/// "contract checked" as "this account can use it now".
public enum ImageParameterVerificationBasis: String, Codable, Sendable, Equatable {
    case officialAgentPlanVisualModels
    case officialMediaModelCatalog
    case unreviewed
}

/// How a requested candidate count is fulfilled. `nativeBatch` means the
/// provider documents multiple images in one request. `sequentialSingleImageRequests`
/// means the image service must issue bounded one-image requests for the
/// remaining candidates instead of silently returning fewer images.
public enum ImageCountStrategy: String, Codable, Sendable, Equatable {
    case nativeBatch
    case sequentialSingleImageRequests
    case unsupported
}

/// Converts the product's aspect-ratio and resolution controls into the
/// provider-native `size` value. Keeping this at the adapter boundary prevents
/// UI labels such as `16:9` from leaking into incompatible wire fields.
public enum ImageGenerationPresetResolver {
    public struct ParameterContract: Codable, Sendable {
        /// True only when the reviewed catalog has a parameter contract for
        /// this identifier. It does not prove account/region entitlement or
        /// that a live generation will succeed.
        public var verifiedModel: Bool
        public var verificationBasis: ImageParameterVerificationBasis
        /// Offline state only. No model listing or name recognition is an
        /// account-usability probe, so this stays `notChecked` until a real
        /// user-authorized generation verifies the account.
        public var accountUsability: String
        public var aspectRatio: [String]
        public var resolution: [String]
        public var quality: [String]
        /// Nil means the provider has no documented default aspect control and
        /// the service must not inject `1:1` on the user's behalf.
        public var defaultAspectRatio: String?
        public var defaultResolution: String?
        public var defaultQuality: String?
        public var minimumCount: Int
        /// Maximum candidate images one user/agent request may ask for. Values
        /// above `maximumCountPerRequest` are fulfilled by bounded sequential
        /// single-image requests.
        public var maximumCount: Int
        /// Maximum images the provider returns in one HTTP request.
        public var maximumCountPerRequest: Int
        public var countStrategy: ImageCountStrategy
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
        // Agent Plan publishes its own image ids (the same Seedream family,
        // without the PAYG revision suffix). The catalog offer is the seed
        // authority; this branch supplies only the documented family limits.
        // It must run before the PAYG-descriptor lookup because a plan
        // connection has custom kind and therefore no media family.
        if ProviderBillingEndpoint.resolve(provider.baseURL) == .volcengineAgentPlan,
           let planFamily = Seedream5ImageFamily.resolve(model.remoteModelID) {
            guard planFamily.isAvailableOnAgentPlan else {
                // Lite has an actual UnsupportedModel response on this
                // channel. An unknown user-configured id is different: it
                // falls through to the generic adapter contract below and
                // must not be disabled just because our catalog lacks it.
                return ParameterContract(
                    verifiedModel: false,
                    verificationBasis: .officialAgentPlanVisualModels,
                    accountUsability: "notChecked",
                    aspectRatio: [],
                    resolution: [],
                    quality: [],
                    defaultAspectRatio: nil,
                    defaultResolution: nil,
                    defaultQuality: nil,
                    minimumCount: 1,
                    maximumCount: 0,
                    maximumCountPerRequest: 0,
                    countStrategy: .unsupported,
                    maximumReferenceImages: 0,
                    nativeSizeOverride: false,
                    unavailableControls: ["seed", "watermark", "promptOptimization"]
                )
            }
            let nativeMaximum = planFamily.maximumOutputImages
            return ParameterContract(
                verifiedModel: true,
                verificationBasis: .officialAgentPlanVisualModels,
                accountUsability: "notChecked",
                aspectRatio: planFamily.supportedAspectRatios,
                resolution: planFamily.supportedResolutions,
                quality: [],
                // The documented plan request controls the size tier; the
                // prompt describes the shape. No ratio control means no
                // injected 1:1.
                defaultAspectRatio: nil,
                defaultResolution: planFamily.defaultResolution,
                defaultQuality: nil,
                minimumCount: 1,
                maximumCount: planFamily.maximumCandidateCount,
                maximumCountPerRequest: nativeMaximum,
                countStrategy: nativeMaximum > 1 ? .nativeBatch : .sequentialSingleImageRequests,
                maximumReferenceImages: operation == .generate
                    ? 0
                    : ImageReferenceCapabilityResolver.maximumReferenceImages(provider: provider, model: model),
                nativeSizeOverride: true,
                unavailableControls: ["seed", "watermark", "promptOptimization"]
            )
        }
        let resolutions = (descriptor?.supportedResolutions ?? []).filter {
            !(provider.kind == .alibabaStudio && operation != .generate && $0 == "4K")
        }
        let nativeMaximum = max(1, adapter?.maximumOutputImages(modelRemoteID: model.remoteModelID) ?? 1)
        return ParameterContract(
            verifiedModel: descriptor != nil,
            verificationBasis: descriptor != nil ? .officialMediaModelCatalog : .unreviewed,
            accountUsability: "notChecked",
            aspectRatio: descriptor?.supportedAspectRatios ?? [],
            resolution: resolutions,
            quality: descriptor?.supportedQualities ?? [],
            defaultAspectRatio: descriptor?.supportedAspectRatios.contains("1:1") == true ? "1:1" : nil,
            defaultResolution: descriptor?.defaultResolution,
            defaultQuality: descriptor?.defaultQuality,
            minimumCount: 1,
            maximumCount: 4,
            maximumCountPerRequest: nativeMaximum,
            countStrategy: nativeMaximum > 1 ? .nativeBatch : .sequentialSingleImageRequests,
            maximumReferenceImages: operation == .generate
                ? 0
                : ImageReferenceCapabilityResolver.maximumReferenceImages(provider: provider, model: model),
            nativeSizeOverride: provider.kind != .googleGemini,
            unavailableControls: ["seed", "watermark", "promptOptimization"]
        )
    }

    /// Route eligibility for one selected model. An unsupported plan model is
    /// excluded from `image.models`, public selection and autonomous fallback
    /// instead of being sent once and then silently remapped.
    public static func isEligible(
        provider: ProviderProfile, model: ModelProfile, operation: RemoteImageOperation
    ) -> Bool {
        parameterContract(provider: provider, model: model, operation: operation).countStrategy != .unsupported
    }

    public static func applyingDefaults(
        _ selection: ImageGenerationSelection, provider: ProviderProfile, model: ModelProfile,
        operation: RemoteImageOperation
    ) -> ImageGenerationSelection {
        let contract = parameterContract(provider: provider, model: model, operation: operation)
        let rawOverride = cleaned(selection.nativeSizeOverride)
        let overrideAspect = rawOverride.flatMap { isAspectRatio($0) ? $0 : nil }
        let overrideResolution = rawOverride.flatMap { isResolutionTier($0) ? $0.uppercased() : nil }
        let retainedOverride = rawOverride.flatMap {
            ($0 == overrideAspect || $0 == overrideResolution) ? nil : $0
        }
        return ImageGenerationSelection(
            aspectRatio: selection.aspectRatio ?? overrideAspect ?? contract.defaultAspectRatio,
            resolution: selection.resolution ?? overrideResolution ?? contract.defaultResolution,
            quality: selection.quality ?? contract.defaultQuality,
            nativeSizeOverride: retainedOverride)
    }

    public static func validateSelection(
        _ selection: ImageGenerationSelection, provider: ProviderProfile, model: ModelProfile,
        operation: RemoteImageOperation, count: Int, referenceCount: Int
    ) throws {
        let contract = parameterContract(provider: provider, model: model, operation: operation)
        guard contract.countStrategy != .unsupported else {
            throw RemoteImageError.requestFailed(
                "This image model is not available on the selected billing channel; choose a reviewed candidate from image.models."
            )
        }
        guard count >= contract.minimumCount, count <= contract.maximumCount,
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
        if let size = cleaned(selection.nativeSizeOverride) {
            if isAspectRatio(size) {
                guard contract.aspectRatio.contains(size) else {
                    throw RemoteImageError.requestFailed("Unsupported or unverified aspectRatio=\(size) for \(model.remoteModelID); inspect image.models.")
                }
            } else if isResolutionTier(size) {
                guard contract.resolution.contains(size.uppercased()) else {
                    throw RemoteImageError.requestFailed("Unsupported or unverified resolution=\(size) for \(model.remoteModelID); inspect image.models.")
                }
            } else {
                let parts = size.replacingOccurrences(of: "*", with: "x").split(separator: "x")
                guard contract.nativeSizeOverride, parts.count == 2,
                      let width = Int(parts[0]), let height = Int(parts[1]),
                      width > 0, height > 0, width <= 8192, height <= 8192 else {
                    throw RemoteImageError.requestFailed("Invalid or unsupported native image size")
                }
                if let family = Seedream5ImageFamily.resolve(model.remoteModelID),
                   !family.isValidNativeSize(width: width, height: height) {
                    throw RemoteImageError.requestFailed(
                        "Invalid or unsupported native image size for \(model.remoteModelID); inspect image.models."
                    )
                }
            }
        }
        // Agent Plan is a Volcengine Ark image contract behind a subscription
        // base URL; its saved provider kind stays `.custom` so it cannot
        // inherit the PAYG model list. Validate the actual wire family.
        let imageKind: ProviderKind =
            ProviderBillingEndpoint.resolve(provider.baseURL) == .volcengineAgentPlan
                ? .volcengineArk : provider.kind
        _ = try nativeSize(provider: imageKind, modelRemoteID: model.remoteModelID, operation: operation, selection: selection)
        _ = try normalizedQuality(selection.quality, provider: imageKind, modelRemoteID: model.remoteModelID)
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
        let rawOverride = cleaned(selection.nativeSizeOverride)
        if let override = rawOverride, !isAspectRatio(override), !isResolutionTier(override) {
            return provider == .alibabaStudio
                ? override.replacingOccurrences(of: "x", with: "*")
                : override.replacingOccurrences(of: "*", with: "x")
        }
        let aspect = cleaned(selection.aspectRatio)
            ?? rawOverride.flatMap { isAspectRatio($0) ? $0 : nil }
        let resolution = cleaned(selection.resolution)?.uppercased()
            ?? rawOverride.flatMap { isResolutionTier($0) ? $0.uppercased() : nil }
            ?? defaultResolution(provider: provider, modelRemoteID: modelRemoteID)
        if let aspect, !supportedAspects.contains(aspect) {
            throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_current_image_model_does_not", aspect))
        }
        guard (["1K", "2K", "4K"].contains(resolution) || (provider == .volcengineArk && ["1.5K", "3K"].contains(resolution))) else {
            throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_current_image_model_does_not_2", resolution))
        }

        switch provider {
        case .openAI:
            return openAISize(aspect: aspect ?? "1:1", resolution: resolution)
        case .volcengineArk:
            // Normalize both official spellings (`5.0`/`5-0`) before applying
            // the family limits. Pro/flash (Agent Plan or PAYG) document only
            // single-image generation and the 1K/1.5K/2K tiers. When no aspect
            // ratio is requested, send the documented size tier and let the
            // prompt decide the shape instead of inventing a 1:1 crop.
            let planFamily = Seedream5ImageFamily.resolve(modelRemoteID)
            if let planFamily {
                guard planFamily.supportedResolutions.contains(resolution) else {
                    throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_selected_seedream_model_does_not", resolution))
                }
                guard let aspect else { return resolution }
                guard let size = planFamily.nativeSize(aspect: aspect, resolution: resolution) else {
                    throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_current_image_model_does_not", aspect))
                }
                return size
            }
            let model = (modelRemoteID ?? "")
                .lowercased()
                .replacingOccurrences(of: ".", with: "-")
            if model.contains("seedream-5-0") {
                let allowed = ["2K", "3K", "4K"]
                guard allowed.contains(resolution) else { throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_selected_seedream_model_does_not", resolution)) }
            }
            guard let aspect else { return resolution }
            return volcengineSize(aspect: aspect, resolution: resolution)
        case .alibabaStudio:
            if operation != .generate, resolution == "4K" {
                throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.alibaba_cloud_image_editing_supports_up"))
            }
            let model = modelRemoteID?.lowercased() ?? ""
            if resolution == "4K", !model.contains("wan2.7-image-pro") {
                throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.the_selected_alibaba_cloud_image_model"))
            }
            return alibabaSize(aspect: aspect ?? "1:1", resolution: resolution)
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
            throw RemoteImageError.requestFailed(FloeL10n.l("providers.image_generation_preset_resolver.invalid_openai_image_quality_parameter", value))
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

    private static func isResolutionTier(_ value: String) -> Bool {
        ["1K", "1.5K", "2K", "3K", "4K"].contains(value.uppercased())
    }
}

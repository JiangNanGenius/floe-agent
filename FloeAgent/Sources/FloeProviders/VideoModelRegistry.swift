import Foundation
import FloeCore

/// The user-visible capability contract of one configured video route.
/// Values come from the product-owned official manifest when the remote ID is
/// known, otherwise from the model family's documented limits. Tools must read
/// this instead of guessing enum values.
public struct VideoParameterContract: Sendable, Codable, Hashable {
    public var aspectRatios: [String]
    public var resolutions: [String]
    public var minimumDurationSeconds: Int?
    public var maximumDurationSeconds: Int?
    public var supportedDurations: [Int]
    public var supportsAudio: Bool
    public var supportsWatermark: Bool
    public var supportsSeed: Bool
    public var supportsPromptOptimization: Bool
    public var maximumReferenceAssets: Int
    /// `first_frame`, `first_and_last_frame` or `reference_image`; nil when the
    /// family accepts no image reference.
    public var referenceMode: String?

    public init(
        aspectRatios: [String] = [],
        resolutions: [String] = [],
        minimumDurationSeconds: Int? = nil,
        maximumDurationSeconds: Int? = nil,
        supportedDurations: [Int] = [],
        supportsAudio: Bool = false,
        supportsWatermark: Bool = false,
        supportsSeed: Bool = false,
        supportsPromptOptimization: Bool = false,
        maximumReferenceAssets: Int = 0,
        referenceMode: String? = nil
    ) {
        self.aspectRatios = aspectRatios
        self.resolutions = resolutions
        self.minimumDurationSeconds = minimumDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.supportedDurations = supportedDurations
        self.supportsAudio = supportsAudio
        self.supportsWatermark = supportsWatermark
        self.supportsSeed = supportsSeed
        self.supportsPromptOptimization = supportsPromptOptimization
        self.maximumReferenceAssets = maximumReferenceAssets
        self.referenceMode = referenceMode
    }
}

/// A configured, enabled and actually usable cloud video model. Only providers
/// with a native adapter and a nonempty remote model ID are exposed.
public struct VideoModelRoute: Sendable, Codable, Hashable, Identifiable {
    public var modelID: UUID
    public var providerID: UUID
    public var remoteModelID: String
    public var displayName: String
    public var providerName: String
    public var providerKind: ProviderKind
    public var preferred: Bool
    public var contract: VideoParameterContract

    public var id: UUID { modelID }

    public init(
        modelID: UUID,
        providerID: UUID,
        remoteModelID: String,
        displayName: String,
        providerName: String,
        providerKind: ProviderKind,
        preferred: Bool,
        contract: VideoParameterContract
    ) {
        self.modelID = modelID
        self.providerID = providerID
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.providerName = providerName
        self.providerKind = providerKind
        self.preferred = preferred
        self.contract = contract
    }
}

/// Builds the `video.models` catalog from the user's configuration. Pure and
/// side-effect free so the filter can be tested without networking.
public enum VideoModelRegistry {
    /// A route is usable only when the provider is enabled, the model is
    /// enabled with the video-generation surface, a native adapter exists and
    /// the remote ID is present. Adapters never reach a custom/OpenAI endpoint
    /// by pretending it speaks a native video protocol.
    public static func isUsable(model: ModelProfile, provider: ProviderProfile) -> Bool {
        guard model.isEnabled, provider.isEnabled else { return false }
        guard model.supportsVideoGenerationSurface else { return false }
        let remoteID = model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteID.isEmpty else { return false }
        return VideoProviderAdapterFactory().adapter(for: provider) != nil
    }

    public static func routes(
        models: [ModelProfile],
        providers: [ProviderProfile],
        preferredModelID: UUID?
    ) -> [VideoModelRoute] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        return models.compactMap { model -> VideoModelRoute? in
            guard let provider = providersByID[model.providerID],
                  isUsable(model: model, provider: provider) else { return nil }
            return VideoModelRoute(
                modelID: model.id,
                providerID: provider.id,
                remoteModelID: model.remoteModelID,
                displayName: model.displayName,
                providerName: provider.displayName ?? provider.kind.rawValue,
                providerKind: provider.kind,
                preferred: model.id == preferredModelID,
                contract: contract(model: model, provider: provider)
            )
        }
        .sorted {
            if $0.preferred != $1.preferred { return $0.preferred }
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.modelID.uuidString < $1.modelID.uuidString
        }
    }

    /// Contract for one route. The official manifest wins when its remote ID
    /// matches; the documented family limits are the fallback.
    public static func contract(model: ModelProfile, provider: ProviderProfile) -> VideoParameterContract {
        if let descriptor = OfficialMediaModelCatalog.models.first(where: {
            $0.kind == .video && $0.remoteModelID.caseInsensitiveCompare(model.remoteModelID) == .orderedSame
        }) {
            return VideoParameterContract(
                aspectRatios: descriptor.supportedAspectRatios,
                resolutions: descriptor.supportedResolutions.isEmpty
                    ? descriptor.supportedQualities : descriptor.supportedResolutions,
                minimumDurationSeconds: descriptor.supportedDurations.min(),
                maximumDurationSeconds: descriptor.supportedDurations.max(),
                supportedDurations: descriptor.supportedDurations,
                supportsAudio: descriptor.supportsAudio,
                supportsWatermark: descriptor.supportsWatermark,
                supportsSeed: descriptor.supportsSeed,
                supportsPromptOptimization: descriptor.supportsPromptOptimization,
                maximumReferenceAssets: descriptor.maximumReferenceAssets,
                referenceMode: descriptor.maximumReferenceAssets > 0
                    ? referenceMode(modelRemoteID: model.remoteModelID, providerKind: provider.kind)
                    : nil
            )
        }
        return familyContract(modelRemoteID: model.remoteModelID, providerKind: provider.kind)
    }

    /// Documented reference-image mode for one family. Veo takes asset
    /// reference images (`referenceImages[].referenceType = asset`); Omni, Ark
    /// Seedance and DashScope Wan take a first-frame image.
    public static func referenceMode(
        modelRemoteID: String,
        providerKind: ProviderKind
    ) -> String? {
        if providerKind == .googleGemini,
           !modelRemoteID.lowercased().hasPrefix("gemini-omni-") {
            return "reference_image"
        }
        return "first_frame"
    }

    /// Documented fallback limits for a remote model ID whose official entry is
    /// missing or was edited by the user.
    public static func familyContract(
        modelRemoteID: String,
        providerKind: ProviderKind
    ) -> VideoParameterContract {
        let normalized = modelRemoteID.lowercased()
        switch providerKind {
        case .googleGemini:
            if normalized.hasPrefix("gemini-omni-") {
                return VideoParameterContract(
                    aspectRatios: ["16:9", "9:16"],
                    resolutions: ["720p"],
                    minimumDurationSeconds: 3, maximumDurationSeconds: 10,
                    supportedDurations: Array(3...10),
                    supportsAudio: true, maximumReferenceAssets: 1, referenceMode: "first_frame"
                )
            }
            return VideoParameterContract(
                aspectRatios: ["16:9", "9:16"],
                resolutions: ["720p", "1080p", "4k"],
                minimumDurationSeconds: 4, maximumDurationSeconds: 8,
                supportedDurations: [4, 6, 8],
                supportsAudio: true, maximumReferenceAssets: 3, referenceMode: "reference_image"
            )
        case .volcengineArk:
            if normalized.contains("seedance-2-5") {
                return VideoParameterContract(
                    aspectRatios: ["16:9", "4:3", "1:1", "3:4", "9:16", "21:9", "adaptive"],
                    resolutions: ["480p", "720p", "1080p"],
                    minimumDurationSeconds: 4, maximumDurationSeconds: 30,
                    supportedDurations: Array(4...30),
                    supportsAudio: true, supportsWatermark: true,
                    maximumReferenceAssets: 1, referenceMode: "first_frame"
                )
            }
            return VideoParameterContract(
                aspectRatios: ["16:9", "4:3", "1:1", "3:4", "9:16", "21:9", "adaptive"],
                resolutions: ["480p", "720p", "1080p"],
                minimumDurationSeconds: 4, maximumDurationSeconds: 15,
                supportedDurations: Array(4...15),
                supportsAudio: true, supportsWatermark: true, supportsSeed: true,
                supportsPromptOptimization: true,
                maximumReferenceAssets: 1, referenceMode: "first_frame"
            )
        case .alibabaStudio:
            return VideoParameterContract(
                aspectRatios: ["16:9", "4:3", "1:1", "3:4", "9:16", "adaptive"],
                resolutions: ["480P", "720P", "1080P"],
                minimumDurationSeconds: 2, maximumDurationSeconds: 30,
                supportedDurations: Array(2...30),
                supportsAudio: true, supportsWatermark: true, supportsSeed: true,
                supportsPromptOptimization: true,
                maximumReferenceAssets: 1, referenceMode: "first_frame"
            )
        case .openAI, .anthropic, .local, .custom:
            return VideoParameterContract()
        }
    }
}

/// Validates and normalizes provider-neutral video options against the
/// route's advertised contract before any network call. A rejected option
/// names the accepted values instead of silently substituting a default, so a
/// paid submission is never spent on a request the adapter would reject.
public enum VideoRequestValidator {
    public static func validate(
        _ options: VideoGenerationOptions,
        route: VideoModelRoute
    ) throws -> VideoGenerationOptions {
        try validate(options, contract: route.contract, modelRemoteID: route.remoteModelID)
    }

    public static func validate(
        _ options: VideoGenerationOptions,
        contract: VideoParameterContract,
        modelRemoteID: String
    ) throws -> VideoGenerationOptions {
        var normalized = options
        if let resolution = options.resolution {
            guard let match = contract.resolutions.first(where: {
                $0.caseInsensitiveCompare(resolution) == .orderedSame
            }) else {
                throw FloeError.validationFailed(
                    "resolution \(resolution) is not supported by \(modelRemoteID). Allowed: \(contract.resolutions.isEmpty ? "read video.models" : contract.resolutions.joined(separator: ", "))"
                )
            }
            normalized.resolution = match
        }
        if let aspect = options.aspectRatio {
            guard let match = contract.aspectRatios.first(where: {
                $0.caseInsensitiveCompare(aspect) == .orderedSame
            }) else {
                throw FloeError.validationFailed(
                    "aspectRatio \(aspect) is not supported by \(modelRemoteID). Allowed: \(contract.aspectRatios.isEmpty ? "read video.models" : contract.aspectRatios.joined(separator: ", "))"
                )
            }
            normalized.aspectRatio = match
        }
        if let duration = options.durationSeconds {
            if !contract.supportedDurations.isEmpty {
                guard contract.supportedDurations.contains(duration) else {
                    let allowed = contract.supportedDurations.map(String.init).joined(separator: ", ")
                    throw FloeError.validationFailed(
                        "durationSeconds \(duration) is not supported by \(modelRemoteID). Allowed: \(allowed)"
                    )
                }
            } else if let minimum = contract.minimumDurationSeconds,
                      let maximum = contract.maximumDurationSeconds {
                guard (minimum...maximum).contains(duration) else {
                    throw FloeError.validationFailed(
                        "durationSeconds \(duration) is outside \(minimum)–\(maximum) for \(modelRemoteID)"
                    )
                }
            }
        }
        if options.seed != nil, !contract.supportsSeed {
            throw FloeError.validationFailed("\(modelRemoteID) does not support a fixed seed")
        }
        if options.includeAudio != nil, !contract.supportsAudio {
            throw FloeError.validationFailed("\(modelRemoteID) does not support audio selection")
        }
        if options.watermark != nil, !contract.supportsWatermark {
            throw FloeError.validationFailed("\(modelRemoteID) does not support a watermark selection")
        }
        if options.promptOptimization != nil, !contract.supportsPromptOptimization {
            throw FloeError.validationFailed("\(modelRemoteID) does not support prompt optimization selection")
        }
        return normalized
    }
}


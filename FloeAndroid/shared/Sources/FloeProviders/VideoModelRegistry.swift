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

    /// The public selection name for agent-facing tools. It is the provider's
    /// remote model identifier, never the per-install internal UUID.
    public var publicModelID: String { remoteModelID }

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

    /// Resolves one usable video route from an optional internal UUID and an
    /// optional public selection (display name or remote model ID). The agent
    /// chooses among the public candidates printed by `video.models`, so the
    /// user is never required to know or provide an internal UUID.
    ///
    /// Rules, in order:
    /// * an explicit `modelID` must exist in the usable catalog;
    /// * an explicit `selection` matches by UUID spelling, remote model ID or
    ///   display name (case- and separator-insensitive), then by unique prefix
    ///   or unique containment;
    /// * an ambiguous or unknown selection fails with the public candidate
    ///   list instead of silently choosing a different, possibly paid route;
    /// * with neither identifier the preferred route is used, and the first
    ///   usable route remains the final fallback.
    public static func resolve(
        modelID: UUID?,
        selection: String?,
        routes: [VideoModelRoute]
    ) throws -> VideoModelRoute {
        guard !routes.isEmpty else {
            throw FloeError.invalidConfiguration(
                "No configured, enabled and adapter-backed video model is available. Configure a Google, Volcengine Ark or DashScope provider with a video model and API key, then inspect video.models."
            )
        }
        if let modelID {
            guard let match = routes.first(where: { $0.modelID == modelID }) else {
                throw FloeError.validationFailed(
                    "The requested video model is no longer enabled or usable. Available public candidates: \(publicCandidates(routes))."
                )
            }
            return match
        }
        guard let selection else { return routes[0] }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return routes[0] }

        // A user or model may still pass the internal UUID spelling.
        if let asUUID = UUID(uuidString: trimmed),
           let match = routes.first(where: { $0.modelID == asUUID }) {
            return match
        }
        let needle = normalizedIdentifier(trimmed)
        guard !needle.isEmpty else {
            throw FloeError.validationFailed(
                "Video model selection is empty. Available public candidates: \(publicCandidates(routes))."
            )
        }
        let tiers: [() -> [VideoModelRoute]] = [
            { routes.filter { route in
                route.remoteModelID.caseInsensitiveCompare(trimmed) == .orderedSame
                    || route.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
            } },
            { routes.filter { route in
                normalizedIdentifier(route.remoteModelID) == needle
                    || normalizedIdentifier(route.displayName) == needle
            } },
            { routes.filter { route in
                normalizedIdentifier(route.remoteModelID).hasPrefix(needle)
                    || normalizedIdentifier(route.displayName).hasPrefix(needle)
            } },
            { routes.filter { route in
                normalizedIdentifier(route.remoteModelID).contains(needle)
                    || normalizedIdentifier(route.displayName).contains(needle)
            } }
        ]
        for tier in tiers {
            let matches = tier()
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw FloeError.validationFailed(
                    "Video model selection \"\(trimmed)\" matches several candidates. Choose one public candidate: \(publicCandidates(matches))."
                )
            }
        }
        throw FloeError.validationFailed(
            "Unknown video model \"\(trimmed)\". Available public candidates: \(publicCandidates(routes))."
        )
    }

    /// Public, secret-free candidate list. Internal UUIDs are intentionally
    /// omitted so agents and users only need the public name.
    public static func publicCandidates(_ routes: [VideoModelRoute]) -> String {
        routes.map { route in
            route.displayName.caseInsensitiveCompare(route.remoteModelID) == .orderedSame
                ? route.remoteModelID
                : "\(route.displayName) (\(route.remoteModelID))"
        }.joined(separator: ", ")
    }

    /// Case- and separator-insensitive spelling of one identifier. Provider
    /// catalogues mix `doubao-seedance-2-5-260628`, `doubao seedance 2.5` and
    /// display variants, so dots, dashes, spaces and case are ignored.
    static func normalizedIdentifier(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
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


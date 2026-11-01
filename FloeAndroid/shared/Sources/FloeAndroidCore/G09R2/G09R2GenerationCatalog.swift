// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — configured-generation catalog.
//
// The workbench lists ONLY the user's actual enabled provider/model
// configuration. Availability is the real adapter state; parameter contracts
// come from the existing image preset resolver / video route contract. There
// is no hard-coded model list, no invented price and no credential access in
// this file.
import Foundation
import FloeCore
import FloeProviders

public enum G09R2GenerationCatalog {
    /// Honest wording when the provider reports no price. Kept provider-neutral
    /// so the UI never presents an estimated cost as a real charge.
    public static let accountAuthoritativeCostNote =
        "Actual charges appear on your provider account; Floe does not estimate prices."

    public typealias ImageAdapterLookup = (ProviderProfile) -> (any ImageProviderAdapter)?
    public typealias VideoAdapterLookup = (ProviderProfile) -> (any VideoProviderAdapter)?

    public static func defaultImageAdapter(_ provider: ProviderProfile)
        -> (any ImageProviderAdapter)? {
        ImageProviderAdapterFactory().adapter(for: provider)
    }

    public static func defaultVideoAdapter(_ provider: ProviderProfile)
        -> (any VideoProviderAdapter)? {
        VideoProviderAdapterFactory().adapter(for: provider)
    }

    /// Pure and side-effect free. `preferences` only changes ordering (the
    /// configured default first); it never adds a route.
    public static func build(
        models: [ModelProfile],
        providers: [ProviderProfile],
        preferences: ModelSelectionPreferences? = nil,
        imageAdapter: ImageAdapterLookup = defaultImageAdapter,
        videoAdapter: VideoAdapterLookup = defaultVideoAdapter
    ) -> G09R2ModelCatalogDTO {
        let providersByID = Dictionary(
            providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var imageRoutes: [G09R2ModelRouteDTO] = []
        var videoRoutes: [G09R2ModelRouteDTO] = []
        for model in models {
            guard model.isEnabled,
                  let provider = providersByID[model.providerID],
                  provider.isEnabled else { continue }
            let remote = model.remoteModelID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if model.supportsImageGenerationSurface {
                imageRoutes.append(imageRoute(
                    model: model, provider: provider, remote: remote,
                    adapter: imageAdapter(provider)))
            }
            if model.supportsVideoGenerationSurface {
                videoRoutes.append(videoRoute(
                    model: model, provider: provider, remote: remote,
                    adapter: videoAdapter(provider)))
            }
        }
        let preferredImage = preferences?.imageGenerationModelID?.uuidString.lowercased()
        let preferredVideo = preferences?.defaultVideoModelID?.uuidString.lowercased()
        return G09R2ModelCatalogDTO(
            image: sorted(imageRoutes, preferred: preferredImage),
            video: sorted(videoRoutes, preferred: preferredVideo))
    }

    private static func sorted(
        _ routes: [G09R2ModelRouteDTO], preferred: String?
    ) -> [G09R2ModelRouteDTO] {
        routes.sorted { left, right in
            let leftPreferred = left.routeID == preferred
            let rightPreferred = right.routeID == preferred
            if leftPreferred != rightPreferred { return leftPreferred }
            if left.available != right.available { return left.available }
            let providerOrder = left.providerName.localizedCaseInsensitiveCompare(
                right.providerName)
            if providerOrder != .orderedSame {
                return providerOrder == .orderedAscending
            }
            return left.routeID < right.routeID
        }
    }

    // MARK: - Image

    private static func imageRoute(
        model: ModelProfile, provider: ProviderProfile, remote: String,
        adapter: (any ImageProviderAdapter)?
    ) -> G09R2ModelRouteDTO {
        let contract = ImageGenerationPresetResolver.parameterContract(
            provider: provider, model: model, operation: .generate)
        let referenceMaximum = ImageReferenceCapabilityResolver.maximumReferenceImages(
            provider: provider, model: model)
        var unavailable: String?
        if remote.isEmpty {
            unavailable = "missingRemoteModel"
        } else if adapter == nil {
            unavailable = "adapterUnavailable"
        } else if let adapter,
                  !adapter.supports(.generate, for: provider),
                  !adapter.supports(.edit, for: provider) {
            unavailable = "operationUnsupported"
        }
        let imageKind: ProviderKind =
            ProviderBillingEndpoint.resolve(provider.baseURL) == .volcengineAgentPlan
                ? .volcengineArk : provider.kind
        var sizes: [String] = []
        if contract.nativeSizeOverride {
            outer: for aspect in contract.aspectRatio.prefix(8) {
                for resolution in contract.resolution.prefix(4) {
                    if let value = try? ImageGenerationPresetResolver.nativeSize(
                        provider: imageKind,
                        modelRemoteID: model.remoteModelID,
                        operation: .generate,
                        selection: ImageGenerationSelection(
                            aspectRatio: aspect, resolution: resolution)),
                       !value.isEmpty, !sizes.contains(value) {
                        sizes.append(value)
                        if sizes.count >= 24 { break outer }
                    }
                }
            }
        }
        let parameters = G09R2GenerationParameterContractDTO(
            sizes: sizes.isEmpty ? nil : sizes,
            aspectRatios: contract.aspectRatio,
            resolutions: contract.resolution,
            durationSeconds: nil,
            maxCount: max(1, contract.maximumCount),
            maxReferenceImages: referenceMaximum,
            supportsImageToVideo: false,
            supportsFirstFrame: false,
            codecs: [])
        let policy = G09R2ReferenceImagePolicyDTO(
            maxImages: referenceMaximum,
            maxBytesPerImage: Int64(G09R2CreativeLimits.imageSourceBytes),
            acceptedMimeTypes: ["image/png", "image/jpeg"],
            minWidth: nil, maxWidth: nil,
            minHeight: nil, maxHeight: nil)
        return G09R2ModelRouteDTO(
            routeID: model.id.uuidString.lowercased(),
            remoteModelID: model.remoteModelID,
            providerID: provider.id.uuidString.lowercased(),
            providerName: provider.displayName ?? provider.kind.rawValue,
            kind: .image,
            enabled: model.isEnabled && provider.isEnabled,
            available: unavailable == nil,
            unavailableReason: unavailable,
            parameters: parameters,
            referenceImagePolicy: policy,
            costNote: accountAuthoritativeCostNote)
    }

    // MARK: - Video

    private static func videoRoute(
        model: ModelProfile, provider: ProviderProfile, remote: String,
        adapter: (any VideoProviderAdapter)?
    ) -> G09R2ModelRouteDTO {
        let contract = VideoModelRegistry.contract(model: model, provider: provider)
        var unavailable: String?
        if remote.isEmpty {
            unavailable = "missingRemoteModel"
        } else if adapter == nil {
            unavailable = "adapterUnavailable"
        }
        let referenceMaximum = max(0, min(
            contract.maximumReferenceAssets,
            VideoReferenceImagePolicy.maximumAssets))
        let durations: [Double]? = {
            if !contract.supportedDurations.isEmpty {
                return contract.supportedDurations.map(Double.init)
            }
            if let minimum = contract.minimumDurationSeconds,
               let maximum = contract.maximumDurationSeconds {
                return [Double(minimum), Double(maximum)]
            }
            return nil
        }()
        let parameters = G09R2GenerationParameterContractDTO(
            sizes: nil,
            aspectRatios: contract.aspectRatios,
            resolutions: contract.resolutions,
            durationSeconds: durations,
            maxCount: 1,
            maxReferenceImages: referenceMaximum,
            supportsImageToVideo: referenceMaximum > 0,
            supportsFirstFrame: referenceMaximum > 0
                && contract.referenceMode == "first_frame",
            codecs: [])
        let policy = G09R2ReferenceImagePolicyDTO(
            maxImages: referenceMaximum,
            maxBytesPerImage: Int64(VideoReferenceImagePolicy.maximumBytes),
            acceptedMimeTypes: VideoReferenceImagePolicy.acceptedMIMETypes,
            minWidth: nil, maxWidth: nil,
            minHeight: nil, maxHeight: nil)
        return G09R2ModelRouteDTO(
            routeID: model.id.uuidString.lowercased(),
            remoteModelID: model.remoteModelID,
            providerID: provider.id.uuidString.lowercased(),
            providerName: provider.displayName ?? provider.kind.rawValue,
            kind: .video,
            enabled: model.isEnabled && provider.isEnabled,
            available: unavailable == nil,
            unavailableReason: unavailable,
            parameters: parameters,
            referenceImagePolicy: policy,
            costNote: accountAuthoritativeCostNote)
    }
}

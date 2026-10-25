// FloeProviders — Metadata-driven model capability defaults and the
// user-reviewed capability migration for already-saved models.
//
// Two contracts live here, both pure and offline:
//
//   1. `ProviderCatalogCapabilityResolver` turns verified upstream per-model
//      metadata into capability defaults for a NEWLY created model row. It
//      maps only what the app can actually carry on the wire today: an
//      inference model that accepts image input gets `.vision`. Audio and
//      video modalities stay data because no wire implementation exists for
//      them, and image/video OUTPUT marks a generation endpoint whose image
//      input is a reference asset, not visual understanding.
//
//   2. `ProviderCatalogCapabilityMigration` computes the exact batch diff
//      between saved models and the catalog metadata. It never applies
//      anything by itself: the user reviews the per-model before/after list
//      once and confirms. A bit the user explicitly decided (recorded in
//      `ModelProfile.explicitCapabilities`) is never proposed and never
//      overwritten, so an explicit off survives refresh and sync.

import Foundation
import FloeCore

/// Pure mapping from catalog metadata to model capability defaults.
public enum ProviderCatalogCapabilityResolver {

    /// Metadata fallback for a new row whose editor was opened from a
    /// built-in/manual preset rather than a catalog selection. Only the
    /// actual endpoint and compatible wire/auth family establish identity;
    /// display names, search aliases and model-name patterns do not.
    /// This is capability evidence only, never a credential/routing decision.
    public static func metadata(
        forRemoteID remoteID: String,
        kind: ProviderKind,
        baseURL: URL,
        modelProtocol: ModelProtocol,
        catalog: ProviderCatalogIndex
    ) -> ProviderCatalogModelMetadata? {
        guard kind != .local, let endpoint = metadataEndpoint(baseURL) else { return nil }
        let auth = ProviderConfigurationValidation.ProviderConnectionIdentity.authStyle(for: kind)
        let matches = catalog.all.filter { entry in
            guard entry.availability == .available,
                  !ProviderCatalogIndex.hiddenPresetIDs.contains(entry.presetID),
                  entry.authStyle == auth,
                  entry.kind == kind || kind == .custom,
                  let url = entry.baseURL, metadataEndpoint(url) == endpoint else { return false }
            // The two OpenAI conversation protocols carry the same image
            // capability. Anthropic stays a distinct wire family.
            return entry.defaultProtocol == modelProtocol
                || (entry.defaultProtocol != .anthropicMessages && modelProtocol != .anthropicMessages)
        }
        // Ambiguous directory identities are unknown, not first-match wins.
        guard matches.count == 1 else { return nil }
        return matches[0].modelMetadata?[remoteID]
    }

    private struct MetadataEndpoint: Equatable {
        let host: String
        let port: Int
        let path: String
    }

    private static func metadataEndpoint(_ url: URL) -> MetadataEndpoint? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return MetadataEndpoint(host: host, port: components.port ?? 443, path: path)
    }

    /// Modality token for image input.
    public static let imageModality = "image"
    /// Modality token for text output.
    public static let textModality = "text"

    /// Upstream flags that describe a generation endpoint: its image input is
    /// a reference asset for the produced media, not visual understanding.
    public static func isGenerationModel(_ metadata: ProviderCatalogModelMetadata?) -> Bool {
        guard let output = metadata?.output else { return false }
        return output.contains("image") || output.contains("video")
    }

    /// True only for an inference model that verifiably accepts image input:
    /// output contains text and no image/video output.
    public static func supportsImageInput(_ metadata: ProviderCatalogModelMetadata?) -> Bool {
        guard let metadata,
              let input = metadata.input, input.contains(imageModality),
              let output = metadata.output, output.contains(textModality) else {
            return false
        }
        return !output.contains("image") && !output.contains("video")
    }

    /// Capability defaults for a newly created model row.
    ///
    /// `base` stays the caller's protocol default; this only adjusts it with
    /// verified facts:
    ///   * an upstream `toolCall == false` removes the assumed `.tools` bit
    ///     (absence of the flag keeps the legacy default: unknown, not false);
    ///   * a verified image-input inference model gains `.vision`.
    /// Audio/video/pdf modalities and `attachment`/`reasoning` flags are
    /// deliberately not mapped to capability bits.
    public static func capabilities(
        for metadata: ProviderCatalogModelMetadata?,
        base: ModelCapabilities
    ) -> ModelCapabilities {
        var capabilities = base
        if metadata?.toolCall == false {
            capabilities.remove(.tools)
        }
        if supportsImageInput(metadata) {
            capabilities.insert(.vision)
        }
        return capabilities
    }
}

/// One reviewed model capability update proposed by the official catalog.
public struct ProviderCatalogCapabilityProposal: Sendable, Equatable, Identifiable {
    public var providerID: UUID
    public var providerName: String
    public var presetID: String
    public var modelID: UUID
    public var remoteModelID: String
    public var displayName: String
    /// The saved row's actual capabilities (the review's "before").
    public var currentCapabilities: ModelCapabilities
    /// Capability bits the catalog supports and the saved row lacks. Only
    /// additions are ever proposed; a reviewed migration never downgrades a
    /// locally configured model.
    public var addedCapabilities: ModelCapabilities

    public var id: String { "\(providerID.uuidString)/\(modelID.uuidString)" }

    public init(
        providerID: UUID,
        providerName: String,
        presetID: String,
        modelID: UUID,
        remoteModelID: String,
        displayName: String,
        currentCapabilities: ModelCapabilities,
        addedCapabilities: ModelCapabilities
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.presetID = presetID
        self.modelID = modelID
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.currentCapabilities = currentCapabilities
        self.addedCapabilities = addedCapabilities
    }
}

/// Batch diff between saved models and verified catalog metadata.
public enum ProviderCatalogCapabilityMigration {

    /// Everything the user would confirm, in stable provider order. Pure:
    /// callers pass the current store projection and the active catalog.
    ///
    /// Proposal rules:
    ///   * only available catalog entries with per-model metadata;
    ///   * only inference models (`supportsGeneralAuxiliaryLLM`) — media
    ///     rows keep their role contract untouched;
    ///   * only additions of bits the user has not explicitly decided;
    ///   * empty diffs are not proposals, so nothing is shown for models that
    ///     already carry the truthful defaults.
    public static func proposals(
        providers: [ProviderProfile],
        modelsByProvider: [UUID: [ModelProfile]],
        catalog: ProviderCatalogIndex?
    ) -> [ProviderCatalogCapabilityProposal] {
        guard let catalog else { return [] }
        var proposals: [ProviderCatalogCapabilityProposal] = []
        for provider in providers {
            guard let presetID = provider.presetID,
                  let entry = catalog.entry(presetID: presetID),
                  entry.availability == .available,
                  let metadataByModel = entry.modelMetadata, !metadataByModel.isEmpty else {
                continue
            }
            // User-facing label: the saved name when set, otherwise the
            // catalog's own display name (never the raw preset id).
            let providerName = provider.displayName ?? entry.name
            for model in modelsByProvider[provider.id] ?? [] {
                guard model.supportsGeneralAuxiliaryLLM,
                      let metadata = metadataByModel[model.remoteModelID] else { continue }
                let resolved = ProviderCatalogCapabilityResolver.capabilities(
                    for: metadata,
                    base: ModelCapabilities.defaultTextModel(for: provider.wireProtocol)
                )
                // Only the image-input fact is new information to an existing
                // row, so only `.vision` may be proposed. Text/approval are
                // forced role defaults, and a legacy row's tool/vision state
                // cannot be distinguished from a user decision — the reviewed
                // migration never re-adds or removes those.
                let eligible: ModelCapabilities = [.vision]
                var added = resolved.subtracting(model.capabilities).intersection(eligible)
                if let explicit = model.explicitCapabilities {
                    added.subtract(explicit)
                }
                guard !added.isEmpty else { continue }
                proposals.append(ProviderCatalogCapabilityProposal(
                    providerID: provider.id,
                    providerName: providerName,
                    presetID: presetID,
                    modelID: model.id,
                    remoteModelID: model.remoteModelID,
                    displayName: model.displayName,
                    currentCapabilities: model.capabilities,
                    addedCapabilities: added
                ))
            }
        }
        return proposals.sorted { lhs, rhs in
            if lhs.providerName != rhs.providerName {
                return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
            }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.modelID.uuidString < rhs.modelID.uuidString
        }
    }

    /// A review is bound to the displayed model and capability snapshot. An
    /// intervening explicit choice invalidates it even if the bit stayed off.
    public static func matches(
        _ proposal: ProviderCatalogCapabilityProposal,
        current model: ModelProfile
    ) -> Bool {
        model.id == proposal.modelID
            && model.providerID == proposal.providerID
            && model.remoteModelID == proposal.remoteModelID
            && model.capabilities == proposal.currentCapabilities
            && (model.explicitCapabilities ?? []).intersection(proposal.addedCapabilities).isEmpty
    }

    /// Applies one confirmed proposal: the added bits are set AND recorded as
    /// explicit user decisions, so a later refresh/sync can never silently
    /// revert the reviewed state. Identity, limits, surfaces and media flags
    /// are preserved.
    public static func applying(
        _ proposal: ProviderCatalogCapabilityProposal,
        to model: ModelProfile
    ) -> ModelProfile {
        guard matches(proposal, current: model) else { return model }
        var updated = model
        updated.capabilities.formUnion(proposal.addedCapabilities)
        updated.explicitCapabilities = (updated.explicitCapabilities ?? []).union(proposal.addedCapabilities)
        return updated
    }
}

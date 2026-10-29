// FloeProviders — Role-specific provider form contract.
//
// One pure resolver tells the provider editor which fields, which supplier
// presets, which pre-staged candidate models and which honest connection
// probe apply to one product role (conversation / image / video) for one
// actual connection. Every decision comes from three real sources:
//
//   1. the connection identity (preset template + kind + endpoint, including
//      the Kimi Code endpoint identity — never a model-name substring),
//   2. the shipped adapter contracts (ImageProviderAdapterFactory /
//      VideoProviderAdapterFactory / chat presets), and
//   3. verified model identifiers from the product-owned official media
//      manifest or the catalog's declared service offers.
//
// Consequences the editor enforces through this spec:
//   * A media role only shows supplier presets whose native adapter actually
//     exists for the endpoint: image = OpenAI, Volcengine Ark, Alibaba Model
//     Studio, Google Gemini, Kimi Code; video = Volcengine Ark, Alibaba Model
//     Studio, Google Gemini. Dead routes (generic custom video, Anthropic
//     images) are never offered.
//   * Chat-only fields (wire-protocol picker, tool-name compatibility,
//     context/reasoning model settings) are hidden for native media presets;
//     advanced custom endpoints keep every field they really consume.
//   * A new media-role add pre-stages the official manifest identifiers for
//     the actual connection as honest pre-selected candidates. Discovery
//     never blanket-stamps unrelated chat models with media capabilities:
//     an endpoint-discovered identifier only becomes a media candidate when
//     the official manifest or a declared catalog offer verifies it (the
//     Kimi Code account listing is the single trusted exception because the
//     endpoint's /coding/v1 models response is that account's image-model
//     source and has no product-owned manifest).
//   * A media "Test connection" must not spend a paid generation: it probes
//     the role adapter contract (offline) and, only where a free listing
//     route exists, an unpaid model listing. Chat success is never presented
//     as media readiness.
//
// No credentials are read or carried here; the spec is secret-free data.

import Foundation
import FloeCore

/// How one media role's connection test may honestly verify the current
/// form. `.chatOnly` marks the conversation role, which keeps the existing chat
/// adapter probe (unpaid model listing).
public enum ProviderFormMediaProbe: String, Sendable, Equatable {
    /// Conversation role: the chat adapter probe stays authoritative.
    case chatOnly
    /// A shipped role adapter exists for the connection. The endpoint has no
    /// free live-probe route, so the editor must not claim "Connected": it
    /// reports the verified contract and the candidate count only.
    case contractOnly
    /// A shipped role adapter exists and the endpoint exposes the free
    /// OpenAI-compatible `GET /models` listing. The listing verifies the
    /// credential without any paid generation; only verified identifiers
    /// may become media candidates.
    case contractWithCredentialListing
    /// No shipped adapter can serve this role for this connection. The
    /// editor fails the test honestly with `unavailableReason` instead of
    /// running the chat probe and stamping its results.
    case unavailable
}

/// The resolved form contract for one provider-role editing session.
/// Value type, computed synchronously from the current form fields; it never
/// touches network, Keychain or mutable app state.
public struct ProviderFormSpec: Sendable, Equatable {
    public let role: ProviderCatalogServiceRole
    /// Kind of the currently selected supplier preset.
    public let kind: ProviderKind
    /// Native template identity of the currently selected preset.
    public let templateID: ProviderTemplateID
    /// Supplier presets the shipped adapters can actually serve for the
    /// role. The editor unions in the current preset when an existing saved
    /// provider uses a legacy route so editing never strands the form.
    public let eligiblePresets: [ProviderPreset]
    /// Wire-protocol picker selects the CHAT adapter only. It is meaningful
    /// for the conversation role and irrelevant for native media presets.
    public let showsProtocolPicker: Bool
    /// Tool-name dot→underscore rewriting is a chat tool-call concern; a
    /// media adapter never sends tool names.
    public let showsToolNameCompatibility: Bool
    /// Non-secret headers: chat/gateway consumers send them on every wire
    /// request; native first-party media endpoints have no documented header
    /// contract in this app, so their forms stay compact. The editor must
    /// also show the field whenever the current form already carries header
    /// text (existing configuration is never hidden from the user).
    public let showsHeadersField: Bool
    /// True when "refresh model list" has an honest meaning for this role:
    /// the chat role with a discovering preset, or a media role whose probe
    /// re-runs the free listing and verified-merge.
    public let showsModelListingRefresh: Bool
    /// `requiredRegion` is the only route-level region requirement. No
    /// shipped image/video/chat adapter consumes `ProviderProfile.region`
    /// today (Volcengine Ark and DashScope carry their region inside the
    /// documented endpoint host), so the resolver never requires it and the
    /// editor exposes the field solely to preserve/edit a stored value.
    public let requiredRegion: String?
    /// The honest connection probe for this role.
    public let mediaProbe: ProviderFormMediaProbe
    /// Secret-free reason when `mediaProbe == .unavailable`.
    public var unavailableReason: String? {
        mediaProbe == .unavailable ? mediaProbeReasonDetail : nil
    }
    /// True when a shipped adapter can serve the role for this connection.
    public let roleAdapterAvailable: Bool
    /// Operations the concrete image adapter declares for this provider
    /// (sorted, stable). Empty unless `role == .image` and an adapter exists.
    public let imageOperations: [RemoteImageOperation]
    /// Verified candidate identifiers pre-staged for a NEW media-role add,
    /// in official-manifest order, then catalog-declared-only identifiers.
    /// Empty for the conversation role and for connections without a
    /// verified media table (generic custom; Kimi Code uses its own account
    /// listing, see `trustsDiscoveryForMedia`).
    public let seedModelIDs: [String]
    /// Kimi Code images have no product-owned manifest: the account's
    /// `/coding/v1/models` response is the only honest source of its image
    /// model identifiers (documented existing behavior, retained unchanged).
    public let trustsDiscoveryForMedia: Bool
    /// Reason detail carried alongside `.unavailable` (never shown as a
    /// success). Not part of equality identity.
    private let mediaProbeReasonDetail: String?

    public init(
        role: ProviderCatalogServiceRole,
        kind: ProviderKind,
        templateID: ProviderTemplateID,
        eligiblePresets: [ProviderPreset],
        showsProtocolPicker: Bool,
        showsToolNameCompatibility: Bool,
        showsHeadersField: Bool,
        showsModelListingRefresh: Bool,
        requiredRegion: String?,
        mediaProbe: ProviderFormMediaProbe,
        roleAdapterAvailable: Bool,
        imageOperations: [RemoteImageOperation],
        seedModelIDs: [String],
        trustsDiscoveryForMedia: Bool,
        mediaProbeReasonDetail: String? = nil
    ) {
        self.role = role
        self.kind = kind
        self.templateID = templateID
        self.eligiblePresets = eligiblePresets
        self.showsProtocolPicker = showsProtocolPicker
        self.showsToolNameCompatibility = showsToolNameCompatibility
        self.showsHeadersField = showsHeadersField
        self.showsModelListingRefresh = showsModelListingRefresh
        self.requiredRegion = requiredRegion
        self.mediaProbe = mediaProbe
        self.roleAdapterAvailable = roleAdapterAvailable
        self.imageOperations = imageOperations
        self.seedModelIDs = seedModelIDs
        self.trustsDiscoveryForMedia = trustsDiscoveryForMedia
        self.mediaProbeReasonDetail = mediaProbeReasonDetail
    }

    /// True when one remote identifier is verified for this media role by
    /// the official manifest or a declared catalog offer (exact identifier
    /// match; case- and whitespace-sensitive by design — the provider's own
    /// spelling is the identity). Conversation rows are not media models.
    public func isVerifiedMediaModel(_ remoteID: String) -> Bool {
        guard role == .image || role == .video else { return false }
        let trimmed = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return seedModelIDs.contains(trimmed)
    }
}

/// Builds `ProviderFormSpec` from the current form identity. Pure and
/// side-effect free.
public enum ProviderFormSpecResolver {

    /// Presets the shipped adapters can serve for one role, in stable order.
    public static func eligiblePresets(for role: ProviderCatalogServiceRole) -> [ProviderPreset] {
        switch role {
        case .conversation:
            return ProviderPreset.chatPresets
        case .image:
            return ProviderPreset.all.filter { preset in
                ImageProviderAdapterFactory().adapter(for: probe(preset)) != nil
            }
        case .video:
            return ProviderPreset.all.filter { preset in
                VideoProviderAdapterFactory().adapter(for: probe(preset)) != nil
            }
        }
    }

    /// Whether the official catalog entry can actually serve one role with a
    /// shipped adapter and verified (or account-discovered) identifiers.
    /// Used by the supplier picker so an image/video add never enters a
    /// silent dead config on a chat-only gateway like DeepSeek.
    public static func isCatalogEntry(
        _ entry: ProviderCatalogEntry,
        eligibleFor role: ProviderCatalogServiceRole
    ) -> Bool {
        guard !ProviderCatalogIndex.hiddenPresetIDs.contains(entry.presetID) else {
            return false
        }
        switch role {
        case .conversation:
            // The chat picker already renders unavailable entries honestly
            // (disabled row + localized reason) and search never returns
            // hidden presets, so every visible entry stays visible.
            return true
        case .image, .video:
            guard entry.availability == .available else { return false }
            let offers = ProviderServiceOfferResolver.resolvedOffers(
                for: entry.kind,
                presetID: entry.presetID,
                baseURL: entry.baseURL,
                authStyle: entry.authStyle,
                availability: entry.availability,
                declared: entry.serviceOffers
            )
            return offers.contains { $0.role == role && $0.isUsable }
        }
    }

    /// Resolves the full form contract for the current editor state.
    ///
    /// - Parameters
    ///   - role: the initiating product role of this editor session.
    ///   - preset: the currently selected supplier preset.
    ///   - baseURL: the current endpoint text parsed by the caller (nil when
    ///     the field does not parse; the contract then stays on the preset
    ///     defaults and saving is blocked by the normal preflight).
    ///   - catalogEntry: the entry the editor is anchored to, when a verified
    ///     catalog identity is selected (declared offers narrow seeds).
    public static func resolve(
        role: ProviderCatalogServiceRole,
        preset: ProviderPreset,
        baseURL: URL?,
        catalogEntry: ProviderCatalogEntry? = nil
    ) -> ProviderFormSpec {
        let eligible = eligiblePresets(for: role)
        // Editing a legacy provider whose saved route is no longer eligible
        // keeps the form usable: the current preset stays selectable.
        let presets = eligible.contains(preset)
            ? eligible
            : (eligible + [preset])
        let chat = role == .conversation
        var probePlan: ProviderFormMediaProbe = .chatOnly
        var probeReason: String?
        var adapterAvailable = true
        var operations: [RemoteImageOperation] = []
        var seeds: [String] = []
        let trustsDiscovery = !chat && preset.id == .kimiCode
        if !chat {
            let probeProfile = probe(preset, baseURL: baseURL)
            switch role {
            case .image:
                if let adapter = ImageProviderAdapterFactory().adapter(for: probeProfile) {
                    operations = RemoteImageOperation.allCases.filter {
                        adapter.supportedOperations(for: probeProfile).contains($0)
                    }
                } else {
                    adapterAvailable = false
                }
            case .video:
                adapterAvailable = VideoProviderAdapterFactory().adapter(for: probeProfile) != nil
            case .conversation:
                break
            }
            if adapterAvailable {
                seeds = verifiedMediaModelIDs(
                    for: preset, role: role, catalogEntry: catalogEntry
                )
                probePlan = preset.supportsModelDiscovery
                    ? .contractWithCredentialListing
                    : .contractOnly
            } else {
                probePlan = .unavailable
                probeReason = role == .image
                    ? "This endpoint has no shipped image adapter. Choose an OpenAI, Volcengine Ark, Alibaba, Google Gemini or Kimi Code supplier."
                    : "This endpoint has no shipped video adapter. Choose a Volcengine Ark, Alibaba or Google Gemini supplier."
            }
        }
        let listingProbe = probePlan == .contractWithCredentialListing
        return ProviderFormSpec(
            role: role,
            kind: preset.kind,
            templateID: preset.id,
            eligiblePresets: presets,
            showsProtocolPicker: chat,
            showsToolNameCompatibility: chat,
            showsHeadersField: chat || (preset.kind == .custom && preset.id != .volcengineAgentPlan)
                || preset.kind == .local,
            showsModelListingRefresh: chat
                ? preset.supportsModelDiscovery
                : listingProbe,
            requiredRegion: nil,
            mediaProbe: probePlan,
            roleAdapterAvailable: adapterAvailable,
            imageOperations: operations,
            seedModelIDs: seeds,
            trustsDiscoveryForMedia: trustsDiscovery,
            mediaProbeReasonDetail: probeReason
        )
    }

    /// Verified candidate identifiers for one media role: the official
    /// manifest for the preset's family first (stable manifest order), then
    /// any catalog-declared identifiers the manifest does not already carry.
    /// Generic custom endpoints without a declared offer seed nothing.
    public static func verifiedMediaModelIDs(
        for preset: ProviderPreset,
        role: ProviderCatalogServiceRole,
        catalogEntry: ProviderCatalogEntry? = nil
    ) -> [String] {
        guard role == .image || role == .video else { return [] }
        let catalogKind: MediaKind = role == .video ? .video : .image
        var result: [String] = []
        // Agent Plan has a distinct model entitlement; do not inherit the
        // full PAYG manifest. This identifier is documented by Ark's Plan
        // visual-model guide, and the existing relative-path adapter serves it.
        if preset.id == .volcengineAgentPlan, role == .image {
            result.append("doubao-seedream-5.0-lite")
        }
        if let family = ProviderServiceOfferResolver.mediaFamily(for: preset.kind) {
            for descriptor in OfficialMediaModelCatalog.models(provider: family, kind: catalogKind) {
                if !result.contains(descriptor.remoteModelID) { result.append(descriptor.remoteModelID) }
            }
        }
        if let declared = catalogEntry?.serviceOffers?.first(where: { $0.role == role }) {
            for remoteID in declared.models {
                let trimmed = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
            }
        }
        return result
    }

    // MARK: - Adapter probes

    private static func probe(_ preset: ProviderPreset) -> ProviderProfile {
        probe(preset, baseURL: preset.defaultBaseURL)
    }

    private static func probe(_ preset: ProviderPreset, baseURL: URL?) -> ProviderProfile {
        ProviderProfile(
            kind: preset.kind,
            wireProtocol: preset.defaultProtocol,
            // The endpoint decides Kimi Code identity; an unparsable field
            // falls back to the preset default so the contract probe stays
            // stable while the user types (save preflight still blocks).
            baseURL: baseURL ?? preset.defaultBaseURL
        )
    }
}

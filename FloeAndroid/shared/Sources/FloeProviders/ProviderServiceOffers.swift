// FloeProviders — Multi-service provider metadata and real-adapter filtering.
//
// A provider entry may declare additional product roles it can serve (image,
// video) through the optional `serviceOffers` catalog field. Whether a role
// may actually be offered to the user is decided HERE, from two real sources:
//
//   1. a shipped first-party adapter for the provider kind (no model-name
//      substring guessing), and
//   2. the product-owned official media manifest for known model identifiers.
//
// Declared offers that claim a role without a shipped adapter stay visible as
// explicitly unsupported instead of silently producing a dead control.
// Offers whose endpoint or auth shape differs from the provider connection are
// reported as `.distinct` so the app configures them as visible separate
// settings rather than sharing credentials across hosts.

import Foundation
import FloeCore

/// A product role a catalog provider may additionally serve.
public enum ProviderCatalogServiceRole: String, Codable, Sendable, CaseIterable, Hashable {
    case conversation
    case image
    case video
}

/// Optional directory metadata for one additional service role. Backward
/// compatible: absent means "no declared offer", and every field except the
/// role is optional. Offers never carry credentials.
public struct ProviderCatalogServiceOffer: Codable, Sendable, Equatable, Hashable {
    public var role: ProviderCatalogServiceRole
    /// Endpoint used for this role when it differs from the entry base URL.
    /// A differing host means the credential must not be shared silently.
    public var baseURL: URL?
    /// Auth style when it differs from the entry's (`bearer`, `apiKeyHeader`,
    /// `none`). A differing style means distinct settings.
    public var authStyle: String?
    /// Wire protocols this role's adapter speaks for the offer, when declared.
    public var protocols: [ModelProtocol]?
    /// Known model identifiers for this role (public catalog data only).
    public var models: [String]
    /// Catalog-owned, secret-free note (for example a region hint).
    public var note: String?

    public init(
        role: ProviderCatalogServiceRole,
        baseURL: URL? = nil,
        authStyle: String? = nil,
        protocols: [ModelProtocol]? = nil,
        models: [String] = [],
        note: String? = nil
    ) {
        self.role = role
        self.baseURL = baseURL
        self.authStyle = authStyle
        self.protocols = protocols
        self.models = models
        self.note = note
    }
}

/// Resolution of one possible additional role against the shipped adapters
/// and the provider's current connection. Contains no credentials.
public struct ProviderServiceOfferResolution: Sendable, Equatable {
    /// Whether the connection (endpoint/auth) can be shared with the existing
    /// provider profile. `.distinct` requires visible separate settings.
    public enum ConnectionMode: String, Sendable, Equatable {
        case shared
        case distinct
    }

    public var role: ProviderCatalogServiceRole
    /// True only when a shipped adapter can execute this role and verified
    /// model identifiers exist. Unusable offers are never auto-configured.
    public var isUsable: Bool
    public var connection: ConnectionMode
    public var endpoint: URL?
    public var models: [String]
    /// True when no verified catalog identifiers exist but the endpoint
    /// exposes real model discovery (`GET /models`): the editor must run an
    /// actual discovery round trip before the role can be configured. No
    /// model identifier is ever invented locally.
    public var requiresDiscovery: Bool
    public var note: String?
    /// Non-secret explanation when the offer is unusable or distinct.
    public var reason: String?

    public init(
        role: ProviderCatalogServiceRole,
        isUsable: Bool,
        connection: ConnectionMode,
        endpoint: URL?,
        models: [String],
        requiresDiscovery: Bool = false,
        note: String? = nil,
        reason: String? = nil
    ) {
        self.role = role
        self.isUsable = isUsable
        self.connection = connection
        self.endpoint = endpoint
        self.models = models
        self.requiresDiscovery = requiresDiscovery
        self.note = note
        self.reason = reason
    }
}

/// Filters optional service metadata by the adapters Floe actually ships.
public enum ProviderServiceOfferResolver {

    /// Media roles a shipped first-party adapter can execute for this kind.
    /// This is a real adapter probe, never a model-name substring guess.
    public static func adapterSupportedMediaRoles(
        for kind: ProviderKind
    ) -> Set<ProviderCatalogServiceRole> {
        var roles: Set<ProviderCatalogServiceRole> = []
        let probe = probeProfile(for: kind)
        if ImageProviderAdapterFactory().adapter(for: probe) != nil { roles.insert(.image) }
        if VideoProviderAdapterFactory().adapter(for: probe) != nil { roles.insert(.video) }
        return roles
    }

    /// First-party media family for a kind, used to read the official,
    /// product-owned model manifest. `nil` means no official media route.
    public static func mediaFamily(for kind: ProviderKind) -> MediaProviderFamily? {
        switch kind {
        case .openAI: .openAI
        case .googleGemini: .googleGemini
        case .volcengineArk: .volcengineArk
        case .alibabaStudio: .alibabaModelStudio
        case .anthropic, .local, .custom: nil
        }
    }

    /// Official manifest model identifiers for one media role, in stable
    /// manifest order. Empty when the kind has no official media route.
    public static func officialModelIDs(
        for kind: ProviderKind,
        role: ProviderCatalogServiceRole
    ) -> [String] {
        guard let family = mediaFamily(for: kind) else { return [] }
        let kindValue: MediaKind
        switch role {
        case .image: kindValue = .image
        case .video: kindValue = .video
        case .conversation: return []
        }
        return OfficialMediaModelCatalog.models(provider: family, kind: kindValue)
            .map(\.remoteModelID)
    }

    /// Provider kinds whose default wire protocol has a shipped chat adapter
    /// AND a chat entry in the app's provider presets. Google Gemini is
    /// deliberately absent: its native image contract lives on a different
    /// route than the chat endpoint, so chat is only offered when the catalog
    /// explicitly declares a compatible conversation offer.
    public static func supportsConversation(for kind: ProviderKind) -> Bool {
        switch kind {
        case .openAI, .anthropic, .volcengineArk, .alibabaStudio, .custom: true
        case .googleGemini, .local: false
        }
    }

    /// Resolves every role the provider kind could serve — image, video AND
    /// conversation — filtered by shipped adapters, verified model
    /// identifiers (or real model discovery) and connection compatibility.
    /// Declared catalog offers narrow/annotate the result. The caller's
    /// initiating role is not privileged here; it is excluded by the editor.
    public static func resolvedOffers(
        for kind: ProviderKind,
        baseURL: URL?,
        authStyle: String?,
        availability: ProviderCatalogAvailability,
        declared: [ProviderCatalogServiceOffer]?
    ) -> [ProviderServiceOfferResolution] {
        guard availability == .available, kind != .local else { return [] }
        let supported = adapterSupportedMediaRoles(for: kind)
        let declaredRoles = declared ?? []
        var result: [ProviderServiceOfferResolution] = []
        for role in [ProviderCatalogServiceRole.image, .video, .conversation] {
            let declaredOffer = declaredRoles.first { $0.role == role }
            let adapterSupportsRole: Bool
            switch role {
            case .image, .video:
                adapterSupportsRole = supported.contains(role)
            case .conversation:
                // A declared conversation offer that explicitly includes the
                // kind's own wire protocol (e.g. Gemini's documented
                // OpenAI-compatible route) is honored for otherwise chat-less
                // kinds; the shipped adapter for that protocol is real.
                adapterSupportsRole = supportsConversation(for: kind)
                    || (declaredOffer?.protocols?.contains(
                        ProviderPreset.preset(for: kind).defaultProtocol
                    ) ?? false)
            }
            guard adapterSupportsRole else {
                // A declared role without a shipped adapter stays visible as
                // explicitly unsupported; an undeclared one is simply absent.
                if let declaredOffer {
                    result.append(ProviderServiceOfferResolution(
                        role: role,
                        isUsable: false,
                        connection: .distinct,
                        endpoint: declaredOffer.baseURL,
                        models: declaredOffer.models,
                        reason: "no shipped adapter for \(role.rawValue)"
                    ))
                }
                continue
            }
            let declaredModels = declaredOffer?.models ?? []
            let usesOfficialManifest = declaredModels.isEmpty && role != .conversation
            let models = declaredModels.isEmpty
                ? (usesOfficialManifest ? officialModelIDs(for: kind, role: role) : [])
                : declaredModels
            var requiresDiscovery = false
            if models.isEmpty {
                switch role {
                case .conversation:
                    // Real discovery is the only honest source of chat model
                    // identifiers when the catalog declares none.
                    requiresDiscovery = ProviderPreset.preset(for: kind).supportsModelDiscovery
                case .image, .video:
                    requiresDiscovery = false
                }
            }
            guard !models.isEmpty || requiresDiscovery else {
                result.append(ProviderServiceOfferResolution(
                    role: role,
                    isUsable: false,
                    connection: .distinct,
                    endpoint: declaredOffer?.baseURL,
                    models: [],
                    reason: "no verified model identifiers"
                ))
                continue
            }
            var connection: ProviderServiceOfferResolution.ConnectionMode = .shared
            var reason: String?
            if let offerURL = declaredOffer?.baseURL {
                if let baseURL, !sameOrigin(baseURL, offerURL) {
                    connection = .distinct
                    reason = "endpoint differs from the provider connection"
                } else if baseURL == nil {
                    connection = .distinct
                    reason = "provider endpoint unavailable for comparison"
                }
            }
            if let offerAuth = declaredOffer?.authStyle, offerAuth != authStyle {
                connection = .distinct
                reason = reason ?? "authentication differs from the provider connection"
            }
            result.append(ProviderServiceOfferResolution(
                role: role,
                isUsable: true,
                connection: connection,
                endpoint: declaredOffer?.baseURL,
                models: models,
                requiresDiscovery: requiresDiscovery,
                note: declaredOffer?.note,
                reason: reason
            ))
        }
        return result
    }

    /// Scheme/host/port identity. A shared credential is only safe when the
    /// origin is byte-identical; path differences stay shareable because the
    /// adapters own their documented path contracts.
    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              normalizedHost(lhs) == normalizedHost(rhs) else { return false }
        return (lhs.port ?? defaultPort(lhs)) == (rhs.port ?? defaultPort(rhs))
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    /// Kind-only probe profile. The adapter factories switch on `kind`; the
    /// URL is a non-routable placeholder and is never sent anywhere.
    private static func probeProfile(for kind: ProviderKind) -> ProviderProfile {
        ProviderProfile(
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://adapter-probe.invalid")!
        )
    }
}

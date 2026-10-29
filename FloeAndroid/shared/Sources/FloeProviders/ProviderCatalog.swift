// FloeProviders — Searchable provider catalog imported from models.dev.
//
// ProviderCatalog.json is generated deterministically by
// content-hub/providers/import_models_dev.py and bundled by the app target.
// The catalog is data only: it never carries credentials, and once decoded
// search is pure local computation (no network, no file I/O).

import Foundation
import FloeCore

/// Whether Floe can target the provider with an existing adapter today.
public enum ProviderCatalogAvailability: String, Codable, Sendable, Hashable {
    /// Wire protocol and auth style map onto a shipped Floe adapter.
    case available
    /// Real provider kept for search, but needs OAuth or a nonstandard
    /// request transform (see `unsupportedReason`).
    case unsupported
}

/// Rejection reason for a catalog document that fails the activation gate.
public struct ProviderCatalogValidationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One provider in the bundled catalog. `id` is the stable `presetID`.
public struct ProviderCatalogEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var presetID: String
    public var name: String
    /// Curated search aliases, including Chinese product names.
    public var aliases: [String]
    public var kind: ProviderKind
    public var defaultProtocol: ModelProtocol
    /// Public API root. `nil` for unsupported providers whose endpoint is
    /// deployment- or project-scoped.
    public var baseURL: URL?
    /// Host fallbacks used by search, e.g. `api.deepseek.com`.
    public var domains: [String]
    /// Selected model identifiers, sorted and capped by the import script.
    public var models: [String]
    public var availability: ProviderCatalogAvailability
    public var unsupportedReason: String?
    /// Primary upstream models.dev provider id.
    public var upstreamID: String
    /// `bearer`, `apiKeyHeader` or `none`.
    public var authStyle: String
    /// Mirrors `ProviderProfile.toolNameCompatibility` for this preset.
    public var toolNameCompatibility: Bool
    /// Optional directory metadata for additional product roles this provider
    /// can serve (image, video). Backward compatible: catalogs written before
    /// multi-service metadata existed decode as `nil`, and the app only offers
    /// a role when a shipped adapter can actually execute it.
    public var serviceOffers: [ProviderCatalogServiceOffer]?
    /// Optional upstream per-model metadata keyed by remote model identifier
    /// (the same strings that appear in `models` or in a declared service
    /// offer). Descriptive only — never credentials, never an override of a
    /// locally saved user setting. Backward compatible: absent means "no
    /// verified metadata" and the caller keeps the legacy protocol default.
    public var modelMetadata: [String: ProviderCatalogModelMetadata]?

    public var id: String { presetID }

    public init(
        presetID: String,
        name: String,
        aliases: [String] = [],
        kind: ProviderKind,
        defaultProtocol: ModelProtocol,
        baseURL: URL? = nil,
        domains: [String] = [],
        models: [String] = [],
        availability: ProviderCatalogAvailability = .available,
        unsupportedReason: String? = nil,
        upstreamID: String,
        authStyle: String,
        toolNameCompatibility: Bool = false,
        serviceOffers: [ProviderCatalogServiceOffer]? = nil,
        modelMetadata: [String: ProviderCatalogModelMetadata]? = nil
    ) {
        self.presetID = presetID
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.defaultProtocol = defaultProtocol
        self.baseURL = baseURL
        self.domains = domains
        self.models = models
        self.availability = availability
        self.unsupportedReason = unsupportedReason
        self.upstreamID = upstreamID
        self.authStyle = authStyle
        self.toolNameCompatibility = toolNameCompatibility
        self.serviceOffers = serviceOffers
        self.modelMetadata = modelMetadata
    }
}

/// Optional upstream per-model metadata carried by a catalog entry.
///
/// `input`/`output` are upstream-declared modality tokens
/// (`text`, `image`, `audio`, `video`, `pdf`). The app maps only a verified
/// image-input inference model to the existing `.vision` capability; audio and
/// video are kept as data because no wire implementation exists for them yet.
/// `toolCall`/`attachment`/`reasoning` describe upstream flags; absence means
/// "upstream did not say", never "false".
public struct ProviderCatalogModelMetadata: Codable, Sendable, Equatable, Hashable {
    public var input: [String]?
    public var output: [String]?
    public var toolCall: Bool?
    public var attachment: Bool?
    public var reasoning: Bool?

    public init(
        input: [String]? = nil,
        output: [String]? = nil,
        toolCall: Bool? = nil,
        attachment: Bool? = nil,
        reasoning: Bool? = nil
    ) {
        self.input = input
        self.output = output
        self.toolCall = toolCall
        self.attachment = attachment
        self.reasoning = reasoning
    }
}

/// Decoded shape of ProviderCatalog.json.
public struct ProviderCatalogDocument: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public var project: String
        public var url: String
        public var license: String
        public var documentSHA256: String
        public var fetchedAt: String

        public init(
            project: String,
            url: String,
            license: String,
            documentSHA256: String,
            fetchedAt: String
        ) {
            self.project = project
            self.url = url
            self.license = license
            self.documentSHA256 = documentSHA256
            self.fetchedAt = fetchedAt
        }
    }

    public var schemaVersion: Int
    public var source: Source
    public var providers: [ProviderCatalogEntry]

    public init(
        schemaVersion: Int,
        source: Source,
        providers: [ProviderCatalogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.providers = providers
    }
}

/// Restricts which entries a search may return.
public enum ProviderCatalogFilter: String, Sendable, Hashable, CaseIterable {
    case all
    case configured
    case available
    case local
}

/// Immutable, decoded catalog with local search.
public struct ProviderCatalogIndex: Sendable {
    public let document: ProviderCatalogDocument
    /// Every entry in document order.
    public let all: [ProviderCatalogEntry]

    /// Preset ids that are never offered for adding a provider: these entries
    /// describe real public providers that need OAuth, deployment-scoped
    /// endpoints or nonstandard signing, so a Floe adapter cannot execute
    /// them. The policy lives here, in code, and is deliberately independent
    /// of `availability` so a newer signed catalog (bundled or installed)
    /// cannot flip them back into the picker. The entries themselves stay in
    /// `all` because saved providers may still reference them: editing an
    /// existing account keeps working.
    public static let hiddenPresetIDs: Set<String> = [
        "github-copilot",
        "azure",
        "amazon-bedrock",
        "google-vertex"
    ]

    /// Number of catalog entries the supplier picker can actually offer
    /// (every entry except the hidden presets). Used for honest footer counts.
    public var offeredProviderCount: Int {
        all.count - all.filter { Self.hiddenPresetIDs.contains($0.presetID) }.count
    }

    /// Catalog entry for a saved provider's stable preset identity, including
    /// hidden presets so existing configurations remain editable.
    public func entry(presetID: String) -> ProviderCatalogEntry? {
        all.first { $0.presetID == presetID }
    }

    private let records: [Record]

    private struct Record: Sendable {
        let entry: ProviderCatalogEntry
        let documentIndex: Int
        let normalizedName: String
        let normalizedAliases: [String]
        let normalizedDomains: [String]
        let normalizedModels: [String]
    }

    /// Test-only construction from an already-decoded document. Untrusted
    /// data must go through `validated(from:)`.
    init(document: ProviderCatalogDocument) {
        self.document = document
        self.all = document.providers
        self.records = document.providers.enumerated().map { index, entry in
            Record(
                entry: entry,
                documentIndex: index,
                normalizedName: Self.normalized(entry.name),
                normalizedAliases: entry.aliases.map(Self.normalized),
                normalizedDomains: entry.domains.map(Self.normalized),
                normalizedModels: entry.models.map(Self.normalized)
            )
        }
    }

    /// Maximum accepted size of the raw catalog payload (2 MiB).
    public static let maximumDocumentBytes = 2 * 1_024 * 1_024

    /// Activation gate for catalog data. Pure and throwing: a document is
    /// only indexed after every invariant below holds.
    ///
    /// Rejects: oversized payloads; schemaVersion != 1; provider counts
    /// outside 1...256; empty source project/license; missing or malformed
    /// presetIDs (regex `[a-z0-9][a-z0-9._-]{0,63}`) and duplicate presetIDs;
    /// names over 128 chars; more than 16 aliases (each empty or over
    /// 64 chars); more than 16 domains (each over 253 or not host-shaped);
    /// more than 200 models (each empty, over 256 chars, or containing
    /// whitespace/control characters); unsupported entries without a
    /// non-empty reason; available entries carrying a reason; unknown auth
    /// styles; incompatible kind/protocol/auth combinations for available
    /// entries (anthropic => anthropicMessages + apiKeyHeader; openAI/
    /// volcengineArk/alibabaStudio => an OpenAI protocol; googleGemini =>
    /// openAIChatCompletions; local => auth none; OpenAI protocols => bearer
    /// or apiKeyHeader); and available entries without a clean HTTPS base URL
    /// (no credentials, query, fragment or port; host non-empty; <= 512 chars).
    public static func validated(from data: Data) throws -> ProviderCatalogIndex {
        guard data.count <= maximumDocumentBytes else {
            throw ProviderCatalogValidationError(
                "provider catalog is \(data.count) bytes; maximum is \(maximumDocumentBytes)"
            )
        }
        let document: ProviderCatalogDocument
        do {
            document = try JSONDecoder().decode(ProviderCatalogDocument.self, from: data)
        } catch {
            throw ProviderCatalogValidationError("malformed provider catalog JSON: \(error)")
        }
        try validate(document)
        return ProviderCatalogIndex(document: document)
    }

    private static func validate(_ document: ProviderCatalogDocument) throws {
        guard document.schemaVersion == 1 else {
            throw ProviderCatalogValidationError(
                "unsupported schemaVersion \(document.schemaVersion)"
            )
        }
        guard (1...256).contains(document.providers.count) else {
            throw ProviderCatalogValidationError(
                "provider count \(document.providers.count) is outside 1...256"
            )
        }
        guard !document.source.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCatalogValidationError("source.project must not be empty")
        }
        guard !document.source.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCatalogValidationError("source.license must not be empty")
        }
        var seenPresetIDs = Set<String>()
        for entry in document.providers {
            guard seenPresetIDs.insert(entry.presetID).inserted else {
                throw ProviderCatalogValidationError("duplicate presetID \(entry.presetID)")
            }
            try validate(entry)
        }
    }

    private static func validate(_ entry: ProviderCatalogEntry) throws {
        let presetID = entry.presetID
        guard presetID.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw ProviderCatalogValidationError("invalid presetID \(presetID)")
        }
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, entry.name.count <= 128 else {
            throw ProviderCatalogValidationError("\(presetID): name must be 1...128 characters")
        }
        guard entry.aliases.count <= 16 else {
            throw ProviderCatalogValidationError("\(presetID): more than 16 aliases")
        }
        for alias in entry.aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, alias.count <= 64 else {
                throw ProviderCatalogValidationError(
                    "\(presetID): alias must be 1...64 characters"
                )
            }
        }
        guard entry.domains.count <= 16 else {
            throw ProviderCatalogValidationError("\(presetID): more than 16 domains")
        }
        for domain in entry.domains {
            guard isHostLike(domain) else {
                throw ProviderCatalogValidationError("\(presetID): invalid domain \(domain)")
            }
        }
        guard entry.models.count <= 200 else {
            throw ProviderCatalogValidationError("\(presetID): more than 200 models")
        }
        for model in entry.models {
            guard !model.isEmpty, model.count <= 256,
                  model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  model.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ProviderCatalogValidationError("\(presetID): invalid model identifier \(model)")
            }
        }
        try validateServiceOffers(entry.serviceOffers, presetID: presetID)
        try validateModelMetadata(entry.modelMetadata, entry: entry)
        switch entry.availability {
        case .available:
            guard entry.unsupportedReason == nil else {
                throw ProviderCatalogValidationError(
                    "\(presetID): available provider must not carry unsupportedReason"
                )
            }
        case .unsupported:
            let reason = entry.unsupportedReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty else {
                throw ProviderCatalogValidationError(
                    "\(presetID): unsupported provider requires a reason"
                )
            }
        }
        switch entry.authStyle {
        case "bearer", "apiKeyHeader", "none":
            break
        default:
            throw ProviderCatalogValidationError(
                "\(presetID): unknown authStyle \(entry.authStyle)"
            )
        }
        // Kind/protocol/auth consistency gates activation only: unsupported
        // providers are never handed to an adapter, so their descriptive auth
        // metadata (e.g. AWS SigV4) may be "none" without failing the gate.
        guard entry.availability == .available else {
            try validateBaseURL(entry.baseURL, presetID: presetID, availability: entry.availability)
            return
        }
        // Kind/protocol consistency.
        switch entry.kind {
        case .openAI, .volcengineArk, .alibabaStudio:
            guard entry.defaultProtocol == .openAIResponses
                || entry.defaultProtocol == .openAIChatCompletions else {
                throw ProviderCatalogValidationError(
                    "\(presetID): kind \(entry.kind.rawValue) requires an OpenAI protocol"
                )
            }
        case .anthropic:
            guard entry.defaultProtocol == .anthropicMessages else {
                throw ProviderCatalogValidationError(
                    "\(presetID): anthropic kind requires anthropicMessages"
                )
            }
        case .googleGemini:
            guard entry.defaultProtocol == .openAIChatCompletions else {
                throw ProviderCatalogValidationError(
                    "\(presetID): googleGemini kind requires openAIChatCompletions"
                )
            }
        case .custom, .local:
            break
        }
        // Protocol/auth compatibility.
        if entry.kind == .local {
            guard entry.authStyle == "none" else {
                throw ProviderCatalogValidationError(
                    "\(presetID): local kind requires authStyle none"
                )
            }
        } else {
            switch entry.defaultProtocol {
            case .anthropicMessages:
                guard entry.authStyle == "apiKeyHeader" else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): anthropicMessages requires authStyle apiKeyHeader"
                    )
                }
            case .openAIResponses, .openAIChatCompletions:
                guard entry.authStyle == "bearer" || entry.authStyle == "apiKeyHeader" else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): OpenAI protocols require bearer or apiKeyHeader auth"
                    )
                }
            }
        }
        try validateBaseURL(entry.baseURL, presetID: presetID, availability: entry.availability)
    }

    /// Validates optional multi-service metadata. Offers are descriptive only:
    /// they never carry credentials, and the app additionally filters them by
    /// the adapters that actually ship. Rule set: at most 4 offers, unique
    /// roles, at most 100 model identifiers per offer validated exactly like
    /// entry models, at most 3 protocols per offer, known auth styles only,
    /// bounded notes, and a clean HTTPS endpoint when one is declared.
    private static func validateServiceOffers(
        _ offers: [ProviderCatalogServiceOffer]?,
        presetID: String
    ) throws {
        guard let offers, !offers.isEmpty else { return }
        guard offers.count <= 4 else {
            throw ProviderCatalogValidationError("\(presetID): more than 4 service offers")
        }
        var seenRoles = Set<ProviderCatalogServiceRole>()
        for offer in offers {
            guard seenRoles.insert(offer.role).inserted else {
                throw ProviderCatalogValidationError(
                    "\(presetID): duplicate service offer role \(offer.role.rawValue)"
                )
            }
            guard offer.models.count <= 100 else {
                throw ProviderCatalogValidationError(
                    "\(presetID): more than 100 models in the \(offer.role.rawValue) service offer"
                )
            }
            for model in offer.models {
                guard !model.isEmpty, model.count <= 256,
                      model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      model.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): invalid \(offer.role.rawValue) service offer model \(model)"
                    )
                }
            }
            if let protocols = offer.protocols {
                guard !protocols.isEmpty, protocols.count <= 3 else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): service offer protocols must be 1...3 entries"
                    )
                }
            }
            if let authStyle = offer.authStyle {
                guard ["bearer", "apiKeyHeader", "none"].contains(authStyle) else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): unknown service offer authStyle \(authStyle)"
                    )
                }
            }
            if let note = offer.note {
                guard !note.isEmpty, note.count <= 256,
                      note.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): service offer note must be 1...256 characters"
                    )
                }
            }
            if let baseURL = offer.baseURL {
                try validateBaseURL(baseURL, presetID: presetID, availability: .available)
            }
        }
    }

    /// Modality tokens the app understands in per-model metadata. Unknown
    /// tokens are rejected instead of silently ignored so a future catalog
    /// cannot smuggle unimplemented capabilities into the app.
    public static let knownModelModalities: Set<String> = [
        "text", "image", "audio", "video", "pdf"
    ]

    /// Validates optional per-model metadata. Keys must be identifiers the
    /// entry actually declares (in `models` or in a service offer), modality
    /// arrays are bounded, unique and drawn from the known set, flags are
    /// booleans by decoding, and an entry must carry at least one fact.
    private static func validateModelMetadata(
        _ metadata: [String: ProviderCatalogModelMetadata]?,
        entry: ProviderCatalogEntry
    ) throws {
        guard let metadata, !metadata.isEmpty else { return }
        let presetID = entry.presetID
        guard metadata.count <= 200 else {
            throw ProviderCatalogValidationError("\(presetID): more than 200 model metadata entries")
        }
        var declared = Set(entry.models)
        for offer in entry.serviceOffers ?? [] {
            declared.formUnion(offer.models)
        }
        for (modelID, value) in metadata {
            guard declared.contains(modelID) else {
                throw ProviderCatalogValidationError(
                    "\(presetID): model metadata for undeclared model \(modelID)"
                )
            }
            for (label, modalities) in [("input", value.input), ("output", value.output)] {
                guard let modalities else { continue }
                guard (1...knownModelModalities.count).contains(modalities.count) else {
                    throw ProviderCatalogValidationError(
                        "\(presetID): \(label) modalities for \(modelID) must be 1...\(knownModelModalities.count) entries"
                    )
                }
                var seen = Set<String>()
                for modality in modalities {
                    guard knownModelModalities.contains(modality) else {
                        throw ProviderCatalogValidationError(
                            "\(presetID): unknown \(label) modality \(modality) for \(modelID)"
                        )
                    }
                    guard seen.insert(modality).inserted else {
                        throw ProviderCatalogValidationError(
                            "\(presetID): duplicate \(label) modality \(modality) for \(modelID)"
                        )
                    }
                }
            }
            guard value.input != nil || value.output != nil || value.toolCall != nil
                    || value.attachment != nil || value.reasoning != nil else {
                throw ProviderCatalogValidationError(
                    "\(presetID): empty model metadata for \(modelID)"
                )
            }
        }
    }

    private static func validateBaseURL(
        _ url: URL?,
        presetID: String,
        availability: ProviderCatalogAvailability
    ) throws {
        guard let url else {
            guard availability == .unsupported else {
                throw ProviderCatalogValidationError("\(presetID): available provider requires a baseURL")
            }
            return
        }
        let text = url.absoluteString
        guard text.count <= 512 else {
            throw ProviderCatalogValidationError("\(presetID): baseURL exceeds 512 characters")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ProviderCatalogValidationError("\(presetID): baseURL must be https")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ProviderCatalogValidationError("\(presetID): baseURL must have a host")
        }
        guard url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil, url.port == nil else {
            throw ProviderCatalogValidationError(
                "\(presetID): baseURL must not carry credentials, query, fragment or port"
            )
        }
    }

    private static func isHostLike(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        return domain.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$",
            options: .regularExpression
        ) != nil
    }

    /// Loads and validates a catalog from any file URL.
    public static func load(from url: URL) throws -> ProviderCatalogIndex {
        try validated(from: Data(contentsOf: url))
    }

    /// Loads the app-bundled `ProviderCatalog.json`, or `nil` when absent.
    public static func loadBundled(bundle: Bundle = .main) -> ProviderCatalogIndex? {
        let candidates: [URL?] = [
            bundle.url(forResource: "ProviderCatalog", withExtension: "json"),
            bundle.url(forResource: "ProviderCatalog", withExtension: "json", subdirectory: "Resources")
        ]
        for case let url? in candidates {
            if let index = try? load(from: url) {
                return index
            }
        }
        return nil
    }

    /// Pure local search, deterministic for identical inputs.
    ///
    /// Non-empty queries rank entries (lower is better):
    /// 1. exact case/width/diacritic-insensitive name or alias match,
    /// 2. name or alias prefix,
    /// 3. domain contains,
    /// 4. model identifier contains,
    /// 5. other name or alias substring.
    /// Entries with no match are dropped. At equal rank: `available` before
    /// `unsupported`, then configured presets, then normalized-name order
    /// (deterministic Unicode ordering, never locale-dependent), then
    /// `presetID`.
    ///
    /// An empty query returns every entry the filter accepts in stable
    /// document order with configured presets moved to the front.
    ///
    /// `hiddenPresetIDs` entries are never returned, for any filter and
    /// whatever availability the document claims; they remain reachable
    /// through `entry(presetID:)` for editing saved providers.
    public func search(
        query: String,
        filter: ProviderCatalogFilter,
        configuredPresetIDs: Set<String>
    ) -> [ProviderCatalogEntry] {
        let normalizedQuery = Self.normalized(query)
        let filtered = records.filter {
            matches($0, filter: filter, configuredPresetIDs: configuredPresetIDs)
        }
        guard !normalizedQuery.isEmpty else {
            return filtered
                .sorted { lhs, rhs in
                    let lhsConfigured = configuredPresetIDs.contains(lhs.entry.presetID)
                    let rhsConfigured = configuredPresetIDs.contains(rhs.entry.presetID)
                    if lhsConfigured != rhsConfigured { return lhsConfigured }
                    return lhs.documentIndex < rhs.documentIndex
                }
                .map(\.entry)
        }
        let ranked = filtered.compactMap { record -> (record: Record, rank: Int)? in
            guard let rank = Self.rank(record, query: normalizedQuery) else { return nil }
            return (record, rank)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let lhsUnsupported = lhs.record.entry.availability == .unsupported
                let rhsUnsupported = rhs.record.entry.availability == .unsupported
                if lhsUnsupported != rhsUnsupported { return !lhsUnsupported }
                let lhsConfigured = configuredPresetIDs.contains(lhs.record.entry.presetID)
                let rhsConfigured = configuredPresetIDs.contains(rhs.record.entry.presetID)
                if lhsConfigured != rhsConfigured { return lhsConfigured }
                if lhs.record.normalizedName != rhs.record.normalizedName {
                    return lhs.record.normalizedName < rhs.record.normalizedName
                }
                return lhs.record.entry.presetID < rhs.record.entry.presetID
            }
            .map(\.record.entry)
    }

    /// Case/width/diacritic-insensitive normalization. Chinese text is kept
    /// as-is; no transliteration is attempted, so no locale transform can
    /// crash or distort CJK queries.
    public static func normalized(_ query: String) -> String {
        let folded = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(
        _ record: Record,
        filter: ProviderCatalogFilter,
        configuredPresetIDs: Set<String>
    ) -> Bool {
        // Hidden presets are never offered for adding, for every filter and
        // regardless of the availability a catalog document claims.
        guard !Self.hiddenPresetIDs.contains(record.entry.presetID) else { return false }
        switch filter {
        case .all:
            return true
        case .configured:
            return configuredPresetIDs.contains(record.entry.presetID)
        case .available:
            return record.entry.availability == .available
        case .local:
            return record.entry.kind == .local
        }
    }

    private static func rank(_ record: Record, query: String) -> Int? {
        if record.normalizedName == query || record.normalizedAliases.contains(query) {
            return 0
        }
        if record.normalizedName.hasPrefix(query)
            || record.normalizedAliases.contains(where: { $0.hasPrefix(query) }) {
            return 1
        }
        if record.normalizedDomains.contains(where: { $0.contains(query) }) {
            return 2
        }
        if record.normalizedModels.contains(where: { $0.contains(query) }) {
            return 3
        }
        if record.normalizedName.contains(query)
            || record.normalizedAliases.contains(where: { $0.contains(query) }) {
            return 4
        }
        return nil
    }
}

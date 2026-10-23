// FloeExecution — declarative search provider catalog.
//
// The catalog is DATA, never code or authority: it describes which existing
// in-app adapters can be added, their default endpoint, required credential
// fields and optional settings. Adapters themselves are compiled into the
// app (`WebSearchService`); a catalog entry naming an adapter this build does
// not know is dropped fail-closed and needs an app update to appear. The
// document ships as the app-bundled fallback and as the `SearchProviderCatalog.json`
// payload of the signed `floe.search.providers` content package (kind
// `providers`, validated through the same signed install transaction).
//
// Credentials never live in the catalog: entries reference stable field keys
// (`apiKey`, `secretId`, …) and every instance gets its own UUID-owned
// Keychain account. Enabling is exclusively the user's per-instance switch;
// the catalog carries no enabled defaults and nothing is auto-added.

import Foundation

// MARK: - Constants

public enum SearchProviderCatalog {
    /// Stable signed package identity. Mirrored by the content hub source
    /// `content-hub/sources/providers/floe.search.providers/` and by the
    /// FloeSkills codec structural dispatch.
    public static let packageID = "floe.search.providers"
    /// Payload file inside the signed package (and the bundled fallback).
    public static let payloadFileName = "SearchProviderCatalog.json"
    public static let bundledResourceName = "SearchProviderCatalog"
    public static let schemaVersion = 1
    public static let maximumDocumentBytes = 512 * 1_024
    public static let maximumEntries = 32
}

// MARK: - Errors

public enum SearchProviderCatalogError: Error, Equatable, LocalizedError {
    case oversized
    case notAnObject
    case schemaVersionUnsupported
    case packageIdentityMismatch
    case invalidVersion(String)
    case emptyEntries
    case tooManyEntries
    case duplicatePresetID(String)
    case invalidPresetID(String)
    case invalidAdapterKind(String)
    case invalidName(String)
    case invalidBlurb(String)
    case invalidEndpoint(String)
    case tooManyCredentialFields(String)
    case invalidCredentialKey(String)
    case tooManyOptionFields(String)
    case invalidOptionKey(String)
    case noUsableEntries

    public var errorDescription: String? {
        switch self {
        case .oversized: "Search provider catalog exceeds the size limit"
        case .notAnObject: "Search provider catalog must be a JSON object"
        case .schemaVersionUnsupported: "This app cannot read the search provider catalog schema"
        case .packageIdentityMismatch: "Search provider catalog identity does not match its package"
        case .invalidVersion(let v): "Invalid search provider catalog version: \(v)"
        case .emptyEntries: "Search provider catalog has no entries"
        case .tooManyEntries: "Search provider catalog has too many entries"
        case .duplicatePresetID(let v): "Duplicate search provider preset id: \(v)"
        case .invalidPresetID(let v): "Invalid search provider preset id: \(v)"
        case .invalidAdapterKind(let v): "Invalid search provider adapter kind: \(v)"
        case .invalidName(let v): "Search provider \(v) needs a bounded English and Simplified Chinese name"
        case .invalidBlurb(let v): "Search provider \(v) needs a bounded English and Simplified Chinese description"
        case .invalidEndpoint(let v): "Search provider \(v) has an invalid default endpoint"
        case .tooManyCredentialFields(let v): "Search provider \(v) declares too many credential fields"
        case .invalidCredentialKey(let v): "Search provider has an invalid credential field key: \(v)"
        case .tooManyOptionFields(let v): "Search provider \(v) declares too many option fields"
        case .invalidOptionKey(let v): "Search provider has an invalid option field key: \(v)"
        case .noUsableEntries: "This app does not support any adapter in the search provider catalog; update Floe"
        }
    }
}

// MARK: - Document

public struct SearchProviderCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    /// Credential descriptor: a stable Keychain value key plus UI label. The
    /// catalog never carries a value.
    public struct CredentialField: Codable, Hashable, Sendable, Identifiable {
        public let key: String
        public let required: Bool
        public let label: [String: String]
        public var id: String { key }

        public init(key: String, required: Bool, label: [String: String]) {
            self.key = key
            self.required = required
            self.label = label
        }
    }

    /// One configurable option exposed by the entry. `option` values must
    /// come from `allowedValues`; `bool` accepts true/false; `text` is a
    /// bounded free value. Defaults are catalog DATA, not enablement.
    public struct OptionField: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case bool
            case text
            case option
        }

        public let key: String
        public let kind: Kind
        public let defaultValue: String?
        public let allowedValues: [String]?
        public let label: [String: String]
        public var id: String { key }

        public init(
            key: String,
            kind: Kind,
            defaultValue: String?,
            allowedValues: [String]?,
            label: [String: String]
        ) {
            self.key = key
            self.kind = kind
            self.defaultValue = defaultValue
            self.allowedValues = allowedValues
            self.label = label
        }
    }

    public let presetID: String
    /// RawValue of a compiled-in `WebSearchProviderKind`. Unknown values make
    /// this entry unusable in this build (dropped fail-closed at validation).
    public let adapterKind: String
    public let name: [String: String]
    public let blurb: [String: String]
    /// Clean HTTPS default endpoint, or nil when the adapter selects its
    /// origin by other means (Volcengine interfaces) or requires one (SearXNG,
    /// custom).
    public let defaultEndpoint: String?
    public let endpointRequired: Bool
    /// When true the catalog owns this entry's endpoint and may propose a
    /// new one on review (with host-change confirmation). The built-in
    /// adapters leave this false: their compiled canonical endpoints (and
    /// the fake-IP tunnel grant tied to `endpoint == nil`) must never change
    /// implicitly. Absent decodes as false.
    public let managesEndpoint: Bool?
    public let credentialFields: [CredentialField]
    public let optionFields: [OptionField]
    /// Localized note shown next to the credential section (auth style).
    public let authNote: [String: String]?

    public var id: String { presetID }

    public init(
        presetID: String,
        adapterKind: String,
        name: [String: String],
        blurb: [String: String],
        defaultEndpoint: String?,
        endpointRequired: Bool,
        managesEndpoint: Bool? = nil,
        credentialFields: [CredentialField],
        optionFields: [OptionField],
        authNote: [String: String]? = nil
    ) {
        self.presetID = presetID
        self.adapterKind = adapterKind
        self.name = name
        self.blurb = blurb
        self.defaultEndpoint = defaultEndpoint
        self.endpointRequired = endpointRequired
        self.managesEndpoint = managesEndpoint
        self.credentialFields = credentialFields
        self.optionFields = optionFields
        self.authNote = authNote
    }

    /// The compiled adapter kind, when this build supports it.
    public var supportedAdapter: WebSearchProviderKind? {
        WebSearchProviderKind(rawValue: adapterKind)
    }

    /// Display name for the primary locale, with the same deterministic
    /// fallback the rest of the app uses (primary locale, then English).
    public func displayName(localePrimary: String) -> String {
        name[localePrimary] ?? name["en"] ?? name["zh-Hans"] ?? presetID
    }

    public func localizedBlurb(localePrimary: String) -> String {
        blurb[localePrimary] ?? blurb["en"] ?? blurb["zh-Hans"] ?? ""
    }

    public func localizedAuthNote(localePrimary: String) -> String? {
        guard let authNote else { return nil }
        return authNote[localePrimary] ?? authNote["en"] ?? authNote["zh-Hans"]
    }

    /// The stable per-instance credential value keys this entry asks for.
    public var credentialKeys: [String] { credentialFields.map(\.key) }
}

public struct SearchProviderCatalogDocument: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let version: String
    public let entries: [SearchProviderCatalogEntry]

    public init(
        schemaVersion: Int,
        id: String,
        version: String,
        entries: [SearchProviderCatalogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.entries = entries
    }

    /// Strict activation gate. Structural or envelope failures throw so the
    /// caller keeps its previously active catalog; entries whose adapter kind
    /// this build does not compile are dropped fail-closed (never offered),
    /// and a document with no usable entry at all throws.
    public static func validated(from data: Data) throws -> SearchProviderCatalogDocument {
        guard data.count <= SearchProviderCatalog.maximumDocumentBytes else {
            throw SearchProviderCatalogError.oversized
        }
        let decoder = JSONDecoder()
        let document: SearchProviderCatalogDocument
        do {
            document = try decoder.decode(SearchProviderCatalogDocument.self, from: data)
        } catch {
            throw SearchProviderCatalogError.notAnObject
        }
        try document.validateStructure()
        // Fail closed per entry: an adapter this build does not compile is
        // never surfaced, so a newer signed catalog can add brands without
        // breaking older apps; those brands appear after an app update. If
        // nothing is usable the whole document is rejected and the caller
        // keeps its previously active catalog.
        let supported = document.entries.filter { $0.supportedAdapter != nil }
        guard !supported.isEmpty else {
            throw SearchProviderCatalogError.noUsableEntries
        }
        guard supported.count != document.entries.count else { return document }
        return SearchProviderCatalogDocument(
            schemaVersion: document.schemaVersion,
            id: document.id,
            version: document.version,
            entries: supported
        )
    }

    private func validateStructure() throws {
        guard schemaVersion == SearchProviderCatalog.schemaVersion else {
            throw SearchProviderCatalogError.schemaVersionUnsupported
        }
        guard id == SearchProviderCatalog.packageID else {
            throw SearchProviderCatalogError.packageIdentityMismatch
        }
        guard Self.isValidVersion(version) else {
            throw SearchProviderCatalogError.invalidVersion(version)
        }
        guard !entries.isEmpty else {
            throw SearchProviderCatalogError.emptyEntries
        }
        guard entries.count <= SearchProviderCatalog.maximumEntries else {
            throw SearchProviderCatalogError.tooManyEntries
        }
        var seen: Set<String> = []
        for entry in entries {
            guard Self.isValidPresetID(entry.presetID) else {
                throw SearchProviderCatalogError.invalidPresetID(entry.presetID)
            }
            guard seen.insert(entry.presetID).inserted else {
                throw SearchProviderCatalogError.duplicatePresetID(entry.presetID)
            }
            // Adapter kind: a declared unknown value is dropped at the
            // document level (see validated), but a non-string or empty
            // identity would be structural rot: reject.
            guard !entry.adapterKind.isEmpty, entry.adapterKind.utf8.count <= 64 else {
                throw SearchProviderCatalogError.invalidAdapterKind(entry.presetID)
            }
            try Self.validateLocalized(
                entry.name, presetID: entry.presetID,
                makeError: SearchProviderCatalogError.invalidName
            )
            try Self.validateLocalized(
                entry.blurb, presetID: entry.presetID,
                makeError: SearchProviderCatalogError.invalidBlurb,
                maximumCharacters: 280
            )
            if let endpoint = entry.defaultEndpoint {
                try Self.validateCleanHTTPS(endpoint, presetID: entry.presetID)
            }
            guard entry.credentialFields.count <= 8 else {
                throw SearchProviderCatalogError.tooManyCredentialFields(entry.presetID)
            }
            var credentialKeys: Set<String> = []
            for field in entry.credentialFields {
                guard Self.isValidIdentifier(field.key), credentialKeys.insert(field.key).inserted else {
                    throw SearchProviderCatalogError.invalidCredentialKey(field.key)
                }
                try Self.validateLocalized(
                    field.label, presetID: entry.presetID,
                    makeError: SearchProviderCatalogError.invalidCredentialKey,
                    maximumCharacters: 80
                )
            }
            guard entry.optionFields.count <= 8 else {
                throw SearchProviderCatalogError.tooManyOptionFields(entry.presetID)
            }
            var optionKeys: Set<String> = []
            for field in entry.optionFields {
                guard Self.isValidIdentifier(field.key), optionKeys.insert(field.key).inserted else {
                    throw SearchProviderCatalogError.invalidOptionKey(field.key)
                }
                try Self.validateLocalized(
                    field.label, presetID: entry.presetID,
                    makeError: SearchProviderCatalogError.invalidOptionKey,
                    maximumCharacters: 80
                )
                if field.kind == .option, let allowed = field.allowedValues {
                    guard allowed.count <= 16, allowed.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
                          let value = field.defaultValue, allowed.contains(value) else {
                        throw SearchProviderCatalogError.invalidOptionKey(field.key)
                    }
                }
                if field.kind == .bool, let value = field.defaultValue {
                    guard ["true", "false"].contains(value) else {
                        throw SearchProviderCatalogError.invalidOptionKey(field.key)
                    }
                }
            }
            if let authNote = entry.authNote {
                try Self.validateLocalized(
                    authNote, presetID: entry.presetID,
                    makeError: SearchProviderCatalogError.invalidBlurb,
                    maximumCharacters: 200
                )
            }
        }
    }

    private static func isValidVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return false }
        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy(\.isNumber) && (piece == "0" || !piece.hasPrefix("0"))
        }
    }

    private static func isValidPresetID(_ value: String) -> Bool {
        guard let first = value.first, value.count >= 2, value.count <= 64,
              first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter, value.count <= 32 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func validateLocalized(
        _ dictionary: [String: String],
        presetID: String,
        makeError: (String) -> SearchProviderCatalogError,
        maximumCharacters: Int = 128
    ) throws {
        guard !dictionary.isEmpty, dictionary.count <= 8,
              dictionary["en"]?.isEmpty == false,
              (dictionary["en"]?.utf8.count ?? 0) <= maximumCharacters * 4,
              dictionary["zh-Hans"]?.isEmpty == false,
              (dictionary["zh-Hans"]?.utf8.count ?? 0) <= maximumCharacters * 4,
              dictionary.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }),
              dictionary.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumCharacters * 4 }) else {
            throw makeError(presetID)
        }
    }

    private static func validateCleanHTTPS(_ raw: String, presetID: String) throws {
        guard raw.utf8.count <= 512, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil else {
            throw SearchProviderCatalogError.invalidEndpoint(presetID)
        }
    }

    /// Loads and validates a catalog document from raw bytes.
    public static func validated(from url: URL) throws -> SearchProviderCatalogDocument {
        try validated(from: Data(contentsOf: url))
    }
}

// MARK: - Indexed catalog with local search

public struct SearchProviderCatalogIndex: Sendable {
    public let document: SearchProviderCatalogDocument
    /// Every usable entry in document order. Entries naming an adapter this
    /// build does not compile are already excluded by validation.
    public let entries: [SearchProviderCatalogEntry]

    public init(document: SearchProviderCatalogDocument) {
        self.document = document
        self.entries = document.entries
    }

    public static func validated(from data: Data) throws -> SearchProviderCatalogIndex {
        SearchProviderCatalogIndex(document: try SearchProviderCatalogDocument.validated(from: data))
    }

    /// Loads the app-bundled fallback copy, or nil when it is absent or
    /// invalid. A broken bundle copy never blocks an installed catalog.
    public static func loadBundled(bundle: Bundle = .main) -> SearchProviderCatalogIndex? {
        let candidates: [URL?] = [
            bundle.url(forResource: SearchProviderCatalog.bundledResourceName, withExtension: "json"),
            bundle.url(
                forResource: SearchProviderCatalog.bundledResourceName,
                withExtension: "json",
                subdirectory: "Resources"
            )
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let index = try? validated(from: data) {
                return index
            }
        }
        return nil
    }

    public var version: String { document.version }

    public func entry(presetID: String) -> SearchProviderCatalogEntry? {
        entries.first { $0.presetID == presetID }
    }

    /// Deterministic local search: name/blurb substring on the primary
    /// locale (fallback English), case/width/diacritic-insensitive; document
    /// order preserved. Empty query returns every entry.
    public func search(query: String, localePrimary: String) -> [SearchProviderCatalogEntry] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            Self.normalize(entry.displayName(localePrimary: localePrimary)).contains(needle)
                || Self.normalize(entry.localizedBlurb(localePrimary: localePrimary)).contains(needle)
                || Self.normalize(entry.presetID).contains(needle)
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Stable preset identity (code side)

/// Preset ids this build's adapters are known under. The signed catalog uses
/// the same ids; instances keep provenance even when no catalog is present.
public enum SearchProviderPresets {
    public static let bocha = "bocha"
    public static let tencentWSA = "tencent-wsa"
    public static let volcengine = "volcengine"
    public static let brave = "brave"
    public static let tavily = "tavily"
    public static let exa = "exa"
    public static let googleProgrammable = "google-programmable"
    public static let searxng = "searxng"
    public static let custom = "custom-interface"

    public static func presetID(for kind: WebSearchProviderKind) -> String? {
        switch kind {
        case .bochaWeb, .bochaAI: bocha
        case .tencentWSA: tencentWSA
        case .volcengine: volcengine
        case .brave: brave
        case .tavily: tavily
        case .exa: exa
        case .googleProgrammable: googleProgrammable
        case .searxng: searxng
        case .custom: custom
        }
    }

    /// Default display names the app historically auto-created per kind. Used
    /// only to recognize untouched legacy presets during migration.
    public static func legacyDefaultDisplayName(for kind: WebSearchProviderKind) -> String {
        switch kind {
        case .bochaWeb, .bochaAI: "Bocha Search"
        case .tencentWSA: "Tencent Cloud WSA"
        case .volcengine: "Volcengine Web Search"
        case .brave: "Brave Search"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .googleProgrammable: "Google Programmable Search"
        case .searxng: "SearXNG"
        case .custom: "Custom"
        }
    }

    public static let legacySharedAccounts: [WebSearchProviderKind: String] = [
        .bochaWeb: "web-search.bochaWeb",
        .bochaAI: "web-search.bochaAI",
        .tencentWSA: "web-search.tencentWSA",
        .volcengine: "web-search.volcengine",
        .brave: "web-search.brave",
        .tavily: "web-search.tavily",
        .exa: "web-search.exa",
        .googleProgrammable: "web-search.googleProgrammable",
        .searxng: "web-search.searxng",
        .custom: "web-search.custom"
    ]
}

// MARK: - Draft creation from a catalog entry

public enum SearchProviderDraftFactory {
    /// Builds the unsaved draft instance for a catalog pick. Nothing is
    /// persisted here: cancelling the editor creates nothing. New instances
    /// are created DISABLED — enablement is exclusively the user's own switch.
    ///
    /// `volcengineCredentialAccount` supplies the app's exact per-provider,
    /// per-interface account formula so the dedicated Volcengine editor keeps
    /// its captured-account guards without string duplication.
    public static func draftInstance(
        for entry: SearchProviderCatalogEntry,
        localePrimary: String,
        volcengineCredentialAccount: (UUID) -> String = { id in
            // Matches VolcengineSettingsDraft.perProviderCredentialAccount for
            // the Agent Plan default; the app injects the real helper.
            "web-search.volcengine.\(id.uuidString.lowercased()).agentPlan"
        }
    ) -> WebSearchProviderInstance? {
        guard let kind = entry.supportedAdapter else { return nil }
        let id = UUID()
        var options: [String: String] = [:]
        for field in entry.optionFields {
            if let value = field.defaultValue { options[field.key] = value }
        }
        let endpoint: URL?
        let credentialAccount: String
        switch kind {
        case .volcengine:
            // New Volcengine instances start on the Agent Plan interface with
            // a provider-UUID-owned account, mirroring the historical preset;
            // the dedicated editor still forces an explicit interface and
            // never shares accounts across instances or products.
            options[VolcengineSearchOptions.Key.interface] =
                VolcengineSearchInterface.agentPlan.rawValue
            endpoint = nil
            credentialAccount = volcengineCredentialAccount(id)
        default:
            // Keep the compiled canonical endpoint (and its tunnel grant)
            // unless the user must supply one or the catalog manages it.
            let usesCatalogEndpoint = entry.endpointRequired || (entry.managesEndpoint ?? false)
            endpoint = usesCatalogEndpoint ? entry.defaultEndpoint.flatMap { URL(string: $0) } : nil
            credentialAccount = WebSearchProviderInstance.credentialAccount(for: id)
        }
        let configuration = WebSearchProviderConfiguration(
            id: id,
            kind: kind,
            displayName: entry.displayName(localePrimary: localePrimary),
            endpoint: endpoint,
            credentialAccount: credentialAccount,
            enabled: false,
            priority: 0,
            options: options
        )
        return WebSearchProviderInstance(
            configuration: configuration,
            presetID: entry.presetID,
            appliedCatalogVersion: nil,
            overrides: [],
            catalogCredentialKeys: entry.credentialKeys
        )
    }
}

// MARK: - Catalog update proposals (reviewed before applying)

/// One pending, non-destructive update of a user instance to a newer catalog
/// revision. Creating a plan never mutates anything: the UI shows the exact
/// field diff and the user decides. Removed catalog entries never delete or
/// change instances; in-flight queries always run on the configuration that
/// was frozen when the query started.
///
/// The supplier display name is deliberately NOT a reviewable field: it is
/// catalog-owned cosmetic metadata, auto-refreshed by
/// `SearchProviderTitleSynchronizer` unless the user personally renamed the
/// instance (a `displayName` override). A name-only catalog revision
/// therefore offers no update at all.
public struct SearchProviderUpdatePlan: Equatable, Sendable {
    public struct FieldChange: Equatable, Sendable {
        public enum Field: Equatable, Sendable {
            case endpoint
            case option(String)
            case credentialKeys
        }

        public let field: Field
        public let from: String?
        public let to: String?

        public init(field: Field, from: String?, to: String?) {
            self.field = field
            self.from = from
            self.to = to
        }
    }

    public let presetID: String
    public let fromCatalogVersion: String?
    public let toCatalogVersion: String
    public let changes: [FieldChange]
    /// True when an endpoint field change moves the request to a different
    /// host. Applying a host change rotates the credential account so the
    /// previously stored key can never be sent to a new destination.
    public let touchesHost: Bool
    /// True when the entry's credential field set changed (auth requirement
    /// change). Applying rotates the credential account as well.
    public let touchesCredentialKeys: Bool
    /// Host or credential-schema changes require an explicit confirmation
    /// before apply; plain copy/endpoint-same-host/option-default changes
    /// apply directly.
    public let requiresConfirmation: Bool

    public init(
        presetID: String,
        fromCatalogVersion: String?,
        toCatalogVersion: String,
        changes: [FieldChange],
        touchesHost: Bool,
        touchesCredentialKeys: Bool
    ) {
        self.presetID = presetID
        self.fromCatalogVersion = fromCatalogVersion
        self.toCatalogVersion = toCatalogVersion
        self.changes = changes
        self.touchesHost = touchesHost
        self.touchesCredentialKeys = touchesCredentialKeys
        self.requiresConfirmation = touchesHost || touchesCredentialKeys
    }

    /// Whether applying must rotate the instance-owned credential account
    /// (a new, empty Keychain account; the old entry stays as backup).
    public var rotatesCredentialAccount: Bool { touchesHost || touchesCredentialKeys }
}

public enum SearchProviderUpdatePlanner {
    /// The pending plan for one instance against the effective catalog, or
    /// nil when there is nothing to review. Instances with no preset
    /// identity are never touched by catalog updates. The supplier display
    /// name is never part of a plan: official catalog titles are cosmetic
    /// metadata refreshed automatically by `SearchProviderTitleSynchronizer`
    /// (user aliases — a `displayName` override — are never changed), so a
    /// catalog revision that only renames entries offers nothing to review.
    public static func plan(
        for instance: WebSearchProviderInstance,
        in catalog: SearchProviderCatalogIndex,
        localePrimary: String
    ) -> SearchProviderUpdatePlan? {
        guard let presetID = instance.presetID,
              let entry = catalog.entry(presetID: presetID),
              instance.appliedCatalogVersion != catalog.version else { return nil }
        var changes: [SearchProviderUpdatePlan.FieldChange] = []
        var touchesHost = false

        if (entry.managesEndpoint ?? false), !instance.overrides.contains("endpoint") {
            let current = instance.configuration.endpoint?.absoluteString
            let desired = entry.defaultEndpoint
            if current != desired {
                if let hostChanged = Self.endpointHostChanged(from: current, to: desired) {
                    touchesHost = hostChanged
                }
                changes.append(.init(field: .endpoint, from: current, to: desired))
            }
        }

        for field in entry.optionFields {
            let overrideKey = "option:\(field.key)"
            let current = instance.configuration.options[field.key]
            guard current != field.defaultValue,
                  !instance.overrides.contains(overrideKey),
                  !instance.overrides.contains("options") else { continue }
            changes.append(.init(field: .option(field.key), from: current, to: field.defaultValue))
        }

        let desiredKeys = entry.credentialKeys
        let storedKeys = instance.catalogCredentialKeys
        var touchesCredentialKeys = false
        if storedKeys != nil {
            touchesCredentialKeys = Set(storedKeys ?? []) != Set(desiredKeys)
            if touchesCredentialKeys {
                changes.append(.init(
                    field: .credentialKeys,
                    from: storedKeys?.joined(separator: ","),
                    to: desiredKeys.joined(separator: ",")
                ))
            }
        }

        guard !changes.isEmpty else { return nil }
        return SearchProviderUpdatePlan(
            presetID: presetID,
            fromCatalogVersion: instance.appliedCatalogVersion,
            toCatalogVersion: catalog.version,
            changes: changes,
            touchesHost: touchesHost,
            touchesCredentialKeys: touchesCredentialKeys
        )
    }

    /// Applies a plan to the instance. Only fields the user has not
    /// overridden change; the instance id, enabled toggle, priority,
    /// credential account (unless a host/auth change forces rotation),
    /// preset identity and unmanaged options are retained. A host or auth
    /// change NEVER carries the old key over: the account rotates to a fresh
    /// empty entry (the caller keeps the old one as backup) and the plan is
    /// only ever applied after explicit confirmation.
    public static func apply(
        _ plan: SearchProviderUpdatePlan,
        to instance: WebSearchProviderInstance,
        entry: SearchProviderCatalogEntry,
        rotatedCredentialAccount: String? = nil
    ) -> (instance: WebSearchProviderInstance, didRotateCredential: Bool) {
        var configuration = instance.configuration
        let overrides = instance.overrides

        for change in plan.changes {
            switch change.field {
            case .endpoint:
                guard !overrides.contains("endpoint") else { continue }
                if let to = change.to {
                    configuration.endpoint = URL(string: to)
                } else {
                    configuration.endpoint = nil
                }
            case .option(let key):
                guard !overrides.contains("option:\(key)"),
                      !overrides.contains("options") else { continue }
                if let to = change.to {
                    configuration.options[key] = to
                } else {
                    configuration.options.removeValue(forKey: key)
                }
            case .credentialKeys:
                break
            }
        }

        var didRotate = false
        if plan.rotatesCredentialAccount, let rotatedCredentialAccount {
            configuration.credentialAccount = rotatedCredentialAccount
            didRotate = true
        }

        var updated = instance
        updated.configuration = configuration
        updated.appliedCatalogVersion = plan.toCatalogVersion
        updated.overrides = overrides
        updated.catalogCredentialKeys = entry.credentialKeys
        return (updated, didRotate)
    }

    private static func endpointHostChanged(from: String?, to: String?) -> Bool? {
        guard let from, let url = URL(string: from) else {
            // No endpoint before: a newly introduced default endpoint is not
            // a destination change for an instance that never had one… but a
            // required endpoint moving from nil to a host IS a new
            // destination. Conservative: treat nil -> host as a host touch.
            return to == nil ? nil : true
        }
        guard let to, let target = URL(string: to) else {
            // Endpoint removed by the catalog: the adapter falls back to its
            // compiled canonical host — destination effectively changed.
            return true
        }
        let lhs = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rhs = URLComponents(url: target, resolvingAgainstBaseURL: false)
        let lhsHost = (lhs?.host?.lowercased(), lhs?.port)
        let rhsHost = (rhs?.host?.lowercased(), rhs?.port)
        return lhsHost != rhsHost
    }
}

// MARK: - Official supplier title sync (pure, automatic)

/// The catalog-owned supplier display name is cosmetic metadata, not a user
/// setting: while the user has never renamed an instance — its `overrides`
/// does not contain `displayName` — the current localized catalog title
/// owns the visible name and refreshes automatically with later catalog
/// revisions. That covers migration-kept records that still carry the exact
/// legacy default and saved configs that still carry the catalog default
/// from the revision they were added from: saving a default never turns it
/// into an alias. An actually user-edited name is a `displayName` override
/// (recorded by the editor save paths and the v1 → v2 migration provenance)
/// and is preserved against every later catalog revision. Sync never touches
/// endpoint, options, credential keys, the credential account, the enabled
/// switch, priority, preset identity or `appliedCatalogVersion`: real field
/// changes still require the reviewed plan with its host/auth confirmation.
public enum SearchProviderTitleSynchronizer {
    /// The current official title an instance should adopt, or nil when the
    /// name is not catalog-owned (user alias), the preset is not in the
    /// catalog, or the stored name already equals the current title.
    public static func officialTitle(
        for instance: WebSearchProviderInstance,
        entry: SearchProviderCatalogEntry,
        localePrimary: String
    ) -> String? {
        guard !instance.overrides.contains("displayName") else { return nil }
        let desired = entry.displayName(localePrimary: localePrimary)
        guard !desired.isEmpty, desired != instance.configuration.displayName else {
            return nil
        }
        return desired
    }

    /// The title-synchronised copy of one instance. Identical to the input
    /// when the name is user-owned or already current.
    public static func synchronizing(
        _ instance: WebSearchProviderInstance,
        catalog: SearchProviderCatalogIndex,
        localePrimary: String
    ) -> WebSearchProviderInstance {
        guard let presetID = instance.presetID,
              let entry = catalog.entry(presetID: presetID),
              let desired = officialTitle(
                for: instance, entry: entry, localePrimary: localePrimary
              ) else { return instance }
        var updated = instance
        updated.configuration.displayName = desired
        return updated
    }

    /// Batch sync. Document order is preserved and only the display name can
    /// change. The caller persists the result through its existing store
    /// lifecycle; this function itself never mutates or writes.
    public static func synchronize(
        instances: [WebSearchProviderInstance],
        catalog: SearchProviderCatalogIndex,
        localePrimary: String
    ) -> (instances: [WebSearchProviderInstance], renamedCount: Int) {
        var renamed = 0
        let updated = instances.map { instance in
            let next = synchronizing(instance, catalog: catalog, localePrimary: localePrimary)
            if next.configuration.displayName != instance.configuration.displayName {
                renamed += 1
            }
            return next
        }
        return (updated, renamed)
    }
}

// MARK: - v1 → v2 instance migration (pure)

/// Decision for one legacy record when moving to the user-instance store.
public enum WebSearchLegacyRecordDisposition: String, Codable, Sendable, Equatable {
    case kept
    case droppedPlaceholder
    case collapsedIntoBochaWeb
}

public enum WebSearchInstanceMigration {
    public struct CredentialCopy: Equatable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct LegacyRecordOutcome: Equatable, Sendable {
        public let sourceIndex: Int
        public let disposition: WebSearchLegacyRecordDisposition
        public let instance: WebSearchProviderInstance?
        public let credentialCopies: [CredentialCopy]
    }

    public struct Result: Sendable {
        public let outcomes: [LegacyRecordOutcome]
        public let instances: [WebSearchProviderInstance]
        public let droppedPlaceholderCount: Int

        public init(
            outcomes: [LegacyRecordOutcome],
            instances: [WebSearchProviderInstance],
            droppedPlaceholderCount: Int
        ) {
            self.outcomes = outcomes
            self.instances = instances
            self.droppedPlaceholderCount = droppedPlaceholderCount
        }

        /// Deterministic backup document written BEFORE the first v2 save:
        /// every legacy record verbatim plus its disposition.
        public func backupDocument(originalRecords: [WebSearchProviderConfiguration]) -> Data {
            struct Backup: Encodable {
                let schemaVersion: Int
                let originalRecords: [WebSearchProviderConfiguration]
                let outcomes: [BackupOutcome]
            }
            struct BackupOutcome: Encodable {
                let sourceIndex: Int
                let disposition: String
                let credentialCopies: [String: String]
            }
            let backup = Backup(
                schemaVersion: 1,
                originalRecords: originalRecords,
                outcomes: outcomes.map { outcome in
                    BackupOutcome(
                        sourceIndex: outcome.sourceIndex,
                        disposition: outcome.disposition.rawValue,
                        credentialCopies: Dictionary(
                            uniqueKeysWithValues: outcome.credentialCopies.map { ($0.from, $0.to) }
                        )
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(backup)) ?? Data("{}".utf8)
        }
    }

    /// Pure per-record classification. The caller reads Keychain presence
    /// through `hasCredential` and performs the returned copy requests itself.
    /// - A record is a provably unused placeholder only when it is disabled,
    ///   has no credential anywhere in its possible accounts, carries no
    ///   endpoint, keeps its exact default display name and no non-default
    ///   options.
    /// - Kept records become instances with a UUID-owned credential account;
    ///   existing values are copied (never moved), so legacy keys stay as a
    ///   readable backup and the bocha shared-account rewrite is fixed for
    ///   every future instance.
    public static func migrate(
        records: [WebSearchProviderConfiguration],
        hasCredential: (String) -> Bool,
        legacyBochaAccounts: [String] = [
            "web-search.bochaWeb",
            "web-search.bochaAI"
        ]
    ) -> Result {
        var outcomes: [LegacyRecordOutcome] = []
        var instances: [WebSearchProviderInstance] = []
        var dropped = 0

        let bochaWebIndex = records.firstIndex { $0.kind == .bochaWeb }

        for (index, record) in records.enumerated() {
            if record.kind == .bochaAI {
                outcomes.append(LegacyRecordOutcome(
                    sourceIndex: index,
                    disposition: .collapsedIntoBochaWeb,
                    instance: nil,
                    credentialCopies: []
                ))
                continue
            }

            let options = record.options
            let isPresetShapedVolcengine = record.kind == .volcengine
                && record.endpoint == nil
                && options == [VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue]
            let optionsAreDefault = options.isEmpty || isPresetShapedVolcengine
            let credentialAccounts = candidateCredentialAccounts(for: record)
            let hasAnyCredential = credentialAccounts.contains { hasCredential($0) }
            let isPlaceholder = !record.enabled
                && record.endpoint == nil
                && optionsAreDefault
                && record.displayName == SearchProviderPresets.legacyDefaultDisplayName(for: record.kind)
                && !hasAnyCredential

            if isPlaceholder {
                dropped += 1
                outcomes.append(LegacyRecordOutcome(
                    sourceIndex: index,
                    disposition: .droppedPlaceholder,
                    instance: nil,
                    credentialCopies: []
                ))
                continue
            }

            var configuration = record
            var overrides: Set<String> = []
            var catalogCredentialKeys: [String]? = nil
            let isBocha = record.kind == .bochaWeb

            if isBocha {
                // Legacy Web/AI collapse: one Bocha instance keeps the Web
                // record's identity; summary behavior carries the old default
                // so the model contract is unchanged. Only the AI record's
                // enable flag and credential can enrich it.
                if let aiIndex = records.firstIndex(where: { $0.kind == .bochaAI }),
                   !configuration.options.keys.contains("summaryEnabled") {
                    if records[aiIndex].enabled {
                        configuration.enabled = true
                    }
                    configuration.options["summaryEnabled"] = "true"
                }
                if !configuration.options.keys.contains("summaryEnabled") {
                    configuration.options["summaryEnabled"] = "true"
                }
                if configuration.displayName == SearchProviderPresets.legacyDefaultDisplayName(for: .bochaWeb) {
                    // Default display name is catalog-managed.
                } else {
                    overrides.insert("displayName")
                }
            } else {
                if record.displayName != SearchProviderPresets.legacyDefaultDisplayName(for: record.kind) {
                    overrides.insert("displayName")
                }
                if record.endpoint != nil {
                    overrides.insert("endpoint")
                    catalogCredentialKeys = []
                }
                if !options.isEmpty {
                    overrides.insert("options")
                }
                if record.kind == .volcengine {
                    // Interface, engine and model choices are the user's own
                    // product decisions, never catalog-managed defaults.
                    overrides.insert("options")
                    catalogCredentialKeys = ["apiKey"]
                }
            }

            let newAccount = WebSearchProviderInstance.credentialAccount(for: record.id)
            var copies: [CredentialCopy] = []
            if record.credentialAccount != newAccount {
                if isBocha {
                    let sources = [record.credentialAccount] + legacyBochaAccounts
                    if let source = sources.first(where: { hasCredential($0) }) {
                        copies.append(CredentialCopy(from: source, to: newAccount))
                    }
                    configuration.credentialAccount = newAccount
                } else if hasCredential(record.credentialAccount) {
                    copies.append(CredentialCopy(from: record.credentialAccount, to: newAccount))
                    configuration.credentialAccount = newAccount
                }
                // searxng-style records with no credential still move to the
                // instance-owned namespace so future keys are never shared.
                if configuration.credentialAccount == record.credentialAccount,
                   !hasCredential(record.credentialAccount) {
                    configuration.credentialAccount = newAccount
                }
            }

            let instance = WebSearchProviderInstance(
                configuration: configuration,
                presetID: SearchProviderPresets.presetID(for: record.kind),
                appliedCatalogVersion: nil,
                overrides: overrides,
                catalogCredentialKeys: catalogCredentialKeys
            )
            instances.append(instance)
            outcomes.append(LegacyRecordOutcome(
                sourceIndex: index,
                disposition: .kept,
                instance: instance,
                credentialCopies: copies
            ))
        }

        // Bocha AI-only installs: no Web record existed, but the AI record
        // collapsed above left its identity unused. Recreate it as a Web
        // instance so the user's configured AI search keeps working.
        if bochaWebIndex == nil, let aiIndex = records.firstIndex(where: { $0.kind == .bochaAI }) {
            let aiRecord = records[aiIndex]
            var configuration = aiRecord
            configuration.kind = .bochaWeb
            configuration.options["summaryEnabled"] = "true"
            let newAccount = WebSearchProviderInstance.credentialAccount(for: aiRecord.id)
            var copies: [CredentialCopy] = []
            if hasCredential(aiRecord.credentialAccount) {
                copies.append(CredentialCopy(from: aiRecord.credentialAccount, to: newAccount))
            }
            configuration.credentialAccount = newAccount
            var overrides: Set<String> = ["options"]
            if configuration.displayName != SearchProviderPresets.legacyDefaultDisplayName(for: .bochaAI) {
                overrides.insert("displayName")
            }
            let instance = WebSearchProviderInstance(
                configuration: configuration,
                presetID: SearchProviderPresets.bocha,
                appliedCatalogVersion: nil,
                overrides: overrides,
                catalogCredentialKeys: nil
            )
            instances.append(instance)
            if let position = outcomes.firstIndex(where: { $0.sourceIndex == aiIndex }) {
                outcomes[position] = LegacyRecordOutcome(
                    sourceIndex: aiIndex,
                    disposition: .kept,
                    instance: instance,
                    credentialCopies: copies
                )
            }
        }

        let ordered = instances.sorted { $0.configuration.priority < $1.configuration.priority }
        return Result(
            outcomes: outcomes,
            instances: ordered,
            droppedPlaceholderCount: dropped
        )
    }

    /// Accounts whose credential presence makes a legacy record "not an
    /// unused placeholder", including the historical bocha shared accounts.
    public static func candidateCredentialAccounts(
        for record: WebSearchProviderConfiguration
    ) -> [String] {
        var accounts = [record.credentialAccount]
        if record.kind == .bochaWeb || record.kind == .bochaAI {
            accounts.append(contentsOf: ["web-search.bochaWeb", "web-search.bochaAI"])
        }
        if let legacy = SearchProviderPresets.legacySharedAccounts[record.kind] {
            accounts.append(legacy)
        }
        if record.kind == .volcengine {
            accounts.append(contentsOf: VolcengineCredentialAccounts.sharedInterfaceAccounts)
        }
        return Array(Set(accounts))
    }
}

/// Shared per-interface Keychain accounts used by the first unreleased
/// Volcengine draft. RawValue is internal-safe here: only lowercase
/// alphanumerics appear in stored option values.
public enum VolcengineCredentialAccounts {
    public static let agentPlan = "web-search.volcengine.agentPlan"
    public static let arkResponses = "web-search.volcengine.arkResponses"
    public static let doubaoSearch = "web-search.volcengine.doubaoSearch"

    public static let sharedInterfaceAccounts = [agentPlan, arkResponses, doubaoSearch]
}

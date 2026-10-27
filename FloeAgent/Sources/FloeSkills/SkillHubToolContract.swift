// FloeSkills — curated Hub boundary for the EXISTING skill tools.
//
// `skill.search`, `skill.read` and `skill.install` keep their default
// installed-workflow behavior byte-for-byte. This file adds ONLY the optional
// injected protocols the App may wire into those same tools so the model can
// discover, review and install entries from the signed curated Hub channel
// (floe-skill-hub, catalog contract at 139b9bd, schemaVersion 3).
//
// Deliberate boundaries:
// - The contract types below are self-contained, bounded, portable
//   Codable/Sendable values. They intentionally do NOT import the unstable
//   Curated client implementation: the App adapter maps its verified client
//   (signature, feed, review and package joins already enforced there) into
//   these shapes at the injection point. A model can never mint these values.
// - Discovery carries metadata only: no instruction bodies, no resource
//   bodies, no host paths.
// - The audited source commit X (`sourceCommit`, inside the signed feed) and
//   the external retrieval pin Y (`publicationCommit`, the immutable
//   publication ref every artifact path of one operation is fetched at) stay
//   separate identities everywhere. Nothing may require X == Y.
// - There is no second permission database and no self-approval: an injected
//   install bridge applies the EXISTING review, grant-delta and install
//   transaction; the tools here accept no model-supplied approval, review
//   status or trust flag of any kind.
//
// This file imports Foundation and FloeTools (the same edges
// `SkillManagement.swift` already uses — the Android shared overlay links
// both modules, so the per-file link stays default source-compatible).

import Foundation
import FloeTools

// MARK: - Bounded portable metadata

/// One localized metadata pair. Both values are clamped and single-lined at
/// construction so no caller can smuggle an unbounded or multi-line body into
/// a discovery response.
public struct SkillHubLocalizedText: Codable, Sendable, Equatable, Hashable {
    public static let maximumNameCharacters = 120
    public static let maximumDescriptionCharacters = 1_024

    public let en: String
    public let zhHans: String

    public init(en: String, zhHans: String, maximumCharacters: Int) {
        let cap = max(1, min(maximumCharacters, SkillHubContractLimits.maximumClampCharacters))
        self.en = SkillHubContractLimits.clamp(en, cap)
        self.zhHans = SkillHubContractLimits.clamp(zhHans, cap)
    }

    /// Display name pair (bounded to `maximumNameCharacters`).
    public static func name(en: String, zhHans: String) -> SkillHubLocalizedText {
        SkillHubLocalizedText(en: en, zhHans: zhHans, maximumCharacters: maximumNameCharacters)
    }

    /// Description metadata pair (bounded to `maximumDescriptionCharacters`;
    /// discovery never carries an instruction body here).
    public static func description(en: String, zhHans: String) -> SkillHubLocalizedText {
        SkillHubLocalizedText(en: en, zhHans: zhHans, maximumCharacters: maximumDescriptionCharacters)
    }

    /// Search-normalized concatenation of both languages.
    var searchableText: String { en + " " + zhHans }
}

/// Shared clamping/collapsing helpers. Values are display metadata, never
/// authority; the boundary still refuses control bytes and host paths.
public enum SkillHubContractLimits {
    public static let maximumClampCharacters = 4_096
    public static let maximumIdentifierCharacters = 64
    public static let maximumVersionCharacters = 64
    public static let maximumTagCount = 12
    public static let maximumTagCharacters = 48
    public static let maximumCategoryCharacters = 64
    public static let maximumListEntryCharacters = 64
    public static let maximumListCount = 16
    public static let maximumInstructionsCharacters = 262_144
    public static let maximumBundledFileEntries = 32
    public static let maximumBundledFileCharacters = 160
    public static let maximumMessageCharacters = 240

    /// Collapse newlines/tabs/control bytes into spaces, trim, hard-cap.
    static func clamp(_ value: String, _ maximum: Int) -> String {
        var collapsed = ""
        for scalar in value.unicodeScalars.prefix(4_096) {
            collapsed.unicodeScalars.append(
                (scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value < 32 || scalar.value == 127)
                    ? " " : scalar
            )
        }
        while collapsed.contains("  ") { collapsed = collapsed.replacingOccurrences(of: "  ", with: " ") }
        collapsed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(max(1, maximum)))
    }

    /// Bounded reviewed instruction text. Unlike display metadata this keeps
    /// Markdown structure (`\n`, `\t`): it only normalizes `\r\n`/`\r` to
    /// `\n`, drops NUL/other C0 controls and DEL, and hard-caps at the
    /// contract's 256 KiB `SKILL.md` ceiling.
    static func normalizedInstructions(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 9, 10: // TAB, LF stay
                break
            case 0...8, 11...31, 127:
                continue
            default:
                break
            }
            let scalarBytes = scalar.utf8.count
            guard bytes + scalarBytes <= maximumInstructionsCharacters else { break }
            bytes += scalarBytes
            out.append(scalar)
        }
        return String(out)
    }

    /// Exact-length lowercase hex, or nil. Never guesses or pads.
    static func normalizedHex(_ value: String?, length: Int) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.count == length, raw.allSatisfy(\.isHexDigit), !raw.isEmpty else { return nil }
        return raw
    }

    /// Bounded version-like token: no whitespace/control, ASCII-printable
    /// subset only (`X.Y.Z` grammar is enforced where it is contractually strict).
    static func normalizedToken(_ value: String, maximum: Int) -> String? {
        let raw = clamp(value, maximum)
        guard !raw.isEmpty, raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "_" }),
              raw.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return raw
    }

    /// `owner/repo` shaped repository identity: ASCII, one or more `/`, no
    /// whitespace, backslash, `@`, `:` or control bytes. Display provenance
    /// only — the tools never fetch from it and never treat it as a URL.
    static func normalizedRepository(_ value: String) -> String? {
        let raw = clamp(value, 160)
        guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return nil }
        guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let allowed: Set<Character> = ["/", "-", "_", "."]
        guard raw.allSatisfy({ $0.isLetter || $0.isNumber || allowed.contains($0) }) else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasSuffix("/") else { return nil }
        return raw
    }

    /// Strict `X.Y.Z` numeric-triple check (version / minimumAppVersion).
    static func isSemanticVersion(_ value: String?) -> Bool {
        guard let value else { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// A package-internal relative path: never absolute, never `..`, never a
    /// host path, backslash, NUL or control character.
    static func normalizedRelativePath(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count <= maximumBundledFileCharacters else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~"), !raw.contains("\\"), !raw.contains("\u{0}") else { return nil }
        if raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return nil }
        var depth = 0
        for component in raw.split(separator: "/", omittingEmptySubsequences: false) {
            if component == ".." { return nil }
            if component.isEmpty || component == "." { continue }
            depth += 1
            guard depth <= 24 else { return nil }
        }
        return raw
    }

    /// Protocol identities are case-sensitive and are never shortened into
    /// a different identifier. Display tags use a separate normalization.
    static func exactIdentities(_ values: [String], field: String, namespaced: Bool) throws -> [String] {
        guard values.count <= 256 else { throw SkillHubValidationError.invalidText(field: field) }
        var seen = Set<String>()
        for value in values {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !value.isEmpty, value.utf8.count <= 128,
                  !namespaced || parts.count >= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                  }}), seen.insert(value).inserted else {
                throw SkillHubValidationError.invalidText(field: field)
            }
        }
        return values
    }

    static func normalizedStringList(_ values: [String], count: Int, entry: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let raw = clamp(value, entry).lowercased()
            guard !raw.isEmpty, !seen.contains(raw) else { continue }
            seen.insert(raw)
            out.append(raw)
            if out.count >= count { break }
        }
        return out
    }
}

// MARK: - Catalog vocabulary

/// Store channel of the verified feed the metadata came from.
public enum SkillHubChannel: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case ios
    case android
}

/// Feed honesty marker: production feeds carry real signed review; fixture
/// feeds are test material and must never be presented as production trust.
public enum SkillHubFeedStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case production
    case fixture
}

/// Whether the verified client judged this entry installable right now.
/// Mirrors the catalog contract §6; the tool never upgrades an offer.
public enum SkillHubInstallOffer: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case qualified
    case fixtureSimulated
}

/// Entry lifecycle identity from the verified feed.
public enum SkillHubEntryKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case builtin
    case optional
}

/// Explicit provenance bundle. X and Y are separate fields and stay separate
/// in every response; there are no host paths here by construction.
public struct SkillHubProvenance: Codable, Sendable, Equatable, Hashable {
    public let hubRepository: String
    public let publisher: String
    public let channel: SkillHubChannel
    public let feedStatus: SkillHubFeedStatus
    public let signatureKeyID: String?
    /// Audited source revision X inside the signed feed. 40-hex or nil
    /// (fixture feeds may lack it). Never used to locate artifacts.
    public let sourceCommit: String?
    /// External immutable retrieval pin Y actually carrying the feed, review
    /// records and archives. Every fetch of one operation happens at Y.
    public let publicationCommit: String
    /// Canonical digest of the verified catalog bytes.
    public let catalogDigest: String
    public let contentDigest: String?
    public let packageSHA256: String?
    /// Digest of the canonical review record bytes, when one verified.
    public let reviewDigest: String?

    public init(
        hubRepository: String,
        publisher: String,
        channel: SkillHubChannel,
        feedStatus: SkillHubFeedStatus,
        signatureKeyID: String?,
        sourceCommit: String?,
        publicationCommit: String,
        catalogDigest: String,
        contentDigest: String?,
        packageSHA256: String?,
        reviewDigest: String?
    ) throws {
        guard let repository = SkillHubContractLimits.normalizedRepository(hubRepository) else {
            throw SkillHubValidationError.invalidText(field: "hubRepository")
        }
        guard let publisher = SkillHubContractLimits.clampedNonEmpty(publisher, 120) else {
            throw SkillHubValidationError.invalidText(field: "publisher")
        }
        let keyID: String?
        if let signatureKeyID {
            let clamped = SkillHubContractLimits.clampedNonEmpty(signatureKeyID, 64)
            guard clamped != nil else { throw SkillHubValidationError.invalidText(field: "signatureKeyID") }
            keyID = clamped
        } else {
            keyID = nil
        }
        guard sourceCommit == nil || SkillHubContractLimits.normalizedHex(sourceCommit, length: 40) != nil else {
            throw SkillHubValidationError.invalidCommit(field: "sourceCommit")
        }
        guard SkillHubContractLimits.normalizedHex(publicationCommit, length: 40) != nil else {
            throw SkillHubValidationError.invalidCommit(field: "publicationCommit")
        }
        guard SkillHubContractLimits.normalizedHex(catalogDigest, length: 64) != nil else {
            throw SkillHubValidationError.invalidDigest(field: "catalogDigest")
        }
        for (field, value) in [("contentDigest", contentDigest), ("packageSHA256", packageSHA256), ("reviewDigest", reviewDigest)] {
            guard value == nil || SkillHubContractLimits.normalizedHex(value, length: 64) != nil else {
                throw SkillHubValidationError.invalidDigest(field: field)
            }
        }
        self.hubRepository = repository
        self.publisher = publisher
        self.channel = channel
        self.feedStatus = feedStatus
        self.signatureKeyID = keyID
        self.sourceCommit = sourceCommit.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.publicationCommit = publicationCommit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.catalogDigest = catalogDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.contentDigest = contentDigest.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.packageSHA256 = packageSHA256.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.reviewDigest = reviewDigest.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

/// One bounded catalog row for discovery. Metadata only: it has no
/// instruction body, no resource body and no installed claim — `installOffer`
/// and `provenance` describe the catalog, never this device's state.
public struct SkillHubCatalogEntry: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let version: String
    public let kind: SkillHubEntryKind
    public let name: SkillHubLocalizedText
    public let description: SkillHubLocalizedText
    public let category: String?
    public let tags: [String]
    public let containsScripts: Bool
    public let installOffer: SkillHubInstallOffer
    public let reviewed: Bool
    public let qualified: Bool
    public let published: Bool
    public let minimumAppVersion: String?
    public let provenance: SkillHubProvenance?

    public init(
        id: String,
        version: String,
        kind: SkillHubEntryKind,
        name: SkillHubLocalizedText,
        description: SkillHubLocalizedText,
        category: String?,
        tags: [String],
        containsScripts: Bool,
        installOffer: SkillHubInstallOffer,
        reviewed: Bool,
        qualified: Bool,
        published: Bool,
        minimumAppVersion: String? = nil,
        provenance: SkillHubProvenance? = nil
    ) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        try SkillIdentifier.validate(trimmed)
        guard let version = SkillHubContractLimits.normalizedToken(version, maximum: SkillHubContractLimits.maximumVersionCharacters) else {
            throw SkillHubValidationError.invalidText(field: "version")
        }
        guard minimumAppVersion == nil || SkillHubContractLimits.isSemanticVersion(minimumAppVersion) else {
            throw SkillHubValidationError.invalidText(field: "minimumAppVersion")
        }
        let categoryValue = category.map { SkillHubContractLimits.clamp($0, SkillHubContractLimits.maximumCategoryCharacters).lowercased() }
        self.id = trimmed
        self.version = version
        self.kind = kind
        self.name = name
        self.description = description
        self.category = (categoryValue?.isEmpty ?? true) ? nil : categoryValue
        self.tags = SkillHubContractLimits.normalizedStringList(
            tags,
            count: SkillHubContractLimits.maximumTagCount,
            entry: SkillHubContractLimits.maximumTagCharacters
        )
        self.containsScripts = containsScripts
        self.installOffer = installOffer
        self.reviewed = reviewed
        self.qualified = qualified
        self.published = published
        self.minimumAppVersion = minimumAppVersion
        self.provenance = provenance
    }
}

/// Exact-id hub read payload: reviewed metadata plus the bundled reviewed
/// instructions text and the package-internal file inventory. Nothing here
/// registers a tool, enables or installs anything; the tool that serves this
/// value stays `readOnly`.
public struct SkillHubCatalogDetail: Codable, Sendable, Equatable {
    public let entry: SkillHubCatalogEntry
    public let instructions: String?
    /// Package-internal relative paths only (bounded, no host paths).
    public let bundledFiles: [String]
    public let fileCount: Int?
    public let totalBytes: Int?
    public let reviewedCapabilities: [String]
    public let reviewedTools: [String]

    public init(
        entry: SkillHubCatalogEntry,
        instructions: String?,
        bundledFiles: [String],
        fileCount: Int?,
        totalBytes: Int?,
        reviewedCapabilities: [String] = [],
        reviewedTools: [String] = []
    ) throws {
        var files: [String] = []
        var seen = Set<String>()
        for raw in bundledFiles {
            guard let path = SkillHubContractLimits.normalizedRelativePath(raw) else {
                throw SkillHubValidationError.unsafeBundledPath(raw)
            }
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            files.append(path)
            if files.count >= SkillHubContractLimits.maximumBundledFileEntries { break }
        }
        guard (fileCount ?? 0) >= 0, (totalBytes ?? 0) >= 0 else {
            throw SkillHubValidationError.invalidText(field: "fileCount/totalBytes")
        }
        self.entry = entry
        self.instructions = instructions.map { SkillHubContractLimits.normalizedInstructions($0) }
        self.bundledFiles = files
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.reviewedCapabilities = try SkillHubContractLimits.exactIdentities(reviewedCapabilities, field: "reviewedCapabilities", namespaced: false)
        self.reviewedTools = try SkillHubContractLimits.exactIdentities(reviewedTools, field: "reviewedTools", namespaced: true)
    }
}

// MARK: - Availability and errors

/// Honest availability of the curated catalog for one tool call. A search
/// never turns a catalog problem into a fake valid-empty result: on failure
/// the tool reports `unavailable`/`invalid` while keeping installed results.
public enum SkillHubCatalogState: String, Codable, Sendable, Equatable, Hashable {
    /// Verified catalog data was consulted for this call.
    case available
    /// The catalog could not be reached (network, storage, resolution at Y).
    case unavailable
    /// Data arrived but failed signature/digest/shape verification.
    case invalid
}

public struct SkillHubCatalogAvailability: Codable, Sendable, Equatable, Hashable {
    public let state: SkillHubCatalogState
    /// Bounded, sanitized, single-line honest reason; never a host path.
    public let message: String?

    public init(state: SkillHubCatalogState, message: String?) {
        self.state = state
        let clamped = message.map { SkillHubContractLimits.clamp($0, SkillHubContractLimits.maximumMessageCharacters) }
        self.message = (clamped?.isEmpty ?? true) ? nil : clamped
    }
}

/// The only failure vocabulary an injected catalog provider should surface to
/// these tools. Both cases carry honest, bounded messages; the tool maps them
/// one-to-one into `SkillHubCatalogAvailability`.
public enum SkillHubCatalogError: Error, Equatable, Sendable, LocalizedError {
    /// Fetch/retrieval could not complete (network, pin resolution, staging).
    case unavailable(String)
    /// Bytes arrived but verification failed (signature, digest, schema,
    /// review joins). Never silently presented as an empty valid catalog.
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): "Curated catalog unavailable: \(message)"
        case .invalid(let message): "Curated catalog failed verification: \(message)"
        }
    }

    public var availability: SkillHubCatalogAvailability {
        switch self {
        case .unavailable(let message): SkillHubCatalogAvailability(state: .unavailable, message: message)
        case .invalid(let message): SkillHubCatalogAvailability(state: .invalid, message: message)
        }
    }
}

/// Construction-time contract violations (bad digests, unsafe paths, wrong
/// identity). The tools surface these honestly, never sanitized away.
public enum SkillHubValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidDigest(field: String)
    case invalidCommit(field: String)
    case invalidText(field: String)
    case unsafeBundledPath(String)
    case hubIdRequired
    case unexpectedWorkspaceParameter(String)
    case unexpectedHubParameter(String)
    /// A committed receipt disagrees with the request identity/pin.
    case receiptIdentityMismatch
    /// A receipt carries fields outside the contract shape.
    case invalidReceipt(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDigest(let field): "\(field) must be the 64-character SHA-256 of the verified bytes"
        case .invalidCommit(let field): "\(field) must be the 40-character commit of the pinned publication"
        case .invalidText(let field): "\(field) is not a valid bounded catalog value"
        case .unsafeBundledPath(let path): "Bundled file paths must be package-relative: \(String(path.prefix(64)))"
        case .hubIdRequired: "source=hub requires an exact catalog skill id"
        case .unexpectedWorkspaceParameter(let fields): "\(fields) are workspace-directory install parameters; omit them when source=hub"
        case .unexpectedHubParameter(let fields): "\(fields) are Hub install parameters; omit them for a workspace-directory install"
        case .receiptIdentityMismatch:
            "The install receipt does not match the requested skill id or pinned publication; nothing was reported as installed"
        case .invalidReceipt(let reason): "The install receipt is malformed: \(reason)"
        }
    }
}

// MARK: - Injected discovery/read boundary

/// Optional native-injected catalog provider for `skill.search` and
/// `skill.read`. The App implements this with its REAL verified client
/// (envelope signature, feed/review/package digest joins, fail-closed rules
/// from the catalog contract §6); module tests inject bounded fakes that
/// supply verified-shaped metadata only. Trust lives in the implementation,
/// never in model output: nothing here reads or accepts a provider-supplied
/// signature, and no method has side effects.
public protocol SkillHubCatalogProviding: Sendable {
    /// The verified catalog metadata snapshot for discovery. Implementations
    /// return entries with the pinned publication Y (and audited X) already
    /// resolved; the tool bounds and scores them.
    func verifiedCatalogEntries() async throws -> [SkillHubCatalogEntry]
    /// Verified exact-id detail (reviewed metadata, bundled reviewed
    /// instructions, package-relative inventory), or nil when the verified
    /// catalog has no such entry. Never registers, enables, activates or
    /// installs anything.
    func verifiedCatalogDetail(id: String) async throws -> SkillHubCatalogDetail?
    /// Runtime binding for immutable reads/pagination within one real run.
    func verifiedCatalogDetail(id: String, context: ToolContext) async throws -> SkillHubCatalogDetail?
}

public extension SkillHubCatalogProviding {
    func verifiedCatalogDetail(id: String, context: ToolContext) async throws -> SkillHubCatalogDetail? {
        try await verifiedCatalogDetail(id: id)
    }
}

// MARK: - Discovery ranking

/// Deterministic catalog ranking shared by `skill.search`. Same per-query
/// bound as installed discovery (8). Chinese and English metadata both score;
/// an entry whose id already exists installed is NEVER merged over the user's
/// installed choice — it is excluded from hub matches.
public enum SkillHubSearch {
    public static let maximumMatchesPerQuery = 8
    public static let maximumSnapshotEntries = 256

    public static func matching(
        query: String,
        entries: [SkillHubCatalogEntry],
        excluding installedIDs: Set<String> = []
    ) -> [String] {
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let tokens = normalized.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        var ranked: [(id: String, score: Int)] = []
        for entry in entries where !installedIDs.contains(entry.id) {
            let identity = (entry.id + " " + entry.name.searchableText)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let description = entry.description.searchableText
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let meta = ([entry.category ?? ""] + entry.tags)
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let identityScore = tokens.filter { identity.contains($0) }.count * 3
            let metaScore = tokens.filter { meta.contains($0) }.count * 2
            let descriptionScore = tokens.filter { description.contains($0) }.count
            let score = normalized == entry.id.lowercased() ? 10_000 : identityScore + metaScore + descriptionScore
            if score > 0 { ranked.append((entry.id, score)) }
        }
        ranked.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        // Highest-scoring row wins per id; a malformed snapshot with duplicate
        // ids can never double-list one catalog match.
        var unique: [(id: String, score: Int)] = []
        var seen = Set<String>()
        for item in ranked where seen.insert(item.id).inserted {
            unique.append(item)
        }
        return unique.prefix(maximumMatchesPerQuery).map { $0.id }
    }
}

// MARK: - Explicit source selectors for the existing tools

/// `skill.install` argument vocabulary. `workspace` is the legacy default:
/// an omitted `source` behaves exactly like before.
public enum SkillInstallSource: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case workspace
    case hub
}

/// `skill.read` argument vocabulary. `installed` is the legacy default.
public enum SkillReadSource: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case installed
    case hub
}

// MARK: - Injected install boundary

/// One validated Hub install intent. Only a catalog id (existing identifier
/// grammar) and an OPTIONAL frozen 40-hex publication pin Y are representable;
/// there is deliberately no URL, no host path, no review/approval/trust flag
/// and no workspace directory vocabulary in this request.
public struct SkillHubInstallRequest: Sendable, Equatable {
    public let id: String
    public let publicationCommit: String?

    public init(id: String, publicationCommit: String? = nil) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        try SkillIdentifier.validate(trimmed)
        let pin = publicationCommit?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pin, !pin.isEmpty {
            guard SkillHubContractLimits.normalizedHex(pin, length: 40) != nil else {
                throw SkillHubValidationError.invalidCommit(field: "publicationCommit")
            }
            self.publicationCommit = pin.lowercased()
        } else {
            self.publicationCommit = nil
        }
        self.id = trimmed
    }
}

/// Honest outcomes of a committed Hub install transaction. The bridge reports
/// what persistence ACTUALLY did; the tool never invents these.
public enum SkillHubInstallStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case installed
    case replaced
    case alreadyInstalled
}

/// Typed proof of one committed curated-Hub install. The injected bridge
/// builds this from the persisted, read-back state — never from the plan —
/// and the tool refuses any receipt whose identity, pin, digests or versions
/// are outside the contract or differ from the request. A string "success"
/// is not a receipt.
public struct SkillHubInstallReceipt: Codable, Sendable, Equatable {
    public let status: SkillHubInstallStatus
    public let skillID: String
    public let version: String
    /// Canonical digest of the unpacked reviewed package bytes.
    public let contentDigest: String
    /// SHA-256 of the exact archive fetched at Y.
    public let packageSHA256: String
    public let catalogDigest: String
    public let reviewDigest: String
    /// Audited source revision X (displayed/kept as provenance, never used
    /// to locate artifacts). nil only in fixture-shaped receipts.
    public let sourceCommit: String?
    /// The pinned publication Y the operation actually fetched at.
    public let publicationCommit: String
    public let containsScripts: Bool
    public let fileCount: Int
    public let totalBytes: Int
    public let reviewedCapabilities: [String]
    public let reviewedTools: [String]

    public init(
        status: SkillHubInstallStatus,
        skillID: String,
        version: String,
        contentDigest: String,
        packageSHA256: String,
        catalogDigest: String,
        reviewDigest: String,
        sourceCommit: String?,
        publicationCommit: String,
        containsScripts: Bool,
        fileCount: Int,
        totalBytes: Int,
        reviewedCapabilities: [String] = [],
        reviewedTools: [String] = []
    ) throws {
        let trimmed = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        try SkillIdentifier.validate(trimmed)
        guard let version = SkillHubContractLimits.normalizedToken(version, maximum: SkillHubContractLimits.maximumVersionCharacters) else {
            throw SkillHubValidationError.invalidReceipt("version")
        }
        for (field, value) in [("contentDigest", contentDigest), ("packageSHA256", packageSHA256), ("catalogDigest", catalogDigest), ("reviewDigest", reviewDigest)] {
            guard SkillHubContractLimits.normalizedHex(value, length: 64) != nil else {
                throw SkillHubValidationError.invalidReceipt(field)
            }
        }
        guard sourceCommit == nil || SkillHubContractLimits.normalizedHex(sourceCommit, length: 40) != nil else {
            throw SkillHubValidationError.invalidReceipt("sourceCommit")
        }
        guard SkillHubContractLimits.normalizedHex(publicationCommit, length: 40) != nil else {
            throw SkillHubValidationError.invalidReceipt("publicationCommit")
        }
        guard fileCount >= 0, totalBytes >= 0 else {
            throw SkillHubValidationError.invalidReceipt("fileCount/totalBytes")
        }
        self.status = status
        self.skillID = trimmed
        self.version = version
        self.contentDigest = contentDigest.lowercased()
        self.packageSHA256 = packageSHA256.lowercased()
        self.catalogDigest = catalogDigest.lowercased()
        self.reviewDigest = reviewDigest.lowercased()
        self.sourceCommit = sourceCommit?.lowercased()
        self.publicationCommit = publicationCommit.lowercased()
        self.containsScripts = containsScripts
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.reviewedCapabilities = try SkillHubContractLimits.exactIdentities(reviewedCapabilities, field: "reviewedCapabilities", namespaced: false)
        self.reviewedTools = try SkillHubContractLimits.exactIdentities(reviewedTools, field: "reviewedTools", namespaced: true)
    }

    /// Requires the committed identity to equal the requested id and, when the
    /// caller pinned Y, the committed retrieval pin to equal that exact pin.
    /// X is never compared to Y: `X != Y` is the normal shape.
    public func verified(against request: SkillHubInstallRequest) throws -> SkillHubInstallReceipt {
        guard skillID == request.id else { throw SkillHubValidationError.receiptIdentityMismatch }
        if let pin = request.publicationCommit {
            guard publicationCommit == pin.lowercased() else {
                throw SkillHubValidationError.receiptIdentityMismatch
            }
        }
        return self
    }
}

/// The install-branch outcomes the tool must classify beyond ordinary
/// retryable failures. Messages are FIXED, bounded, model-independent prose:
/// the cases carry no associated values, so a bridge can never smuggle
/// model-controlled text through them.
/// - `notConfigured`: thrown honestly (never a workspace fallback).
/// - `reviewDeclined` / `userChoiceBlocked`: terminal for this run (the user
///   declined the exact-delta approval, or an explicit user
///   disabled/uninstalled/local-edit choice wins). The tool reports them as
///   non-retryable failed results with no directory fallback. Cancellation of
///   a pending delta approval records the denial for this native run/package
///   on the bridge side, so tool retries cannot re-prompt.
///
/// There is deliberately NO "pending review" outcome: the task path never
/// parks an install in a state the owning conversation cannot see (the
/// build-303 deadlock). A genuine added-scope update waits INSIDE the same
/// tool call on exactly one inline approval in the owning conversation
/// (the runtime's nested `.waitingApproval` seam); once the human decides, the same call
/// commits or terminates honestly. A fresh audited install proceeds under
/// this call's existing runtime authorization.
public enum SkillHubInstallError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case reviewDeclined
    case userChoiceBlocked

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "skill.install(source:\"hub\") is not configured: the curated catalog installer is unavailable in this build. Nothing was installed and there is no workspace fallback."
        case .reviewDeclined:
            "The user declined the required review for this Hub skill."
        case .userChoiceBlocked:
            "An explicit user choice (disabled, uninstalled or locally edited) blocks this Hub install; the user's choice wins."
        }
    }
}

// MARK: - Task-path authorization decision (pure; the deadlock boundary)

/// Facts the task install path knows at the authorization boundary. Every
/// field is derived from the real runtime context and the verified staging
/// result — never from model-supplied text. The run's EFFECTIVE authority is
/// considered before any prompt: a grant minted by the user's standing
/// approval policy (full-access, automatic, approval-model, full-control)
/// already covers an added-scope update, so prompting again would request
/// authority the user already gave ("installation grant and existing
/// authorized capabilities must not be requested twice"). Only a one-off
/// HUMAN inline card grant — which authorized exactly that call — needs one
/// nested exact-delta card for a genuinely added scope.
public struct SkillHubTaskInstallFacts: Equatable, Sendable {
    public var temporaryReadOnly: Bool
    public var hasApprovalGrant: Bool
    /// A previous decline recorded for this exact owner/run/package; a retry
    /// cannot re-prompt the human in the same run.
    public var persistedDecline: Bool
    /// An explicit user state (disabled, uninstalled, locally edited or
    /// removed row) that wins over any install.
    public var explicitUserChoiceBlocked: Bool
    /// A live row already exists for this catalog id (UPDATE, not fresh).
    public var existingRow: Bool
    /// The verified delta computed against the skill's ACTUAL effective
    /// grants requires approval (only ever true for adds-scope updates: a
    /// brand-new skill has no grants yet and its declared ceiling is
    /// consented by the authorizing action, per the approved official-Get
    /// precedent).
    public var deltaRequiresApproval: Bool
    public var addedCapabilities: [String]
    public var addedTools: [String]
    public var addedPythonPackageSpecs: [String]
    /// True when this call's grant came from a one-off HUMAN inline card (or
    /// the origin is unknown — conservative). False when the user's standing
    /// approval policy authorized the call, which is sufficient effective
    /// authority for an added-scope update.
    public var humanScopedApproval: Bool
    /// True when the runtime issued its nested-approval seam for this exact
    /// call, so a genuinely required prompt can join the canonical
    /// `.waitingApproval` lifecycle and the same call resumes in place.
    public var inlineApprovalSurfaceAvailable: Bool

    public init(temporaryReadOnly: Bool, hasApprovalGrant: Bool, persistedDecline: Bool,
                explicitUserChoiceBlocked: Bool, existingRow: Bool, deltaRequiresApproval: Bool,
                addedCapabilities: [String], addedTools: [String], addedPythonPackageSpecs: [String],
                humanScopedApproval: Bool = true, inlineApprovalSurfaceAvailable: Bool = false) {
        self.temporaryReadOnly = temporaryReadOnly
        self.hasApprovalGrant = hasApprovalGrant
        self.persistedDecline = persistedDecline
        self.explicitUserChoiceBlocked = explicitUserChoiceBlocked
        self.existingRow = existingRow
        self.deltaRequiresApproval = deltaRequiresApproval
        self.addedCapabilities = addedCapabilities
        self.addedTools = addedTools
        self.addedPythonPackageSpecs = addedPythonPackageSpecs
        self.humanScopedApproval = humanScopedApproval
        self.inlineApprovalSurfaceAvailable = inlineApprovalSurfaceAvailable
    }
}

public enum SkillHubTaskInstallRefusal: String, Equatable, Sendable {
    case temporaryChat
    case approvalRequired
    case reviewDeclined
    case userChoice
    /// A prompt is genuinely required but this context has no runtime
    /// surface to present it (detached job, legacy context). Nothing parks
    /// invisibly; the caller fails honestly and retryably.
    case approvalSurfaceUnavailable
}

public enum SkillHubTaskInstallDecision: Equatable, Sendable {
    case refused(SkillHubTaskInstallRefusal)
    /// Fresh audited install OR an update fully covered by the existing
    /// grants: commit inside THIS call through the verified chain.
    case proceedUnderCallAuthorization
    /// Adds-scope UPDATE: park this same call on exactly one inline
    /// exact-delta approval in the owning conversation, then resume.
    case requestInlineDeltaApproval(addedCapabilities: [String], addedTools: [String],
                                    addedPythonPackageSpecs: [String])
}

/// The single deterministic task-path authorization decision. Hard checks
/// (signature/hash/review chain, compatibility, dependency declaration,
/// publication pin, user states, temporary ceiling, catastrophic gates) run
/// outside and BEFORE this function and are never relaxed by it.
public enum SkillHubTaskInstallPolicy {
    public static func decide(_ facts: SkillHubTaskInstallFacts) -> SkillHubTaskInstallDecision {
        if facts.temporaryReadOnly { return .refused(.temporaryChat) }
        guard facts.hasApprovalGrant else { return .refused(.approvalRequired) }
        if facts.explicitUserChoiceBlocked { return .refused(.userChoice) }
        if facts.persistedDecline { return .refused(.reviewDeclined) }
        // A brand-new audited skill has NO grants yet, so its delta always
        // lists everything declared. Parking that in a review the task can
        // never present is the exact build-303 deadlock: under the call's
        // real authorization it proceeds, and the commit registers only the
        // declared internal ceiling (`installationGrants(declared:)`), which
        // does not broaden later execution rights.
        guard facts.existingRow, facts.deltaRequiresApproval else {
            return .proceedUnderCallAuthorization
        }
        // Adds-scope UPDATE: consult the run's EFFECTIVE authority first.
        // A standing-policy grant (full-access / automatic / approval-model
        // / full-control) already authorizes actions beyond this delta, so
        // prompting would request the same authority twice. A one-off human
        // card authorized only the install action itself, so the exact added
        // scope gets ONE nested inline card and the same call resumes.
        if !facts.humanScopedApproval {
            return .proceedUnderCallAuthorization
        }
        guard facts.inlineApprovalSurfaceAvailable else {
            return .refused(.approvalSurfaceUnavailable)
        }
        return .requestInlineDeltaApproval(addedCapabilities: facts.addedCapabilities,
                                           addedTools: facts.addedTools,
                                           addedPythonPackageSpecs: facts.addedPythonPackageSpecs)
    }
}

/// Bounded, deterministic card copy for the nested exact-delta approval.
/// Only verified facts enter the reason: the identity, the exact staged
/// digest and ONLY the added entries. Language-neutral identifiers keep the
/// line portable; the App prefixes its localized prompt sentence.
public enum SkillHubDeltaApprovalCopy {
    /// "markitdown 2.0.0 · digest d41d…d41d · adds capabilities: a,b ·
    ///  tools: c · packages: d==1" — every list bounded, total bounded.
    public static func factsLine(skillID: String, version: String, contentDigest: String,
                                 addedCapabilities: [String], addedTools: [String],
                                 addedPythonPackageSpecs: [String]) -> String {
        func boundedList(_ values: [String]) -> String {
            let shown = values.prefix(16).map { String($0.prefix(64)) }
            let omitted = values.count - shown.count
            return shown.joined(separator: ",") + (omitted > 0 ? ",+\(omitted)" : "")
        }
        var parts: [String] = ["\(skillID.prefix(64)) \(version.prefix(64))",
                               "digest \(contentDigest.prefix(12))"]
        if !addedCapabilities.isEmpty { parts.append("adds capabilities: " + boundedList(addedCapabilities)) }
        if !addedTools.isEmpty { parts.append("tools: " + boundedList(addedTools)) }
        if !addedPythonPackageSpecs.isEmpty { parts.append("packages: " + boundedList(addedPythonPackageSpecs)) }
        return String(parts.joined(separator: " · ").prefix(600))
    }
}

/// Optional native-injected Hub installer for `skill.install(source:"hub")`.
/// The App implements this on top of the EXISTING install transaction: it
/// fetches every artifact path at the pinned publication Y, repeats the
/// contract §6.3/§6.4 verifications (archive size/sha256, unpacked
/// contentDigest, signed review joins against the actual bytes), applies the
/// task-path authorization decision (`SkillHubTaskInstallPolicy`), honors
/// user disabled/uninstalled/locally-edited state without overriding it, and
/// stages through the existing atomic promotion. It returns what persistence
/// actually committed.
///
/// The `context` is the ACTUAL runtime-issued `ToolContext` for this exact
/// call (never model-minted): the bridge must bind its durable staging and
/// permission-delta handoff to the real `runID`/`conversationID`/
/// `approvalGrantID`/`toolCallID` identity carried there — same-run refusal
/// dedupe must use that identity, never a model-supplied value — and must
/// honor `context.cancellation` while the fetch has not yet committed. The
/// tool already refuses temporary chats and unapproved calls BEFORE this
/// method runs; the bridge must still treat `context.temporaryReadOnly` as
/// authoritative if it consults it. Main checks the requested publication Y
/// and the real signed review BEFORE any commit, then reads back the
/// persisted typed receipt. For an adds-scope UPDATE under a one-off human
/// card grant the bridge parks THIS same call on the runtime's nested
/// approval seam — exactly one inline exact-delta card presented in the
/// OWNING conversation through the canonical `.waitingApproval` lifecycle,
/// settled by the human, after which the same call commits and returns the
/// real receipt. Under a standing-policy grant (full-access/automatic) the
/// effective authority already covers the delta and no prompt is added. Outcomes the tool classifies: `reviewDeclined`/`userChoiceBlocked`
/// for terminal user decisions (reported non-retryable, no directory
/// fallback; declining or cancelling a pending delta approval records the
/// denial for this native run/package on the bridge side so tool retries
/// cannot re-prompt). Any other thrown error is an ordinary honest failed
/// result. A fresh audited install never parks: it commits inside this call
/// under the existing authorization, and the commit registers only the
/// declared internal ceiling without broadening later execution rights.
///
/// Cancellation contract: an implementation that has NOT durably committed
/// must throw a cancellation error; an implementation whose transaction
/// ALREADY committed must return the typed receipt even if cancellation
/// arrives during commit, so the tool can report exactly what landed instead
/// of misreporting "nothing installed". This tool grants nothing itself and
/// never falls back to a workspace or host interpreter.
public protocol SkillHubInstalling: Sendable {
    func install(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> SkillHubInstallReceipt
}

extension SkillHubContractLimits {
    /// `clamp` with an explicit empty refusal, for required display fields.
    static func clampedNonEmpty(_ value: String, _ maximum: Int) -> String? {
        let raw = clamp(value, maximum)
        return raw.isEmpty ? nil : raw
    }
}

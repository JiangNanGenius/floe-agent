// FloeSkills — curated Skill Hub schemaVersion-3 wire models (lane A1).
//
// One-shot strict decode and structural validation of the signed channel
// feeds defined by `docs/CATALOG-CONTRACT.md` in the fixed H1 hub
// (`JiangNanGenius/floe-skill-hub`). The rules here mirror the authoritative
// Python behaviour in `scripts/hubcore.py::validate_catalog` exactly: unknown
// keys, drifted identity, wrong counts, impossible lifecycle states, unsafe
// paths and fixture/production mixing all fail closed. Nothing in this file
// touches the network, the keychain or the legacy four-item decoder
// (`OfficialSkillHub`), which stays byte-for-byte unchanged.

import Foundation

// MARK: - Fixed wire enums

/// Store channel of a curated feed. Deliberately separate from
/// `SkillPlatform` (which also carries `linux`/`macos` host meanings) and from
/// the execution `os`/`arch` plane. Nothing may be inferred across the three.
public enum CuratedSkillChannel: String, Codable, Sendable, CaseIterable, Hashable {
    case ios
    case android
}

public enum CuratedSkillFeedStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case production
    case fixture
}

public enum CuratedSkillInstallOffer: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case qualified
    case fixtureSimulated = "fixture-simulated"
}

public enum CuratedSkillEntryKind: String, Codable, Sendable, CaseIterable, Hashable {
    case builtin
    case optional
}

/// Provenance source code of a curated entry.
public enum CuratedSkillSourceCode: String, Codable, Sendable, CaseIterable, Hashable {
    case floe = "F"
    case anthropics = "A"
    case vercelLabs = "V"
    case alirezarezvani = "R"
    case kDense = "K"
    case superpowers = "S"
    case impeccable = "I"
}

public enum CuratedSkillCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case officeDocuments = "office-documents"
    case writingCommunication = "writing-communication"
    case webDevelopment = "web-development"
    case researchData = "research-data"
    case designCreation = "design-creation"
    case productRequirements = "product-requirements"
    case productivityOrganization = "productivity-organization"
}

public enum CuratedSkillAdaptationStage: String, Codable, Sendable, CaseIterable, Hashable {
    case awaitingImplementation = "awaiting-implementation"
    case planned
    case inProgress = "in-progress"
    case frozen
}

public enum CuratedSkillExecutionEvidence: String, Codable, Sendable, CaseIterable, Hashable {
    case unproven
    case guestVerified = "guest-verified"
}

public enum CuratedSkillUpstreamLicenseStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case verified
    case pendingPerItemAudit = "pending-per-item-audit"
    case blockedNoUpstreamLicense = "blocked-no-upstream-license"
}

// MARK: - Shared value types

/// `{en, zh-Hans}` bilingual text. Both locales are always present; the
/// non-empty requirement applies to names and descriptions (contract §3),
/// notes may be empty.
public struct CuratedSkillLocalizedText: Codable, Sendable, Equatable, Hashable {
    public let en: String
    public let zhHans: String

    public init(en: String, zhHans: String) {
        self.en = en
        self.zhHans = zhHans
    }

    private enum CodingKeys: String, CodingKey {
        case en
        case zhHans = "zh-Hans"
        case legacyZhHans = "zhHans"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        en = try values.decode(String.self, forKey: .en)
        let current = try values.decodeIfPresent(String.self, forKey: .zhHans)
        let legacy = try values.decodeIfPresent(String.self, forKey: .legacyZhHans)
        if let current, let legacy, current != legacy {
            throw DecodingError.dataCorruptedError(forKey: .zhHans, in: values,
                debugDescription: "Conflicting Simplified Chinese text fields.")
        }
        guard let text = current ?? legacy else {
            throw DecodingError.keyNotFound(CodingKeys.zhHans,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing Simplified Chinese text."))
        }
        zhHans = text
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(en, forKey: .en)
        try values.encode(zhHans, forKey: .zhHans)
    }

    /// Picks the value for the user's preferred localizations, falling back to
    /// English. Simplified Chinese (`zh*`) selects `zh-Hans`.
    public func value(preferredLanguages: [String]) -> String {
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return zhHans }
            if language.hasPrefix("en") { return en }
        }
        return en
    }
}

/// The fixed permission policy object every feed must carry byte-equal
/// (contract §4). It documents the existing grant model; it is not a second
/// permission database and it can never self-approve anything.
public struct CuratedSkillPermissionPolicy: Codable, Sendable, Equatable, Hashable {
    public let automaticInstallWhenReviewedAndGranted: Bool
    public let deltaOnlyApproval: Bool
    public let selfApprovalProhibited: Bool
    public let userDisabledAndRemovedPriority: String
    public let temporaryTaskCeiling: String

    public static let contract = CuratedSkillPermissionPolicy(
        automaticInstallWhenReviewedAndGranted: true,
        deltaOnlyApproval: true,
        selfApprovalProhibited: true,
        userDisabledAndRemovedPriority: "user",
        temporaryTaskCeiling: "client-enforced"
    )
}

/// Execution OS/arch/evidence block — runtime metadata, separate from both
/// the store channel and the packaged manifest's native platform enum.
public struct CuratedSkillExecution: Sendable, Equatable, Hashable {
    public let os: String?
    public let arch: String?
    public let evidence: CuratedSkillExecutionEvidence

    public init(os: String?, arch: String?, evidence: CuratedSkillExecutionEvidence) {
        self.os = os
        self.arch = arch
        self.evidence = evidence
    }

    public static let guideOnly = CuratedSkillExecution(os: nil, arch: "n/a", evidence: .unproven)
}

/// Entry runtime block. For `qualified` production entries the feed carries
/// the actual reviewed manifest facts; planned placeholders only appear on
/// unqualified candidates and can never authorize staging.
public struct CuratedSkillRuntime: Sendable, Equatable, Hashable {
    public let scriptRuntime: SkillScriptRuntime
    public let capabilities: [String]
    public let tools: [String]
    public let installPlatforms: [CuratedSkillChannel]
    public let pythonPackagesPlan: [String]
    public let execution: CuratedSkillExecution

    public init(
        scriptRuntime: SkillScriptRuntime,
        capabilities: [String],
        tools: [String],
        installPlatforms: [CuratedSkillChannel],
        pythonPackagesPlan: [String],
        execution: CuratedSkillExecution
    ) {
        self.scriptRuntime = scriptRuntime
        self.capabilities = capabilities
        self.tools = tools
        self.installPlatforms = installPlatforms
        self.pythonPackagesPlan = pythonPackagesPlan
        self.execution = execution
    }
}

/// Distinct lifecycle flags. States are never inferred; the implications
/// `reviewed ⇒ licenseChecked`, `qualified ⇒ reviewed + packaged`,
/// `published ⇒ qualified` and `executionVerified ⇒ frozen adaptation` are
/// enforced at decode time.
public struct CuratedSkillStatus: Sendable, Equatable, Hashable {
    public let sourcePinned: Bool
    public let licenseChecked: Bool
    public let adaptation: CuratedSkillAdaptationStage
    public let packaged: Bool
    public let reviewed: Bool
    public let qualified: Bool
    public let published: Bool
    public let executionVerified: Bool

    public init(
        sourcePinned: Bool, licenseChecked: Bool, adaptation: CuratedSkillAdaptationStage,
        packaged: Bool, reviewed: Bool, qualified: Bool, published: Bool, executionVerified: Bool
    ) {
        self.sourcePinned = sourcePinned
        self.licenseChecked = licenseChecked
        self.adaptation = adaptation
        self.packaged = packaged
        self.reviewed = reviewed
        self.qualified = qualified
        self.published = published
        self.executionVerified = executionVerified
    }
}

/// External upstream pin (review baseline, never a blanket license).
public struct CuratedSkillUpstreamPin: Sendable, Equatable, Hashable {
    public let repository: String
    public let commit: String
    public let path: String
    public let skillManifestPath: String
    public let retrievedAt: String
    public let licenseStatus: CuratedSkillUpstreamLicenseStatus
    public let licenseEvidencePath: String?
    public let repositoryLicense: String
    public let licenseNote: CuratedSkillLocalizedText
    /// Optional signed-registry hint for where the upstream skill was
    /// authored (for example `skill`). Provenance only; the reviewed pin and
    /// package bindings above remain the authority.
    public let authoringPath: String?
}

/// First-party (builtin) pin. Released and staged versions are recorded
/// separately and are never conflated.
public struct CuratedSkillFirstPartyPin: Sendable, Equatable, Hashable {
    public let repository: String
    public let commit: String
    public let path: String
    public let skillManifestPath: String
    public let retrievedAt: String
    public let licenseEvidencePath: String?
    public let releasedVersion: String?
    public let stagedSourceVersion: String?
}

/// Exact-archive binding (contract §2/§3): `sha256` covers the archive bytes,
/// `contentDigest` covers the unpacked canonical file set.
public struct CuratedSkillPackageBinding: Sendable, Equatable, Hashable {
    public let path: String
    public let size: Int
    public let sha256: String
    public let contentDigest: String
    public let containsScripts: Bool
}

/// Signed review-record binding: digest of the canonical record bytes plus
/// the signing identity that vouched for them.
public struct CuratedSkillReviewBinding: Sendable, Equatable, Hashable {
    public let path: String
    public let sha256: String
    public let keyID: String
}

/// Actual per-feed values recomputed from entries. The store shows these,
/// never a hardcoded candidate total.
public struct CuratedSkillCounts: Sendable, Equatable, Hashable {
    public let total: Int
    public let builtin: Int
    public let optional: Int
    public let deepAdaptation: Int
    public let packaged: Int
    public let reviewed: Int
    public let qualified: Int
    public let offerQualified: Int
}

/// One channel-feed entry: exactly the nineteen contract keys.
public struct CuratedSkillEntry: Sendable, Equatable {
    public let id: String
    public let planNumber: Int
    public let kind: CuratedSkillEntryKind
    public let source: CuratedSkillSourceCode
    public let name: CuratedSkillLocalizedText
    public let description: CuratedSkillLocalizedText
    public let category: CuratedSkillCategory
    public let tags: [String]
    public let deepAdaptation: Bool
    public let upstream: CuratedSkillUpstreamPin?
    public let firstParty: CuratedSkillFirstPartyPin?
    public let runtime: CuratedSkillRuntime
    public let version: String
    public let minimumAppVersion: String?
    public let status: CuratedSkillStatus
    public let notes: CuratedSkillLocalizedText
    public let package: CuratedSkillPackageBinding?
    public let review: CuratedSkillReviewBinding?
    public let installOffer: CuratedSkillInstallOffer
}

/// One signed schemaVersion-3 channel feed, fully validated structurally.
/// `sourceCommit` is the audited source revision X (signed provenance);
/// it is NEVER the retrieval pin. The client resolves `publicationCommit` Y
/// once and fetches every artifact at Y (contract §1.1).
public struct CuratedSkillFeed: Sendable, Equatable {
    public let schemaVersion: Int
    public let publisher: String
    public let channel: CuratedSkillChannel
    public let feedStatus: CuratedSkillFeedStatus
    public let hubRepository: String
    public let sourceCommit: String?
    public let permissionPolicy: CuratedSkillPermissionPolicy
    public let entries: [CuratedSkillEntry]
    public let counts: CuratedSkillCounts
    public let generatedNote: String?

    public static let schemaVersionValue = 3
    public static let publisherValue = "JiangNanGenius"
    public static let hubRepositoryValue = "JiangNanGenius/floe-skill-hub"

    /// Entry lookups by id (feed ids are unique by validation).
    public func entry(id: String) -> CuratedSkillEntry? {
        entries.first { $0.id == id }
    }

    /// Strict decode of the exact feed bytes. Throws
    /// `CuratedSkillHubFailure.feed` for any contract violation; a signed
    /// envelope check happens separately in `CuratedSkillHub.verifiedFeed`
    /// because trust mode is not part of the bytes.
    public static func decode(bytes: Data, expectedChannel: CuratedSkillChannel) throws -> CuratedSkillFeed {
        let root = try CuratedSkillStrictJSON.object(bytes)
        let schemaVersion = try CuratedSkillStrictJSON.integer(root["schemaVersion"], path: "catalog.schemaVersion")
        guard schemaVersion == schemaVersionValue else {
            throw CuratedSkillHubFailure.feed("catalog schemaVersion must be \(schemaVersionValue), found \(schemaVersion)")
        }
        try CuratedSkillStrictJSON.exactKeys(
            root,
            required: ["schemaVersion", "publisher", "channel", "feedStatus", "hubRepository",
                       "sourceCommit", "permissionPolicy", "entries", "counts"],
            optional: ["generatedNote"],
            path: "catalog"
        )
        let publisher = try CuratedSkillStrictJSON.string(root["publisher"], path: "catalog.publisher")
        guard publisher == publisherValue else {
            throw CuratedSkillHubFailure.feed("catalog publisher must be '\(publisherValue)', found '\(publisher)'")
        }
        let channelValue = try CuratedSkillStrictJSON.string(root["channel"], path: "catalog.channel")
        guard let channel = CuratedSkillChannel(rawValue: channelValue) else {
            throw CuratedSkillHubFailure.feed("catalog channel unknown")
        }
        guard channel == expectedChannel else {
            throw CuratedSkillHubFailure.feed("catalog channel '\(channel.rawValue)' does not match the fetched \(expectedChannel.rawValue) channel path")
        }
        let statusValue = try CuratedSkillStrictJSON.string(root["feedStatus"], path: "catalog.feedStatus")
        guard let feedStatus = CuratedSkillFeedStatus(rawValue: statusValue) else {
            throw CuratedSkillHubFailure.feed("catalog feedStatus unknown")
        }
        let hubRepository = try CuratedSkillStrictJSON.string(root["hubRepository"], path: "catalog.hubRepository")
        guard hubRepository == hubRepositoryValue else {
            throw CuratedSkillHubFailure.feed("catalog hubRepository must be '\(hubRepositoryValue)', found '\(hubRepository)'")
        }
        var sourceCommit: String? = nil
        if let commitValue = root["sourceCommit"], !(commitValue is NSNull) {
            sourceCommit = try CuratedSkillStrictJSON.string(commitValue, path: "catalog.sourceCommit")
            guard CuratedSkillStrictJSON.isCommit(sourceCommit!) else {
                throw CuratedSkillHubFailure.feed("catalog sourceCommit must be 40 lowercase hex (audited source revision X)")
            }
        }
        if feedStatus == .production {
            guard sourceCommit != nil else {
                throw CuratedSkillHubFailure.feed("production feeds must bind the audited source commit (X); the publication commit (Y) is resolved externally")
            }
        }
        let policy = try CuratedSkillStrictJSON.permissionPolicy(root["permissionPolicy"], path: "catalog.permissionPolicy")
        guard policy == CuratedSkillPermissionPolicy.contract else {
            throw CuratedSkillHubFailure.feed("catalog permissionPolicy drifted from the fixed contract")
        }
        let entryValues = try CuratedSkillStrictJSON.array(root["entries"], path: "catalog.entries")
        guard !entryValues.isEmpty, entryValues.count <= CuratedSkillHub.maximumEntries else {
            throw CuratedSkillHubFailure.feed("catalog entries must contain 1...\(CuratedSkillHub.maximumEntries) rows")
        }
        var entries: [CuratedSkillEntry] = []
        entries.reserveCapacity(entryValues.count)
        var seenIDs: Set<String> = []
        var seenPlanNumbers: Set<Int> = []
        for (index, value) in entryValues.enumerated() {
            let entry = try CuratedSkillEntryDecoder.decode(
                value, feedChannel: channel, feedStatus: feedStatus,
                path: "catalog.entries[\(index)]")
            guard seenIDs.insert(entry.id).inserted else {
                throw CuratedSkillHubFailure.feed("duplicate entry id '\(entry.id)'")
            }
            guard seenPlanNumbers.insert(entry.planNumber).inserted else {
                throw CuratedSkillHubFailure.feed("duplicate planNumber \(entry.planNumber)")
            }
            entries.append(entry)
        }
        let counts = try CuratedSkillCountsDecoder.decode(
            root["counts"],
            recomputing: entries,
            path: "catalog.counts")
        let generatedNote: String?
        if let note = root["generatedNote"] {
            generatedNote = try CuratedSkillStrictJSON.string(note, path: "catalog.generatedNote")
        } else {
            generatedNote = nil
        }
        return CuratedSkillFeed(
            schemaVersion: schemaVersion, publisher: publisher, channel: channel,
            feedStatus: feedStatus, hubRepository: hubRepository, sourceCommit: sourceCommit,
            permissionPolicy: policy, entries: entries, counts: counts, generatedNote: generatedNote
        )
    }
}

// MARK: - Strict JSON primitives

/// Fail-closed JSON walking: exact key sets, no unknown fields, no silent
/// NSNumber coercion between booleans and integers. Mirrors the hub
/// validator's `set(object) == required` discipline.
enum CuratedSkillStrictJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CuratedSkillHubFailure.feed("payload is not valid JSON: \(error.localizedDescription)")
        }
        guard let object = value as? [String: Any] else {
            throw CuratedSkillHubFailure.feed("payload top level must be a JSON object")
        }
        return object
    }

    static func object(from value: Any?, path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw CuratedSkillHubFailure.feed("\(path) must be a JSON object")
        }
        return object
    }

    static func exactKeys(_ object: [String: Any], required: Set<String>,
                          optional: Set<String> = [], path: String) throws {
        let keys = Set(object.keys)
        if !keys.isSubset(of: required.union(optional)) {
            let unknown = keys.subtracting(required.union(optional)).sorted()
            throw CuratedSkillHubFailure.feed("\(path) has keys outside the contract: \(unknown)")
        }
        if !required.isSubset(of: keys) {
            let missing = required.subtracting(keys).sorted()
            throw CuratedSkillHubFailure.feed("\(path) is missing required keys: \(missing)")
        }
    }

    static func string(_ value: Any?, path: String) throws -> String {
        guard let string = value as? String else {
            throw CuratedSkillHubFailure.feed("\(path) must be a string")
        }
        return string
    }

    static func boolean(_ value: Any?, path: String) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CuratedSkillHubFailure.feed("\(path) must be a boolean")
        }
        return number.boolValue
    }

    static func integer(_ value: Any?, path: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CuratedSkillHubFailure.feed("\(path) must be an integer")
        }
        let double = number.doubleValue
        let int = number.intValue
        guard Double(int) == double else {
            throw CuratedSkillHubFailure.feed("\(path) must be an integral value")
        }
        return int
    }

    static func array(_ value: Any?, path: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw CuratedSkillHubFailure.feed("\(path) must be an array")
        }
        return array
    }

    static func stringArray(_ value: Any?, path: String) throws -> [String] {
        try array(value, path: path).map { try string($0, path: path) }
    }

    static func permissionPolicy(_ value: Any?, path: String) throws -> CuratedSkillPermissionPolicy {
        let object = try object(from: value, path: path)
        try exactKeys(object, required: [
            "automaticInstallWhenReviewedAndGranted", "deltaOnlyApproval",
            "selfApprovalProhibited", "userDisabledAndRemovedPriority", "temporaryTaskCeiling",
        ], path: path)
        return CuratedSkillPermissionPolicy(
            automaticInstallWhenReviewedAndGranted: try boolean(
                object["automaticInstallWhenReviewedAndGranted"], path: "\(path).automaticInstallWhenReviewedAndGranted"),
            deltaOnlyApproval: try boolean(object["deltaOnlyApproval"], path: "\(path).deltaOnlyApproval"),
            selfApprovalProhibited: try boolean(object["selfApprovalProhibited"], path: "\(path).selfApprovalProhibited"),
            userDisabledAndRemovedPriority: try string(
                object["userDisabledAndRemovedPriority"], path: "\(path).userDisabledAndRemovedPriority"),
            temporaryTaskCeiling: try string(object["temporaryTaskCeiling"], path: "\(path).temporaryTaskCeiling")
        )
    }

    /// Bilingual locale object: exactly `{en, zh-Hans}` strings.
    static func localizedText(_ value: Any?, path: String, nonEmpty: Bool) throws -> CuratedSkillLocalizedText {
        let object = try object(from: value, path: path)
        try exactKeys(object, required: ["en", "zh-Hans"], path: path)
        let en = try string(object["en"], path: "\(path).en")
        let zhHans = try string(object["zh-Hans"], path: "\(path).zh-Hans")
        if nonEmpty {
            guard !en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !zhHans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CuratedSkillHubFailure.feed("\(path) requires non-empty en and zh-Hans text")
            }
        }
        return CuratedSkillLocalizedText(en: en, zhHans: zhHans)
    }

    // Character-class validators (ASCII-strict, identical to the hub regexes).

    static func isIdentifier(_ value: String) -> Bool {
        // ^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$ — lowercase first, no "--", no trailing "-".
        guard !value.isEmpty, value.count <= 64,
              let first = value.first, isLowerAlpha(first) else { return false }
        var lastWasDash = false
        for character in value.dropFirst() {
            if character == "-" {
                if lastWasDash { return false }
                lastWasDash = true
            } else if isLowerAlpha(character) || isDigit(character) {
                lastWasDash = false
            } else {
                return false
            }
        }
        return !lastWasDash
    }

    static func isVersion(_ value: String) -> Bool {
        // (0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(isDigit) else { return false }
            if part.count > 1, part.first == "0" { return false }
        }
        return true
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static func isCommit(_ value: String) -> Bool { isHex(value, length: 40) }
    static func isSHA256(_ value: String) -> Bool { isHex(value, length: 64) }

    static func isDate(_ value: String) -> Bool {
        // YYYY-MM-DD with calendar-range month/day components
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(isDigit) }),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    static func isToolName(_ value: String) -> Bool {
        // ^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$
        guard !value.isEmpty, value.count <= 128 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { isAlphaNumeric($0) || $0 == "_" || $0 == "-" }
        }
    }

    static func isTagSlug(_ value: String) -> Bool {
        // ^[a-z0-9][a-z0-9.-]*$
        guard let first = value.first, isLowerAlpha(first) || isDigit(first) else { return false }
        return value.allSatisfy { isLowerAlpha($0) || isDigit($0) || $0 == "." || $0 == "-" }
    }

    static func isGitHubRepositoryURL(_ value: String) -> Bool {
        // ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$
        let prefix = "https://github.com/"
        guard value.hasPrefix(prefix) else { return false }
        let components = value.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
            }
        }
    }

    static func isRepositoryRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isExactPythonSpec(_ value: String) -> Bool {
        // ^[A-Za-z][A-Za-z0-9._-]*==[A-Za-z0-9][A-Za-z0-9._+!-]*$
        let parts = value.components(separatedBy: "==")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        guard let nameFirst = parts[0].first, nameFirst.isASCII, nameFirst.isLetter else { return false }
        guard parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else { return false }
        guard let versionFirst = parts[1].first, versionFirst.isASCII,
              versionFirst.isLetter || versionFirst.isNumber else { return false }
        return parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+!-".contains($0)) }
    }

    private static func isLowerAlpha(_ character: Character) -> Bool {
        character.isASCII && (("a"..."z").contains(character))
    }
    private static func isAlphaNumeric(_ character: Character) -> Bool {
        character.isASCII && (("a"..."z").contains(character) || ("A"..."Z").contains(character) || isDigit(character))
    }
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && (("0"..."9").contains(character))
    }
}

// MARK: - Entry decoding

enum CuratedSkillEntryDecoder {
    static func decode(_ value: Any, feedChannel: CuratedSkillChannel,
                       feedStatus: CuratedSkillFeedStatus, path: String) throws -> CuratedSkillEntry {
        let object = try CuratedSkillStrictJSON.object(from: value, path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "id", "planNumber", "kind", "source", "name", "description", "category", "tags",
            "deepAdaptation", "upstream", "firstParty", "runtime", "version",
            "minimumAppVersion", "status", "notes", "package", "review", "installOffer",
        ], path: path)

        let id = try CuratedSkillStrictJSON.string(object["id"], path: "\(path).id")
        guard CuratedSkillStrictJSON.isIdentifier(id) else {
            throw CuratedSkillHubFailure.feed("\(path).id is not a SkillIdentifier-grammar identifier")
        }
        let planNumber = try CuratedSkillStrictJSON.integer(object["planNumber"], path: "\(path).planNumber")
        guard (1...43).contains(planNumber) else {
            throw CuratedSkillHubFailure.feed("\(path).planNumber must be a 1...43 row")
        }
        guard let kind = CuratedSkillEntryKind(
            rawValue: try CuratedSkillStrictJSON.string(object["kind"], path: "\(path).kind")) else {
            throw CuratedSkillHubFailure.feed("\(path).kind unknown")
        }
        guard let source = CuratedSkillSourceCode(
            rawValue: try CuratedSkillStrictJSON.string(object["source"], path: "\(path).source")) else {
            throw CuratedSkillHubFailure.feed("\(path).source unknown")
        }
        let name = try CuratedSkillStrictJSON.localizedText(object["name"], path: "\(path).name", nonEmpty: true)
        let description = try CuratedSkillStrictJSON.localizedText(object["description"], path: "\(path).description", nonEmpty: true)
        guard let category = CuratedSkillCategory(
            rawValue: try CuratedSkillStrictJSON.string(object["category"], path: "\(path).category")) else {
            throw CuratedSkillHubFailure.feed("\(path).category unknown")
        }
        let tags = try CuratedSkillStrictJSON.stringArray(object["tags"], path: "\(path).tags")
        guard (2...12).contains(tags.count), Set(tags).count == tags.count,
              tags.allSatisfy(CuratedSkillStrictJSON.isTagSlug) else {
            throw CuratedSkillHubFailure.feed("\(path).tags must be 2-12 unique lowercase slugs")
        }
        let deepAdaptation = try CuratedSkillStrictJSON.boolean(object["deepAdaptation"], path: "\(path).deepAdaptation")
        let upstream = try decodeUpstream(object["upstream"], path: "\(path).upstream")
        let firstParty = try decodeFirstParty(object["firstParty"], path: "\(path).firstParty")
        if upstream != nil && firstParty != nil {
            throw CuratedSkillHubFailure.feed("\(path): upstream and firstParty pins are mutually exclusive")
        }
        let runtime = try decodeRuntime(object["runtime"], feedChannel: feedChannel, path: "\(path).runtime")
        let version = try CuratedSkillStrictJSON.string(object["version"], path: "\(path).version")
        guard CuratedSkillStrictJSON.isVersion(version) else {
            throw CuratedSkillHubFailure.feed("\(path).version must be strict X.Y.Z")
        }
        let minimumAppVersion: String?
        if let value = object["minimumAppVersion"], !(value is NSNull) {
            let candidate = try CuratedSkillStrictJSON.string(value, path: "\(path).minimumAppVersion")
            guard CuratedSkillStrictJSON.isVersion(candidate) else {
                throw CuratedSkillHubFailure.feed("\(path).minimumAppVersion must be strict X.Y.Z")
            }
            minimumAppVersion = candidate
        } else {
            minimumAppVersion = nil
        }
        let status = try decodeStatus(object["status"], path: "\(path).status")
        let notes = try CuratedSkillStrictJSON.localizedText(object["notes"], path: "\(path).notes", nonEmpty: false)
        let package = try decodePackage(object["package"], id: id, version: version,
                                        feedChannel: feedChannel, path: "\(path).package")
        if package != nil {
            guard minimumAppVersion != nil else {
                throw CuratedSkillHubFailure.feed("\(path): packaged entries require minimumAppVersion")
            }
        }
        let review = try decodeReview(object["review"], id: id, version: version,
                                      feedStatus: feedStatus, path: "\(path).review")
        if package == nil && review != nil {
            throw CuratedSkillHubFailure.feed("\(path): a review binding requires a package")
        }
        if status.reviewed && review == nil {
            throw CuratedSkillHubFailure.feed("\(path): reviewed status requires a review binding")
        }
        if status.qualified && (package == nil || review == nil) {
            throw CuratedSkillHubFailure.feed("\(path): qualified status requires package and review")
        }
        guard let offer = CuratedSkillInstallOffer(
            rawValue: try CuratedSkillStrictJSON.string(object["installOffer"], path: "\(path).installOffer")) else {
            throw CuratedSkillHubFailure.feed("\(path).installOffer unknown")
        }
        switch offer {
        case .qualified:
            guard feedStatus == .production else {
                throw CuratedSkillHubFailure.feed("\(path): qualified offers never appear in fixture feeds")
            }
            guard package != nil, review != nil else {
                throw CuratedSkillHubFailure.feed("\(path): qualified offers require package and review")
            }
            guard status.qualified else {
                throw CuratedSkillHubFailure.feed("\(path): qualified offer without qualified status")
            }
        case .fixtureSimulated:
            guard feedStatus == .fixture else {
                throw CuratedSkillHubFailure.feed("\(path): fixture offers require a fixture feed")
            }
            guard id.hasPrefix("fixture-") else {
                throw CuratedSkillHubFailure.feed("\(path): fixture offers require fixture- ids")
            }
        case .none:
            break
        }
        return CuratedSkillEntry(
            id: id, planNumber: planNumber, kind: kind, source: source, name: name,
            description: description, category: category, tags: tags, deepAdaptation: deepAdaptation,
            upstream: upstream, firstParty: firstParty, runtime: runtime, version: version,
            minimumAppVersion: minimumAppVersion, status: status, notes: notes,
            package: package, review: review, installOffer: offer
        )
    }

    private static func decodeUpstream(_ value: Any?, path: String) throws -> CuratedSkillUpstreamPin? {
        guard let value, !(value is NSNull) else { return nil }
        let object = try CuratedSkillStrictJSON.object(from: value, path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "repository", "commit", "path", "skillManifestPath", "retrievedAt",
            "licenseStatus", "licenseEvidencePath", "repositoryLicense", "licenseNote",
        ], optional: ["authoringPath"], path: path)
        let repository = try CuratedSkillStrictJSON.string(object["repository"], path: "\(path).repository")
        guard CuratedSkillStrictJSON.isGitHubRepositoryURL(repository) else {
            throw CuratedSkillHubFailure.feed("\(path).repository must be an https GitHub repository URL")
        }
        let commit = try CuratedSkillStrictJSON.string(object["commit"], path: "\(path).commit")
        guard CuratedSkillStrictJSON.isCommit(commit) else {
            throw CuratedSkillHubFailure.feed("\(path).commit must be 40 lowercase hex (review baseline pin)")
        }
        let skillPath = try CuratedSkillStrictJSON.string(object["path"], path: "\(path).path")
        guard CuratedSkillStrictJSON.isRepositoryRelativePath(skillPath), !skillPath.hasPrefix(".") else {
            throw CuratedSkillHubFailure.feed("\(path).path must be a clean repository-relative path")
        }
        let manifestPath = try CuratedSkillStrictJSON.string(object["skillManifestPath"], path: "\(path).skillManifestPath")
        guard CuratedSkillStrictJSON.isRepositoryRelativePath(manifestPath) else {
            throw CuratedSkillHubFailure.feed("\(path).skillManifestPath must be a clean repository-relative path")
        }
        let retrievedAt = try CuratedSkillStrictJSON.string(object["retrievedAt"], path: "\(path).retrievedAt")
        guard CuratedSkillStrictJSON.isDate(retrievedAt) else {
            throw CuratedSkillHubFailure.feed("\(path).retrievedAt must be YYYY-MM-DD")
        }
        guard let licenseStatus = CuratedSkillUpstreamLicenseStatus(
            rawValue: try CuratedSkillStrictJSON.string(object["licenseStatus"], path: "\(path).licenseStatus")) else {
            throw CuratedSkillHubFailure.feed("\(path).licenseStatus unknown")
        }
        let evidencePath: String?
        if let evidence = object["licenseEvidencePath"], !(evidence is NSNull) {
            evidencePath = try CuratedSkillStrictJSON.string(evidence, path: "\(path).licenseEvidencePath")
        } else {
            evidencePath = nil
        }
        let repositoryLicense = try CuratedSkillStrictJSON.string(object["repositoryLicense"], path: "\(path).repositoryLicense")
        let licenseNote = try CuratedSkillStrictJSON.localizedText(object["licenseNote"], path: "\(path).licenseNote", nonEmpty: true)
        let authoringPath: String?
        if let value = object["authoringPath"], !(value is NSNull) {
            authoringPath = try CuratedSkillStrictJSON.string(value, path: "\(path).authoringPath")
        } else {
            authoringPath = nil
        }
        return CuratedSkillUpstreamPin(
            repository: repository, commit: commit, path: skillPath, skillManifestPath: manifestPath,
            retrievedAt: retrievedAt, licenseStatus: licenseStatus, licenseEvidencePath: evidencePath,
            repositoryLicense: repositoryLicense, licenseNote: licenseNote,
            authoringPath: authoringPath
        )
    }

    private static func decodeFirstParty(_ value: Any?, path: String) throws -> CuratedSkillFirstPartyPin? {
        guard let value, !(value is NSNull) else { return nil }
        let object = try CuratedSkillStrictJSON.object(from: value, path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "repository", "commit", "path", "skillManifestPath", "retrievedAt",
            "licenseStatus", "licenseEvidencePath", "releasedVersion", "stagedSourceVersion",
        ], path: path)
        let repository = try CuratedSkillStrictJSON.string(object["repository"], path: "\(path).repository")
        let commit = try CuratedSkillStrictJSON.string(object["commit"], path: "\(path).commit")
        guard CuratedSkillStrictJSON.isCommit(commit) else {
            throw CuratedSkillHubFailure.feed("\(path).commit must be 40 lowercase hex")
        }
        let skillPath = try CuratedSkillStrictJSON.string(object["path"], path: "\(path).path")
        guard CuratedSkillStrictJSON.isRepositoryRelativePath(skillPath) else {
            throw CuratedSkillHubFailure.feed("\(path).path must be a clean repository-relative path")
        }
        let manifestPath = try CuratedSkillStrictJSON.string(object["skillManifestPath"], path: "\(path).skillManifestPath")
        guard CuratedSkillStrictJSON.isRepositoryRelativePath(manifestPath) else {
            throw CuratedSkillHubFailure.feed("\(path).skillManifestPath must be a clean repository-relative path")
        }
        let retrievedAt = try CuratedSkillStrictJSON.string(object["retrievedAt"], path: "\(path).retrievedAt")
        guard CuratedSkillStrictJSON.isDate(retrievedAt) else {
            throw CuratedSkillHubFailure.feed("\(path).retrievedAt must be YYYY-MM-DD")
        }
        let licenseStatus = try CuratedSkillStrictJSON.string(object["licenseStatus"], path: "\(path).licenseStatus")
        guard licenseStatus == "floe-owned" else {
            throw CuratedSkillHubFailure.feed("\(path).licenseStatus must be 'floe-owned'")
        }
        let evidencePath: String?
        if let evidence = object["licenseEvidencePath"], !(evidence is NSNull) {
            evidencePath = try CuratedSkillStrictJSON.string(evidence, path: "\(path).licenseEvidencePath")
        } else {
            evidencePath = nil
        }
        func optionalVersion(_ value: Any?, _ name: String) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            let candidate = try CuratedSkillStrictJSON.string(value, path: "\(path).\(name)")
            guard CuratedSkillStrictJSON.isVersion(candidate) else {
                throw CuratedSkillHubFailure.feed("\(path).\(name) must be strict X.Y.Z")
            }
            return candidate
        }
        let releasedVersion = try optionalVersion(object["releasedVersion"], "releasedVersion")
        let stagedSourceVersion = try optionalVersion(object["stagedSourceVersion"], "stagedSourceVersion")
        return CuratedSkillFirstPartyPin(
            repository: repository, commit: commit, path: skillPath, skillManifestPath: manifestPath,
            retrievedAt: retrievedAt, licenseEvidencePath: evidencePath,
            releasedVersion: releasedVersion, stagedSourceVersion: stagedSourceVersion
        )
    }

    private static func decodeRuntime(_ value: Any?, feedChannel: CuratedSkillChannel, path: String) throws -> CuratedSkillRuntime {
        let object = try CuratedSkillStrictJSON.object(from: value ?? NSNull(), path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "scriptRuntime", "capabilities", "tools", "installPlatforms",
            "pythonPackagesPlan", "execution",
        ], path: path)
        guard let scriptRuntime = SkillScriptRuntime(
            rawValue: try CuratedSkillStrictJSON.string(object["scriptRuntime"], path: "\(path).scriptRuntime")) else {
            throw CuratedSkillHubFailure.feed("\(path).scriptRuntime unknown")
        }
        let capabilityValues = try CuratedSkillStrictJSON.stringArray(object["capabilities"], path: "\(path).capabilities")
        guard Set(capabilityValues).count == capabilityValues.count else {
            throw CuratedSkillHubFailure.feed("\(path).capabilities must be unique")
        }
        for capability in capabilityValues where SkillCapability(rawValue: capability) == nil {
            throw CuratedSkillHubFailure.feed("\(path).capabilities contains a value outside the native enum: \(capability)")
        }
        let toolValues = try CuratedSkillStrictJSON.stringArray(object["tools"], path: "\(path).tools")
        guard Set(toolValues).count == toolValues.count,
              toolValues.allSatisfy(CuratedSkillStrictJSON.isToolName) else {
            throw CuratedSkillHubFailure.feed("\(path).tools must be unique dotted names")
        }
        let platformValues = try CuratedSkillStrictJSON.stringArray(object["installPlatforms"], path: "\(path).installPlatforms")
        guard !platformValues.isEmpty, Set(platformValues).count == platformValues.count else {
            throw CuratedSkillHubFailure.feed("\(path).installPlatforms must be non-empty and unique")
        }
        var installPlatforms: [CuratedSkillChannel] = []
        for platform in platformValues {
            guard let channel = CuratedSkillChannel(rawValue: platform) else {
                throw CuratedSkillHubFailure.feed("\(path).installPlatforms contains a value outside the store channels: \(platform)")
            }
            installPlatforms.append(channel)
        }
        guard installPlatforms.contains(feedChannel) else {
            throw CuratedSkillHubFailure.feed("\(path): entry installPlatforms must include the feed channel '\(feedChannel.rawValue)'")
        }
        let pythonPackagesPlan = try CuratedSkillStrictJSON.stringArray(
            object["pythonPackagesPlan"], path: "\(path).pythonPackagesPlan")
        let execution = try decodeExecution(object["execution"], path: "\(path).execution")
        return CuratedSkillRuntime(
            scriptRuntime: scriptRuntime, capabilities: capabilityValues, tools: toolValues,
            installPlatforms: installPlatforms, pythonPackagesPlan: pythonPackagesPlan, execution: execution
        )
    }

    static func decodeExecution(_ value: Any?, path: String) throws -> CuratedSkillExecution {
        let object = try CuratedSkillStrictJSON.object(from: value ?? NSNull(), path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: ["os", "arch", "evidence"], path: path)
        let operatingSystem: String?
        if let os = object["os"], !(os is NSNull) {
            let candidate = try CuratedSkillStrictJSON.string(os, path: "\(path).os")
            guard ["linux", "macos", "ios"].contains(candidate) else {
                throw CuratedSkillHubFailure.feed("\(path).os outside the execution enum (store channels are a different plane)")
            }
            operatingSystem = candidate
        } else {
            operatingSystem = nil
        }
        let architecture: String?
        if let arch = object["arch"], !(arch is NSNull) {
            let candidate = try CuratedSkillStrictJSON.string(arch, path: "\(path).arch")
            guard ["riscv64", "x86_64", "aarch64", "n/a"].contains(candidate) else {
                throw CuratedSkillHubFailure.feed("\(path).arch outside the execution enum")
            }
            architecture = candidate
        } else {
            architecture = nil
        }
        guard let evidence = CuratedSkillExecutionEvidence(
            rawValue: try CuratedSkillStrictJSON.string(object["evidence"], path: "\(path).evidence")) else {
            throw CuratedSkillHubFailure.feed("\(path).evidence unknown")
        }
        return CuratedSkillExecution(os: operatingSystem, arch: architecture, evidence: evidence)
    }

    private static func decodeStatus(_ value: Any?, path: String) throws -> CuratedSkillStatus {
        let object = try CuratedSkillStrictJSON.object(from: value ?? NSNull(), path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "sourcePinned", "licenseChecked", "adaptation", "packaged",
            "reviewed", "qualified", "published", "executionVerified",
        ], path: path)
        guard let adaptation = CuratedSkillAdaptationStage(
            rawValue: try CuratedSkillStrictJSON.string(object["adaptation"], path: "\(path).adaptation")) else {
            throw CuratedSkillHubFailure.feed("\(path).adaptation unknown")
        }
        let status = CuratedSkillStatus(
            sourcePinned: try CuratedSkillStrictJSON.boolean(object["sourcePinned"], path: "\(path).sourcePinned"),
            licenseChecked: try CuratedSkillStrictJSON.boolean(object["licenseChecked"], path: "\(path).licenseChecked"),
            adaptation: adaptation,
            packaged: try CuratedSkillStrictJSON.boolean(object["packaged"], path: "\(path).packaged"),
            reviewed: try CuratedSkillStrictJSON.boolean(object["reviewed"], path: "\(path).reviewed"),
            qualified: try CuratedSkillStrictJSON.boolean(object["qualified"], path: "\(path).qualified"),
            published: try CuratedSkillStrictJSON.boolean(object["published"], path: "\(path).published"),
            executionVerified: try CuratedSkillStrictJSON.boolean(object["executionVerified"], path: "\(path).executionVerified")
        )
        if status.reviewed && !status.licenseChecked {
            throw CuratedSkillHubFailure.feed("\(path): reviewed entries require a completed license check")
        }
        if status.qualified && !(status.reviewed && status.packaged) {
            throw CuratedSkillHubFailure.feed("\(path): qualified requires reviewed and packaged")
        }
        if status.published && !status.qualified {
            throw CuratedSkillHubFailure.feed("\(path): published requires qualified")
        }
        if status.executionVerified && adaptation != .frozen {
            throw CuratedSkillHubFailure.feed("\(path): executionVerified requires frozen adaptation")
        }
        if status.packaged && adaptation != .frozen && adaptation != .inProgress {
            throw CuratedSkillHubFailure.feed("\(path): packaged requires adaptation in-progress or frozen")
        }
        return status
    }

    private static func decodePackage(_ value: Any?, id: String, version: String,
                                      feedChannel: CuratedSkillChannel, path: String) throws -> CuratedSkillPackageBinding? {
        guard let value, !(value is NSNull) else { return nil }
        let object = try CuratedSkillStrictJSON.object(from: value, path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "path", "size", "sha256", "contentDigest", "containsScripts",
        ], path: path)
        let archivePath = try CuratedSkillStrictJSON.string(object["path"], path: "\(path).path")
        let prefix = feedChannel == .ios ? "" : "\(feedChannel.rawValue)/"
        let expected = "\(prefix)packages/\(id)/\(version)/\(id).zip"
        guard archivePath == expected else {
            throw CuratedSkillHubFailure.feed("\(path).path must be '\(expected)'")
        }
        let size = try CuratedSkillStrictJSON.integer(object["size"], path: "\(path).size")
        guard (1...8_388_608).contains(size) else {
            throw CuratedSkillHubFailure.feed("\(path).size must be within 1...8 MiB")
        }
        let sha256 = try CuratedSkillStrictJSON.string(object["sha256"], path: "\(path).sha256")
        guard CuratedSkillStrictJSON.isSHA256(sha256) else {
            throw CuratedSkillHubFailure.feed("\(path).sha256 must be 64 lowercase hex")
        }
        let contentDigest = try CuratedSkillStrictJSON.string(object["contentDigest"], path: "\(path).contentDigest")
        guard CuratedSkillStrictJSON.isSHA256(contentDigest) else {
            throw CuratedSkillHubFailure.feed("\(path).contentDigest must be 64 lowercase hex")
        }
        let containsScripts = try CuratedSkillStrictJSON.boolean(object["containsScripts"], path: "\(path).containsScripts")
        return CuratedSkillPackageBinding(path: archivePath, size: size, sha256: sha256,
                                          contentDigest: contentDigest, containsScripts: containsScripts)
    }

    private static func decodeReview(_ value: Any?, id: String, version: String,
                                     feedStatus: CuratedSkillFeedStatus, path: String) throws -> CuratedSkillReviewBinding? {
        guard let value, !(value is NSNull) else { return nil }
        let object = try CuratedSkillStrictJSON.object(from: value, path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: ["path", "sha256", "keyID"], path: path)
        let reviewPath = try CuratedSkillStrictJSON.string(object["path"], path: "\(path).path")
        let expected = "reviews/\(id)/\(version).review.json"
        guard reviewPath == expected else {
            throw CuratedSkillHubFailure.feed("\(path).path must be '\(expected)'")
        }
        let sha256 = try CuratedSkillStrictJSON.string(object["sha256"], path: "\(path).sha256")
        guard CuratedSkillStrictJSON.isSHA256(sha256) else {
            throw CuratedSkillHubFailure.feed("\(path).sha256 must be 64 lowercase hex")
        }
        let keyID = try CuratedSkillStrictJSON.string(object["keyID"], path: "\(path).keyID")
        switch feedStatus {
        case .production:
            guard keyID != CuratedSkillHub.fixtureKeyID else {
                throw CuratedSkillHubFailure.feed("\(path): a fixture review can never back a production entry")
            }
        case .fixture:
            guard keyID == CuratedSkillHub.fixtureKeyID else {
                throw CuratedSkillHubFailure.feed("\(path): fixture feeds only bind fixture reviews")
            }
        }
        return CuratedSkillReviewBinding(path: reviewPath, sha256: sha256, keyID: keyID)
    }
}

// MARK: - Counts decoding

enum CuratedSkillCountsDecoder {
    static func decode(_ value: Any?, recomputing entries: [CuratedSkillEntry], path: String) throws -> CuratedSkillCounts {
        let object = try CuratedSkillStrictJSON.object(from: value ?? NSNull(), path: path)
        try CuratedSkillStrictJSON.exactKeys(object, required: [
            "total", "builtin", "optional", "deepAdaptation", "packaged", "reviewed", "qualified", "offerQualified",
        ], path: path)
        let counts = CuratedSkillCounts(
            total: try CuratedSkillStrictJSON.integer(object["total"], path: "\(path).total"),
            builtin: try CuratedSkillStrictJSON.integer(object["builtin"], path: "\(path).builtin"),
            optional: try CuratedSkillStrictJSON.integer(object["optional"], path: "\(path).optional"),
            deepAdaptation: try CuratedSkillStrictJSON.integer(object["deepAdaptation"], path: "\(path).deepAdaptation"),
            packaged: try CuratedSkillStrictJSON.integer(object["packaged"], path: "\(path).packaged"),
            reviewed: try CuratedSkillStrictJSON.integer(object["reviewed"], path: "\(path).reviewed"),
            qualified: try CuratedSkillStrictJSON.integer(object["qualified"], path: "\(path).qualified"),
            offerQualified: try CuratedSkillStrictJSON.integer(object["offerQualified"], path: "\(path).offerQualified")
        )
        let recomputed = CuratedSkillCounts(
            total: entries.count,
            builtin: entries.filter { $0.kind == .builtin }.count,
            optional: entries.filter { $0.kind == .optional }.count,
            deepAdaptation: entries.filter { $0.deepAdaptation }.count,
            packaged: entries.filter { $0.package != nil }.count,
            reviewed: entries.filter { $0.review != nil }.count,
            qualified: entries.filter { $0.status.qualified }.count,
            offerQualified: entries.filter { $0.installOffer == .qualified }.count
        )
        guard counts == recomputed else {
            throw CuratedSkillHubFailure.feed("\(path) drifted from the entries: declared \(counts) != recomputed \(recomputed)")
        }
        return counts
    }
}

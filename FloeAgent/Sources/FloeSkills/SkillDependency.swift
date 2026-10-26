// FloeSkills — managed official Skill dependency declaration v1 (strict, fail-closed).
//
// Contract: `references/dependencies.json` inside a canonical Skill package declares
// the resources the official Skill Hub installation flow may automatically prepare
// and install into the task's resolved Linux guest environment. The channel is
// reviewed/signed only: the bytes live inside the canonical package, so the package
// `contentDigest` and the review `.sig` binding already cover the declaration and
// every referenced lock — no external hashes exist in this file's trust path.
//
// Version management (four frozen distinctions; the package id/version stays the
// single user-visible authority):
//   1. Skill package version — floe.json `id`/`version`. Released bytes are immutable:
//      any change to scripts, dependencies or permissions requires a NEW package
//      version and a NEW signed digest. Bytes are never replaced under a published
//      same version; the curated receipt digest equality (existing authority gates)
//      fails a same-id/same-version bytes-mismatch closed.
//   2. `schemaVersion` — parser compatibility ONLY. This build accepts exactly 1; a
//      newer unknown value fails compatibility instead of being guessed, and never
//      breaks reading, staging or the rest of the skill.
//   3. Exact resource versions + locks — per-requirement pins, wheel sha256s in the
//      referenced pip lock, and the pinned component descriptor's own facts. These
//      are what gets installed and read back; no ranges, no `latest`, no silent
//      downgrade, no hidden same-version dependency refresh.
//   4. `minimumAppVersion` — the existing hub-entry old-client gate, raised by the
//      publisher to the first capable build (candidate 1.7.60); the component
//      descriptor keeps its own gate unchanged.
//
// Trust rules (declaration is DATA, never authority):
// - Decoded only from bytes of the digest-verified official curated snapshot; the
//   caller (SkillsCenter + the app-side preparation center) establishes installed +
//   enabled + typed receipt + grant authority on every use.
// - Exact key sets per object and per tagged `kind`. There is NO URL, command,
//   script, environment, registry/index, permission or approval field anywhere, so a
//   declaration can never mint a shell command, redirect a download, or widen an
//   approval. Unknown fields fail closed.
// - The runtime component requirement references ONLY the frozen descriptor path
//   (`references/engine-dependency.json`) whose own strict decoder + allowlist
//   (today exactly `impeccable-engine`) stays authoritative; this contract does not
//   broaden the component allowlist, its artifact caps, or its nonblocking hook.
// - Ordinary Skill package limits are untouched: this file is bounded inert data for
//   old clients and adds no new artifact allowance.

import Foundation
import CoreFoundation
import FloeCore

/// Fail-closed outcomes of declaration decoding and package cross-validation.
/// Every case carries a model-safe reason; none exposes a host path.
public enum SkillDependencyError: Error, Equatable, Sendable, LocalizedError {
    case invalidJSON(String)
    case missingFields([String])
    case unknownFields([String])
    case invalidField(String)
    case unsupportedSchemaVersion(Int)
    case tooManyProfiles(Int)
    case tooManyRequirements(Int)
    case duplicateProfileID(String)
    case duplicateRequirement(String)
    case unsupportedKind(String)
    case unsupportedTarget(String)
    case lockPathRejected(String)
    case descriptorPathRejected(String)
    case lockFileMissing(String)
    case descriptorFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason): "The dependency declaration is not valid JSON: \(reason)"
        case .missingFields(let fields): "The dependency declaration is missing required fields: \(fields.sorted().joined(separator: ", "))"
        case .unknownFields(let fields): "The dependency declaration has fields outside the contract: \(fields.sorted().joined(separator: ", "))"
        case .invalidField(let field): "The dependency declaration field '\(field)' has an invalid value"
        case .unsupportedSchemaVersion(let version): "The dependency declaration schemaVersion \(version) is newer than this build supports (1); provisioning is unavailable until a capable app is installed"
        case .tooManyProfiles(let count): "The dependency declaration carries \(count) profiles; at most 8 are allowed"
        case .tooManyRequirements(let count): "A dependency profile carries \(count) requirements; at most 32 are allowed"
        case .duplicateProfileID(let id): "Dependency profile id '\(id)' is declared more than once"
        case .duplicateRequirement(let key): "Dependency requirement '\(key)' is declared more than once in one profile"
        case .unsupportedKind(let kind): "Dependency requirement kind '\(kind)' is not one of pip, apt, npm, font or runtimeComponent"
        case .unsupportedTarget(let value): "The dependency target '\(value)' cannot be provisioned in this build"
        case .lockPathRejected(let path): "The dependency lock path '\(path)' is outside the package-local references contract"
        case .descriptorPathRejected(let path): "The runtime-component descriptor path '\(path)' is not the frozen references/engine-dependency.json"
        case .lockFileMissing(let path): "The declared dependency lock file '\(path)' is not present in the package"
        case .descriptorFileMissing(let path): "The declared runtime-component descriptor '\(path)' is not present in the package"
        }
    }
}

/// One decoded dependency requirement. `kind` selects the exact field set the strict
/// decoder accepted; per-kind fields that do not exist in the schema are simply absent.
public struct SkillDependencyRequirement: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case pip
        case apt
        case npm
        case font
        case runtimeComponent

        /// Exact key set per tagged kind (top-level requirement keys).
        var exactKeys: [String] {
            switch self {
            case .pip: ["kind", "name", "version", "purpose", "required", "lockfile"]
            case .apt: ["kind", "name", "version", "purpose", "required"]
            case .npm: ["kind", "name", "version", "purpose", "required"]
            case .font: ["kind", "name", "version", "purpose", "required"]
            case .runtimeComponent: ["kind", "componentDescriptorPath", "purpose", "required"]
            }
        }
    }

    public let kind: Kind
    /// Distribution / Debian identity / npm name / font apt identity. The
    /// runtimeComponent kind carries the pinned descriptor's componentID here
    /// after cross-validation; it never comes from the requirement bytes.
    public let name: String
    /// Exact single-version pin. Absent only for the `font` kind (the apt
    /// identity plus the fixed CJK probe are the pin).
    public let version: String?
    public let purpose: String
    public let required: Bool
    /// Package-local lock reference (pip kind only), e.g.
    /// `references/requirements.lock.txt`. Covered by the package digest.
    public let lockfile: String?
    /// Frozen runtime-component descriptor path (runtimeComponent kind only).
    public let componentDescriptorPath: String?

    /// Stable identity key used for uniqueness, receipts and readback.
    public var identityKey: String { "\(kind.rawValue):\(name)" }

    /// The exact managed pip spec (`name==version`).
    public var pipSpec: String? { kind == .pip ? "\(name)==\(version ?? "")" : nil }
    /// The exact Debian pin argument (`name=version`). Both the `apt` kind and
    /// the `font` kind carry an exact Debian version (v1 has no unversioned
    /// exception): a font requirement is an exact apt identity+version pin plus
    /// the fixed CJK availability probe as its readiness gate, and the receipt
    /// records the version bytes verbatim.
    public var aptPin: String? {
        (kind == .apt || kind == .font) ? "\(name)=\(version ?? "")" : nil
    }
    /// The exact npm spec (`name@version`).
    public var npmSpec: String? { kind == .npm ? "\(name)@\(version ?? "")" : nil }
}

/// One decoded profile: an id, a Linux target with allowed architectures, and its
/// requirements.
public struct SkillDependencyProfile: Sendable, Equatable, Codable {
    public let id: String
    public let os: String
    public let architectures: [String]
    public let requirements: [SkillDependencyRequirement]
}

/// The whole decoded declaration. Immutable after strict decode.
public struct SkillDependencyDeclaration: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let profiles: [SkillDependencyProfile]
}

public enum SkillDependency {
    /// Repository-relative path of the declaration inside the canonical package.
    public static let packagePath = "references/dependencies.json"

    /// Bounded declaration read (the published declarations are < 4 KiB).
    public static let maximumDeclarationBytes = 65_536

    // Frozen v1 constants.
    public static let frozenSchemaVersion = 1
    public static let maximumProfiles = 8
    public static let maximumRequirementsPerProfile = 32
    public static let maximumPurposeBytes = 200
    public static let frozenTargetOS = "linux"
    public static let supportedArchitectures: Set<String> = ["riscv64", "arm64", "x86_64", "any"]

    /// The first app version whose native provisioning honors this contract. The
    /// publisher raises a dependency-carrying curated entry's existing
    /// `minimumAppVersion` to at least this value (old-client gate); the native side
    /// does NOT self-gate on it, and no second user-visible version counter is
    /// introduced.
    public static let minimumCapableAppVersion = "1.7.60"

    /// True when `appVersion` parses and is >= `minimumCapableAppVersion`.
    public static func isProvisioningCapable(appVersion: String) -> Bool {
        SkillRuntimeDependency.isCompatible(
            minimumAppVersion: minimumCapableAppVersion, appVersion: appVersion
        )
    }

    /// The frozen runtime-component descriptor path a v1 declaration may reference.
    public static let componentDescriptorPath = SkillRuntimeDependency.engineDependencyPackagePath

    // MARK: - Patterns (ASCII strict; `Character.isNumber` Unicode numerals never pass)

    static func isASCIIDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    static func matchesAsciiPattern(_ value: String, ascii: Set<UInt8>, first: Set<UInt8>, maxCount: Int) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maxCount else { return false }
        guard first.contains(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { ascii.contains($0) }
    }

    private static func characterSet(_ ranges: [ClosedRange<UInt8>], extra: [UInt8] = []) -> Set<UInt8> {
        var set = Set<UInt8>()
        for range in ranges { set.formUnion(range) }
        set.formUnion(extra)
        return set
    }

    private static let asciiLower = ClosedRange(uncheckedBounds: (UInt8(ascii: "a"), UInt8(ascii: "z")))
    private static let asciiUpper = ClosedRange(uncheckedBounds: (UInt8(ascii: "A"), UInt8(ascii: "Z")))
    private static let asciiDigits = ClosedRange(uncheckedBounds: (UInt8(ascii: "0"), UInt8(ascii: "9")))

    // PyPI name `[A-Za-z0-9][A-Za-z0-9._-]*` (extras/brackets rejected); exact
    // PEP 440 version tail additionally allows `* + !` (epoch `!`, local `+`).
    private static let pipNameFirst: Set<UInt8> = characterSet([asciiLower, asciiUpper, asciiDigits])
    private static let pipNameRest: Set<UInt8> = characterSet(
        [asciiLower, asciiUpper, asciiDigits],
        extra: [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")]
    )
    private static let pipVersionFirst = pipNameFirst
    private static let pipVersionRest: Set<UInt8> = pipNameRest.union([
        UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "!")
    ])
    // Debian identity `[a-z0-9][a-z0-9+._-]*`.
    private static let aptNameFirst: Set<UInt8> = characterSet([asciiLower, asciiDigits])
    private static let aptNameRest: Set<UInt8> = characterSet(
        [asciiLower, asciiDigits],
        extra: [UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")]
    )
    // Debian version body: alphanumerics plus `+ . : ~ -` (epoch `:` and tilde
    // ordering stay verbatim inside the pin; `/` and spaces never pass).
    private static let aptVersionFirst: Set<UInt8> = characterSet([asciiLower, asciiUpper, asciiDigits])
    private static let aptVersionRest: Set<UInt8> = characterSet(
        [asciiLower, asciiUpper, asciiDigits],
        extra: [UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "~"), UInt8(ascii: "-")]
    )
    // npm name `(name|@scope/name)` lowercase charset; version `X.Y.Z[-tail]`.
    private static let npmNameFirst: Set<UInt8> = characterSet(
        [asciiLower, asciiDigits], extra: [UInt8(ascii: "-"), UInt8(ascii: "~")]
    )
    private static let npmNameRest: Set<UInt8> = characterSet(
        [asciiLower, asciiDigits],
        extra: [UInt8(ascii: "-"), UInt8(ascii: "~"), UInt8(ascii: "."), UInt8(ascii: "_")]
    )

    /// PyPI distribution name: `[A-Za-z0-9][A-Za-z0-9._-]*` (extras not allowed).
    public static func isValidPipName(_ value: String) -> Bool {
        matchesAsciiPattern(value, ascii: pipNameRest, first: pipNameFirst, maxCount: 128)
    }

    /// Single exact PEP 440 version: `[A-Za-z0-9][A-Za-z0-9.*+!_-]*`, and it
    /// must contain at least one ASCII digit — floating aliases (`latest`,
    /// `stable`, …) can never pass a real pin.
    public static func isValidPipVersion(_ value: String) -> Bool {
        guard value.utf8.contains(where: { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return false
        }
        return matchesAsciiPattern(value, ascii: pipVersionRest, first: pipVersionFirst, maxCount: 128)
    }

    /// Debian package identity: `[a-z0-9][a-z0-9+._-]*`.
    public static func isValidAptName(_ value: String) -> Bool {
        matchesAsciiPattern(value, ascii: aptNameRest, first: aptNameFirst, maxCount: 128)
    }

    /// Exact Debian version with optional `epoch:` prefix:
    /// `([0-9]+:)?[A-Za-z0-9][A-Za-z0-9+~:.+-]*`. `+dfsg`/`-rev`/`+tilde` stay
    /// part of the pin.
    public static func isValidAptVersion(_ value: String) -> Bool {
        var body = Substring(value)
        if let colon = value.firstIndex(of: ":") {
            let epoch = value[value.startIndex..<colon]
            guard isASCIIDigits(epoch) else { return false }
            body = value[value.index(after: colon)...]
        }
        // Every real Debian version body carries a digit; require one AFTER
        // the epoch so floating aliases ("latest", "stable", even "1:latest")
        // can never masquerade as an exact pin. v1 has no unversioned
        // exception for fonts either.
        let bytes = Array(body.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              bytes.contains(where: { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return false }
        return aptVersionFirst.contains(bytes[0])
            && bytes.dropFirst().allSatisfy { aptVersionRest.contains($0) }
    }

    /// npm package name, optionally scoped: `(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*`.
    public static func isValidNpmName(_ value: String) -> Bool {
        if value.hasPrefix("@") {
            let body = value.dropFirst()
            guard let slash = body.firstIndex(of: "/") else { return false }
            let scope = body[..<slash]
            let name = body[body.index(after: slash)...]
            return matchesAsciiPattern(String(scope), ascii: npmNameRest, first: npmNameFirst, maxCount: 64)
                && !name.isEmpty
                && matchesAsciiPattern(String(name), ascii: npmNameRest, first: npmNameFirst, maxCount: 128)
                && !value.utf8.contains(UInt8(ascii: " "))
        }
        return matchesAsciiPattern(value, ascii: npmNameRest, first: npmNameFirst, maxCount: 128)
    }

    /// Exact semver: `X.Y.Z` with optional prerelease/build tail (no `+` tail in v1).
    public static func isValidNpmVersion(_ value: String) -> Bool {
        let core = value.split(separator: "-", maxSplits: 1)
        let numeric = core[0]
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy(isASCIIDigits(_:)) else { return false }
        if value.count > 64 || value.utf8.contains(UInt8(ascii: "+")) || value.utf8.contains(UInt8(ascii: " ")) { return false }
        if value.hasSuffix("-") { return false }
        if let dash = value.firstIndex(of: "-") {
            let tail = value[value.index(after: dash)...]
            guard !tail.isEmpty else { return false }
            return tail.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || byte == UInt8(ascii: ".")
                    || byte == UInt8(ascii: "-")
            }
        }
        return true
    }

    /// Font apt identity: `fonts-[a-z0-9][a-z0-9+._-]*`. The exact Debian
    /// version pin travels with it (validated like the apt kind); the fixed
    /// CJK probe only confirms the installed identity is actually usable.
    public static func isValidFontIdentity(_ value: String) -> Bool {
        guard value.hasPrefix("fonts-") else { return false }
        return isValidAptName(value)
    }

    /// Profile id: same grammar as a Skill identifier.
    public static func isValidProfileID(_ value: String) -> Bool {
        do {
            try SkillIdentifier.validate(value)
            return true
        } catch {
            return false
        }
    }

    /// Package-local lock path: starts with `references/`, ends `.txt`, no empty
    /// segments, no `.`/`..` traversal, bounded length.
    public static func isPackageLocalLockPath(_ value: String) -> Bool {
        guard value.utf8.count <= 256, value.hasPrefix("references/"), value.hasSuffix(".txt"),
              !value.contains(" "), !value.contains("\""), !value.contains("\u{0}") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "references" else { return false }
        for part in parts.dropFirst() where part.isEmpty || part == "." || part == ".." { return false }
        return value.utf8.allSatisfy { lockPathAllowedBytes.contains($0) }
    }

    private static let lockPathAllowedBytes: Set<UInt8> = characterSet(
        [asciiLower, asciiUpper, asciiDigits],
        extra: [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "/")]
    )

    /// Purpose: 1...200 bytes, no control characters (model-safe text only).
    public static func isValidPurpose(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty, value.utf8.count <= maximumPurposeBytes else { return false }
        return value.unicodeScalars.allSatisfy { !NSCharacterSet.controlCharacters.contains($0) }
    }

    // MARK: - Strict decode

    /// Strictly decode one declaration byte string. Fail-closed on unknown schema,
    /// unknown fields, untagged kinds, pattern misses, duplicates and limits.
    public static func decode(_ bytes: Data) throws -> SkillDependencyDeclaration {
        guard bytes.count <= maximumDeclarationBytes else {
            throw SkillDependencyError.invalidJSON("declaration exceeds the \(maximumDeclarationBytes)-byte bound")
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? [String: Any]
                ?? { throw NSError(domain: "SkillDependency", code: 1) }()
        } catch {
            throw SkillDependencyError.invalidJSON(error.localizedDescription)
        }
        try exactKeys(object, allowed: ["schemaVersion", "profiles"], required: ["schemaVersion", "profiles"], path: "declaration")

        let rawSchema = object["schemaVersion"]
        guard let number = rawSchema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              Double(number.intValue) == number.doubleValue else {
            throw SkillDependencyError.invalidField("schemaVersion")
        }
        let schemaVersion = number.intValue
        if schemaVersion > frozenSchemaVersion {
            // Unknown newer schema: fail compatibility, never guess forward.
            throw SkillDependencyError.unsupportedSchemaVersion(schemaVersion)
        }
        if schemaVersion < frozenSchemaVersion {
            throw SkillDependencyError.invalidField("schemaVersion")
        }

        guard let profileArray = object["profiles"] as? [Any], !profileArray.isEmpty else {
            throw SkillDependencyError.invalidField("profiles")
        }
        guard profileArray.count <= maximumProfiles else {
            throw SkillDependencyError.tooManyProfiles(profileArray.count)
        }
        var profiles: [SkillDependencyProfile] = []
        var seenProfileIDs = Set<String>()
        for (index, rawProfile) in profileArray.enumerated() {
            let path = "profiles[\(index)]"
            guard let profileObject = rawProfile as? [String: Any] else {
                throw SkillDependencyError.invalidField(path)
            }
            try exactKeys(profileObject, allowed: ["id", "target", "requirements"],
                          required: ["id", "target", "requirements"], path: path)
            let id = try string(profileObject["id"], path: "\(path).id")
            guard isValidProfileID(id) else { throw SkillDependencyError.invalidField("\(path).id") }
            guard seenProfileIDs.insert(id).inserted else {
                throw SkillDependencyError.duplicateProfileID(id)
            }
            let targetObject = try objectField(profileObject["target"], path: "\(path).target")
            try exactKeys(targetObject, allowed: ["os", "architectures"],
                          required: ["os", "architectures"], path: "\(path).target")
            let os = try string(targetObject["os"], path: "\(path).target.os")
            guard os == frozenTargetOS else {
                throw SkillDependencyError.unsupportedTarget(os)
            }
            guard let architectureArray = targetObject["architectures"] as? [Any],
                  !architectureArray.isEmpty, architectureArray.count <= 4 else {
                throw SkillDependencyError.invalidField("\(path).target.architectures")
            }
            var architectures: [String] = []
            var seenArchitectures = Set<String>()
            for rawArch in architectureArray {
                let arch = try string(rawArch, path: "\(path).target.architectures")
                guard supportedArchitectures.contains(arch), seenArchitectures.insert(arch).inserted else {
                    throw SkillDependencyError.invalidField("\(path).target.architectures")
                }
                architectures.append(arch)
            }
            guard let requirementArray = targetRequirements(profileObject["requirements"]),
                  !requirementArray.isEmpty else {
                throw SkillDependencyError.invalidField("\(path).requirements")
            }
            guard requirementArray.count <= maximumRequirementsPerProfile else {
                throw SkillDependencyError.tooManyRequirements(requirementArray.count)
            }
            var requirements: [SkillDependencyRequirement] = []
            var seenRequirements = Set<String>()
            for (requirementIndex, rawRequirement) in requirementArray.enumerated() {
                let requirement = try decodeRequirement(
                    rawRequirement, path: "\(path).requirements[\(requirementIndex)]"
                )
                guard seenRequirements.insert(requirement.identityKey).inserted else {
                    throw SkillDependencyError.duplicateRequirement(requirement.identityKey)
                }
                requirements.append(requirement)
            }
            profiles.append(SkillDependencyProfile(
                id: id, os: os, architectures: architectures, requirements: requirements
            ))
        }
        return SkillDependencyDeclaration(schemaVersion: frozenSchemaVersion, profiles: profiles)
    }

    /// Cross-validate the decoded declaration against the exact package inventory:
    /// every declared lock and the runtime-component descriptor must be present in
    /// the signed package bytes (the digest covers them), and a runtime-component
    /// requirement must carry the frozen descriptor path with a descriptor that
    /// itself strict-decodes and whose componentID is the allowlisted known one.
    public static func validate(
        _ declaration: SkillDependencyDeclaration,
        packageFiles: [String: Data]
    ) throws {
        for profile in declaration.profiles {
            for requirement in profile.requirements {
                if let lock = requirement.lockfile {
                    guard isPackageLocalLockPath(lock) else {
                        throw SkillDependencyError.lockPathRejected(lock)
                    }
                    guard packageFiles[lock] != nil else {
                        throw SkillDependencyError.lockFileMissing(lock)
                    }
                }
                if let descriptorPath = requirement.componentDescriptorPath {
                    guard descriptorPath == componentDescriptorPath else {
                        throw SkillDependencyError.descriptorPathRejected(descriptorPath)
                    }
                    guard let descriptorBytes = packageFiles[descriptorPath] else {
                        throw SkillDependencyError.descriptorFileMissing(descriptorPath)
                    }
                    // Reuse the frozen managed runtime-component gate unchanged:
                    // allowlist, patterns and caps are its own; nothing broadens
                    // it here.
                    _ = try SkillRuntimeDependency.decode(descriptorBytes)
                }
            }
        }
    }

    /// The decoded component identity/version are the requirement's binding facts:
    /// a requirement can never shadow, replace or bypass the descriptor's own
    /// pinned values (its strict decoder + allowlist stay the single authority).

    private static func decodeRequirement(_ raw: Any, path: String) throws -> SkillDependencyRequirement {
        guard let object = raw as? [String: Any] else {
            throw SkillDependencyError.invalidField(path)
        }
        let rawKind = try string(object["kind"], path: "\(path).kind")
        guard let kind = SkillDependencyRequirement.Kind(rawValue: rawKind) else {
            throw SkillDependencyError.unsupportedKind(rawKind)
        }
        try exactKeys(object, allowed: kind.exactKeys,
                      required: kind.exactKeys.filter { $0 != "lockfile" }, path: path)
        let purpose = try string(object["purpose"], path: "\(path).purpose")
        guard isValidPurpose(purpose) else { throw SkillDependencyError.invalidField("\(path).purpose") }
        let required = try boolean(object["required"], path: "\(path).required")

        var name = ""
        var version: String? = nil
        var lockfile: String? = nil
        var descriptorPath: String? = nil

        switch kind {
        case .pip:
            name = try string(object["name"], path: "\(path).name")
            guard isValidPipName(name) else { throw SkillDependencyError.invalidField("\(path).name") }
            let pin = try string(object["version"], path: "\(path).version")
            guard isValidPipVersion(pin) else { throw SkillDependencyError.invalidField("\(path).version") }
            version = pin
            if let lock = object["lockfile"] {
                let lockValue = try string(lock, path: "\(path).lockfile")
                guard isPackageLocalLockPath(lockValue) else {
                    throw SkillDependencyError.lockPathRejected(lockValue)
                }
                lockfile = lockValue
            }
        case .apt:
            name = try string(object["name"], path: "\(path).name")
            guard isValidAptName(name) else { throw SkillDependencyError.invalidField("\(path).name") }
            let pin = try string(object["version"], path: "\(path).version")
            guard isValidAptVersion(pin) else { throw SkillDependencyError.invalidField("\(path).version") }
            version = pin
        case .npm:
            name = try string(object["name"], path: "\(path).name")
            guard isValidNpmName(name) else { throw SkillDependencyError.invalidField("\(path).name") }
            let pin = try string(object["version"], path: "\(path).version")
            guard isValidNpmVersion(pin) else { throw SkillDependencyError.invalidField("\(path).version") }
            version = pin
        case .font:
            name = try string(object["name"], path: "\(path).name")
            guard isValidFontIdentity(name) else { throw SkillDependencyError.invalidField("\(path).name") }
            let pin = try string(object["version"], path: "\(path).version")
            guard isValidAptVersion(pin) else { throw SkillDependencyError.invalidField("\(path).version") }
            version = pin
        case .runtimeComponent:
            let candidate = try string(object["componentDescriptorPath"], path: "\(path).componentDescriptorPath")
            guard candidate == componentDescriptorPath else {
                throw SkillDependencyError.descriptorPathRejected(candidate)
            }
            descriptorPath = candidate
            // Identity arrives from the pinned descriptor at cross-validation,
            // never from the requirement bytes.
            name = ""
        }
        return SkillDependencyRequirement(
            kind: kind, name: name, version: version, purpose: purpose,
            required: required, lockfile: lockfile, componentDescriptorPath: descriptorPath
        )
    }

    private static func targetRequirements(_ value: Any?) throws -> [Any]? {
        value as? [Any]
    }

    // MARK: - Strict JSON helpers (same discipline as SkillRuntimeDependency)

    private static func exactKeys(
        _ object: [String: Any], allowed: [String], required: [String], path: String
    ) throws {
        let keys = Set(object.keys)
        let allowedSet = Set(allowed)
        let unknown = keys.subtracting(allowedSet)
        guard unknown.isEmpty else {
            throw SkillDependencyError.unknownFields(Array(unknown))
        }
        let requiredSet = Set(required)
        let missing = requiredSet.subtracting(keys)
        guard missing.isEmpty else {
            throw SkillDependencyError.missingFields(Array(missing))
        }
    }

    private static func string(_ value: Any?, path: String) throws -> String {
        guard let string = value as? String else {
            throw SkillDependencyError.invalidField(path)
        }
        return string
    }

    private static func boolean(_ value: Any?, path: String) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw SkillDependencyError.invalidField(path)
        }
        return number.boolValue
    }

    private static func objectField(_ value: Any?, path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw SkillDependencyError.invalidField(path)
        }
        return object
    }
}

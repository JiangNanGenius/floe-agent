// FloeSkills — managed runtime component descriptor v1 (strict, fail-closed).
//
// Frozen contract of the Skill Hub "runtime component" channel (currently the
// allowlisted `impeccable-engine` RISC-V Linux binary). This file owns the
// strict decoding gate and the structural ELF gate for that artifact.
//
// Trust rules (descriptor is DATA, never authority):
// - Decode only from the bytes of `references/engine-dependency.json` inside
//   the already verified official curated package snapshot (the caller — the
//   app-side SkillsCenter — establishes that authority: installed + enabled
//   row, typed curated receipt whose contentDigest matches the row digest and
//   the pinned snapshot, production feed + approve review).
// - The schema has NO URL/repository/environment/command/approval fields; the
//   key set is exact, so a package can never redirect the download anywhere
//   or mint an installer. Unknown fields fail closed.
// - componentID is a const (`impeccable-engine`); the 16 MiB artifact cap is
//   ONLY for this explicitly allowlisted component — ordinary Skill packages
//   keep their existing 2 MiB/file / 8 MiB/package limits untouched.
// - The artifact path is reconstructed from componentVersion + target.triple
//   and required to match the decoded path byte-for-byte, so a forged path
//   segment can never point anywhere else in the repository.

import Foundation
import CoreFoundation
import FloeCore

/// Fail-closed outcomes of descriptor decoding and artifact validation. Every
/// case carries a model-safe reason; none of them ever exposes a host path.
public enum SkillRuntimeDependencyError: Error, Equatable, Sendable, LocalizedError {
    case invalidJSON(String)
    case missingFields([String])
    case unknownFields([String])
    case invalidField(String)
    case sizeOutOfRange(Int)
    case unsupportedComponent(String)
    case unsupportedCaptureContractVersion(Int)
    case incompatibleAppVersion(minimum: String, app: String)
    case elfRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason): "The runtime-component descriptor is not valid JSON: \(reason)"
        case .missingFields(let fields): "The runtime-component descriptor is missing required fields: \(fields.sorted().joined(separator: ", "))"
        case .unknownFields(let fields): "The runtime-component descriptor has fields outside the contract: \(fields.sorted().joined(separator: ", "))"
        case .invalidField(let field): "The runtime-component descriptor field '\(field)' has an invalid value"
        case .sizeOutOfRange(let size): "The runtime-component artifact size \(size) is outside the allowed range"
        case .unsupportedComponent(let componentID): "The runtime component '\(componentID)' is not the allowlisted known component"
        case .unsupportedCaptureContractVersion(let version): "The runtime component's capture-contract version \(version) is not supported by this build"
        case .incompatibleAppVersion(let minimum, let app): "This app version \(app) is below the component's minimum app version \(minimum)"
        case .elfRejected(let reason): "The runtime-component artifact failed its static ELF gate: \(reason)"
        }
    }
}

/// One frozen runtime-component descriptor. Immutable after strict decode;
/// the property set mirrors schema v1 exactly (seven top-level fields).
public struct SkillRuntimeDependencyDescriptor: Sendable, Equatable {
    public struct Target: Sendable, Equatable {
        public let os: String
        public let arch: String
        public let triple: String
        public let format: String
    }

    public struct Artifact: Sendable, Equatable {
        /// Exact repository-relative path at the SAME externally pinned
        /// publication commit Y (never a URL; the caller constructs the fetch
        /// from its trusted Hub repository + Y).
        public let path: String
        public let size: Int
        public let sha256: String
    }

    public struct CaptureContract: Sendable, Equatable {
        public let version: Int
        public let sha256: String
    }

    public let schemaVersion: Int
    public let componentID: String
    public let componentVersion: String
    public let minimumAppVersion: String
    public let target: Target
    public let artifact: Artifact
    public let captureContract: CaptureContract
}

public enum SkillRuntimeDependency {
    /// The single allowlisted component for this release. Anything else in the
    /// descriptor position is rejected; the 16 MiB component cap exists ONLY
    /// here and never broadens ordinary Skill package limits.
    public static let knownComponentID = "impeccable-engine"

    /// Capture-contract versions the native producer supports today. The
    /// descriptor must carry one of these; the probed `contract` output must
    /// hash to the descriptor's sha256 AND parse to one of these versions.
    public static let supportedCaptureContractVersions: Set<Int> = [1]

    /// Hard artifact bound for the allowlisted component only. Ordinary Skill
    /// package caps (2 MiB/file, 8 MiB/package) remain untouched elsewhere.
    public static let maximumArtifactBytes = 16_777_216

    /// Repository-relative path of the descriptor inside the canonical
    /// curated Skill package.
    public static let engineDependencyPackagePath = "references/engine-dependency.json"

    /// Bounded descriptor read (the published descriptor is ~600 bytes).
    public static let maximumDescriptorBytes = 65_536

    // MARK: - Frozen constants

    public static let frozenSchemaVersion = 1
    public static let frozenTargetOS = "linux"
    public static let frozenTargetArch = "riscv64"
    public static let frozenTargetTriple = "riscv64gc-unknown-linux-musl"
    public static let frozenTargetFormat = "elf64-little-riscv-exec-static"
    public static let frozenEngineFileName = "floe-impeccable"
    public static let captureContractName = "floe.impeccable.snapshot"

    /// The exact cross-field path the schema requires:
    /// `engines/impeccable/dist/impeccable-{componentVersion}/{triple}/floe-impeccable`.
    public static func expectedArtifactPath(componentVersion: String, triple: String) -> String {
        "engines/impeccable/dist/impeccable-\(componentVersion)/\(triple)/\(frozenEngineFileName)"
    }

    /// The exact `engine-probe` handshake line the guest probe must print.
    public static func expectedProbeStdout(componentVersion: String) -> String {
        "impeccable-engine \(componentVersion)\n"
    }

    public static func isCaptureContractVersionSupported(_ version: Int) -> Bool {
        supportedCaptureContractVersions.contains(version)
    }

    /// True only for an exact ASCII lowercase 64-hex SHA-256.
    public static func isCanonicalLowercaseHexSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    /// App-version gate: `appVersion` must parse as a numeric triple and be
    /// >= the descriptor's `minimumAppVersion`. An unparseable version never
    /// passes.
    public static func isCompatible(minimumAppVersion: String, appVersion: String) -> Bool {
        guard let minimum = try? SignedContentVersion(minimumAppVersion),
              let app = try? SignedContentVersion(appVersion) else { return false }
        return app >= minimum
    }

    // MARK: - Strict decode

    /// Strictly decode one descriptor byte string. Fail-closed: top level must
    /// be an object with EXACTLY the seven contract fields, constants fixed,
    /// patterns enforced, cross-field artifact path required, sizes exact
    /// integers, digests exact lowercase 64-hex.
    public static func decode(_ bytes: Data) throws -> SkillRuntimeDependencyDescriptor {
        guard bytes.count <= maximumDescriptorBytes else {
            throw SkillRuntimeDependencyError.invalidJSON("descriptor exceeds the \(maximumDescriptorBytes)-byte bound")
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: bytes, options: []) as? [String: Any]
                ?? { throw NSError(domain: "SkillRuntimeDependency", code: 1) }()
        } catch {
            throw SkillRuntimeDependencyError.invalidJSON(error.localizedDescription)
        }

        try exactKeys(object, required: ["schemaVersion", "componentID", "componentVersion",
                                         "minimumAppVersion", "target", "artifact", "captureContract"],
                      path: "descriptor")

        let schemaVersion = try integer(object["schemaVersion"], path: "descriptor.schemaVersion")
        guard schemaVersion == frozenSchemaVersion else {
            throw SkillRuntimeDependencyError.invalidField("schemaVersion")
        }

        let componentID = try string(object["componentID"], path: "descriptor.componentID")
        guard componentID == knownComponentID else {
            throw SkillRuntimeDependencyError.unsupportedComponent(componentID)
        }

        let componentVersion = try string(object["componentVersion"], path: "descriptor.componentVersion")
        guard componentVersion.utf8.count <= 64, isValidComponentVersion(componentVersion) else {
            throw SkillRuntimeDependencyError.invalidField("componentVersion")
        }

        let minimumAppVersion = try string(object["minimumAppVersion"], path: "descriptor.minimumAppVersion")
        guard (try? SignedContentVersion(minimumAppVersion)) != nil else {
            throw SkillRuntimeDependencyError.invalidField("minimumAppVersion")
        }

        let targetObject = try objectField(object["target"], path: "descriptor.target")
        try exactKeys(targetObject, required: ["os", "arch", "triple", "format"], path: "descriptor.target")
        let target = SkillRuntimeDependencyDescriptor.Target(
            os: try string(targetObject["os"], path: "descriptor.target.os"),
            arch: try string(targetObject["arch"], path: "descriptor.target.arch"),
            triple: try string(targetObject["triple"], path: "descriptor.target.triple"),
            format: try string(targetObject["format"], path: "descriptor.target.format")
        )
        guard target.os == frozenTargetOS,
              target.arch == frozenTargetArch,
              target.triple == frozenTargetTriple,
              target.format == frozenTargetFormat else {
            throw SkillRuntimeDependencyError.invalidField("target")
        }

        let artifactObject = try objectField(object["artifact"], path: "descriptor.artifact")
        try exactKeys(artifactObject, required: ["path", "size", "sha256"], path: "descriptor.artifact")
        let artifactPath = try string(artifactObject["path"], path: "descriptor.artifact.path")
        guard artifactPath.utf8.count <= 256 else {
            throw SkillRuntimeDependencyError.invalidField("artifact.path")
        }
        let artifactSize = try integer(artifactObject["size"], path: "descriptor.artifact.size")
        guard (1...maximumArtifactBytes).contains(artifactSize) else {
            throw SkillRuntimeDependencyError.sizeOutOfRange(artifactSize)
        }
        let artifactSHA = try string(artifactObject["sha256"], path: "descriptor.artifact.sha256")
        guard isCanonicalLowercaseHexSHA256(artifactSHA) else {
            throw SkillRuntimeDependencyError.invalidField("artifact.sha256")
        }
        // Cross-field requirement: the path must be exactly the frozen layout
        // for THIS component version and target triple. No override possible.
        guard artifactPath == expectedArtifactPath(componentVersion: componentVersion, triple: target.triple) else {
            throw SkillRuntimeDependencyError.invalidField("artifact.path")
        }
        let artifact = SkillRuntimeDependencyDescriptor.Artifact(path: artifactPath, size: artifactSize, sha256: artifactSHA)

        let contractObject = try objectField(object["captureContract"], path: "descriptor.captureContract")
        try exactKeys(contractObject, required: ["version", "sha256"], path: "descriptor.captureContract")
        let contractVersion = try integer(contractObject["version"], path: "descriptor.captureContract.version")
        guard contractVersion >= 1 else {
            throw SkillRuntimeDependencyError.unsupportedCaptureContractVersion(contractVersion)
        }
        let contractSHA = try string(contractObject["sha256"], path: "descriptor.captureContract.sha256")
        guard isCanonicalLowercaseHexSHA256(contractSHA) else {
            throw SkillRuntimeDependencyError.invalidField("captureContract.sha256")
        }
        let captureContract = SkillRuntimeDependencyDescriptor.CaptureContract(version: contractVersion, sha256: contractSHA)

        return SkillRuntimeDependencyDescriptor(
            schemaVersion: schemaVersion,
            componentID: componentID,
            componentVersion: componentVersion,
            minimumAppVersion: minimumAppVersion,
            target: target,
            artifact: artifact,
            captureContract: captureContract
        )
    }

    /// `X.Y.Z+floe.A.B.C` with no leading zeros and every segment numeric.
    static func isValidComponentVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: "+floe.", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return false }
        return isNumericTriple(String(pieces[0])) && isNumericTriple(String(pieces[1]))
    }

    static func isNumericTriple(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        // ASCII digits only: `Character.isNumber` also accepts Unicode
        // numerals, which the frozen schema does not.
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy({ byte in byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") })
                && (part == "0" || !part.hasPrefix("0"))
        }
    }

    // MARK: - Static ELF gate

    /// Structural gate for the allowlisted artifact: ELF64 little-endian,
    /// RISC-V (`e_machine == 243`), `ET_EXEC`, bounded program-header table
    /// and NO `PT_INTERP` (fully static, no dynamic loader dependency).
    /// This is a shape check for the explicitly allowlisted component, never
    /// a general "any executable" bypass.
    public static func verifyStaticRISCVExecELF(_ bytes: Data) throws {
        struct ELFValidation: Error, LocalizedError {
            let reason: String
            var errorDescription: String? { reason }
        }
        func reject(_ reason: String) -> SkillRuntimeDependencyError { .elfRejected(reason) }

        guard bytes.count >= 64 else { throw reject("fewer than 64 bytes (no ELF64 header)") }
        let values = bytes.withUnsafeBytes { raw -> (type: UInt16, machine: UInt16, version: UInt32,
                                                     phoff: UInt64, phentsize: UInt16, phnum: UInt16)? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            func u16(_ offset: Int) -> UInt16 {
                UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
            }
            func u32(_ offset: Int) -> UInt32 {
                UInt32(u16(offset)) | (UInt32(u16(offset + 2)) << 16)
            }
            func u64(_ offset: Int) -> UInt64 {
                UInt64(u32(offset)) | (UInt64(u32(offset + 4)) << 32)
            }
            // e_ident sanity: magic, ELFCLASS64, ELFDATA2LSB, EV_CURRENT.
            guard base[0] == 0x7F, base[1] == UInt8(ascii: "E"),
                  base[2] == UInt8(ascii: "L"), base[3] == UInt8(ascii: "F"),
                  base[4] == 2, base[5] == 1, base[6] == 1 else { return nil }
            return (u16(16), u16(18), u32(20), u64(32), u16(54), u16(56))
        }
        guard let values else { throw reject("missing ELF magic / class / endianness / version") }
        guard values.type == 2 else { throw reject("e_type is \(values.type), expected 2 (ET_EXEC)") }
        guard values.machine == 243 else { throw reject("e_machine is \(values.machine), expected 243 (EM_RISCV)") }
        guard values.version == 1 else { throw reject("e_version is not EV_CURRENT") }
        let phentsize = Int(values.phentsize)
        let phnum = Int(values.phnum)
        guard phentsize == 56 else { throw reject("e_phentsize is \(phentsize), expected 56") }
        guard (1...256).contains(phnum) else { throw reject("e_phnum \(phnum) is outside the bounded range") }
        let tableBytes = phnum * phentsize
        guard values.phoff > 0, values.phoff <= UInt64(bytes.count),
              tableBytes <= bytes.count - Int(values.phoff) else {
            throw reject("the program-header table lies outside the artifact")
        }
        let hasInterpreter = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            for index in 0..<phnum {
                let offset = Int(values.phoff) + index * phentsize
                let pType = UInt32(base[offset])
                    | (UInt32(base[offset + 1]) << 8)
                    | (UInt32(base[offset + 2]) << 16)
                    | (UInt32(base[offset + 3]) << 24)
                if pType == 3 { return true } // PT_INTERP
            }
            return false
        }
        guard !hasInterpreter else { throw reject("PT_INTERP is present; the artifact is not fully static") }
    }

    // MARK: - Strict JSON helpers (local, same pattern as CuratedSkillStrictJSON)

    private static func exactKeys(_ object: [String: Any], required: [String], path: String) throws {
        let keys = Set(object.keys)
        let requiredSet = Set(required)
        let unknown = keys.subtracting(requiredSet)
        guard unknown.isEmpty else {
            throw SkillRuntimeDependencyError.unknownFields(Array(unknown))
        }
        let missing = requiredSet.subtracting(keys)
        guard missing.isEmpty else {
            throw SkillRuntimeDependencyError.missingFields(Array(missing))
        }
    }

    private static func string(_ value: Any?, path: String) throws -> String {
        guard let string = value as? String else {
            throw SkillRuntimeDependencyError.invalidField(path)
        }
        return string
    }

    private static func integer(_ value: Any?, path: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw SkillRuntimeDependencyError.invalidField(path)
        }
        let double = number.doubleValue
        let int = number.intValue
        guard Double(int) == double else {
            throw SkillRuntimeDependencyError.invalidField(path)
        }
        return int
    }

    private static func objectField(_ value: Any?, path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw SkillRuntimeDependencyError.invalidField(path)
        }
        return object
    }
}

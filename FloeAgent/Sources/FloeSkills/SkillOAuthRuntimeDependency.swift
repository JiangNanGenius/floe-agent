import Foundation
import CoreFoundation
import FloeCore

/// Ortie has its own contract. Impeccable's descriptor/API stays unchanged.
public struct SkillOAuthRuntimeDependencyDescriptor: Sendable, Equatable {
    public struct OAuthContract: Sendable, Equatable {
        public let version: Int
        public let sha256: String
    }
    public let schemaVersion: Int
    public let componentID: String
    public let componentVersion: String
    public let minimumAppVersion: String
    public let target: SkillRuntimeDependencyDescriptor.Target
    public let artifact: SkillRuntimeDependencyDescriptor.Artifact
    public let oauthContract: OAuthContract
}

public enum SkillOAuthRuntimeDependencyError: Error, Equatable, Sendable {
    case rejected(String)
}

public enum SkillOAuthRuntimeDependency {
    public static let knownComponentID = "ortie-oauth-engine"
    public static let frozenEngineFileName = "floe-ortie"
    public static let maximumArtifactBytes = 16_777_216
    public static let contractPath = "engines/ortie/runtime-dependency/oauth-contract.v1.json"
    public static let handshakePath = "engines/ortie/runtime-dependency/mcp-handshake.v1.json"
    public static let distributionPath = "engines/ortie/runtime-dependency/distribution.v1.json"
    public static let handshakeSHA256 = "1cbf74ffdba9bf2179435cf1dfa9089b87185031c11813d2dbb7a7080ad69d1e"
    public static let mplSourceSHA256 = "04744f49eae99ab78e0d5c0b603ab218f515ea8cfe5a456d7629ad883a3b6e7d"

    public struct Binding: Sendable, Equatable {
        public let path: String
        public let size: Int
        public let sha256: String
    }
    public struct Contract: Sendable {
        public let handshake: Binding
        public let distribution: Binding
        public let bytes: Data
    }
    public struct Metadata: Sendable {
        public let contract: Contract
        public let handshakeBytes: Data
        public let distributionBytes: Data
        public let notices: [Binding]
    }

    public static func expectedArtifactPath(componentVersion: String) -> String {
        "engines/ortie/dist/ortie-\(componentVersion)/aarch64-unknown-linux-musl/floe-ortie"
    }

    public static func decode(_ data: Data) throws -> SkillOAuthRuntimeDependencyDescriptor {
        let value = try canonicalObject(data, limit: 65_536)
        try exact(value, ["schemaVersion", "componentID", "componentVersion", "minimumAppVersion", "target", "artifact", "oauthContract"])
        guard try integer(value["schemaVersion"]) == 1,
              try text(value["componentID"]) == knownComponentID else { throw rejected("component") }
        let version = try text(value["componentVersion"])
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+floe\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#
        guard version.utf8.count <= 64, version.range(of: pattern, options: .regularExpression) != nil else { throw rejected("version") }
        let minimum = try text(value["minimumAppVersion"])
        _ = try SignedContentVersion(minimum)
        let target = try object(value["target"])
        try exact(target, ["os", "arch", "triple", "format"])
        guard try text(target["os"]) == "linux", try text(target["arch"]) == "arm64",
              try text(target["triple"]) == "aarch64-unknown-linux-musl",
              try text(target["format"]) == "elf64-little-aarch64-exec-static" else { throw rejected("target") }
        let artifact = try binding(value["artifact"], path: expectedArtifactPath(componentVersion: version), limit: maximumArtifactBytes)
        let contract = try object(value["oauthContract"])
        try exact(contract, ["version", "sha256"])
        guard try integer(contract["version"]) == 1 else { throw rejected("contract version") }
        return SkillOAuthRuntimeDependencyDescriptor(schemaVersion: 1, componentID: knownComponentID,
            componentVersion: version, minimumAppVersion: minimum,
            target: .init(os: "linux", arch: "arm64", triple: "aarch64-unknown-linux-musl", format: "elf64-little-aarch64-exec-static"),
            artifact: .init(path: artifact.path, size: artifact.size, sha256: artifact.sha256),
            oauthContract: .init(version: 1, sha256: try digest(contract["sha256"])))
    }

    public static func verifyArtifact(_ data: Data, descriptor: SkillOAuthRuntimeDependencyDescriptor) throws {
        guard data.count == descriptor.artifact.size, data.count <= maximumArtifactBytes,
              FloeDigest.sha256Hex(data) == descriptor.artifact.sha256 else { throw rejected("artifact binding") }
        try SkillRuntimeDependency.verifyStaticAArch64ExecELF(data)
    }

    public static func decodeContract(_ data: Data, descriptor: SkillOAuthRuntimeDependencyDescriptor) throws -> Contract {
        guard FloeDigest.sha256Hex(data) == descriptor.oauthContract.sha256 else { throw rejected("contract digest") }
        let value = try canonicalObject(data, limit: 65_536)
        try exact(value, ["schemaVersion", "componentID", "handshake", "distribution", "transport"])
        guard try integer(value["schemaVersion"]) == 1,
              try text(value["componentID"]) == knownComponentID else { throw rejected("contract identity") }
        let transport = try object(value["transport"])
        try exact(transport, ["mode", "externalLoopback", "allowRevoke"])
        guard try text(transport["mode"]) == "private-stdio",
              try boolean(transport["externalLoopback"]) == true,
              try boolean(transport["allowRevoke"]) == false else { throw rejected("private transport") }
        let handshake = try binding(value["handshake"], path: handshakePath, limit: 65_536)
        guard handshake.sha256 == handshakeSHA256 else { throw rejected("unsupported full handshake") }
        return Contract(handshake: handshake,
            distribution: try binding(value["distribution"], path: distributionPath, limit: 1_048_576), bytes: data)
    }

    public static func verifyMetadata(contract: Contract, handshake: Data, distribution: Data,
                                      descriptor: SkillOAuthRuntimeDependencyDescriptor) throws -> Metadata {
        guard FloeDigest.sha256Hex(contract.bytes) == descriptor.oauthContract.sha256 else { throw rejected("contract/descriptor identity") }
        try verifyBytes(handshake, binding: contract.handshake)
        try verifyBytes(distribution, binding: contract.distribution)
        let fixture = try canonicalObject(handshake, limit: 65_536)
        try exact(fixture, ["initialize", "toolsList"])
        let value = try canonicalObject(distribution, limit: 1_048_576)
        try exact(value, ["schemaVersion", "componentID", "files"])
        guard try integer(value["schemaVersion"]) == 1,
              try text(value["componentID"]) == knownComponentID,
              let files = value["files"] as? [[String: Any]], (1...1024).contains(files.count) else { throw rejected("distribution") }
        let prefix = "engines/ortie/notices/\(descriptor.componentVersion)/"
        var previous = ""
        var folded: Set<String> = []
        var notices: [Binding] = []
        var total = 0
        for item in files {
            let path = try text(item["path"])
            guard path.utf8.count <= 512, path.hasPrefix(prefix), safe(path),
                  previous.isEmpty || previous.utf8.lexicographicallyPrecedes(path.utf8) else { throw rejected("notice path/order") }
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard folded.insert(normalized).inserted else { throw rejected("duplicate notice path") }
            let local = String(path.dropFirst(prefix.count))
            guard ["THIRD_PARTY_NOTICES.md", "manifest.json", "sources/option-ext-0.2.0.crate"].contains(local)
                    || ["licenses/", "toolchain-reference/", "provenance/"].contains(where: { local.hasPrefix($0) }) else { throw rejected("notice subtree") }
            let entry = try binding(item, path: path, limit: 2_097_152)
            total += entry.size
            guard total <= 16_777_216 else { throw rejected("notice total") }
            notices.append(entry); previous = path
        }
        guard let source = notices.first(where: { $0.path == prefix + "sources/option-ext-0.2.0.crate" }),
              source.size == 7345, source.sha256 == mplSourceSHA256 else { throw rejected("complete pinned MPL source") }
        return Metadata(contract: contract, handshakeBytes: handshake, distributionBytes: distribution, notices: notices)
    }

    /// Actual private-worker results, not server instructions or model tools.
    public static func verifyProbe(initializeResult: Data, toolsListResult: Data, metadata: Metadata) throws {
        let fixture = try canonicalObject(metadata.handshakeBytes, limit: 65_536)
        for (key, actual) in [("initialize", initializeResult), ("toolsList", toolsListResult)] {
            guard actual.count <= 65_536 else { throw rejected("probe output bound") }
            let result: Any
            do { result = try JSONSerialization.jsonObject(with: actual) }
            catch { throw rejected("probe JSON") }
            guard let actualObject = result as? [String: Any], let expected = fixture[key],
                  try canonical(actualObject) == canonical(expected) else { throw rejected("complete probe schema") }
        }
    }

    private static func rejected(_ field: String) -> SkillOAuthRuntimeDependencyError { .rejected(field) }
    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func canonicalObject(_ data: Data, limit: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= limit else { throw rejected("JSON bound") }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw rejected("JSON") }
        guard let object = value as? [String: Any], try canonical(object) == data else { throw rejected("canonical JSON") }
        return object
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw rejected("object") }; return value
    }
    private static func exact(_ value: [String: Any], _ keys: Set<String>) throws {
        guard Set(value.keys) == keys else { throw rejected("exact fields") }
    }
    private static func text(_ value: Any?) throws -> String {
        guard let value = value as? String else { throw rejected("string") }; return value
    }
    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(Int.max),
              let value = Int(number.stringValue) else { throw rejected("integer") }
        return value
    }
    private static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw rejected("boolean") }
        return number.boolValue
    }
    private static func digest(_ value: Any?) throws -> String {
        let value = try text(value)
        guard SkillRuntimeDependency.isCanonicalLowercaseHexSHA256(value) else { throw rejected("sha256") }; return value
    }
    private static func safe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func binding(_ value: Any?, path: String, limit: Int) throws -> Binding {
        let fields = try object(value); try exact(fields, ["path", "size", "sha256"])
        let size = try integer(fields["size"])
        guard try text(fields["path"]) == path, safe(path), (1...limit).contains(size) else { throw rejected("file binding") }
        return Binding(path: path, size: size, sha256: try digest(fields["sha256"]))
    }
    private static func verifyBytes(_ data: Data, binding: Binding) throws {
        guard data.count == binding.size, FloeDigest.sha256Hex(data) == binding.sha256 else { throw rejected("bound bytes") }
    }
}

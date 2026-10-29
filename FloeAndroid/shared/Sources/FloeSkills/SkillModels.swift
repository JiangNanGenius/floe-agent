import Foundation

/// Capabilities are deliberately coarse and map to compiled Floe toolsets.
/// A skill can narrow authority, but can never add a capability at runtime.
public enum SkillCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case workspaceWrite = "workspace.write"
    case workspaceDelete = "workspace.delete"
    case network = "network"
    case browserObserve = "browser.observe"
    case browserInteract = "browser.interact"
    case credentials = "credentials"
    case localJavaScript = "javascript.local"
    case localPython = "python.local"
    case remoteExecution = "execution.remote"
}

public enum SkillPlatform: String, Codable, CaseIterable, Sendable, Hashable {
    case iOS = "ios"
    case macOS = "macos"
    case linux = "linux"
}

public enum SkillScriptRuntime: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case javaScriptCore = "javascriptcore"
    case localPython = "python.local"
    case remote
}

/// One immutable PyPI dependency reviewed when a skill is installed. Exact
/// versions make the reviewed wheel stable; URLs, VCS references, local paths
/// and version ranges are rejected by the package validator.
public struct SkillPythonPackageRequirement: Codable, Equatable, Sendable, Hashable {
    public var spec: String
    public var purpose: String
    public var capabilities: [String]

    public init(spec: String, purpose: String, capabilities: [String]) {
        self.spec = spec
        self.purpose = purpose
        self.capabilities = capabilities
    }
}

/// UTF-8 source bundled into `scripts/` by the skill authoring tool. The
/// package validator remains the authority for path, size and source checks.
public struct SkillBundledPythonScript: Codable, Equatable, Sendable, Hashable {
    public var relativePath: String
    public var source: String

    public init(relativePath: String, source: String) {
        self.relativePath = relativePath
        self.source = source
    }
}

public struct SkillManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var capabilities: [String]
    public var tools: [String]
    public var platforms: [String]
    public var scriptRuntime: SkillScriptRuntime
    public var pythonPackages: [SkillPythonPackageRequirement]

    public init(
        schemaVersion: Int = 1,
        id: String,
        version: String,
        capabilities: [String] = [],
        tools: [String] = [],
        platforms: [String] = [SkillPlatform.iOS.rawValue],
        scriptRuntime: SkillScriptRuntime = .none,
        pythonPackages: [SkillPythonPackageRequirement] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.capabilities = capabilities
        self.tools = tools
        self.platforms = platforms
        self.scriptRuntime = scriptRuntime
        self.pythonPackages = pythonPackages
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, version, capabilities, tools, platforms
        case scriptRuntime, pythonPackages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(String.self, forKey: .version)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        platforms = try container.decodeIfPresent([String].self, forKey: .platforms)
            ?? [SkillPlatform.iOS.rawValue]
        scriptRuntime = try container.decodeIfPresent(SkillScriptRuntime.self, forKey: .scriptRuntime) ?? .none
        pythonPackages = try container.decodeIfPresent(
            [SkillPythonPackageRequirement].self,
            forKey: .pythonPackages
        ) ?? []
    }
}

public struct SkillMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var instructions: String

    public init(name: String, description: String, instructions: String) {
        self.name = name
        self.description = description
        self.instructions = instructions
    }
}

public struct SkillFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var byteCount: Int

    public init(relativePath: String, byteCount: Int) {
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

public struct ValidatedSkillPackage: Sendable {
    public var rootURL: URL
    public var metadata: SkillMetadata
    public var manifest: SkillManifest
    public var declaredCapabilities: Set<SkillCapability>
    public var supportedPlatforms: Set<SkillPlatform>
    public var files: [SkillFile]
    public var canonicalSHA256: String

    public var containsScripts: Bool {
        files.contains { $0.relativePath.hasPrefix("scripts/") }
    }

    public init(
        rootURL: URL,
        metadata: SkillMetadata,
        manifest: SkillManifest,
        declaredCapabilities: Set<SkillCapability>,
        supportedPlatforms: Set<SkillPlatform>,
        files: [SkillFile],
        canonicalSHA256: String
    ) {
        self.rootURL = rootURL
        self.metadata = metadata
        self.manifest = manifest
        self.declaredCapabilities = declaredCapabilities
        self.supportedPlatforms = supportedPlatforms
        self.files = files
        self.canonicalSHA256 = canonicalSHA256
    }
}

public enum SkillValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingRequiredFile(String)
    case invalidFrontmatter(String)
    case invalidManifest(String)
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case unknownCapability(String)
    case unknownPlatform(String)
    case unsafePath(String)
    case symbolicLink(String)
    case duplicatePath(String)
    case unsupportedFile(String)
    case tooManyFiles(limit: Int)
    case tooManyEntries(limit: Int)
    case fileTooLarge(path: String, limit: Int)
    case packageTooLarge(limit: Int)
    case incompatibleScriptRuntime(String)
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .missingRequiredFile(let file): "Missing required file: \(file)"
        case .invalidFrontmatter(let reason): "Invalid SKILL.md frontmatter: \(reason)"
        case .invalidManifest(let reason): "Invalid floe.json: \(reason)"
        case .unsupportedSchema(let version): "Unsupported floe.json schema version: \(version)"
        case .invalidIdentifier(let value): "Invalid skill identifier: \(value)"
        case .invalidVersion(let value): "Invalid skill version: \(value)"
        case .unknownCapability(let value): "Unknown skill capability: \(value)"
        case .unknownPlatform(let value): "Unknown skill platform: \(value)"
        case .unsafePath(let path): "Unsafe path in skill: \(path)"
        case .symbolicLink(let path): "Symbolic links are not allowed in skills: \(path)"
        case .duplicatePath(let path): "Conflicting normalized path in skill: \(path)"
        case .unsupportedFile(let path): "Unsupported file in skill: \(path)"
        case .tooManyFiles(let limit): "Skill contains more than \(limit) files"
        case .tooManyEntries(let limit): "Skill contains more than \(limit) filesystem entries"
        case .fileTooLarge(let path, let limit): "Skill file exceeds \(limit) bytes: \(path)"
        case .packageTooLarge(let limit): "Skill exceeds \(limit) bytes"
        case .incompatibleScriptRuntime(let reason): "Incompatible script runtime: \(reason)"
        case .digestMismatch: "Rewritten skill digest does not match the reviewed package"
        }
    }
}

public struct SkillValidationLimits: Sendable, Equatable {
    public var maximumFileCount: Int
    public var maximumFileBytes: Int
    public var maximumPackageBytes: Int
    public var maximumSkillMarkdownBytes: Int
    public var maximumManifestBytes: Int

    public init(
        maximumFileCount: Int = 256,
        maximumFileBytes: Int = 2 * 1024 * 1024,
        maximumPackageBytes: Int = 8 * 1024 * 1024,
        maximumSkillMarkdownBytes: Int = 256 * 1024,
        maximumManifestBytes: Int = 64 * 1024
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumFileBytes = maximumFileBytes
        self.maximumPackageBytes = maximumPackageBytes
        self.maximumSkillMarkdownBytes = maximumSkillMarkdownBytes
        self.maximumManifestBytes = maximumManifestBytes
    }
}

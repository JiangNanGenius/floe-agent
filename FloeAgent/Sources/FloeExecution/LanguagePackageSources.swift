// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// One explicit source per ecosystem; never merge indexes by highest version.
public struct LanguagePackageSources: Codable, Equatable, Sendable {
    public var pythonIndex: String {
        didSet { pythonIndexIsExplicit = true }
    }
    public var nodeRegistry: String
    /// A Node-only save or the absence of a source file must not opt shell
    /// commands into the default PyPI URL and overwrite guest pip settings.
    public private(set) var pythonIndexIsExplicit: Bool

    public init() {
        self.init(pythonIndex: "https://pypi.org/simple/", nodeRegistry: "https://registry.npmjs.org/", pythonIndexIsExplicit: false)
    }
    public init(nodeRegistry: String) {
        self.init(pythonIndex: "https://pypi.org/simple/", nodeRegistry: nodeRegistry, pythonIndexIsExplicit: false)
    }
    public init(pythonIndex: String, nodeRegistry: String = "https://registry.npmjs.org/") {
        self.init(pythonIndex: pythonIndex, nodeRegistry: nodeRegistry, pythonIndexIsExplicit: true)
    }
    private init(pythonIndex: String, nodeRegistry: String, pythonIndexIsExplicit: Bool) {
        self.pythonIndex = pythonIndex; self.nodeRegistry = nodeRegistry
        self.pythonIndexIsExplicit = pythonIndexIsExplicit
    }
    private enum CodingKeys: String, CodingKey { case pythonIndex, nodeRegistry, pythonIndexIsExplicit }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pythonIndex = try values.decode(String.self, forKey: .pythonIndex)
        nodeRegistry = try values.decode(String.self, forKey: .nodeRegistry)
        if values.contains(.pythonIndexIsExplicit) {
            pythonIndexIsExplicit = try values.decode(Bool.self, forKey: .pythonIndexIsExplicit)
        } else {
            // Old saves always wrote BOTH default-valued fields, even for a
            // Node-only change. A custom Python URL is evidence of a prior
            // choice; an old Official value is ambiguous and needs a new
            // explicit Python save before it overrides guest configuration.
            let parts = URLComponents(string: pythonIndex.trimmingCharacters(in: .whitespacesAndNewlines))
            pythonIndexIsExplicit = !(parts?.scheme?.lowercased() == "https"
                && parts?.host?.lowercased() == "pypi.org"
                && (parts?.port == nil || parts?.port == 443)
                && ["/simple", "/simple/"].contains(parts?.path ?? ""))
        }
    }
    public func validated() throws -> Self {
        func url(_ value: String) throws -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 2048, var parts = URLComponents(string: value),
                  parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  !value.contains(where: { $0.isWhitespace || $0.isNewline }), parts.url != nil else {
                throw FloeError.validationFailed(FloeL10n.l("execution.language_package_sources.the_software_source_must_be_an"))
            }
            if !parts.path.hasSuffix("/") { parts.path += "/" }
            guard let normalized = parts.url?.absoluteString, normalized.utf8.count <= 2048 else {
                throw FloeError.validationFailed(FloeL10n.l("execution.language_package_sources.the_software_source_url_is_too"))
            }
            return normalized
        }
        return try Self(pythonIndex: url(pythonIndex), nodeRegistry: url(nodeRegistry), pythonIndexIsExplicit: pythonIndexIsExplicit)
    }
    private static func file(in root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        // Resolve the existing parent separately: Foundation may leave an
        // entire path unchanged when its final file does not exist yet.
        let parent = base.appendingPathComponent("var").resolvingSymlinksInPath()
        guard parent.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.language_package_sources.the_software_source_configuration_is_outside")) }
        let file = parent.appendingPathComponent("language-package-sources.json").resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed(FloeL10n.l("execution.language_package_sources.the_software_source_configuration_is_outside")) }
        return file
    }
    public static func load(in root: URL) throws -> Self {
        let file = try file(in: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 8192 else {
            throw FloeError.validationFailed(FloeL10n.l("execution.language_package_sources.the_software_source_configuration_is_damaged"))
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)).validated()
    }
    public func save(in root: URL) throws {
        let value = try validated(), file = try Self.file(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    /// Saved, validated, environment-local public defaults only. The shell
    /// backend filters caller-owned ordinary/sensitive names before export.
    /// No file means no defaults: preserve guest pip config and env verbatim.
    static func pythonShellDefaults(in root: URL) throws -> [String: String] {
        let value = try load(in: root)
        guard value.pythonIndexIsExplicit else { return [:] }
        return ["PIP_INDEX_URL": value.pythonIndex, "PIP_EXTRA_INDEX_URL": "", "PIP_TRUSTED_HOST": ""]
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// One explicit source per ecosystem; never merge indexes by highest version.
public struct LanguagePackageSources: Codable, Equatable, Sendable {
    public var pythonIndex: String
    public var nodeRegistry: String
    public init(pythonIndex: String = "https://pypi.org/simple/", nodeRegistry: String = "https://registry.npmjs.org/") {
        self.pythonIndex = pythonIndex; self.nodeRegistry = nodeRegistry
    }
    public func validated() throws -> Self {
        func url(_ value: String) throws -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 2048, var parts = URLComponents(string: value),
                  parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  !value.contains(where: { $0.isWhitespace || $0.isNewline }), parts.url != nil else {
                throw FloeError.validationFailed("软件源须为不含凭据、查询参数或片段的 HTTPS 地址")
            }
            if !parts.path.hasSuffix("/") { parts.path += "/" }
            guard let normalized = parts.url?.absoluteString, normalized.utf8.count <= 2048 else {
                throw FloeError.validationFailed("软件源地址过长")
            }
            return normalized
        }
        return try Self(pythonIndex: url(pythonIndex), nodeRegistry: url(nodeRegistry))
    }
    private static func file(in root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        // Resolve the existing parent separately: Foundation may leave an
        // entire path unchanged when its final file does not exist yet.
        let parent = base.appendingPathComponent("var").resolvingSymlinksInPath()
        guard parent.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed("软件源配置越出环境") }
        let file = parent.appendingPathComponent("language-package-sources.json").resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw FloeError.validationFailed("软件源配置越出环境") }
        return file
    }
    public static func load(in root: URL) throws -> Self {
        let file = try file(in: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 8192 else {
            throw FloeError.validationFailed("软件源配置损坏或过大")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)).validated()
    }
    public func save(in root: URL) throws {
        let value = try validated(), file = try Self.file(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
}

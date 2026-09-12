import Foundation
import FloeCore

/// A layer manifest records what a writable layer contains and which CAS
/// blobs it references. The base slice manifest uses the same shape.
public struct LayerManifest: Codable, Sendable {
    public var id: String
    public var kind: LayerKind
    public var baseRevision: String
    public var layerFormat: Int
    public var createdAt: Date
    public var packages: [InstalledPackage]
    public var casRefs: [String]
    public var nodeGlobalModules: [String]
    public var pythonPackages: [String]
    public var wasmCommands: [String]

    public init(
        id: String,
        kind: LayerKind,
        baseRevision: String,
        layerFormat: Int = ContainerRecord.currentLayerFormat,
        createdAt: Date = Date(),
        packages: [InstalledPackage] = [],
        casRefs: [String] = [],
        nodeGlobalModules: [String] = [],
        pythonPackages: [String] = [],
        wasmCommands: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.baseRevision = baseRevision
        self.layerFormat = layerFormat
        self.createdAt = createdAt
        self.packages = packages
        self.casRefs = casRefs
        self.nodeGlobalModules = nodeGlobalModules
        self.pythonPackages = pythonPackages
        self.wasmCommands = wasmCommands
    }

    public static let fileName = "opt/floe/layer.json"

    public static func load(from layerURL: URL) -> LayerManifest? {
        let url = layerURL.appendingPathComponent(Self.fileName)
        guard let data = try? Data(floeContentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LayerManifest.self, from: data)
    }

    public func write(to layerURL: URL) throws {
        let url = layerURL.appendingPathComponent(Self.fileName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Resolved ordered stack for one container: session > project > shared >
/// base. Path lookup merges the layers in that order.
public struct ResolvedLayerStack: Sendable {
    public struct Layer: Sendable {
        public var kind: LayerKind
        public var url: URL
        public var manifest: LayerManifest?
    }

    public var layers: [Layer]

    public init(layers: [Layer]) {
        self.layers = layers
    }

    private func contained(_ path: String, in root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        return candidate == base || candidate.path.hasPrefix(base.path + "/") ? candidate : nil
    }

    public func layers(ofKind kind: LayerKind) -> [Layer] {
        layers.filter { $0.kind == kind }
    }

    /// Resolves `relativePath` against the stack, returning the first
    /// existing file (top layer wins).
    public func resolve(_ relativePath: String) -> URL? {
        for layer in layers {
            guard let candidate = contained(relativePath, in: layer.url) else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// All existing candidates for a relative directory, top-first.
    public func resolveAll(_ relativePath: String) -> [URL] {
        layers.compactMap { layer in
            guard let candidate = contained(relativePath, in: layer.url) else { return nil }
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Directory search path (e.g. `usr/bin`) across the stack, top-first.
    public func searchPaths(_ relativePath: String) -> [URL] {
        resolveAll(relativePath)
    }

    public func pythonSearchPaths() -> [URL] {
        resolveAll("usr/lib/floe-python/site-packages")
    }

    public func nodeModulePaths() -> [URL] {
        resolveAll("usr/lib/node_modules")
    }

    public var wasmCommandDirectories: [URL] {
        resolveAll("usr/lib/floe-wasm")
    }

    /// All packages visible in the stack, top-first with shadowing by name.
    public func mergedPackages() -> [InstalledPackage] {
        var seen = Set<String>()
        var result: [InstalledPackage] = []
        for layer in layers {
            for package in layer.manifest?.packages ?? [] where !seen.contains(package.name) {
                seen.insert(package.name)
                result.append(package)
            }
        }
        return result
    }

    public func package(named name: String) -> InstalledPackage? {
        mergedPackages().first { $0.name == name }
    }

    public func layerOwning(package name: String) -> LayerKind? {
        for layer in layers {
            if layer.manifest?.packages.contains(where: { $0.name == name }) == true {
                return layer.kind
            }
        }
        return nil
    }
}

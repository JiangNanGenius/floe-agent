// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Typed build-time diagnostics for ordinary microStudio canvas2d projects.
///
/// Project JSON is user content: it may describe resource metadata, but it can
/// never grant commands, permissions, host paths or network access. Known
/// higher-level runtimes and optional libraries that this package does not ship
/// are rejected explicitly instead of being silently misplayed.
public enum MicroStudioArtifactError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidProjectJSON(String)
    case unsupportedLanguage(String)
    case unsupportedGraphics(String)
    case unsupportedLibraries([String])
    case networkingUnsupported
    case noSources
    case tooManySources(Int)
    case duplicateSourceName(String)
    case sourceTooLarge(String)
    case sourcesTooLarge(Int)
    case tooManyResources(Int)
    case duplicateResourceName(String)
    case invalidResourceName(String)
    case resourceTooLarge(String)
    case resourcesTooLarge(Int)
    case invalidMap(String)
    case symbolicLink(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .invalidProjectJSON(let reason):
            return "invalid microStudio project.json: " + reason
        case .unsupportedLanguage(let language):
            return "unsupported microStudio language '\(language)'; this build ships microscript_v2 only"
        case .unsupportedGraphics(let graphics):
            return "unsupported microStudio graphics library '\(graphics)'; only the canvas2d player is bundled"
        case .unsupportedLibraries(let libraries):
            return "unsupported microStudio optional libraries: " + libraries.joined(separator: ", ")
        case .networkingUnsupported:
            return "microStudio networking/server projects are not supported by the offline artifact"
        case .noSources:
            return "no microScript source file"
        case .tooManySources(let maximum):
            return "more than \(maximum) microScript source files"
        case .duplicateSourceName(let name):
            return "two source files map to the same runtime name: " + name
        case .sourceTooLarge(let path):
            return "microScript source too large: " + path
        case .sourcesTooLarge(let maximum):
            return "microScript sources exceed \(maximum) bytes"
        case .tooManyResources(let maximum):
            return "more than \(maximum) microStudio resources"
        case .duplicateResourceName(let name):
            return "two resources map to the same runtime name: " + name
        case .invalidResourceName(let name):
            return "invalid microStudio resource name: " + name
        case .resourceTooLarge(let path):
            return "microStudio resource too large: " + path
        case .resourcesTooLarge(let maximum):
            return "microStudio resources exceed \(maximum) bytes"
        case .invalidMap(let path):
            return "invalid microStudio map JSON: " + path
        case .symbolicLink(let path):
            return "symbolic link is not a readable microStudio source/resource: " + path
        case .unreadable(let path):
            return "unreadable microStudio source/resource: " + path
        }
    }
}

public enum MicroStudioResourceKind: String, Sendable, Equatable, CaseIterable {
    case sprite, map, sound, music, asset

    public var folder: String {
        switch self {
        case .sprite: return "sprites"
        case .map: return "maps"
        case .sound: return "sounds"
        case .music: return "music"
        case .asset: return "assets"
        }
    }
}

public struct MicroStudioSourceFile: Sendable, Equatable {
    /// Original project-relative path (e.g. `ms/main.ms`).
    public let path: String
    /// microStudio's stored runtime file name: `/` encoded as `-`.
    public let runtimeName: String
    public let text: String

    public init(path: String, runtimeName: String, text: String) {
        self.path = path; self.runtimeName = runtimeName; self.text = text
    }
}

public struct MicroStudioResourceFile: Sendable, Equatable {
    public let kind: MicroStudioResourceKind
    /// Original project-relative path.
    public let sourcePath: String
    /// Official exported file name inside the kind folder (`/` encoded as `-`).
    public let runtimeFile: String
    public let version: Int
    /// Only `frames`/`fps`, only for sprites, only when valid in project.json.
    public let imageProperties: [String: Int]?

    public init(kind: MicroStudioResourceKind, sourcePath: String, runtimeFile: String,
                version: Int, imageProperties: [String: Int]? = nil) {
        self.kind = kind; self.sourcePath = sourcePath; self.runtimeFile = runtimeFile
        self.version = version; self.imageProperties = imageProperties
    }

    public var artifactPath: String { kind.folder + "/" + runtimeFile }
}

public struct MicroStudioMapContent: Sendable, Equatable {
    public let resource: MicroStudioResourceFile
    /// Resources.maps key used by the pinned runtime (dashes are folder separators).
    public let name: String
    /// Original map JSON text embedded into `resources.maps`.
    public let text: String

    public init(resource: MicroStudioResourceFile, name: String, text: String) {
        self.resource = resource; self.name = name; self.text = text
    }
}

/// A validated, deterministic plan for one ordinary canvas2d project.
public struct MicroStudioBuildPlan: Sendable, Equatable {
    public let title: String
    public let language: String
    public let graphics: String
    public let orientation: String
    public let aspect: String
    public let sources: [MicroStudioSourceFile]
    public let resources: [MicroStudioResourceFile]
    public let maps: [MicroStudioMapContent]

    public init(title: String, language: String, graphics: String, orientation: String, aspect: String,
                sources: [MicroStudioSourceFile], resources: [MicroStudioResourceFile],
                maps: [MicroStudioMapContent]) {
        self.title = title; self.language = language; self.graphics = graphics
        self.orientation = orientation; self.aspect = aspect
        self.sources = sources; self.resources = resources; self.maps = maps
    }
}

/// Inspects a microStudio project folder using the official archive/export
/// layout (`project.json`, `ms/`, `sprites/`, `maps/`, `sounds/`, `music/`,
/// `assets/`). The original folder is never modified; nested archive paths are
/// flattened to microStudio's own dashed runtime names exactly like its
/// importer does.
public enum MicroStudioProjectPlan {
    public static let maximumSources = 128
    public static let maximumSourceBytes = 512 * 1_024
    public static let maximumTotalSourceBytes = 2 * 1_024 * 1_024
    public static let maximumResources = 512
    public static let maximumResourceBytes = 16 * 1_024 * 1_024
    public static let maximumTotalResourceBytes = 64 * 1_024 * 1_024
    public static let maximumMapBytes = 4 * 1_024 * 1_024
    public static let maximumProjectJSONBytes = 256 * 1_024

    public static func prepare(projectAt project: URL) throws -> MicroStudioBuildPlan {
        let tree: NarrativeBuildTree
        do { tree = try NarrativeBuildTree(root: project) }
        catch { throw MicroStudioArtifactError.unreadable("project root") }
        let entries = try tree.walk()
        let info = try readProjectInfo(tree: tree, entries: entries)

        var runtimeNames: Set<String> = []
        var sources: [MicroStudioSourceFile] = []
        var sourceBytes = 0
        for entry in entries where !entry.directory && entry.path.lowercased().hasSuffix(".ms") {
            if entry.symlink { throw MicroStudioArtifactError.symbolicLink(entry.path) }
            guard entry.regular else { throw MicroStudioArtifactError.unreadable(entry.path) }
            let runtimeName = flatName(entry.path)
            try validateResourceName(runtimeName, isSource: true)
            guard runtimeNames.insert(runtimeName).inserted else {
                throw MicroStudioArtifactError.duplicateSourceName(runtimeName)
            }
            guard entry.bytes <= maximumSourceBytes else {
                throw MicroStudioArtifactError.sourceTooLarge(entry.path)
            }
            sourceBytes += entry.bytes
            guard sourceBytes <= maximumTotalSourceBytes else {
                throw MicroStudioArtifactError.sourcesTooLarge(maximumTotalSourceBytes)
            }
            let data: Data
            do { data = try tree.read(entry.path, maximum: maximumSourceBytes) }
            catch { throw readFailure(error, path: entry.path) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw MicroStudioArtifactError.unreadable(entry.path)
            }
            sources.append(.init(path: entry.path, runtimeName: runtimeName, text: text))
        }
        guard !sources.isEmpty else { throw MicroStudioArtifactError.noSources }
        guard sources.count <= maximumSources else {
            throw MicroStudioArtifactError.tooManySources(maximumSources)
        }
        sources.sort { $0.runtimeName.utf8.lexicographicallyPrecedes($1.runtimeName.utf8) }

        var resources: [MicroStudioResourceFile] = []
        var maps: [MicroStudioMapContent] = []
        var resourceNames: [MicroStudioResourceKind: Set<String>] = [:]
        var resourceBytes = 0
        for entry in entries where !entry.directory {
            guard let (kind, relative) = classify(entry.path) else { continue }
            if entry.symlink { throw MicroStudioArtifactError.symbolicLink(entry.path) }
            guard entry.regular else { continue }
            guard let basename = entry.path.split(separator: "/").last, !basename.hasPrefix(".") else { continue }
            let runtimeFile = flatName(relative)
            try validateResourceName(runtimeFile, isSource: false)
            var names = resourceNames[kind] ?? []
            guard names.insert(runtimeFile).inserted else {
                throw MicroStudioArtifactError.duplicateResourceName(runtimeFile)
            }
            resourceNames[kind] = names
            guard entry.bytes <= maximumResourceBytes else {
                throw MicroStudioArtifactError.resourceTooLarge(entry.path)
            }
            resourceBytes += entry.bytes
            guard resourceBytes <= maximumTotalResourceBytes else {
                throw MicroStudioArtifactError.resourcesTooLarge(maximumTotalResourceBytes)
            }
            guard resources.count < maximumResources else {
                throw MicroStudioArtifactError.tooManyResources(maximumResources)
            }
            let metadata = info.files[kind.folder + "/" + runtimeFile]
            let version = metadata?.version ?? 0
            let properties = kind == .sprite ? sanitizedImageProperties(metadata?.properties) : nil
            let resource = MicroStudioResourceFile(kind: kind, sourcePath: entry.path,
                                                   runtimeFile: runtimeFile, version: version,
                                                   imageProperties: properties)
            resources.append(resource)

            if kind == .map {
                let data: Data
                do { data = try tree.read(entry.path, maximum: maximumMapBytes) }
                catch { throw readFailure(error, path: entry.path) }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw MicroStudioArtifactError.invalidMap(entry.path)
                }
                try validateMap(text, path: entry.path)
                let base = officialBaseName(runtimeFile)
                guard !base.isEmpty else { throw MicroStudioArtifactError.invalidResourceName(runtimeFile) }
                let name = base.replacingOccurrences(of: "-", with: "/")
                maps.append(.init(resource: resource, name: name, text: text))
            }
        }
        resources.sort { $0.artifactPath.utf8.lexicographicallyPrecedes($1.artifactPath.utf8) }
        maps.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var mapNames: Set<String> = []
        for map in maps {
            guard mapNames.insert(map.name).inserted else {
                throw MicroStudioArtifactError.duplicateResourceName(map.name)
            }
        }

        return MicroStudioBuildPlan(
            title: sanitizeTitle(info.title, fallback: "microStudio game"),
            language: info.language,
            graphics: info.graphics,
            orientation: sanitizeOrientation(info.orientation),
            aspect: sanitizeAspect(info.aspect),
            sources: sources,
            resources: resources,
            maps: maps
        )
    }

    // MARK: - Official names

    /// microStudio stores nested files flat with dashes; its project importer
    /// applies the same transformation to archive paths.
    static func flatName(_ relative: String) -> String {
        relative.replacingOccurrences(of: "/", with: "-")
    }

    /// Official exporters use `file.split(".")[0]` for resource identifiers.
    static func officialBaseName(_ file: String) -> String {
        String(file.prefix { $0 != "." })
    }

    static func validateResourceName(_ name: String, isSource: Bool) throws {
        guard !name.isEmpty, name.utf8.count <= 200,
              !name.hasPrefix("/"), !name.contains("/"),
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MicroStudioArtifactError.invalidResourceName(name)
        }
        if !isSource {
            guard !officialBaseName(name).isEmpty else {
                throw MicroStudioArtifactError.invalidResourceName(name)
            }
        }
    }

    static func classify(_ path: String) -> (MicroStudioResourceKind, String)? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2 else { return nil }
        let folder = components[0]
        let relative = components.dropFirst().joined(separator: "/")
        let ext = (relative as NSString).pathExtension.lowercased()
        switch folder {
        case "sprites" where ext == "png": return (.sprite, relative)
        case "maps" where ext == "json": return (.map, relative)
        case "sounds" where ext == "wav": return (.sound, relative)
        case "music" where ext == "mp3": return (.music, relative)
        case "assets" where !ext.isEmpty: return (.asset, relative)
        default: return nil
        }
    }

    // MARK: - project.json (non-authoritative metadata)

    struct FileMetadata: Sendable {
        var version: Int?
        var properties: [String: Int]?
    }

    struct ProjectInfo: Sendable {
        var title: String?
        var language: String = "microscript_v2"
        var graphics: String = "M1"
        var orientation: String?
        var aspect: String?
        var files: [String: FileMetadata] = [:]
    }

    static func readProjectInfo(tree: NarrativeBuildTree, entries: [NarrativeBuildTree.Entry]) throws -> ProjectInfo {
        var info = ProjectInfo()
        guard entries.contains(where: { $0.path == "project.json" && !$0.directory }) else { return info }
        let data: Data
        do { data = try tree.read("project.json", maximum: maximumProjectJSONBytes) }
        catch { throw readFailure(error, path: "project.json") }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MicroStudioArtifactError.invalidProjectJSON("not a JSON object")
        }
        func string(_ key: String) throws -> String? {
            guard let value = dictionary[key] else { return nil }
            guard let string = value as? String else {
                throw MicroStudioArtifactError.invalidProjectJSON("\(key) is not a string")
            }
            return string
        }
        info.title = try string("title")
        if let language = try string("language") {
            guard language == "microscript_v2" else {
                throw MicroStudioArtifactError.unsupportedLanguage(language)
            }
            info.language = language
        }
        if let raw = try string("graphics") {
            let lower = raw.lowercased()
            if lower.hasPrefix("m2d") || lower.hasPrefix("m3d")
                || lower.hasPrefix("pixi") || lower.hasPrefix("babylon") {
                throw MicroStudioArtifactError.unsupportedGraphics(raw)
            }
            info.graphics = raw.isEmpty ? "M1" : raw
        }
        if let value = dictionary["libs"] {
            guard let libs = value as? [Any] else {
                throw MicroStudioArtifactError.invalidProjectJSON("libs is not an array")
            }
            let names = libs.compactMap { $0 as? String }
            guard names.count == libs.count else {
                throw MicroStudioArtifactError.invalidProjectJSON("libs contains a non-string")
            }
            guard names.isEmpty else { throw MicroStudioArtifactError.unsupportedLibraries(names) }
        }
        if let value = dictionary["networking"] {
            guard let networking = value as? Bool else {
                throw MicroStudioArtifactError.invalidProjectJSON("networking is not a boolean")
            }
            if networking { throw MicroStudioArtifactError.networkingUnsupported }
        }
        info.orientation = try string("orientation")
        info.aspect = try string("aspect")
        if let files = dictionary["files"] as? [String: Any] {
            for (key, raw) in files {
                guard let record = raw as? [String: Any] else { continue }
                var metadata = FileMetadata()
                if let version = record["version"] as? NSNumber {
                    let value = version.doubleValue
                    if value.rounded() == value, value >= 0, value <= Double(Int32.max) {
                        metadata.version = Int(value)
                    }
                }
                if let properties = record["properties"] as? [String: Any] {
                    var clean: [String: Int] = [:]
                    for key in ["frames", "fps"] {
                        if let number = properties[key] as? NSNumber {
                            let value = number.doubleValue
                            if value.rounded() == value, value >= 0, value <= 10_000 {
                                clean[key] = Int(value)
                            }
                        }
                    }
                    if !clean.isEmpty { metadata.properties = clean }
                }
                info.files[key] = metadata
            }
        }
        return info
    }

    static func sanitizedImageProperties(_ raw: [String: Int]?) -> [String: Int]? {
        guard let raw else { return nil }
        var clean: [String: Int] = [:]
        if let frames = raw["frames"], (1...64).contains(frames) { clean["frames"] = frames }
        if let fps = raw["fps"], (1...120).contains(fps) { clean["fps"] = fps }
        return clean.isEmpty ? nil : clean
    }

    static func sanitizeTitle(_ raw: String?, fallback: String) -> String {
        guard var title = raw else { return fallback }
        title = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
        title = String(title.prefix(200))
        return title.isEmpty ? fallback : title
    }

    static func sanitizeOrientation(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 32,
              raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            return "landscape"
        }
        return raw
    }

    static func sanitizeAspect(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 16,
              raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "/" || $0 == ">" }) else {
            return "16/9"
        }
        return raw
    }

    // MARK: - Maps

    static func validateMap(_ text: String, path: String) throws {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: Any] else {
            throw MicroStudioArtifactError.invalidMap(path)
        }
        func integer(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            guard let number = map[key] as? NSNumber else { return nil }
            let value = number.doubleValue
            guard value.rounded() == value, value >= Double(range.lowerBound),
                  value <= Double(range.upperBound) else { return nil }
            return Int(value)
        }
        guard let width = integer("width", 1...4_096), let height = integer("height", 1...4_096),
              let blockWidth = integer("block_width", 1...1_024), let blockHeight = integer("block_height", 1...1_024),
              let sprites = map["sprites"] as? [Any], (1...4_096).contains(sprites.count),
              let firstSprite = sprites.first as? NSNumber, firstSprite.intValue == 0,
              sprites.dropFirst().allSatisfy({ $0 is String }),
              let cells = map["data"] as? [Any], cells.count == width * height else {
            throw MicroStudioArtifactError.invalidMap(path)
        }
        // Official SaveMap uses a zero placeholder at index 0 and 1-based ids.
        let count = sprites.count - 1
        for cell in cells {
            guard let number = cell as? NSNumber else { throw MicroStudioArtifactError.invalidMap(path) }
            let value = number.doubleValue
            guard value.rounded() == value, value >= 0, value <= Double(count) else {
                throw MicroStudioArtifactError.invalidMap(path)
            }
        }
        _ = blockWidth; _ = blockHeight
    }

    static func readFailure(_ error: Error, path: String) -> MicroStudioArtifactError {
        if let error = error as? NarrativeAdapterError, case .invalidProject(let reason) = error,
           reason.hasPrefix("symbolic link:") {
            return .symbolicLink(path)
        }
        return .unreadable(path)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeRPGCore

/// The nine standard RPG Maker A/B..E sheets. XP uses a different layout and
/// is described by `RPGTileSheetKind` instead.
public enum RPGTilesetSection: String, CaseIterable, Codable, Hashable, Sendable {
    case a1, a2, a3, a4, a5, b, c, d, e

    public var index: Int {
        switch self {
        case .a1: return 0
        case .a2: return 1
        case .a3: return 2
        case .a4: return 3
        case .a5: return 4
        case .b: return 5
        case .c: return 6
        case .d: return 7
        case .e: return 8
        }
    }

    public var isAutotile: Bool { self == .a1 || self == .a2 || self == .a3 || self == .a4 }
}

/// One image that supplies tiles. XP has a dedicated tileset image plus seven
/// independent autotile images; VX/Ace/MV/MZ have the nine standard sheets.
public enum RPGTileSheetKind: Hashable, Codable, Sendable {
    case xpTileset
    case xpAutotile(index: Int)
    case section(RPGTilesetSection)
    case character

    public var section: RPGTilesetSection? {
        if case .section(let value) = self { return value }
        return nil
    }
}

public enum RPGTileAssetSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

/// A rendering/resolution issue that must be shown to the user. Codes are
/// stable and deliberately not user-facing; `messageEN`/`messageZH` are.
public struct RPGTileAssetDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public var code: String
    public var severity: RPGTileAssetSeverity
    public var messageEN: String
    public var messageZH: String
    public var path: String?

    public var id: String { [code, path ?? "", messageEN].joined(separator: "|") }

    public init(code: String, severity: RPGTileAssetSeverity, messageEN: String,
                messageZH: String, path: String? = nil) {
        self.code = code; self.severity = severity
        self.messageEN = messageEN; self.messageZH = messageZH; self.path = path
    }

    public func message(chinese: Bool) -> String { chinese ? messageZH : messageEN }
}

/// One tileset record resolved to actual project-relative image paths.
public struct RPGTilesetDefinition: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var engine: RPGEngine
    public var mode: Int
    /// Data file that supplied this record.
    public var sourcePath: String
    /// VX/Ace/MV/MZ standard sheets. Missing/empty names stay absent.
    public var sectionPaths: [RPGTilesetSection: String]
    /// XP normal tileset image (`Graphics/Tilesets/<name>.png`).
    public var xpTilesetPath: String?
    /// XP seven autotile images, padded to seven entries with nil.
    public var xpAutotilePaths: [String?]
    /// Original (untrusted) names, retained for diagnostics only.
    public var rawSectionNames: [RPGTilesetSection: String]
    public var rawXPAutotileNames: [String]

    public init(id: Int, name: String, engine: RPGEngine, mode: Int = 0,
                sourcePath: String, sectionPaths: [RPGTilesetSection: String] = [:],
                xpTilesetPath: String? = nil, xpAutotilePaths: [String?] = [],
                rawSectionNames: [RPGTilesetSection: String] = [:],
                rawXPAutotileNames: [String] = []) {
        self.id = id; self.name = name; self.engine = engine; self.mode = mode
        self.sourcePath = sourcePath; self.sectionPaths = sectionPaths
        self.xpTilesetPath = xpTilesetPath; self.xpAutotilePaths = xpAutotilePaths
        self.rawSectionNames = rawSectionNames; self.rawXPAutotileNames = rawXPAutotileNames
    }

    public func imagePath(for sheet: RPGTileSheetKind) -> String? {
        switch sheet {
        case .xpTileset: return xpTilesetPath
        case .xpAutotile(let index):
            guard xpAutotilePaths.indices.contains(index) else { return nil }
            return xpAutotilePaths[index]
        case .section(let section): return sectionPaths[section]
        case .character: return nil
        }
    }

    public var availableSheets: [RPGTileSheetKind] {
        if engine == .rpgMakerXP {
            var result: [RPGTileSheetKind] = []
            if xpTilesetPath != nil { result.append(.xpTileset) }
            for index in xpAutotilePaths.indices where xpAutotilePaths[index] != nil {
                result.append(.xpAutotile(index: index))
            }
            return result
        }
        return RPGTilesetSection.allCases.compactMap { section -> RPGTileSheetKind? in
            guard sectionPaths[section] != nil else { return nil }
            return .section(section)
        }
    }
}

/// All tilesets decoded from one project's Tilesets data file, with honest
/// diagnostics instead of silent fallbacks. The catalog is immutable after
/// loading and can be passed across isolation domains.
public struct RPGTilesetCatalog: Sendable {
    public var engine: RPGEngine
    public var definitions: [Int: RPGTilesetDefinition]
    public var diagnostics: [RPGTileAssetDiagnostic]
    public var dataPath: String?

    public init(engine: RPGEngine, definitions: [Int: RPGTilesetDefinition] = [:],
                diagnostics: [RPGTileAssetDiagnostic] = [], dataPath: String? = nil) {
        self.engine = engine; self.definitions = definitions
        self.diagnostics = diagnostics; self.dataPath = dataPath
    }

    public func definition(id: Int) -> RPGTilesetDefinition? { definitions[id] }
    public var sortedDefinitions: [RPGTilesetDefinition] { definitions.values.sorted { $0.id < $1.id } }
    public var isEmpty: Bool { definitions.isEmpty }
}

// MARK: - Project path index

/// Deterministic, case-insensitive resolver over the project's declared file
/// list. It only returns declared files; it never inspects a host path or
/// borrows from RTP/another project.
public struct RPGProjectFileIndex: Sendable {
    private var paths: [GameRelativePath]
    private var byLowercase: [String: [GameRelativePath]]

    public init(paths: [GameRelativePath]) {
        self.paths = paths
        var index: [String: [GameRelativePath]] = [:]
        for path in paths { index[path.value.lowercased(), default: []].append(path) }
        self.byLowercase = index
    }

    public func exact(_ candidate: String) -> GameRelativePath? {
        paths.first(where: { $0.value == candidate })
    }

    /// Returns (path, ambiguous). Ambiguous means multiple differently-cased
    /// files would match; the caller must not silently choose one for an
    /// imported resource name.
    public func uniqueCaseInsensitive(_ candidate: String) -> (GameRelativePath?, Bool) {
        let matches = byLowercase[candidate.lowercased()] ?? []
        if matches.count <= 1 { return (matches.first, false) }
        if matches.count > 1, let exact = matches.first(where: { $0.value == candidate }) {
            return (exact, true)
        }
        return (matches.sorted { $0.value < $1.value }.first, true)
    }

    public var allPaths: [GameRelativePath] { paths }
}

// MARK: - Loading

public enum RPGTilesetCatalogError: Error, Equatable, Sendable {
    case missingTilesetData(expected: String)
    case ambiguousTilesetData
    case unsupportedEngine
    case decodeFailed(String)
}

extension RPGTilesetCatalog {
    /// Loads Tilesets.rxdata/rvdata2 or MV/MZ data/Tilesets.json and resolves
    /// every sheet name to a declared project file. Names are untrusted input:
    /// path escapes, absolute paths and ambiguous case variants are rejected.
    public static func load(engine: RPGEngine, files: [GameRelativePath],
                            reader: @escaping @Sendable (GameRelativePath) async throws -> Data,
                            marshalLimits: MarshalParseLimits = MarshalParseLimits()) async throws -> RPGTilesetCatalog {
        let index = RPGProjectFileIndex(paths: files)
        guard let dataPath = resolveTilesetDataPath(engine: engine, index: index) else {
            let expected = expectedTilesetDataPath(engine: engine)
            return RPGTilesetCatalog(engine: engine, diagnostics: [
                .init(code: "tileset.data.missing", severity: .warning,
                      messageEN: "No \(expected) was found. Tile images cannot be resolved for this map.",
                      messageZH: "未找到 \(expected)，无法解析此地图的图块图片。", path: expected)
            ])
        }
        let bytes = try await reader(dataPath)
        var diagnostics: [RPGTileAssetDiagnostic] = []
        let rawRecords: [(id: Int, name: String, mode: Int,
                          sectionNames: [RPGTilesetSection: String],
                          xpTileset: String?, xpAutotiles: [String])]
        if engine.usesJSONData {
            let document = try RPGDataDocument.decode(bytes, kind: .tilesets, engine: engine, marshalLimits: marshalLimits)
            rawRecords = document.jsonRecords().enumerated().compactMap { offset, value in
                guard value.objectValue != nil, !value.isNull else { return nil }
                let id = value["id"]?.intValue ?? offset
                let name = value["name"]?.stringValue ?? "Tileset \(id)"
                let mode = value["mode"]?.intValue ?? 0
                let names = value["tilesetNames"]?.arrayValue ?? []
                var sections: [RPGTilesetSection: String] = [:]
                for (index, section) in RPGTilesetSection.allCases.enumerated()
                where names.indices.contains(index) {
                    let text = names[index].stringValue ?? ""
                    if !text.isEmpty { sections[section] = text }
                }
                return (id, name, mode, sections, nil, [])
            }
        } else {
            let document = try RPGDataDocument.decode(bytes, kind: .tilesets, engine: engine, marshalLimits: marshalLimits)
            rawRecords = document.binaryRecords().enumerated().compactMap { offset, node in
                guard let node else { return nil }
                let id = Int(node.intMember("@id") ?? Int64(offset))
                let name = node.stringMember("@name") ?? "Tileset \(id)"
                let mode = Int(node.intMember("@mode") ?? 0)
                var sections: [RPGTilesetSection: String] = [:]
                if let names = node[member: "@tileset_names"]?.value.kind.arrayValue {
                    for (index, section) in RPGTilesetSection.allCases.enumerated()
                    where names.indices.contains(index) {
                        let text = names[index].value.kind.stringValue?.utf8String ?? ""
                        if !text.isEmpty { sections[section] = text }
                    }
                }
                let xpTileset = node.stringMember("@tileset_name")
                let xpAutotiles: [String] = {
                    guard let list = node[member: "@autotile_names"]?.value.kind.arrayValue else { return [] }
                    return list.map { $0.value.kind.stringValue?.utf8String ?? "" }
                }()
                return (id, name, mode, sections, xpTileset, xpAutotiles)
            }
        }

        var definitions: [Int: RPGTilesetDefinition] = [:]
        for record in rawRecords {
            if definitions[record.id] != nil {
                diagnostics.append(.init(code: "tileset.duplicate", severity: .warning,
                    messageEN: "Tileset id \(record.id) appears more than once; the first record is used.",
                    messageZH: "图块集 ID \(record.id) 出现多次，已使用第一条记录。", path: dataPath.value))
                continue
            }
            if engine == .rpgMakerXP {
                let normal = resolveImageName(record.xpTileset ?? "", folder: "Graphics/Tilesets",
                                              index: index, diagnostics: &diagnostics)
                var autotiles: [String?] = []
                for autotileIndex in 0..<7 {
                    let name = record.xpAutotiles.indices.contains(autotileIndex)
                        ? record.xpAutotiles[autotileIndex] : ""
                    autotiles.append(resolveImageName(name, folder: "Graphics/Autotiles",
                                                      index: index, diagnostics: &diagnostics))
                }
                definitions[record.id] = RPGTilesetDefinition(
                    id: record.id, name: record.name, engine: engine, mode: record.mode,
                    sourcePath: dataPath.value, sectionPaths: [:],
                    xpTilesetPath: normal, xpAutotilePaths: autotiles,
                    rawSectionNames: [:], rawXPAutotileNames: record.xpAutotiles)
            } else {
                let folder = engine == .rpgMakerMV || engine == .rpgMakerMZ
                    ? "img/tilesets" : "Graphics/System"
                var paths: [RPGTilesetSection: String] = [:]
                for section in RPGTilesetSection.allCases {
                    guard let name = record.sectionNames[section], !name.isEmpty else { continue }
                    if let path = resolveImageName(name, folder: folder, index: index,
                                                   diagnostics: &diagnostics) {
                        paths[section] = path
                    }
                }
                definitions[record.id] = RPGTilesetDefinition(
                    id: record.id, name: record.name, engine: engine, mode: record.mode,
                    sourcePath: dataPath.value, sectionPaths: paths,
                    xpTilesetPath: nil, xpAutotilePaths: [],
                    rawSectionNames: record.sectionNames, rawXPAutotileNames: [])
            }
        }
        return RPGTilesetCatalog(engine: engine, definitions: definitions,
                                 diagnostics: diagnostics, dataPath: dataPath.value)
    }

    private static func expectedTilesetDataPath(engine: RPGEngine) -> String {
        if let ext = engine.marshalExtension { return "Data/Tilesets.\(ext)" }
        return "data/Tilesets.json"
    }

    private static func resolveTilesetDataPath(engine: RPGEngine, index: RPGProjectFileIndex) -> GameRelativePath? {
        let expected = expectedTilesetDataPath(engine: engine)
        if let exact = index.exact(expected) { return exact }
        let (path, _) = index.uniqueCaseInsensitive(expected)
        return path
    }

    /// Resolves a resource name to a declared image file. The result is nil
    /// (with a diagnostic) for empty names, traversal, absolute paths,
    /// duplicates and missing files.
    private static func resolveImageName(_ rawName: String, folder: String,
                                         index: RPGProjectFileIndex,
                                         diagnostics: inout [RPGTileAssetDiagnostic]) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"), !name.contains(":"),
              !name.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            diagnostics.append(.init(code: "tileset.name.unsafe", severity: .error,
                messageEN: "A tileset image name contains an invalid or unsafe path and was not loaded.",
                messageZH: "图块图片名称包含无效或不安全路径，已拒绝加载。", path: rawName))
            return nil
        }
        let supported = ["png", "jpg", "jpeg", "bmp", "webp"]
        let lower = name.lowercased()
        var candidates: [String] = []
        let hasExtension = supported.contains(where: { lower.hasSuffix(".\($0)") })
        if hasExtension {
            candidates.append(folder + "/" + name)
        } else {
            for ext in ["png", "bmp", "jpg", "jpeg", "webp"] {
                candidates.append(folder + "/" + name + "." + ext)
            }
        }
        for candidate in candidates {
            let (path, ambiguous) = index.uniqueCaseInsensitive(candidate)
            if let path {
                if ambiguous {
                    diagnostics.append(.init(code: "tileset.asset.ambiguous", severity: .warning,
                        messageEN: "Multiple files match \(candidate); the exact case was preferred. Check the project for duplicate image names.",
                        messageZH: "有多个文件匹配 \(candidate)；已优先使用大小写完全一致的文件，请检查项目中的重名图片。",
                        path: candidate))
                }
                return path.value
            }
        }
        diagnostics.append(.init(code: "tileset.asset.missing", severity: .warning,
            messageEN: "Tileset image \(folder)/\(name) is not in the project. The map data is kept; assign or import the image to preview it.",
            messageZH: "项目中没有图块图片 \(folder)/\(name)。地图数据会保留；导入或指定图片后即可预览。",
            path: folder + "/" + name))
        return nil
    }
}


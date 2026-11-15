// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Which existing native editor can be offered for one selected asset. The
/// App still owns the actual `GameEditingSession`; this classification is
/// metadata for choosing a surface, never a permission or a second editor.
public enum GameNativeEditorKind: String, Equatable, Sendable {
    case tileMap
    case sprite
    case parameterForm
    case narrative
    case audio
    case code
    case document
    case binary
    case unsupported
}

public struct GameEditorEntry: Equatable, Sendable, Identifiable {
    public let path: GameRelativePath
    public let kind: GameNativeEditorKind
    public let engine: GameEngineID
    public let bytes: Int

    public var id: String { path.value }
}

/// File classification used by the Space quick-edit browser. It covers all 20
/// engines with extension/path rules and never hides an unknown file: unknown
/// assets stay visible and hand off to the existing IDE.
public enum GameEditorPresentation {
    private static let spriteExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tga", "aseprite", "ase"
    ]
    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "ogg", "m4a", "aac", "flac", "aiff", "aif", "mid", "midi", "smf"
    ]
    private static let documentExtensions: Set<String> = [
        "md", "txt", "ini", "cfg", "conf", "toml", "yaml", "yml", "csv", "tsv"
    ]
    private static let binaryExtensions: Set<String> = [
        "rxdata", "rvdata", "rvdata2", "rmmzsave", "wasm", "dll", "so", "dylib",
        "exe", "bin", "pak", "dat", "ttf", "otf", "woff", "woff2"
    ]

    public static func classify(path: GameRelativePath, engine: GameEngineID,
                                project: GameStoredProject) -> GameNativeEditorKind {
        let lower = path.value.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (lower as NSString).pathExtension

        // The project's own declarations are structured, not ordinary JSON.
        if name == "floe-inputs.json" || name == "floe-game.json" { return .parameterForm }

        // RPG Maker maps and tilesets are structured, not plain JSON.
        if isRPGMap(name: name, path: lower) { return .tileMap }
        if Self.rpgEngine(for: engine),
           ["rxdata", "rvdata", "rvdata2", "json"].contains(ext) {
            // Database/System/CommonEvents are edited through the native
            // parameter adapter, never as a generic JSON text file.
            return name.hasPrefix("scripts.") ? .binary : .parameterForm
        }
        if lower.contains("tilesets/") || lower.contains("tileset/") { return .sprite }

        // Narrative adapters and the project's own script/data formats.
        switch engine {
        case .ink where ext == "ink": return .narrative
        case .twine where ext == "json" || ext == "twee" || lower.hasSuffix(".twine.json"): return .narrative
        case .tic80 where ext == "tic": return .narrative
        case .microStudio where ext == "ms": return .narrative
        case .wasm4 where ext == "wasm": return .binary
        case .gdevelop where ext == "json" && lower.contains("game.json"): return .parameterForm
        case .cocosCreator where lower.contains("assets/") && ext == "scene": return .parameterForm
        case .unity where lower.contains("assets/") && ext == "scene": return .parameterForm
        case .godot where ext == "tscn" || ext == "tres": return .parameterForm
        default: break
        }

        // Ren'Py/RPG script source is text and belongs in the existing IDE,
        // with the narrative visual surface offered only for declarations.
        if ext == "rpy" || ext == "rb" || ext == "js" || ext == "ts"
            || ext == "gd" || ext == "lua" || ext == "cs" || ext == "c" || ext == "h"
            || ext == "cpp" || ext == "mm" || ext == "py" || ext == "html" || ext == "css"
            || ext == "json" || ext == "xml" || ext == "plist" || ext == "sh" {
            return .code
        }
        if spriteExtensions.contains(ext) { return .sprite }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if binaryExtensions.contains(ext) { return .binary }
        return .unsupported
    }

    /// Editable entries for the quick-edit browser, bounded and sorted. Binary
    /// and unsupported files remain listed for the IDE; they are not filtered
    /// out of the project.
    public static func entries(project: GameStoredProject, engine: GameEngineID,
                               prefix: String? = nil, limit: Int = 500) -> [GameEditorEntry] {
        let bounded = max(1, min(2_000, limit))
        var result: [GameEditorEntry] = []
        for file in project.files {
            if result.count >= bounded { break }
            if let prefix, !file.path.value.hasPrefix(prefix + "/") { continue }
            let kind = classify(path: file.path, engine: engine, project: project)
            result.append(.init(path: file.path, kind: kind, engine: engine, bytes: file.bytes))
        }
        return result.sorted { $0.path.value < $1.path.value }
    }

    /// True only for surfaces that can be offered without turning binary
    /// bytes into text. The IDE remains the fallback for everything else.
    public static func offersNativeSurface(_ kind: GameNativeEditorKind) -> Bool {
        switch kind {
        case .tileMap, .sprite, .parameterForm, .narrative: return true
        case .audio, .code, .document, .binary, .unsupported: return false
        }
    }

    public static func preferredEntry(project: GameStoredProject, engine: GameEngineID) -> GameEditorEntry? {
        let values = entries(project: project, engine: engine)
        let priority: [GameNativeEditorKind] = [.tileMap, .narrative, .parameterForm, .sprite, .code, .document, .audio, .binary, .unsupported]
        for kind in priority {
            if let entry = values.first(where: { $0.kind == kind }) { return entry }
        }
        return values.first
    }

    private static func rpgEngine(for engine: GameEngineID) -> Bool {
        switch engine {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ: return true
        default: return false
        }
    }

    private static func isRPGMap(name: String, path: String) -> Bool {
        let lower = name.lowercased()
        return (lower.hasPrefix("map") || path.contains("/maps/"))
            && (lower.hasSuffix(".rxdata") || lower.hasSuffix(".rvdata")
                || lower.hasSuffix(".rvdata2") || lower.hasSuffix(".json"))
    }
}

public enum GameQuickEditCopy {
    public static func title(for kind: GameNativeEditorKind, zh: Bool) -> String {
        switch kind {
        case .tileMap: return zh ? "地图编辑" : "Map editor"
        case .sprite: return zh ? "图像编辑" : "Image editor"
        case .parameterForm: return zh ? "参数编辑" : "Parameters"
        case .narrative: return zh ? "剧情编辑" : "Story"
        case .audio: return zh ? "音频" : "Audio"
        case .code: return zh ? "代码" : "Code"
        case .document: return zh ? "文本" : "Text"
        case .binary: return zh ? "二进制文件" : "Binary file"
        case .unsupported: return zh ? "其他文件" : "Other file"
        }
    }
}

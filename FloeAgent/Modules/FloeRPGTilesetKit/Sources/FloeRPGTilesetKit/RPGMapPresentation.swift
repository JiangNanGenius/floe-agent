// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeGameCore
import FloeRPGCore

public struct RPGResolvedProjectImage: Sendable, Equatable {
    public var path: String?
    public var ambiguous: Bool
    public var unsafeName: Bool
    public var missing: Bool
    public init(path: String? = nil, ambiguous: Bool = false,
                unsafeName: Bool = false, missing: Bool = false) {
        self.path = path; self.ambiguous = ambiguous
        self.unsafeName = unsafeName; self.missing = missing
    }
}

public extension RPGProjectFileIndex {
    /// Resolves an image stem (e.g. a character name) under a folder. The
    /// name is untrusted: absolute paths, `..` and backslashes are rejected.
    func resolveImage(folder: String, name rawName: String) -> RPGResolvedProjectImage {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .init(missing: true) }
        guard !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"), !name.contains(":"),
              !name.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return .init(unsafeName: true)
        }
        let supported = ["png", "bmp", "jpg", "jpeg", "webp"]
        let lower = name.lowercased()
        let hasExtension = supported.contains(where: { lower.hasSuffix(".\($0)") })
        var candidates: [String] = []
        if hasExtension {
            candidates.append(folder + "/" + name)
        } else {
            for ext in ["png", "bmp", "jpg", "jpeg", "webp"] {
                candidates.append(folder + "/" + name + "." + ext)
            }
        }
        var ambiguous = false
        for candidate in candidates {
            let (path, isAmbiguous) = uniqueCaseInsensitive(candidate)
            if let path { return .init(path: path.value, ambiguous: isAmbiguous || ambiguous) }
            if isAmbiguous { ambiguous = true }
        }
        return .init(ambiguous: ambiguous, missing: true)
    }
}

/// Event page 0 graphic reference. Only the data path is resolved; no image
/// is decoded here.
public struct RPGEventGraphicRef: Sendable, Hashable {
    public var eventID: Int
    public var characterName: String
    public var characterIndex: Int
    public var direction: Int
    public var pattern: Int
    public var imagePath: String?
    public init(eventID: Int, characterName: String, characterIndex: Int,
                direction: Int, pattern: Int, imagePath: String? = nil) {
        self.eventID = eventID; self.characterName = characterName
        self.characterIndex = characterIndex; self.direction = direction
        self.pattern = pattern; self.imagePath = imagePath
    }
}

public struct RPGMapPresentation: Sendable {
    public var tilesetID: Int
    public var events: [Int: RPGEventGraphicRef]
    public var diagnostics: [RPGTileAssetDiagnostic]
    public init(tilesetID: Int, events: [Int: RPGEventGraphicRef] = [:],
                diagnostics: [RPGTileAssetDiagnostic] = []) {
        self.tilesetID = tilesetID; self.events = events; self.diagnostics = diagnostics
    }
}

/// Reads only presentation metadata from a decoded map document. The map
/// document itself remains the authoritative source for tile data.
public enum RPGMapPresentationLoader {
    public static func load(document: RPGMapDocument,
                            projectIndex: RPGProjectFileIndex) -> RPGMapPresentation {
        var diagnostics: [RPGTileAssetDiagnostic] = []
        let tilesetID = document.tilesetID
        let folder: String
        switch document.engine {
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: folder = "Graphics/Characters"
        case .rpgMakerMV, .rpgMakerMZ: folder = "img/characters"
        }
        var events: [Int: RPGEventGraphicRef] = [:]
        for event in document.events {
            guard let graphic = firstPageGraphic(event: event, engine: document.engine) else { continue }
            let resolved = projectIndex.resolveImage(folder: folder, name: graphic.characterName)
            if resolved.unsafeName {
                diagnostics.append(.init(code: "character.name.unsafe", severity: .warning,
                    messageEN: "Event \(event.id) has an unsafe character image name; using its map marker.",
                    messageZH: "事件 \(event.id) 的行走图名称不安全，已改用地图标记。"))
            } else if resolved.missing && !graphic.characterName.isEmpty {
                diagnostics.append(.init(code: "character.image.missing", severity: .info,
                    messageEN: "Event \(event.id) uses a character image that is not in the project; its marker is kept.",
                    messageZH: "事件 \(event.id) 使用的行走图不在项目中，已保留其地图标记。",
                    path: folder + "/" + graphic.characterName))
            } else if resolved.ambiguous {
                diagnostics.append(.init(code: "character.image.ambiguous", severity: .warning,
                    messageEN: "Multiple character images match event \(event.id); the exact case was preferred.",
                    messageZH: "事件 \(event.id) 匹配到多个行走图；已优先使用大小写完全一致的文件。"))
            }
            events[event.id] = RPGEventGraphicRef(
                eventID: event.id, characterName: graphic.characterName,
                characterIndex: graphic.characterIndex, direction: graphic.direction,
                pattern: graphic.pattern, imagePath: resolved.path)
        }
        return RPGMapPresentation(tilesetID: tilesetID, events: events, diagnostics: diagnostics)
    }

    private struct FirstPageGraphic {
        var characterName: String
        var characterIndex: Int
        var direction: Int
        var pattern: Int
    }

    private static func firstPageGraphic(event: RPGMapEvent, engine: RPGEngine) -> FirstPageGraphic? {
        if let json = event.json {
            guard let pages = json["pages"]?.arrayValue, let first = pages.first,
                  let image = first["image"]?.objectValue else { return nil }
            let name = image["characterName"]?.stringValue ?? ""
            guard !name.isEmpty else { return nil }
            return FirstPageGraphic(
                characterName: name,
                characterIndex: image["characterIndex"]?.intValue ?? 0,
                direction: image["direction"]?.intValue ?? 2,
                pattern: image["pattern"]?.intValue ?? 1)
        }
        guard let node = event.node,
              let pages = node[member: "@pages"]?.value.kind.arrayValue,
              let first = pages.first,
              let graphic = first[member: "@graphic"] else { return nil }
        let name = graphic.stringMember("@character_name") ?? ""
        guard !name.isEmpty else { return nil }
        return FirstPageGraphic(
            characterName: name,
            characterIndex: Int(graphic.intMember("@character_index") ?? 0),
            direction: Int(graphic.intMember("@direction") ?? 2),
            pattern: Int(graphic.intMember("@pattern") ?? 1))
    }
}

public extension RPGMapDocument {
    var tilesetID: Int {
        if let json { return json["tilesetId"]?.intValue ?? 0 }
        return Int(root?.intMember("@tileset_id") ?? 0)
    }
}

/// Character sheet geometry for static event previews. It uses the documented
/// 3x4 (VX/Ace/MV/MZ) and 4x4 (XP) frame layouts; an event's own page
/// direction/pattern/index selects the cell.
public struct RPGCharacterSheetLayout: Sendable {
    public let engine: RPGEngine
    public init(engine: RPGEngine) { self.engine = engine }

    public var frameSize: CGSize {
        switch engine {
        case .rpgMakerXP: return CGSize(width: 32, height: 48)
        case .rpgMakerVX, .rpgMakerVXAce: return CGSize(width: 32, height: 32)
        case .rpgMakerMV, .rpgMakerMZ: return CGSize(width: 48, height: 48)
        }
    }

    public var framesPerCharacter: Int {
        engine == .rpgMakerXP ? 4 : 3
    }

    public func sourceRect(characterIndex: Int, direction: Int, pattern: Int,
                           imageSize: CGSize) -> CGRect? {
        guard characterIndex >= 0, characterIndex < 8 else { return nil }
        let frame = frameSize
        let columns = 4 // characters per sheet row
        let charColumn = characterIndex % columns
        let charRow = characterIndex / columns
        let frameColumn = min(max(0, pattern), framesPerCharacter - 1)
        let directionRow = min(max(0, direction / 2 - 1), 3)
        let rect = CGRect(x: CGFloat(charColumn * framesPerCharacter + frameColumn) * frame.width,
                          y: CGFloat(charRow * 4 + directionRow) * frame.height,
                          width: frame.width, height: frame.height)
        guard rect.maxX <= imageSize.width + 0.0001,
              rect.maxY <= imageSize.height + 0.0001 else { return nil }
        return rect
    }

    /// The usual idle frame for each engine (middle frame for 3-frame sheets).
    public var idlePattern: Int { engine == .rpgMakerXP ? 0 : 1 }
}

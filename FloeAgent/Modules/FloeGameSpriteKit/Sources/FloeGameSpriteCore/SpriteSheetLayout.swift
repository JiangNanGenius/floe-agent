// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameEditingCore

public enum SpriteSheetScope: String, CaseIterable, Codable, Sendable {
    case character
    case fullSheet

    public var title: GameEditCopy {
        switch self {
        case .character: return GameEditCopy("One character", "单个角色")
        case .fullSheet: return GameEditCopy("Full sheet", "完整图集")
        }
    }
}

public struct SpriteSheetGridShape: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let characterColumns: Int
    public let characterRows: Int

    public init(columns: Int, rows: Int, characterColumns: Int, characterRows: Int) {
        self.columns = columns
        self.rows = rows
        self.characterColumns = characterColumns
        self.characterRows = characterRows
    }
}

/// Common RPG Maker character-sheet geometry. Presets only select a grid;
/// they never resize pixels. An image whose dimensions do not divide exactly
/// is rejected with a readable message instead of being stretched or cropped.
public enum SpriteSheetPreset: String, CaseIterable, Codable, Sendable {
    case custom
    case rpgMakerXP
    case rpgMakerVX
    case rpgMakerVXAce
    case rpgMakerMV
    case rpgMakerMZ

    public var title: GameEditCopy {
        switch self {
        case .custom: return GameEditCopy("Custom grid", "自定义网格")
        case .rpgMakerXP: return GameEditCopy("RPG Maker XP · 4 × 4", "RPG Maker XP · 4 × 4")
        case .rpgMakerVX: return GameEditCopy("RPG Maker VX · 3 × 4", "RPG Maker VX · 3 × 4")
        case .rpgMakerVXAce: return GameEditCopy("RPG Maker VX Ace · 3 × 4", "RPG Maker VX Ace · 3 × 4")
        case .rpgMakerMV: return GameEditCopy("RPG Maker MV · 3 × 4 / 12 × 8", "RPG Maker MV · 3 × 4 / 12 × 8")
        case .rpgMakerMZ: return GameEditCopy("RPG Maker MZ · 3 × 4 / 12 × 8", "RPG Maker MZ · 3 × 4 / 12 × 8")
        }
    }

    public var isEnginePreset: Bool { self != .custom }

    public var supportsFullSheet: Bool {
        switch self {
        case .custom, .rpgMakerXP: return false
        default: return true
        }
    }

    public func shape(scope: SpriteSheetScope) -> SpriteSheetGridShape? {
        switch self {
        case .custom:
            return nil
        case .rpgMakerXP:
            guard scope == .character else { return nil }
            return SpriteSheetGridShape(columns: 4, rows: 4, characterColumns: 4, characterRows: 4)
        case .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ:
            switch scope {
            case .character:
                return SpriteSheetGridShape(columns: 3, rows: 4, characterColumns: 3, characterRows: 4)
            case .fullSheet:
                return SpriteSheetGridShape(columns: 12, rows: 8, characterColumns: 3, characterRows: 4)
            }
        }
    }
}

public enum SpriteSheetError: Error, Equatable, Sendable {
    case invalidGrid
    case frameLimitExceeded
    case dimensionsMismatch(width: Int, height: Int, columns: Int, rows: Int)
    case presetUnavailable(preset: SpriteSheetPreset, scope: SpriteSheetScope)

    public var copy: GameEditCopy {
        switch self {
        case .invalidGrid:
            return GameEditCopy("Enter positive frame columns and rows.",
                                "请输入有效的帧列数和行数。")
        case .frameLimitExceeded:
            return GameEditCopy("The frame grid is too large. Use at most 64 columns and 64 rows.",
                                "帧网格过大，最多支持 64 列、64 行。")
        case .dimensionsMismatch(let width, let height, let columns, let rows):
            return GameEditCopy(
                "The \(width) × \(height) image does not divide into \(columns) × \(rows) equal frames. Choose a matching grid or preset; the image is not resized.",
                "\(width) × \(height) 的图片无法平均分成 \(columns) × \(rows) 帧。请选择匹配的网格或预设，图片不会被缩放。")
        case .presetUnavailable(let preset, let scope):
            return GameEditCopy(
                "\(preset.title.en) does not provide a \(scope.title.en.lowercased()) layout.",
                "\(preset.title.zh) 不提供\(scope.title.zh)布局。")
        }
    }
}

public enum SpriteFrameDirection: String, CaseIterable, Codable, Sendable {
    case down, left, right, up, custom

    public var title: GameEditCopy {
        switch self {
        case .down: return GameEditCopy("Down", "下")
        case .left: return GameEditCopy("Left", "左")
        case .right: return GameEditCopy("Right", "右")
        case .up: return GameEditCopy("Up", "上")
        case .custom: return GameEditCopy("Frame", "帧")
        }
    }
}

public struct SpriteFrameDescriptor: Hashable, Identifiable, Sendable {
    public let index: Int
    public let column: Int
    public let row: Int
    public let characterIndex: Int?
    public let localColumn: Int
    public let localRow: Int
    public let direction: SpriteFrameDirection

    public var id: Int { index }

    public func title(_ locale: GameEditLocale) -> String {
        let number = direction == .custom ? index + 1 : localColumn + 1
        var components: [String] = []
        if let characterIndex, direction != .custom {
            components.append(locale == .chinese ? "角色 \(characterIndex + 1)" : "Character \(characterIndex + 1)")
        }
        if direction == .custom {
            components.append(locale == .chinese ? "帧 \(number)" : "Frame \(number)")
        } else {
            components.append(direction.title.text(locale))
            components.append(locale == .chinese ? "第 \(number) 帧" : "frame \(number)")
        }
        return components.joined(separator: " · ")
    }
}

public struct SpriteFrameGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let characterIndex: Int?
    public let frameIndices: [Int]

    public init(id: String, characterIndex: Int?, frameIndices: [Int]) {
        self.id = id
        self.characterIndex = characterIndex
        self.frameIndices = frameIndices
    }
}

/// A validated integer frame grid for one exact image size. All editing is
/// clipped to the selected frame; the grid never changes image dimensions.
public struct SpriteSheetLayout: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let frameWidth: Int
    public let frameHeight: Int
    public let preset: SpriteSheetPreset
    public let scope: SpriteSheetScope

    public init(columns: Int, rows: Int, frameWidth: Int, frameHeight: Int,
                preset: SpriteSheetPreset = .custom,
                scope: SpriteSheetScope = .character) throws {
        guard columns > 0, rows > 0, frameWidth > 0, frameHeight > 0 else {
            throw SpriteSheetError.invalidGrid
        }
        guard columns <= 64, rows <= 64 else { throw SpriteSheetError.frameLimitExceeded }
        let (count, overflow) = columns.multipliedReportingOverflow(by: rows)
        guard !overflow, count <= 4_096 else { throw SpriteSheetError.frameLimitExceeded }
        let (pixelWidth, widthOverflow) = columns.multipliedReportingOverflow(by: frameWidth)
        let (pixelHeight, heightOverflow) = rows.multipliedReportingOverflow(by: frameHeight)
        guard !widthOverflow, !heightOverflow,
              pixelWidth <= SpritePixelImage.maximumDimension,
              pixelHeight <= SpritePixelImage.maximumDimension else {
            throw SpriteSheetError.invalidGrid
        }
        if preset != .custom {
            guard let shape = preset.shape(scope: scope),
                  shape.columns == columns, shape.rows == rows else {
                throw SpriteSheetError.presetUnavailable(preset: preset, scope: scope)
            }
        }
        self.columns = columns
        self.rows = rows
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.preset = preset
        self.scope = scope
    }

    public var frameCount: Int { columns * rows }
    public var pixelSize: SpritePixelSize {
        SpritePixelSize(width: columns * frameWidth, height: rows * frameHeight)
    }
    public var framePixelCount: Int { frameWidth * frameHeight }
    public var isCustom: Bool { preset == .custom }

    public func validated(for size: SpritePixelSize) throws -> SpriteSheetLayout {
        let expected = pixelSize
        guard expected == size else {
            throw SpriteSheetError.dimensionsMismatch(width: size.width, height: size.height,
                                                      columns: columns, rows: rows)
        }
        return self
    }

    public func frameRect(column: Int, row: Int) -> SpritePixelRect? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return SpritePixelRect(x: column * frameWidth, y: row * frameHeight,
                               width: frameWidth, height: frameHeight)
    }

    public func frameRect(at index: Int) -> SpritePixelRect? {
        guard index >= 0, index < frameCount else { return nil }
        return frameRect(column: index % columns, row: index / columns)
    }

    public func frameIndex(column: Int, row: Int) -> Int? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return row * columns + column
    }

    public func descriptor(at index: Int) -> SpriteFrameDescriptor? {
        guard index >= 0, index < frameCount else { return nil }
        let column = index % columns
        let row = index / columns
        guard preset != .custom, let shape = preset.shape(scope: scope),
              shape.characterColumns > 0, shape.characterRows > 0 else {
            return SpriteFrameDescriptor(index: index, column: column, row: row,
                                         characterIndex: nil, localColumn: column, localRow: row,
                                         direction: .custom)
        }
        let localColumn = column % shape.characterColumns
        let localRow = row % shape.characterRows
        let charactersPerRow = max(1, columns / shape.characterColumns)
        let characterIndex = (row / shape.characterRows) * charactersPerRow
            + (column / shape.characterColumns)
        let direction: SpriteFrameDirection
        switch localRow {
        case 0: direction = .down
        case 1: direction = .left
        case 2: direction = .right
        case 3: direction = .up
        default: direction = .custom
        }
        return SpriteFrameDescriptor(index: index, column: column, row: row,
                                     characterIndex: characterIndex,
                                     localColumn: localColumn, localRow: localRow,
                                     direction: direction)
    }

    /// Index groups used by the frame list. A full sheet is grouped per
    /// character block; a custom grid stays one flat list.
    public func frameGroups() -> [SpriteFrameGroup] {
        guard preset != .custom, let shape = preset.shape(scope: scope),
              shape.characterColumns > 0, shape.characterRows > 0 else {
            return [SpriteFrameGroup(id: "custom", characterIndex: nil,
                                     frameIndices: Array(0..<frameCount))]
        }
        let charactersPerRow = columns / shape.characterColumns
        let characterRowCount = rows / shape.characterRows
        guard charactersPerRow > 0, characterRowCount > 0 else {
            return [SpriteFrameGroup(id: "custom", characterIndex: nil,
                                     frameIndices: Array(0..<frameCount))]
        }
        var groups: [SpriteFrameGroup] = []
        let totalCharacters = charactersPerRow * characterRowCount
        for character in 0..<totalCharacters {
            let blockColumn = character % charactersPerRow
            let blockRow = character / charactersPerRow
            var indices: [Int] = []
            indices.reserveCapacity(shape.characterColumns * shape.characterRows)
            for localRow in 0..<shape.characterRows {
                let row = blockRow * shape.characterRows + localRow
                let start = row * columns + blockColumn * shape.characterColumns
                for localColumn in 0..<shape.characterColumns {
                    indices.append(start + localColumn)
                }
            }
            groups.append(SpriteFrameGroup(id: "character-\(character)", characterIndex: character,
                                           frameIndices: indices))
        }
        return groups
    }

    /// Frames that animate together for the selected frame: its direction row
    /// inside one character block. Custom grids use the whole selected row.
    public func animationFrameIndices(containing index: Int) -> [Int] {
        guard let descriptor = descriptor(at: index) else { return [] }
        if preset == .custom || descriptor.direction == .custom {
            let row = descriptor.row
            return (0..<columns).map { row * columns + $0 }
        }
        guard let shape = preset.shape(scope: scope) else { return [index] }
        let blockStart = (descriptor.column / shape.characterColumns) * shape.characterColumns
        return (0..<shape.characterColumns).map {
            descriptor.row * columns + blockStart + $0
        }
    }

    public static func custom(for size: SpritePixelSize, columns: Int, rows: Int) throws -> SpriteSheetLayout {
        guard columns > 0, rows > 0, columns <= 64, rows <= 64 else {
            throw SpriteSheetError.invalidGrid
        }
        guard size.width % columns == 0, size.height % rows == 0 else {
            throw SpriteSheetError.dimensionsMismatch(width: size.width, height: size.height,
                                                      columns: columns, rows: rows)
        }
        return try SpriteSheetLayout(columns: columns, rows: rows,
                                     frameWidth: size.width / columns,
                                     frameHeight: size.height / rows,
                                     preset: .custom, scope: .character)
    }

    public static func applying(_ preset: SpriteSheetPreset, scope: SpriteSheetScope,
                                to size: SpritePixelSize) throws -> SpriteSheetLayout {
        guard preset != .custom, let shape = preset.shape(scope: scope) else {
            throw SpriteSheetError.presetUnavailable(preset: preset, scope: scope)
        }
        guard size.width % shape.columns == 0, size.height % shape.rows == 0 else {
            throw SpriteSheetError.dimensionsMismatch(width: size.width, height: size.height,
                                                      columns: shape.columns, rows: shape.rows)
        }
        return try SpriteSheetLayout(columns: shape.columns, rows: shape.rows,
                                     frameWidth: size.width / shape.columns,
                                     frameHeight: size.height / shape.rows,
                                     preset: preset, scope: scope)
    }

    /// Conservative auto-detection for the common RPG Maker sheets. It only
    /// accepts square frames of at least 8 pixels; users can always choose a
    /// preset or custom grid explicitly.
    public static func detected(for size: SpritePixelSize) -> SpriteSheetLayout? {
        func fits(_ columns: Int, _ rows: Int) -> Bool {
            guard size.width % columns == 0, size.height % rows == 0 else { return false }
            let frameWidth = size.width / columns
            let frameHeight = size.height / rows
            return frameWidth == frameHeight && frameWidth >= 8
        }
        if fits(12, 8), let layout = try? applying(.rpgMakerMV, scope: .fullSheet, to: size) {
            return layout
        }
        if fits(4, 4), let layout = try? applying(.rpgMakerXP, scope: .character, to: size) {
            return layout
        }
        if fits(3, 4), let layout = try? applying(.rpgMakerMV, scope: .character, to: size) {
            return layout
        }
        return nil
    }

    /// Fallback used when a sheet was rotated and its old preset no longer
    /// matches. The old frame size is transposed so every pixel stays in a
    /// valid, exactly-covering grid without resizing the image.
    public func transposedForRotation() -> SpriteSheetLayout? {
        try? SpriteSheetLayout(columns: rows, rows: columns,
                               frameWidth: frameHeight, frameHeight: frameWidth,
                               preset: .custom, scope: .character)
    }
}

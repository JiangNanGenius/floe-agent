// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit

/// Fixed logical operations kept for old callers and legacy persisted data.
/// New defaults and project declarations use keyboard bindings instead.
public enum GameTouchAction: String, Codable, CaseIterable, Hashable, Sendable {
    case left, right, up, down, confirm, cancel, action1, action2, action3, action4, start, select

    public var isDirection: Bool {
        switch self {
        case .left, .right, .up, .down: return true
        default: return false
        }
    }

    /// The existing WebKit player's documented bridge fallback for typed
    /// actions. Used only to migrate old persisted profiles, never as a new
    /// default. The current player maps exactly these keys.
    public var legacyKeyboardKey: GameKeyboardKey? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .confirm: return .enter
        case .start: return .enter
        case .cancel: return .escape
        case .action1: return .z
        case .action2: return .x
        case .action3: return .a
        case .action4: return .s
        case .select: return .tab
        }
    }
}

/// A bounded, data-only control identity. IDs are never executable code,
/// selectors, URLs, or file paths. Legacy raw values `a`, `b`, `x`, `y`,
/// `start`, and `select` decode unchanged from the old string enum.
public struct GameTouchButtonID: RawRepresentable, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public static let a = GameTouchButtonID(unchecked: "a")
    public static let b = GameTouchButtonID(unchecked: "b")
    public static let x = GameTouchButtonID(unchecked: "x")
    public static let y = GameTouchButtonID(unchecked: "y")
    public static let start = GameTouchButtonID(unchecked: "start")
    public static let select = GameTouchButtonID(unchecked: "select")
    public static let allCases: [GameTouchButtonID] = [.a, .b, .x, .y, .start, .select]

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Throwing spelling used by the App and by project declarations.
    public init(_ raw: String) throws {
        guard let value = Self(rawValue: raw) else { throw GameProjectError.invalidEdit }
        self = value
    }

    private init(unchecked raw: String) { self.rawValue = raw }

    /// Stable generator for user-added controls. The prefix is sanitized to a
    /// fixed short ASCII token so the resulting ID always fits the bound.
    public static func generated(prefix: String = "key") -> GameTouchButtonID {
        let base = isValid(prefix) && prefix.utf8.count <= 24 ? prefix : "key"
        return GameTouchButtonID(unchecked: base + "." + UUID().uuidString.lowercased())
    }

    public static func isValid(_ raw: String) -> Bool {
        guard (1...64).contains(raw.utf8.count) else { return false }
        let scalars = raw.unicodeScalars
        guard let first = scalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return scalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || Self.punctuation.contains(scalar))
        }
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else { throw GameProjectError.invalidEdit }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let punctuation = CharacterSet(charactersIn: "._:-")
}

/// A physical keyboard chord. A chord is always pressed together; arrays in a
/// project declaration are never treated as alternatives. Keys are
/// canonicalized modifiers first, then by stable raw value.
public struct GameTouchChord: Codable, Hashable, Sendable {
    public let keys: [GameKeyboardKey]

    public init(keys: [GameKeyboardKey]) throws {
        guard (1...8).contains(keys.count), Set(keys).count == keys.count else {
            throw GameProjectError.invalidEdit
        }
        self.keys = keys.sorted { lhs, rhs in
            lhs.modifierOrder == rhs.modifierOrder
                ? lhs.rawValue < rhs.rawValue
                : lhs.modifierOrder < rhs.modifierOrder
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(keys: container.decode([GameKeyboardKey].self, forKey: .keys))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
    }

    private enum CodingKeys: String, CodingKey { case keys }
}

public enum GameTouchBinding: Codable, Hashable, Sendable {
    case key(GameKeyboardKey)
    case chord(GameTouchChord)
    /// Compatibility only. New profiles and declarations never emit this.
    case action(GameTouchAction)

    public init(chord: GameTouchChord) {
        self = chord.keys.count == 1 ? .key(chord.keys[0]) : .chord(chord)
    }

    public var keyboardKeys: [GameKeyboardKey]? {
        switch self {
        case .key(let key): return [key]
        case .chord(let chord): return chord.keys
        case .action: return nil
        }
    }

    public var keyCap: String {
        switch self {
        case .key(let key): return key.keyCap
        case .chord(let chord): return chord.keys.map(\.keyCap).joined(separator: " + ")
        case .action(let action):
            switch action {
            case .left: return "←"
            case .right: return "→"
            case .up: return "↑"
            case .down: return "↓"
            case .confirm: return "Confirm"
            case .cancel: return "Cancel"
            case .action1: return "Action 1"
            case .action2: return "Action 2"
            case .action3: return "Action 3"
            case .action4: return "Action 4"
            case .start: return "Start"
            case .select: return "Select"
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .key) {
            self = .key(try nested.decode(GameKeyboardKey.self, forKey: ._0))
            return
        }
        if let nested = try? container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .chord) {
            self = .chord(try nested.decode(GameTouchChord.self, forKey: ._0))
            return
        }
        if let nested = try? container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .action) {
            self = .action(try nested.decode(GameTouchAction.self, forKey: ._0))
            return
        }
        // Accept the direct spelling too, without weakening the legacy shape.
        if let direct = try? container.decode(GameKeyboardKey.self, forKey: .key) {
            self = .key(direct)
            return
        }
        if let direct = try? container.decode(GameTouchChord.self, forKey: .chord) {
            self = .chord(direct)
            return
        }
        if let direct = try? container.decode(GameTouchAction.self, forKey: .action) {
            self = .action(direct)
            return
        }
        throw GameProjectError.invalidEdit
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let value):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .key)
            try nested.encode(value, forKey: ._0)
        case .chord(let value):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .chord)
            try nested.encode(value, forKey: ._0)
        case .action(let value):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .action)
            try nested.encode(value, forKey: ._0)
        }
    }

    private enum CodingKeys: String, CodingKey { case key, chord, action }
    private enum AssociatedKeys: String, CodingKey { case _0 }
}

/// Input encoding only. This is not another environment, permission, or
/// execution route; the host still owns the actual display/web session.
public enum GameTouchKeyboardTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case x11
}

/// Provenance for the current default preset. Engine defaults are documented
/// official key maps; template fallbacks are Floe samples, not universal
/// claims about every imported game.
public enum GameTouchDefaultSource: String, Codable, Hashable, Sendable {
    case engineDefault
    case projectDeclaration
    case templateFallback
    case legacyMigration
}

/// The four movement axes as simultaneous chords. A missing or empty axis is
/// explicitly unbound; it never falls back to arrows on its own.
public struct GameTouchDirectionBindings: Codable, Equatable, Hashable, Sendable {
    public private(set) var left: GameTouchChord?
    public private(set) var right: GameTouchChord?
    public private(set) var up: GameTouchChord?
    public private(set) var down: GameTouchChord?

    public init(left: GameTouchChord? = nil, right: GameTouchChord? = nil,
                up: GameTouchChord? = nil, down: GameTouchChord? = nil) {
        self.left = left
        self.right = right
        self.up = up
        self.down = down
    }

    public subscript(direction: GameTouchAction) -> GameTouchChord? {
        switch direction {
        case .left: return left
        case .right: return right
        case .up: return up
        case .down: return down
        default: return nil
        }
    }

    public var isEmpty: Bool { left == nil && right == nil && up == nil && down == nil }

    public mutating func set(_ chord: GameTouchChord?, for direction: GameTouchAction) throws {
        switch direction {
        case .left: left = chord
        case .right: right = chord
        case .up: up = chord
        case .down: down = chord
        default: throw GameProjectError.invalidEdit
        }
    }

    public func validate() throws {
        for chord in [left, right, up, down].compactMap({ $0 }) {
            _ = try GameTouchChord(keys: chord.keys)
        }
    }

    public static let arrows = GameTouchDirectionBindings(
        left: try! GameTouchChord(keys: [.left]),
        right: try! GameTouchChord(keys: [.right]),
        up: try! GameTouchChord(keys: [.up]),
        down: try! GameTouchChord(keys: [.down])
    )

    public static let wasd = GameTouchDirectionBindings(
        left: try! GameTouchChord(keys: [.a]),
        right: try! GameTouchChord(keys: [.d]),
        up: try! GameTouchChord(keys: [.w]),
        down: try! GameTouchChord(keys: [.s])
    )

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func chord(_ key: CodingKeys) throws -> GameTouchChord? {
            guard let raw = try container.decodeIfPresent([String].self, forKey: key), !raw.isEmpty else { return nil }
            var keys: [GameKeyboardKey] = []
            for value in raw {
                guard let key = GameKeyboardKey(rawValue: value) else { throw GameProjectError.invalidEdit }
                keys.append(key)
            }
            return try GameTouchChord(keys: keys)
        }
        left = try chord(.left)
        right = try chord(.right)
        up = try chord(.up)
        down = try chord(.down)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let left { try container.encode(left.keys.map(\.rawValue), forKey: .left) }
        if let right { try container.encode(right.keys.map(\.rawValue), forKey: .right) }
        if let up { try container.encode(up.keys.map(\.rawValue), forKey: .up) }
        if let down { try container.encode(down.keys.map(\.rawValue), forKey: .down) }
    }

    private enum CodingKeys: String, CodingKey { case left, right, up, down }
}

/// A bounded declaration shared by the App, the runtime owners, and the AI/host
/// that may author `floe-inputs.json`. This parses metadata only; it never
/// loads or executes project scripts.
public struct GameTouchProjectBindings: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumDeclarationBytes = 131_072

    public let engine: GameEngineID
    public let movement: GameTouchDirectionBindings
    public let buttons: [GameTouchButton]

    public var isEmpty: Bool { movement.isEmpty && buttons.isEmpty }

    public init(engine: GameEngineID, movement: GameTouchDirectionBindings = .init(),
                buttons: [GameTouchButton] = []) throws {
        guard buttons.count <= 64, Set(buttons.map(\.id)).count == buttons.count,
              buttons.allSatisfy({ $0.binding.keyboardKeys != nil }) else {
            throw GameProjectError.invalidEdit
        }
        try movement.validate()
        for button in buttons { try button.validate() }
        self.engine = engine
        self.movement = movement
        self.buttons = buttons
    }

    public init(json data: Data, engine: GameEngineID) throws {
        guard !data.isEmpty, data.count <= Self.maximumDeclarationBytes else {
            throw GameProjectError.limitExceeded("floeInputs")
        }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GameProjectError.invalidEdit
            }
            object = value
        } catch let error as GameProjectError {
            throw error
        } catch {
            throw GameProjectError.invalidEdit
        }
        guard Set(object.keys).isSubset(of: Self.topLevelKeys) else { throw GameProjectError.invalidEdit }
        guard let version = object["schemaVersion"] as? Int, version == Self.schemaVersion else {
            throw GameProjectError.invalidEdit
        }
        guard let declaredName = object["engine"] as? String,
              let declared = GameEngineID(rawValue: declaredName), declared == engine else {
            throw GameProjectError.invalidEdit
        }

        var movement = GameTouchDirectionBindings()
        if let rawMovement = object["movement"] {
            guard let dictionary = rawMovement as? [String: Any] else { throw GameProjectError.invalidEdit }
            guard Set(dictionary.keys).isSubset(of: Self.directionNames) else { throw GameProjectError.invalidEdit }
            for (name, value) in dictionary {
                guard let direction = Self.direction(named: name) else { throw GameProjectError.invalidEdit }
                guard let rawKeys = value as? [String] else { throw GameProjectError.invalidEdit }
                // An empty array explicitly means unbound. It is not arrows.
                if rawKeys.isEmpty { continue }
                guard (1...8).contains(rawKeys.count) else { throw GameProjectError.invalidEdit }
                var keys: [GameKeyboardKey] = []
                for raw in rawKeys { keys.append(try Self.resolveKey(raw)) }
                try movement.set(try GameTouchChord(keys: keys), for: direction)
            }
        }

        var buttons: [GameTouchButton] = []
        if let rawButtons = object["buttons"] {
            guard let entries = rawButtons as? [Any], entries.count <= 64 else {
                throw GameProjectError.limitExceeded("floeInputs.buttons")
            }
            var identifiers = Set<GameTouchButton.ID>()
            for entry in entries {
                guard let dictionary = entry as? [String: Any],
                      Set(dictionary.keys).isSubset(of: Self.buttonKeys) else {
                    throw GameProjectError.invalidEdit
                }
                guard let rawID = dictionary["id"] as? String else { throw GameProjectError.invalidEdit }
                let identifier = try GameTouchButton.ID(rawID)
                guard identifiers.insert(identifier).inserted else { throw GameProjectError.invalidEdit }
                guard let rawKeys = dictionary["keys"] as? [String], (1...8).contains(rawKeys.count) else {
                    throw GameProjectError.invalidEdit
                }
                var keys: [GameKeyboardKey] = []
                for raw in rawKeys { keys.append(try Self.resolveKey(raw)) }
                let binding: GameTouchBinding
                if keys.count == 1 {
                    binding = .key(keys[0])
                } else {
                    binding = .chord(try GameTouchChord(keys: keys))
                }
                var label: String?
                if let rawLabel = dictionary["label"] {
                    guard let text = rawLabel as? String else { throw GameProjectError.invalidEdit }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    label = trimmed.isEmpty ? nil : trimmed
                }
                let button = GameTouchButton(id: identifier, binding: binding, label: label)
                try button.validate()
                buttons.append(button)
            }
        }

        try self.init(engine: engine, movement: movement, buttons: buttons)
    }

    /// Accepts keyboard enum raw values (`pageUp`, `rightShift`, `z`) and the
    /// fixed DOM `code` aliases used by the player (`PageUp`, `ShiftRight`,
    /// `KeyZ`, `ArrowLeft`, `Digit1`, `Numpad5`). Unknown names are rejected.
    public static func resolveKey(_ raw: String) throws -> GameKeyboardKey {
        guard raw.utf8.count <= 32,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameProjectError.invalidEdit
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw GameProjectError.invalidEdit }
        if let exact = GameKeyboardKey(rawValue: value) { return exact }
        let folded = value.lowercased()
        if let match = GameKeyboardKey.allCases.first(where: { $0.rawValue.lowercased() == folded }) {
            return match
        }
        if let match = GameKeyboardKey.allCases.first(where: { $0.descriptor.code.lowercased() == folded }) {
            return match
        }
        throw GameProjectError.invalidEdit
    }

    private static func direction(named name: String) -> GameTouchAction? {
        switch name {
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        default: return nil
        }
    }

    private static let topLevelKeys: Set<String> = ["schemaVersion", "engine", "movement", "buttons"]
    private static let directionNames: Set<String> = ["left", "right", "up", "down"]
    private static let buttonKeys: Set<String> = ["id", "label", "keys"]
}

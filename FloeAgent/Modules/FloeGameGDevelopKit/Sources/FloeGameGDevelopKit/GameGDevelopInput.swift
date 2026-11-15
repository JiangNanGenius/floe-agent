// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A keyboard key accepted by the existing `GameKeyboardKey` viewport or a
/// fixed DOM `KeyboardEvent.code`. This is a declaration only: nothing here
/// injects OS events or executes model-authored commands.
public struct GameGDevelopInputKey: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    private static let keyboardRawValues: Set<String> = [
        "left", "right", "up", "down", "enter", "escape", "space", "tab", "backspace",
        "delete", "insert", "home", "end", "pageUp", "pageDown", "shift", "control", "alt",
        "meta", "rightShift", "rightControl", "rightAlt", "rightMeta", "capsLock", "numLock",
        "scrollLock", "printScreen", "pause", "contextMenu",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p",
        "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "minus", "equal", "leftBracket", "rightBracket", "backslash", "semicolon", "quote",
        "backquote", "comma", "period", "slash",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
        "numpad0", "numpad1", "numpad2", "numpad3", "numpad4", "numpad5", "numpad6",
        "numpad7", "numpad8", "numpad9", "numpadDecimal", "numpadDivide", "numpadMultiply",
        "numpadSubtract", "numpadAdd", "numpadEnter"
    ]

    private static let domCodePrefixes = [
        "Key", "Digit", "Arrow", "Numpad", "F", "Shift", "Control", "Alt", "Meta"
    ]

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameGDevelopError.invalidInput("key")
        }
        let isRaw = Self.keyboardRawValues.contains(value)
        let isDOMCode = value.count <= 24 &&
            (Self.domCodePrefixes.contains(where: { value.hasPrefix($0) })
                || ["Space", "Enter", "Escape", "Tab", "Backspace", "Delete", "Insert",
                    "Home", "End", "PageUp", "PageDown", "CapsLock", "NumLock", "ScrollLock",
                    "PrintScreen", "Pause", "ContextMenu", "Minus", "Equal", "BracketLeft",
                    "BracketRight", "Backslash", "Semicolon", "Quote", "Backquote", "Comma",
                    "Period", "Slash"].contains(value))
            && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }
        guard isRaw || isDOMCode else { throw GameGDevelopError.invalidInput("key \(value)") }
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GameGDevelopMovement: Codable, Equatable, Sendable {
    public let left: [GameGDevelopInputKey]
    public let right: [GameGDevelopInputKey]
    public let up: [GameGDevelopInputKey]
    public let down: [GameGDevelopInputKey]

    public init(left: [GameGDevelopInputKey] = [], right: [GameGDevelopInputKey] = [],
                up: [GameGDevelopInputKey] = [], down: [GameGDevelopInputKey] = []) throws {
        try Self.validate(left); try Self.validate(right); try Self.validate(up); try Self.validate(down)
        self.left = left; self.right = right; self.up = up; self.down = down
    }

    private static func validate(_ keys: [GameGDevelopInputKey]) throws {
        guard keys.count <= 4, Set(keys).count == keys.count else {
            throw GameGDevelopError.invalidInput("movement keys")
        }
    }
}

public struct GameGDevelopButton: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let keys: [GameGDevelopInputKey]

    public init(id: String, label: String, keys: [GameGDevelopInputKey]) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard (1...32).contains(id.count), id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 32,
              (1...4).contains(keys.count), Set(keys).count == keys.count else {
            throw GameGDevelopError.invalidInput("button \(id)")
        }
        self.id = id; self.label = label; self.keys = keys
    }
}

/// Truthful project keyboard declaration consumed by the existing touch
/// controls. GDevelop's own runtime binds `keydown`/`keyup`; no injected
/// `window.FloeGame.key` hook is required for this engine.
public struct GameGDevelopInputDeclaration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let engine: String
    public let movement: GameGDevelopMovement
    public let buttons: [GameGDevelopButton]

    public init(movement: GameGDevelopMovement, buttons: [GameGDevelopButton] = []) throws {
        guard buttons.count <= 32, Set(buttons.map(\.id)).count == buttons.count else {
            throw GameGDevelopError.invalidInput("buttons")
        }
        self.schemaVersion = Self.schemaVersion
        self.engine = "gdevelop"
        self.movement = movement
        self.buttons = buttons
    }

    /// Default for the starter template: arrow movement plus a real Z reset.
    public static func starter() throws -> GameGDevelopInputDeclaration {
        try .init(
            movement: .init(left: [try GameGDevelopInputKey("left")],
                            right: [try GameGDevelopInputKey("right")],
                            up: [try GameGDevelopInputKey("up")],
                            down: [try GameGDevelopInputKey("down")]),
            buttons: [try GameGDevelopButton(id: "reset", label: "Z",
                                             keys: [try GameGDevelopInputKey("z")])])
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion, engine == "gdevelop" else {
            throw GameGDevelopError.invalidInput("floe-inputs schema/engine")
        }
        _ = try GameGDevelopMovement(left: movement.left, right: movement.right,
                                    up: movement.up, down: movement.down)
        for button in buttons {
            _ = try GameGDevelopButton(id: button.id, label: button.label, keys: button.keys)
        }
    }

    /// GDevelop `KeyPressed` names declared by this input contract.
    public func gdevelopKeyNames() throws -> Set<String> {
        var names: Set<String> = []
        for key in movement.left + movement.right + movement.up + movement.down + buttons.flatMap(\.keys) {
            guard let name = GameGDevelopKeyMap.gdevelopName(for: key) else {
                throw GameGDevelopError.invalidInput("key \(key.rawValue) has no GDevelop name")
            }
            names.insert(name)
        }
        return names
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GameGDevelopInputDeclaration {
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw GameGDevelopError.invalidInput("floe-inputs.json") }
        try value.validate()
        return value
    }
}

/// Evidence for the host: GDevelop's standard renderer binds browser keyboard
/// events itself (`bindStandardEvents`), so touch controls should send fixed
/// DOM keyboard events rather than semantic gamepad actions.
public enum GameGDevelopBrowserInput {
    public static let bindsNativeKeyboardEvents = true
    public static let requiresWindowFloeGameKeyHook = false
    public static let evidence = "GDJS Runtime index.html calls getRenderer().bindStandardEvents(...); inputmanager.js handles keydown/keyup and keysNameToCode."
}

/// Maps the fixed Floe keyboard vocabulary to GDevelop's `KeyPressed` names.
/// This is a declaration mapping only; the actual browser events remain the
/// official GDJS input manager's responsibility.
public enum GameGDevelopKeyMap {
    public static func gdevelopName(for key: GameGDevelopInputKey) -> String? {
        switch key.rawValue {
        case "left": return "Left"
        case "right": return "Right"
        case "up": return "Up"
        case "down": return "Down"
        case "space": return "Space"
        case "enter": return "Return"
        case "escape": return "Escape"
        case "tab": return "Tab"
        case "backspace": return "Back"
        case "delete": return "Delete"
        case "shift": return "LShift"
        case "rightShift": return "RShift"
        case "control": return "LControl"
        case "rightControl": return "RControl"
        case "alt": return "LAlt"
        case "rightAlt": return "RAlt"
        case "meta": return "LSystem"
        case "rightMeta": return "RSystem"
        case "minus": return "Dash"
        case "equal": return "Equal"
        case "leftBracket": return "LBracket"
        case "rightBracket": return "RBracket"
        case "backslash": return "BackSlash"
        case "semicolon": return "SemiColon"
        case "quote": return "Quote"
        case "backquote": return "Tilde"
        case "comma": return "Comma"
        case "period": return "Period"
        case "slash": return "Slash"
        case "numpadEnter": return "NumpadReturn"
        default:
            if key.rawValue.count == 1, key.rawValue.first!.isLetter { return key.rawValue }
            if key.rawValue.hasPrefix("numpad"), key.rawValue.count == 7 { return key.rawValue.capitalized }
            if key.rawValue.hasPrefix("f"), Int(key.rawValue.dropFirst()) != nil { return key.rawValue.uppercased() }
            return nil
        }
    }
}

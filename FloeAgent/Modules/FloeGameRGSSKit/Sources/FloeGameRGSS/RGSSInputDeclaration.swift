// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct RGSSMovementKeys: Codable, Equatable, Sendable {
    public var left: [String]
    public var right: [String]
    public var up: [String]
    public var down: [String]

    public init(left: [String], right: [String], up: [String], down: [String]) {
        self.left = left
        self.right = right
        self.up = up
        self.down = down
    }
}

public struct RGSSInputButton: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// Simultaneous physical keys, matching GameTouchProjectBindings.
    /// Alternative keys require separate buttons, never one chord array.
    public let keys: [String]

    public init(id: String, label: String, keys: [String]) {
        self.id = id
        self.label = label
        self.keys = keys
    }
}

/// Project-level keyboard declaration written into the repository as
/// `floe-inputs.json`. It describes real keyboard keys, never gamepad labels or
/// commands. The App's Touch UI may present these keys as virtual buttons.
public struct RGSSInputDeclaration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let engine: GameEngineID
    public let movement: RGSSMovementKeys
    public let buttons: [RGSSInputButton]

    public init(schemaVersion: Int = RGSSInputDeclaration.schemaVersion, engine: GameEngineID,
                movement: RGSSMovementKeys, buttons: [RGSSInputButton]) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.movement = movement
        self.buttons = buttons
    }

    /// Keys verified against the Tapir native engine's built-in,
    /// version-specific key_config (see KEYBOARD-MAPPING.md in the private
    /// rgss-guest-mpl package). These are physical keys, not gamepad labels.
    public static func standard(for engine: GameEngineID) throws -> RGSSInputDeclaration {
        guard RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSRuntimeError.invalidEngine(engine.rawValue)
        }
        let isXP = engine == .rpgMakerXP
        return .init(
            engine: engine,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [
                .init(id: "confirm", label: isXP ? "C" : "Z",
                      keys: isXP ? ["c"] : ["z"]),
                .init(id: "cancel", label: "X", keys: ["x"]),
                .init(id: "action1", label: "Shift", keys: ["shift"]),
                .init(id: "action2", label: "Q", keys: ["q"]),
                .init(id: "action3", label: "W", keys: ["w"])
            ])
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RGSSRuntimeError.invalidInputDeclaration("unsupported schemaVersion \(schemaVersion)")
        }
        guard RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSRuntimeError.invalidInputDeclaration("engine is not an RGSS engine")
        }
        let groups: [(String, [String])] = [
            ("left", movement.left), ("right", movement.right),
            ("up", movement.up), ("down", movement.down)
        ]
        for (name, keys) in groups {
            guard (1...4).contains(keys.count) else {
                throw RGSSRuntimeError.invalidInputDeclaration("\(name) movement must have 1...4 keys")
            }
            try Self.validateKeys(keys, field: name)
        }
        guard buttons.count <= 12 else {
            throw RGSSRuntimeError.invalidInputDeclaration("at most 12 buttons are allowed")
        }
        var ids = Set<String>()
        for button in buttons {
            guard (1...32).contains(button.id.utf8.count),
                  button.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  ids.insert(button.id).inserted else {
                throw RGSSRuntimeError.invalidInputDeclaration("invalid or duplicate button id \(button.id)")
            }
            guard (1...32).contains(button.label.count),
                  !button.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RGSSRuntimeError.invalidInputDeclaration("invalid label for \(button.id)")
            }
            guard (1...4).contains(button.keys.count) else {
                throw RGSSRuntimeError.invalidInputDeclaration("button \(button.id) must have 1...4 keys")
            }
            try Self.validateKeys(button.keys, field: button.id)
        }
    }

    public func jsonData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data, expectedEngine: GameEngineID? = nil) throws -> RGSSInputDeclaration {
        let value: RGSSInputDeclaration
        do {
            value = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw RGSSRuntimeError.invalidInputDeclaration("JSON decode failed")
        }
        try value.validate()
        if let expectedEngine, value.engine != expectedEngine {
            throw RGSSRuntimeError.invalidInputDeclaration("engine mismatch")
        }
        return value
    }

    private static func validateKeys(_ keys: [String], field: String) throws {
        var seen = Set<String>()
        for key in keys {
            guard key.utf8.count <= 32, !key.isEmpty, seen.insert(key).inserted else {
                throw RGSSRuntimeError.invalidInputDeclaration("invalid or duplicate key in \(field)")
            }
            guard isKnownKey(key) else {
                throw RGSSRuntimeError.invalidInputDeclaration("unknown keyboard key \(key) in \(field)")
            }
        }
    }

    private static func isKnownKey(_ key: String) -> Bool {
        if rawKeys.contains(key) { return true }
        return key.range(of: #"^(Key[A-Z]|Digit[0-9]|Arrow(Left|Right|Up|Down)|Enter|Escape|Space|Tab|Shift(Left|Right)|Control(Left|Right)|Alt(Left|Right)|F([1-9]|1[0-9]|2[0-4])|Numpad[0-9]|Numpad(Enter|Decimal|Divide|Multiply|Subtract|Add))$"#,
                         options: .regularExpression) != nil
    }

    private static let rawKeys: Set<String> = [
        "left", "right", "up", "down", "enter", "escape", "space", "tab", "backspace", "delete", "insert",
        "home", "end", "pageUp", "pageDown", "shift", "control", "alt", "meta",
        "rightShift", "rightControl", "rightAlt", "rightMeta", "capsLock", "numLock", "scrollLock",
        "printScreen", "pause", "contextMenu",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
        "u", "v", "w", "x", "y", "z",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "minus", "equal", "leftBracket", "rightBracket", "backslash", "semicolon", "quote", "backquote",
        "comma", "period", "slash",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
        "numpad0", "numpad1", "numpad2", "numpad3", "numpad4", "numpad5", "numpad6", "numpad7", "numpad8", "numpad9",
        "numpadDecimal", "numpadDivide", "numpadMultiply", "numpadSubtract", "numpadAdd", "numpadEnter"
    ]
}

/// Verified physical-key to RGSS-button mapping for the Tapir native engine.
/// Z differs by generation: XP -> A; VX/VX Ace -> C. Physical C is unbound in
/// VX/VX Ace. This is metadata/documentation, not an executor.
public enum RGSSKeyRuntimeMapping {
    public static func button(for key: String, engine: GameEngineID) -> String? {
        switch key {
        case "z": engine == .rpgMakerXP ? "A" : "C"
        case "c": engine == .rpgMakerXP ? "C" : nil
        case "shift": "A"
        case "x", "escape": "B"
        case "enter", "space": "C"
        case "q": "L"
        case "w": "R"
        case "a": "X"
        case "s": "Y"
        case "d": "Z"
        case "left": "left"
        case "right": "right"
        case "up": "up"
        case "down": "down"
        default: nil
        }
    }

    public static let source = "qnighy/tapir@a56b1946 src/tapir_config.c:27-39, src/Input.c:175-207"
}

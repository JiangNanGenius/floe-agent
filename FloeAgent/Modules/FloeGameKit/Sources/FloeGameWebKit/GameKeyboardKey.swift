// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Physical keyboard inputs accepted by the game viewport. These describe
/// keys inside the game, never App commands or an operating-system injector.
public enum GameKeyboardKey: String, Codable, CaseIterable, Hashable, Sendable {
    case left, right, up, down, enter, escape, space, tab, backspace, delete, insert
    case home, end, pageUp, pageDown, shift, control, alt, meta
    case rightShift, rightControl, rightAlt, rightMeta, capsLock, numLock, scrollLock, printScreen, pause, contextMenu
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case zero, one, two, three, four, five, six, seven, eight, nine
    case minus, equal, leftBracket, rightBracket, backslash, semicolon, quote, backquote, comma, period, slash
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24
    case numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9
    case numpadDecimal, numpadDivide, numpadMultiply, numpadSubtract, numpadAdd, numpadEnter, numpadEqual

    public var isModifier: Bool { modifierOrder < 100 }
    /// Press modifiers first and release them last when sending a chord.
    public var modifierOrder: Int {
        switch self {
        case .control, .rightControl: 0
        case .alt, .rightAlt: 1
        case .shift, .rightShift: 2
        case .meta, .rightMeta: 3
        default: 100
        }
    }
    public var descriptor: GameKeyboardEventDescriptor {
        let raw = rawValue
        if raw.count == 1, let scalar = raw.unicodeScalars.first, (97...122).contains(scalar.value) {
            return .init(key: raw, code: "Key" + raw.uppercased(), keyCode: Int(scalar.value) - 32, shiftedKey: raw.uppercased())
        }
        if let digit = Self.digits.firstIndex(of: self) {
            let shifted = [")", "!", "@", "#", "$", "%", "^", "&", "*", "("][digit]
            return .init(key: String(digit), code: "Digit" + String(digit), keyCode: 48 + digit, shiftedKey: shifted)
        }
        if raw.hasPrefix("f"), let number = Int(raw.dropFirst()), (1...24).contains(number) {
            return .init(key: "F\(number)", code: "F\(number)", keyCode: 111 + number)
        }
        if raw.hasPrefix("numpad"), let digit = Int(raw.dropFirst(6)), (0...9).contains(digit) {
            return .init(key: String(digit), code: "Numpad\(digit)", keyCode: 96 + digit, location: 3)
        }
        return Self.special[self]!
    }
    public var keyCap: String {
        if descriptor.location == 3 { return descriptor.code.replacingOccurrences(of: "Numpad", with: "Num ") }
        return switch self {
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .escape: "Esc"
        case .control: "Ctrl"
        case .shift: "Shift"
        case .rightShift: "Right Shift"
        case .alt: "Alt"
        case .rightAlt: "Right Alt"
        case .rightControl: "Right Ctrl"
        case .meta: "Cmd/Win"
        case .rightMeta: "Right Cmd/Win"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .space: "Space"
        case .backspace: "Backspace"
        case .delete: "Delete"
        case .insert: "Insert"
        case .contextMenu: "Menu"
        case .printScreen: "PrtSc"
        default: descriptor.key.count == 1 ? descriptor.key.uppercased() : descriptor.code
        }
    }

    /// X11 keysym for the existing Linux display/VNC adapter. Sending still
    /// belongs to the host's exact owned display session and input checks.
    public var x11KeySym: UInt32 {
        switch self {
        case .left: return 0xFF51
        case .up: return 0xFF52
        case .right: return 0xFF53
        case .down: return 0xFF54
        case .enter: return 0xFF0D
        case .escape: return 0xFF1B
        case .tab: return 0xFF09
        case .backspace: return 0xFF08
        case .delete: return 0xFFFF
        case .insert: return 0xFF63
        case .home: return 0xFF50
        case .end: return 0xFF57
        case .pageUp: return 0xFF55
        case .pageDown: return 0xFF56
        case .shift: return 0xFFE1
        case .rightShift: return 0xFFE2
        case .control: return 0xFFE3
        case .rightControl: return 0xFFE4
        case .alt: return 0xFFE9
        case .rightAlt: return 0xFFEA
        case .meta: return 0xFFEB
        case .rightMeta: return 0xFFEC
        case .capsLock: return 0xFFE5
        case .numLock: return 0xFF7F
        case .scrollLock: return 0xFF14
        case .printScreen: return 0xFF61
        case .pause: return 0xFF13
        case .contextMenu: return 0xFF67
        case .numpadDecimal: return 0xFFAE
        case .numpadDivide: return 0xFFAF
        case .numpadMultiply: return 0xFFAA
        case .numpadSubtract: return 0xFFAD
        case .numpadAdd: return 0xFFAB
        case .numpadEnter: return 0xFF8D
        case .numpadEqual: return 0xFFBD
        default:
            if rawValue.hasPrefix("f"), let n = Int(rawValue.dropFirst()) { return 0xFFBD + UInt32(n) }
            if rawValue.hasPrefix("numpad"), let n = UInt32(rawValue.dropFirst(6)) { return 0xFFB0 + n }
            return descriptor.key.unicodeScalars.first?.value ?? 0
        }
    }
    private static let digits: [Self] = [.zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
    private static let special: [Self: GameKeyboardEventDescriptor] = [
        .left: .init(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37),
        .right: .init(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
        .up: .init(key: "ArrowUp", code: "ArrowUp", keyCode: 38),
        .down: .init(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
        .enter: .init(key: "Enter", code: "Enter", keyCode: 13),
        .escape: .init(key: "Escape", code: "Escape", keyCode: 27),
        .space: .init(key: " ", code: "Space", keyCode: 32),
        .tab: .init(key: "Tab", code: "Tab", keyCode: 9),
        .backspace: .init(key: "Backspace", code: "Backspace", keyCode: 8),
        .delete: .init(key: "Delete", code: "Delete", keyCode: 46),
        .insert: .init(key: "Insert", code: "Insert", keyCode: 45),
        .home: .init(key: "Home", code: "Home", keyCode: 36),
        .end: .init(key: "End", code: "End", keyCode: 35),
        .pageUp: .init(key: "PageUp", code: "PageUp", keyCode: 33),
        .pageDown: .init(key: "PageDown", code: "PageDown", keyCode: 34),
        .shift: .init(key: "Shift", code: "ShiftLeft", keyCode: 16, location: 1),
        .rightShift: .init(key: "Shift", code: "ShiftRight", keyCode: 16, location: 2),
        .control: .init(key: "Control", code: "ControlLeft", keyCode: 17, location: 1),
        .rightControl: .init(key: "Control", code: "ControlRight", keyCode: 17, location: 2),
        .alt: .init(key: "Alt", code: "AltLeft", keyCode: 18, location: 1),
        .rightAlt: .init(key: "Alt", code: "AltRight", keyCode: 18, location: 2),
        .meta: .init(key: "Meta", code: "MetaLeft", keyCode: 91, location: 1),
        .rightMeta: .init(key: "Meta", code: "MetaRight", keyCode: 92, location: 2),
        .capsLock: .init(key: "CapsLock", code: "CapsLock", keyCode: 20),
        .numLock: .init(key: "NumLock", code: "NumLock", keyCode: 144),
        .scrollLock: .init(key: "ScrollLock", code: "ScrollLock", keyCode: 145),
        .printScreen: .init(key: "PrintScreen", code: "PrintScreen", keyCode: 44),
        .pause: .init(key: "Pause", code: "Pause", keyCode: 19),
        .contextMenu: .init(key: "ContextMenu", code: "ContextMenu", keyCode: 93),
        .minus: .init(key: "-", code: "Minus", keyCode: 189, shiftedKey: "_"),
        .equal: .init(key: "=", code: "Equal", keyCode: 187, shiftedKey: "+"),
        .leftBracket: .init(key: "[", code: "BracketLeft", keyCode: 219, shiftedKey: "{"),
        .rightBracket: .init(key: "]", code: "BracketRight", keyCode: 221, shiftedKey: "}"),
        .backslash: .init(key: "\\", code: "Backslash", keyCode: 220, shiftedKey: "|"),
        .semicolon: .init(key: ";", code: "Semicolon", keyCode: 186, shiftedKey: ":"),
        .quote: .init(key: "'", code: "Quote", keyCode: 222, shiftedKey: "\""),
        .backquote: .init(key: "\u{0060}", code: "Backquote", keyCode: 192, shiftedKey: "~"),
        .comma: .init(key: ",", code: "Comma", keyCode: 188, shiftedKey: "<"),
        .period: .init(key: ".", code: "Period", keyCode: 190, shiftedKey: ">"),
        .slash: .init(key: "/", code: "Slash", keyCode: 191, shiftedKey: "?"),
        .numpadDecimal: .init(key: ".", code: "NumpadDecimal", keyCode: 110, location: 3),
        .numpadDivide: .init(key: "/", code: "NumpadDivide", keyCode: 111, location: 3),
        .numpadMultiply: .init(key: "*", code: "NumpadMultiply", keyCode: 106, location: 3),
        .numpadSubtract: .init(key: "-", code: "NumpadSubtract", keyCode: 109, location: 3),
        .numpadAdd: .init(key: "+", code: "NumpadAdd", keyCode: 107, location: 3),
        .numpadEnter: .init(key: "Enter", code: "NumpadEnter", keyCode: 13, location: 3),
        .numpadEqual: .init(key: "=", code: "NumpadEqual", keyCode: 187, location: 3)
    ]
}

public struct GameKeyboardEventDescriptor: Equatable, Sendable {
    public let key: String
    public let code: String
    public let keyCode: Int
    public let location: Int
    public let shiftedKey: String?
    public init(key: String, code: String, keyCode: Int, location: Int = 0, shiftedKey: String? = nil) {
        self.key = key; self.code = code; self.keyCode = keyCode; self.location = location; self.shiftedKey = shiftedKey
    }
}

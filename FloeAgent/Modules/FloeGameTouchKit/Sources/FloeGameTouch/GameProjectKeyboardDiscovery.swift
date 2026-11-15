// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit

/// Reads declarations as data. It never loads project scripts, assemblies,
/// Godot resources, Unity YAML objects, or an engine process.
public enum GameProjectKeyboardDiscovery {
    public enum Format: String, Sendable { case declaration, godotInputMap, unityInputActions, unityLegacy }
    public enum Warning: String, Hashable, Sendable {
        case unsupportedBinding, incompleteMovement, multipleMovementBindings
    }
    public struct Source: Sendable {
        public let path: GameRelativePath
        public let data: Data
        public init(path: GameRelativePath, data: Data) { self.path = path; self.data = data }
    }
    /// Multiple Unity action maps or imported roots stay separate. The host
    /// must select a candidate; discovery does not guess an active action map.
    public struct Candidate: Identifiable, Sendable {
        public let id: String
        public let source: GameRelativePath
        public let name: String
        public let format: Format
        public let declaration: Data
        public let warnings: [Warning]
        public func bindings(engine: GameEngineID) throws -> GameTouchProjectBindings {
            try GameTouchProjectBindings(json: declaration, engine: engine)
        }
    }
    public enum Failure: Error, Equatable { case limitExceeded, invalidSource, malformedDeclaration }

    public static func isSupported(path: GameRelativePath, engine: GameEngineID) -> Bool {
        let name = path.value.split(separator: "/").last.map(String.init) ?? ""
        return name == "floe-inputs.json" || (engine == .godot && name == "project.godot") ||
            (engine == .unity && (name.hasSuffix(".inputactions") || path.value.hasSuffix("ProjectSettings/InputManager.asset")))
    }
    public static func discover(engine: GameEngineID, sources: [Source]) throws -> [Candidate] {
        guard sources.count <= 128, sources.reduce(0, { $0 + $1.data.count }) <= 8 * 1_024 * 1_024 else { throw Failure.limitExceeded }
        guard Set(sources.map(\.path)).count == sources.count else { throw Failure.invalidSource }
        var candidates: [Candidate] = []
        for file in sources.sorted(by: { $0.path.value < $1.path.value }) where isSupported(path: file.path, engine: engine) {
            guard file.data.count <= 2 * 1_024 * 1_024 else { throw Failure.limitExceeded }
            let name = file.path.value.split(separator: "/").last.map(String.init) ?? ""
            if name == "floe-inputs.json" {
                _ = try GameTouchProjectBindings(json: file.data, engine: engine)
                candidates.append(.init(id: file.path.value, source: file.path, name: name, format: .declaration, declaration: file.data, warnings: []))
            } else if engine == .unity, name.hasSuffix(".inputactions") {
                candidates += try unityActions(file, engine: engine)
            } else {
                guard let text = String(data: file.data, encoding: .utf8), !text.contains("\0") else { throw Failure.invalidSource }
                if engine == .godot { if let candidate = try godot(file, text: text, engine: engine) { candidates.append(candidate) } }
                else if let candidate = try unityLegacy(file, text: text, engine: engine) { candidates.append(candidate) }
            }
            guard candidates.count <= 128 else { throw Failure.limitExceeded }
        }
        return candidates
    }

    private struct Button: Encodable {
        let id: String
        let label: String
        let keys: [String]
    }
    private struct Declaration: Encodable {
        let schemaVersion = 1
        let engine: String
        let movement: [String: [String]]
        let buttons: [Button]
    }
    private struct Builder {
        var movement: [String: [GameKeyboardKey]] = [:]
        var buttons: [Button] = []
        var warnings: Set<Warning> = []
        mutating func add(label: String, keys: [GameKeyboardKey], direction: String? = nil) throws {
            guard !keys.isEmpty, keys.count <= 8, Set(keys).count == keys.count else { throw Failure.malformedDeclaration }
            let chord = keys.sorted { a, b in a.modifierOrder == b.modifierOrder ? a.rawValue < b.rawValue : a.modifierOrder < b.modifierOrder }
            if let direction {
                if let existing = movement[direction], existing != chord { warnings.insert(.multipleMovementBindings) }
                else { movement[direction] = chord }
            }
            let text = String(label.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(64))
            // Alternatives are preserved as individual keys rather than
            // accidentally turning alternative bindings into a chord.
            if !buttons.contains(where: { $0.label == text && $0.keys == chord.map(\.rawValue) }) {
                guard buttons.count < 64 else { throw Failure.limitExceeded }
                buttons.append(.init(id: "input." + String(buttons.count), label: text, keys: chord.map(\.rawValue)))
            }
        }
        mutating func candidate(file: Source, name: String, discriminator: String? = nil, format: Format, engine: GameEngineID) throws -> Candidate? {
            guard !buttons.isEmpty else { return nil }
            if !movement.isEmpty, movement.count != 4 { warnings.insert(.incompleteMovement); movement = [:] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Declaration(engine: engine.rawValue, movement: movement.mapValues { $0.map(\.rawValue) }, buttons: buttons))
            _ = try GameTouchProjectBindings(json: data, engine: engine)
            return .init(id: file.path.value + "#" + (discriminator ?? name), source: file.path, name: name, format: format, declaration: data, warnings: warnings.sorted { $0.rawValue < $1.rawValue })
        }
    }
    private static func unityActions(_ file: Source, engine: GameEngineID) throws -> [Candidate] {
        guard let root = try JSONSerialization.jsonObject(with: file.data) as? [String: Any],
              let maps = root["maps"] as? [[String: Any]], maps.count <= 64 else { throw Failure.malformedDeclaration }
        var output: [Candidate] = []
        for (mapIndex, map) in maps.enumerated() {
            guard let mapName = map["name"] as? String, mapName.utf8.count <= 256,
                  let bindings = map["bindings"] as? [[String: Any]], bindings.count <= 4_096 else { throw Failure.malformedDeclaration }
            var builder = Builder(), index = 0
            while index < bindings.count {
                let binding = bindings[index]; index += 1
                if binding["isComposite"] as? Bool == true {
                    var parts: [[String: Any]] = []
                    while index < bindings.count, bindings[index]["isPartOfComposite"] as? Bool == true { parts.append(bindings[index]); index += 1 }
                    let kind = ((binding["path"] as? String) ?? "").lowercased().split(separator: "(").first.map(String.init) ?? ""
                    let action = (binding["action"] as? String) ?? ""
                    if ["2dvector", "dpad"].contains(kind) {
                        for part in parts {
                            guard let path = part["path"] as? String, let key = unityKey(path),
                                  let role = (part["name"] as? String)?.lowercased(), ["up", "down", "left", "right"].contains(role) else { builder.warnings.insert(.unsupportedBinding); continue }
                            try builder.add(label: action + " · " + role, keys: [key], direction: role)
                        }
                    } else if ["onemodifier", "twomodifiers", "buttonwithonemodifier", "buttonwithtwomodifiers"].contains(kind) {
                        var chord: [GameKeyboardKey] = [], valid = true
                        for part in parts {
                            guard let path = part["path"] as? String, let key = unityKey(path) else { valid = false; break }
                            chord.append(key)
                        }
                        if valid, !chord.isEmpty { try builder.add(label: action, keys: chord) }
                        else { builder.warnings.insert(.unsupportedBinding) }
                    } else { builder.warnings.insert(.unsupportedBinding) }
                } else if binding["isPartOfComposite"] as? Bool != true,
                          let path = binding["path"] as? String, let key = unityKey(path) {
                    try builder.add(label: (binding["action"] as? String) ?? key.keyCap, keys: [key])
                }
            }
            // Include the map index to keep equally named maps independently selectable.
            if let candidate = try builder.candidate(file: file, name: mapName, discriminator: "\(mapIndex):\(mapName)", format: .unityInputActions, engine: engine) { output.append(candidate) }
        }
        return output
    }
    private static func unityLegacy(_ file: Source, text: String, engine: GameEngineID) throws -> Candidate? {
        var builder = Builder(), record: [String: String] = [:], records: [[String: String]] = []
        var inAxes = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "m_Axes:" { inAxes = true; continue }
            guard inAxes else { continue }
            if value.hasPrefix("- serializedVersion:") {
                if !record.isEmpty { records.append(record); record = [:] }
                guard records.count <= 4_096 else { throw Failure.limitExceeded }; continue
            }
            if let split = value.firstIndex(of: ":") {
                let key = String(value[..<split]), raw = String(value[value.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                guard ["m_Name", "negativeButton", "positiveButton", "altNegativeButton", "altPositiveButton", "type"].contains(key) else { continue }
                record[key] = scalar(raw)
            }
        }
        if !record.isEmpty { records.append(record) }
        for record in records where record["type"] == "0" {
            let action = record["m_Name"] ?? "Key", name = action.lowercased()
            for (field, sign) in [("negativeButton", -1), ("positiveButton", 1), ("altNegativeButton", -1), ("altPositiveButton", 1)] {
                guard let raw = record[field], !raw.isEmpty else { continue }
                guard let key = namedKey(raw) else { builder.warnings.insert(.unsupportedBinding); continue }
                let direction: String? = ["horizontal", "movehorizontal"].contains(name) ? (sign < 0 ? "left" : "right") :
                    (["vertical", "movevertical"].contains(name) ? (sign < 0 ? "down" : "up") : nil)
                try builder.add(label: action + (sign < 0 ? " −" : " +"), keys: [key], direction: direction)
            }
        }
        return try builder.candidate(file: file, name: "Input Manager", format: .unityLegacy, engine: engine)
    }
    private static func godot(_ file: Source, text: String, engine: GameEngineID) throws -> Candidate? {
        var input = false, section = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") { if input { break }; input = trimmed == "[input]"; continue }
            if input { section += String(line) + "\n" }
        }
        var builder = Builder()
        for assignment in try assignments(section) {
            let action = scalar(assignment.0)
            let raw = assignment.1.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.hasPrefix("{"), raw.hasSuffix("}"),
                  let events = try objectFields(String(raw.dropFirst().dropLast()))["events"] else { continue }
            for object in try inputKeyObjects(events) {
                let fields = try objectFields(object)
                let v3 = fields["scancode"] != nil || fields["physical_scancode"] != nil
                let physical = Int(fields[v3 ? "physical_scancode" : "physical_keycode"] ?? "0") ?? 0
                let logical = Int(fields[v3 ? "scancode" : "keycode"] ?? "0") ?? 0
                let unicode = Int(fields["unicode"] ?? "0") ?? 0
                let raw = physical != 0 ? physical : (logical != 0 ? logical : unicode)
                guard raw >= 0, raw <= Int(UInt32.max), let key = godotKey(raw, v3: v3) else { builder.warnings.insert(.unsupportedBinding); continue }
                var chord: [GameKeyboardKey] = []
                for (name, legacy, mask, modifier) in [("ctrl_pressed", "control", 28, GameKeyboardKey.control), ("alt_pressed", "alt", 26, .alt), ("shift_pressed", "shift", 25, .shift), ("meta_pressed", "meta", 27, .meta)] {
                    if fields[name] == "true" || fields[legacy] == "true" || raw & (1 << mask) != 0 { chord.append(modifier) }
                }
                if !chord.contains(key) { chord.append(key) }
                let role = action.lowercased(), direction: String?
                if ["left", "move_left", "ui_left"].contains(role) { direction = "left" }
                else if ["right", "move_right", "ui_right"].contains(role) { direction = "right" }
                else if ["up", "move_up", "ui_up"].contains(role) { direction = "up" }
                else if ["down", "move_down", "ui_down"].contains(role) { direction = "down" }
                else { direction = nil }
                try builder.add(label: action, keys: chord, direction: direction)
            }
        }
        return try builder.candidate(file: file, name: "Input Map", format: .godotInputMap, engine: engine)
    }

    // A bounded lexer handles quoted strings and nested containers. In
    // particular Object(InputEventKey,...) is parsed, never instantiated.
    private static func pieces(_ text: String, separator: Character, maximum: Int = 8_192) throws -> [String] {
        var output: [String] = [], current = "", stack: [Character] = [], quoted = false, escaped = false, comment = false
        for character in text {
            if comment { if character == "\n" { comment = false } else { continue } }
            if quoted {
                current.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
                continue
            }
            if character == ";" { comment = true; continue }
            if character == "\"" { quoted = true; current.append(character); continue }
            if "([{<".contains(character) { stack.append(character); guard stack.count <= 64 else { throw Failure.limitExceeded } }
            else if ")]}>".contains(character) {
                guard let opening = stack.popLast(), zip("([{<", ")]}>").contains(where: { pair in pair.0 == opening && pair.1 == character }) else { throw Failure.malformedDeclaration }
            }
            if character == separator && stack.isEmpty {
                output.append(current); current = ""; guard output.count <= maximum else { throw Failure.limitExceeded }
            } else { current.append(character) }
        }
        guard !quoted, stack.isEmpty else { throw Failure.malformedDeclaration }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output.append(current) }
        return output
    }
    private static func assignments(_ text: String) throws -> [(String, String)] {
        try pieces(text, separator: "\n").compactMap { line in
            guard let equal = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<equal]).trimmingCharacters(in: .whitespacesAndNewlines), String(line[line.index(after: equal)...]))
        }
    }
    private static func inputKeyObjects(_ text: String) throws -> [String] {
        let chars = Array(text); var index = 0, quoted = false, escaped = false, found: [String] = []
        let prefix = Array("Object(InputEventKey,")
        while index < chars.count {
            let c = chars[index]
            if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }; index += 1; continue }
            if c == "\"" { quoted = true; index += 1; continue }
            if index + prefix.count <= chars.count, Array(chars[index..<(index + prefix.count)]) == prefix {
                let start = index + prefix.count; index = start
                var depth = 1, string = false, escape = false
                while index < chars.count, depth > 0 {
                    let value = chars[index]
                    if string { if escape { escape = false } else if value == "\\" { escape = true } else if value == "\"" { string = false } }
                    else if value == "\"" { string = true }
                    else if value == "(" { depth += 1; guard depth <= 64 else { throw Failure.limitExceeded } }
                    else if value == ")" { depth -= 1 }
                    index += 1
                }
                guard depth == 0 else { throw Failure.malformedDeclaration }
                found.append(String(chars[start..<(index - 1)])); guard found.count <= 512 else { throw Failure.limitExceeded }
            } else { index += 1 }
        }
        return found
    }
    private static func objectFields(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for piece in try pieces(text, separator: ",") {
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let key = scalar(String(piece[..<colon])), value = String(piece[piece.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result[key] == nil else { throw Failure.malformedDeclaration }; result[key] = value
        }
        return result
    }
    private static func scalar(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) { return decoded }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return value
    }
    private static func unityKey(_ path: String) -> GameKeyboardKey? {
        guard path.lowercased().hasPrefix("<keyboard>/") else { return nil }
        return namedKey(String(path.dropFirst(11)))
    }
    private static func namedKey(_ text: String) -> GameKeyboardKey? {
        let value = text.lowercased().replacingOccurrences(of: " ", with: "")
        let aliases: [String: GameKeyboardKey] = ["leftarrow": .left, "rightarrow": .right, "uparrow": .up, "downarrow": .down,
            "return": .enter, "esc": .escape, "leftshift": .shift, "rightshift": .rightShift, "leftctrl": .control, "rightctrl": .rightControl,
            "ctrl": .control, "leftcontrol": .control, "rightcontrol": .rightControl, "leftalt": .alt, "rightalt": .rightAlt,
            "leftmeta": .meta, "rightmeta": .rightMeta, "leftcommand": .meta, "rightcommand": .rightMeta,
            "leftwindows": .meta, "rightwindows": .rightMeta, "backquote": .backquote, "equals": .equal,
            "numpadplus": .numpadAdd, "numpadminus": .numpadSubtract, "numpadperiod": .numpadDecimal,
            "numpadequals": .numpadEqual, "[+]": .numpadAdd, "[-]": .numpadSubtract,
            "[*]": .numpadMultiply, "[/]": .numpadDivide, "[.]": .numpadDecimal, "[enter]": .numpadEnter, "[equals]": .numpadEqual]
        if value == "anykey" { return nil }
        if let key = aliases[value] { return key }
        if value.count == 3, value.hasPrefix("["), value.hasSuffix("]"), let number = Int(value.dropFirst().dropLast()) {
            return GameKeyboardKey(rawValue: "numpad" + String(number))
        }
        if value.count == 1, let scalar = value.unicodeScalars.first, !CharacterSet.alphanumerics.contains(scalar) {
            return GameKeyboardKey.allCases.first { $0.descriptor.location != 3 && $0.descriptor.key == value }
        }
        return GameKeyboardKey.allCases.first { $0.rawValue.lowercased() == value || $0.descriptor.code.lowercased() == value || $0.descriptor.key.lowercased() == value }
    }
    private static func godotKey(_ value: Int, v3: Bool) -> GameKeyboardKey? {
        let code = value & (v3 ? ((1 << 25) - 1) : ((1 << 23) - 1)), special = v3 ? (1 << 24) : (1 << 22)
        if code & special != 0 {
            let low = code & ~special
            let keys: [Int: GameKeyboardKey] = [1: .escape, 2: .tab, 4: .backspace, 5: .enter, 6: .numpadEnter, 7: .insert, 8: .delete,
                9: .pause, 10: .printScreen, 13: .home, 14: .end, 15: .left, 16: .up, 17: .right, 18: .down, 19: .pageUp, 20: .pageDown,
                21: .shift, 22: .control, 23: .meta, 24: .alt, 25: .capsLock, 26: .numLock, 27: .scrollLock,
                0x81: .numpadMultiply, 0x82: .numpadDivide, 0x83: .numpadSubtract, 0x84: .numpadDecimal, 0x85: .numpadAdd]
            if let key = keys[low] { return key }
            if (0x1C...(v3 ? 0x2B : 0x33)).contains(low) { return GameKeyboardKey(rawValue: "f" + String(low - 0x1B)) }
            if (0x86...0x8F).contains(low) { return GameKeyboardKey(rawValue: "numpad" + String(low - 0x86)) }
            if low == (v3 ? 0x2E : 0x42) { return .contextMenu }
            return nil
        }
        return GameKeyboardKey.allCases.first { key in
            key.descriptor.location == 0 && key.descriptor.key.unicodeScalars.count == 1 &&
                (key.descriptor.key.uppercased().unicodeScalars.first?.value == UInt32(code) ||
                 key.descriptor.key.unicodeScalars.first?.value == UInt32(code))
        }
    }
}

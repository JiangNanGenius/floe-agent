// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Minimal, byte-preserving `project.godot` reader/patcher for the single
/// reviewed autoload. It never normalizes existing lines: insertion uses the
/// file's BOM and newline style, and all other bytes are retained.
struct GodotProjectFile: Equatable {
    enum LineEnding: String, Equatable {
        case lf
        case crlf
    }

    let originalData: Data
    let hadBOM: Bool
    let lineEnding: LineEnding
    let configVersion: Int
    let autoloadValue: String?
    let insertLine: String
    let patchedData: Data?

    var changed: Bool { patchedData != nil }

    var previousValue: String? { autoloadValue }

    static func parse(_ data: Data, maximumBytes: Int) throws -> GodotProjectFile {
        guard !data.isEmpty else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("project.godot is empty")
        }
        guard data.count <= maximumBytes else {
            throw GameDeveloperInstrumentationError.limitExceeded("project.godot")
        }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hadBOM = data.starts(with: bom)
        let body = hadBOM ? Data(data.dropFirst(bom.count)) : data
        guard let text = String(data: body, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("project.godot is not UTF-8")
        }
        guard !text.isEmpty else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("project.godot is empty")
        }
        if text.contains("\r"),
           text.components(separatedBy: "\r\n").count - 1 != text.components(separatedBy: "\r").count - 1 {
            throw GameDeveloperInstrumentationError.invalidProjectFile("project.godot contains a lone carriage return")
        }
        let lineEnding: LineEnding = text.contains("\r\n") ? .crlf : .lf
        let lines = text.components(separatedBy: "\n")

        var section: String?
        var configVersion: Int?
        var configVersionSeen = false
        var autoloadHeader: Int?
        var autoloadHeaderCount = 0
        var autoloadValues: [(index: Int, raw: String, normalized: String)] = []

        for (index, rawLine) in lines.enumerated() {
            try Task.checkCancellation()
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name == "autoload" {
                    autoloadHeaderCount += 1
                    if autoloadHeader == nil { autoloadHeader = index }
                }
                section = name
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[..<equals]).trimmingCharacters(in: .whitespaces))
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)
            if section == nil, key == "config_version" {
                guard !configVersionSeen, let parsed = Int(value) else {
                    throw GameDeveloperInstrumentationError.invalidProjectFile("duplicate or invalid config_version")
                }
                configVersion = parsed
                configVersionSeen = true
            }
            if section == "autoload", key == GameDeveloperInstrumentationConstants.godotAutoloadKey {
                autoloadValues.append((index: index, raw: rawValue, normalized: value))
            }
        }

        guard autoloadHeaderCount <= 1 else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("duplicate [autoload] section")
        }
        guard let configVersion else {
            throw GameDeveloperInstrumentationError.unsupportedEngineVersion(
                .godot, "project.godot has no explicit config_version=5; Godot 3 has no JavaScriptBridge")
        }
        guard configVersion == GameDeveloperInstrumentationConstants.godotSupportedConfigVersion else {
            throw GameDeveloperInstrumentationError.unsupportedEngineVersion(
                .godot, "config_version=\(configVersion); only Godot 4 (config_version=5) exposes JavaScriptBridge")
        }
        guard autoloadValues.count <= 1 else {
            throw GameDeveloperInstrumentationError.conflictingAutoload(
                GameDeveloperInstrumentationConstants.godotAutoloadKey,
                "the key appears more than once")
        }

        let expectedKey = GameDeveloperInstrumentationConstants.godotAutoloadKey
        let expectedValue = GameDeveloperInstrumentationConstants.godotAutoloadValue
        let insertLine = expectedKey + "=\"" + expectedValue + "\""

        if let existing = autoloadValues.first {
            guard existing.normalized == expectedValue else {
                throw GameDeveloperInstrumentationError.conflictingAutoload(expectedKey, existing.raw)
            }
            return .init(originalData: data, hadBOM: hadBOM, lineEnding: lineEnding,
                         configVersion: configVersion, autoloadValue: existing.normalized,
                         insertLine: insertLine, patchedData: nil)
        }

        let newline = lineEnding == .crlf ? "\r\n" : "\n"
        var patchedText: String
        if let header = autoloadHeader {
            let end = nextSection(after: header, in: lines) ?? lines.count
            var insertion = header + 1
            if end > header + 1 {
                for candidate in stride(from: end - 1, through: header + 1, by: -1) {
                    let content = contentLine(lines[candidate])
                    if !content.isEmpty {
                        insertion = candidate + 1
                        break
                    }
                }
            }
            // Insert at a UTF-8 line boundary without rebuilding the existing
            // lines. CRLF is one Swift Character, so Character suffix/split
            // operations cannot reliably detect its LF byte.
            let offset = min(text.utf8.count, lines.prefix(insertion).reduce(0) {
                $0 + $1.utf8.count + 1
            })
            let prefix = String(decoding: text.utf8.prefix(offset), as: UTF8.self)
            let suffix = String(decoding: text.utf8.dropFirst(offset), as: UTF8.self)
            let separator = prefix.utf8.last == 0x0A ? "" : newline
            patchedText = prefix + separator + insertLine + newline + suffix
        } else {
            patchedText = text
            if patchedText.utf8.last != 0x0A { patchedText += newline }
            patchedText += newline + "[autoload]" + newline + newline + insertLine + newline
        }
        var patched = Data()
        if hadBOM { patched.append(contentsOf: bom) }
        patched.append(contentsOf: patchedText.utf8)
        guard patched.count <= maximumBytes else {
            throw GameDeveloperInstrumentationError.limitExceeded("patched project.godot")
        }
        guard let verified = try? GodotProjectFile.parse(patched, maximumBytes: maximumBytes),
              verified.configVersion == configVersion,
              verified.autoloadValue == expectedValue else {
            throw GameDeveloperInstrumentationError.invalidProjectFile("patched project.godot did not verify")
        }
        return .init(originalData: data, hadBOM: hadBOM, lineEnding: lineEnding,
                     configVersion: configVersion, autoloadValue: nil,
                     insertLine: insertLine, patchedData: patched)
    }

    private static func nextSection(after header: Int, in lines: [String]) -> Int? {
        guard header + 1 < lines.count else { return nil }
        for index in (header + 1)..<lines.count {
            let content = contentLine(lines[index])
            if content.hasPrefix("["), content.hasSuffix("]") { return index }
        }
        return nil
    }

    private static func contentLine(_ rawLine: String) -> String {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { return "" }
        return trimmed
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var result = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

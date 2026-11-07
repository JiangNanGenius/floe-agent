// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXBibField: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var rawValue: String
    public var range: LaTeXSourceRange
}
public struct LaTeXBibEntry: Codable, Identifiable, Sendable {
    public var id: String { key }
    public var type: String
    public var key: String
    public var fields: [LaTeXBibField]
    public var range: LaTeXSourceRange
    public func field(_ name: String) -> String? { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
    public var displayTitle: String { field("title") ?? key }
}
public struct LaTeXBibliography: Sendable {
    public var source: String
    public var entries: [LaTeXBibEntry]
    public var diagnostics: [String]
    public var duplicateKeys: [String]
    public func missingCitations(_ keys: [String]) -> [String] { Array(Set(keys).subtracting(entries.map(\.key)).subtracting(["*"])).sorted() }
}

/// Keeps expressions and comments intact; editing an entry never reprints peers.
public enum LaTeXBibParser {
    public static func parse(_ source: String) -> LaTeXBibliography {
        let bytes = Array(source.utf8)
        var i = 0, entries = [LaTeXBibEntry](), messages = [String](), strings = [String:String]()
        func text(_ a: Int, _ b: Int) -> String { String(decoding:bytes[a..<b],as:UTF8.self) }
        func white(_ b: UInt8) -> Bool { [9,10,13,32].contains(b) }
        func skip() {
            while i < bytes.count {
                if white(bytes[i]) || bytes[i] == 44 { i += 1 }
                else if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 { i += 1 } }
                else { break }
            }
        }
        func value() -> (value:String,raw:String,range:LaTeXSourceRange)? {
            skip(); let start = i
            var pieces = [String]()
            while i < bytes.count {
                if bytes[i] == 123 || bytes[i] == 34 {
                    let quote = bytes[i] == 34; i += 1; let content = i
                    var depth = quote ? 0 : 1
                    while i < bytes.count {
                        if bytes[i] == 92 { i = min(i+2,bytes.count); continue }
                        if bytes[i] == 123 { depth += 1 }
                        if bytes[i] == 125 { depth -= 1; if !quote && depth == 0 { break } }
                        if quote && bytes[i] == 34 && depth == 0 { break }
                        i += 1
                    }
                    guard i < bytes.count else { return nil }
                    pieces.append(text(content,i)); i += 1
                } else {
                    let token = i
                    while i < bytes.count && ![35,44,125,41,9,10,13,32].contains(bytes[i]) { i += 1 }
                    guard i > token else { return nil }
                    let raw = text(token,i); pieces.append(strings[raw.lowercased()] ?? raw)
                }
                let contentEnd = i
                while i < bytes.count && white(bytes[i]) { i += 1 }
                if i < bytes.count && bytes[i] == 35 { i += 1; skip(); continue }
                return (pieces.joined(),text(start,contentEnd),.init(start:start,length:contentEnd-start))
            }
            return nil
        }
        while i < bytes.count {
            if bytes[i] == 37 { while i < bytes.count && bytes[i] != 10 { i += 1 }; continue }
            guard bytes[i] == 64 else { i += 1; continue }
            let start = i; i += 1; let typeStart = i
            while i < bytes.count && ((65...90).contains(bytes[i]) || (97...122).contains(bytes[i])) { i += 1 }
            let type = text(typeStart,i).lowercased(); skip()
            guard i < bytes.count && [123,40].contains(bytes[i]) else { messages.append("Malformed bibliography entry at byte \(start)"); continue }
            let close: UInt8 = bytes[i] == 123 ? 125 : 41; i += 1; skip()
            if type == "comment" || type == "preamble" {
                var depth = 1
                while i < bytes.count && depth > 0 {
                    if bytes[i] == 92 { i = min(i+2,bytes.count); continue }
                    if bytes[i] == (close == 125 ? 123 : 40) { depth += 1 }; if bytes[i] == close { depth -= 1 }; i += 1
                }; continue
            }
            if type == "string" {
                let nameStart = i; while i < bytes.count && bytes[i] != 61 && bytes[i] != close { i += 1 }
                let name = text(nameStart,i).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                if i < bytes.count && bytes[i] == 61 { i += 1; if let item = value() { strings[name] = item.value } }
                while i < bytes.count && bytes[i] != close { i += 1 }; i = min(i+1,bytes.count); continue
            }
            let keyStart = i; while i < bytes.count && bytes[i] != 44 && bytes[i] != close { i += 1 }
            let key = text(keyStart,i).trimmingCharacters(in:.whitespacesAndNewlines)
            var fields = [LaTeXBibField]()
            while i < bytes.count && bytes[i] != close {
                skip(); if i >= bytes.count || bytes[i] == close { break }
                let nameStart = i; while i < bytes.count && ![61,44,125,41].contains(bytes[i]) { i += 1 }
                let name = text(nameStart,i).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                guard i < bytes.count && bytes[i] == 61 else { messages.append("Missing field value in \(key)"); if i < bytes.count && bytes[i] == 44 { i += 1; continue }; break }
                i += 1
                guard let item = value() else { messages.append("Unclosed field in \(key)"); break }
                fields.append(.init(name:name,value:item.value,rawValue:item.raw,range:item.range)); skip()
            }
            if i < bytes.count && bytes[i] == close { i += 1 } else { messages.append("Unclosed entry \(key)") }
            if !key.isEmpty { entries.append(.init(type:type,key:key,fields:fields,range:.init(start:start,length:i-start))) }
        }
        let counts = Dictionary(grouping:entries,by:\.key)
        return .init(source:source,entries:entries,diagnostics:messages,duplicateKeys:counts.filter{$0.value.count > 1}.keys.sorted())
    }

    public static func source(type: String, key: String, fields: [String:String]) throws -> String {
        let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_:-./+"))
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(identifier.contains), !type.isEmpty, type.allSatisfy(\.isLetter),
              fields.keys.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0 == "_" } }) else { throw LaTeXError.invalidOperation("Enter a valid bibliography type and citation key.") }
        func balanced(_ value: String) -> Bool {
            var depth = 0, escaped = false
            for c in value {
                if escaped { escaped = false; continue }; if c == "\\" { escaped = true; continue }
                if c == "{" { depth += 1 }; if c == "}" { depth -= 1; if depth < 0 { return false } }
            }; return depth == 0 && !escaped
        }
        guard fields.values.allSatisfy(balanced) else { throw LaTeXError.invalidOperation("Bibliography fields have unmatched braces.") }
        return "@\(type){\(key),\n" + fields.keys.sorted().map { "  \($0) = {\(fields[$0]!)}," }.joined(separator:"\n") + "\n}\n"
    }
}

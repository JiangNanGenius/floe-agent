// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXDependencyOrigin: Codable, Hashable, Sendable {
    public var path: String?
    public var range: LaTeXSourceRange?
    public var command: String
}
public struct LaTeXDependencyRequirement: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case texFile, fontFamily, program }
    public var id: String { kind.rawValue + ":" + value }
    public var kind: Kind
    public var value: String
    public var origins: [LaTeXDependencyOrigin]
}
public struct LaTeXDependencyReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case source, bibliography, graphic, font }
    public var kind: Kind
    public var requested: String
    public var resolvedPaths: [String]
    public var origin: LaTeXDependencyOrigin
}
public struct LaTeXDependencyIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case dynamicReference, missingProjectResource, ambiguousProjectResource, externalReference }
    public var kind: Kind
    public var value: String
    public var origin: LaTeXDependencyOrigin
}
public struct LaTeXDependencyPlan: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var revision: Int64
    public var engine: LaTeXEngine
    public var mainFile: String
    /// Exact coherent manifest identity, distinct from a PDF/build fingerprint.
    public var inputDigest: String
    public var inspectedFiles: [String]
    public var requirements: [LaTeXDependencyRequirement]
    public var projectReferences: [LaTeXDependencyReference]
    public var issues: [LaTeXDependencyIssue]
    /// Static candidates are not proof that macro expansion has no additional
    /// dependencies. Real compiler diagnostics remain authoritative feedback.
    public var requiresCompilerFeedback = true
}

public enum LaTeXDependencyPlanner {
    public static func plan(manifest: LaTeXProjectManifest, textFiles: [String: String]) throws -> LaTeXDependencyPlan {
        guard manifest.schemaVersion == 1, manifest.files.count <= 10_000,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw LaTeXError.invalidProject }
        _ = try LaTeXPath.validate(manifest.mainFile)
        guard manifest.files.contains(where: { $0.path == manifest.mainFile && $0.kind == .source }),
              Set(textFiles.keys) == Set(manifest.files.filter { $0.kind.isText }.map(\.path)) else { throw LaTeXError.invalidProject }
        var total = 0
        for entry in manifest.files {
            try Task.checkCancellation(); _ = try LaTeXPath.validate(entry.path)
            if entry.kind.isText {
                guard let source = textFiles[entry.path] else { throw LaTeXError.missingFile(entry.path) }
                let bytes = Data(source.utf8); total += bytes.count
                guard total <= 64 * 1024 * 1024 else { throw LaTeXError.limitExceeded("dependency inputs") }
                guard bytes.count == entry.byteCount, LaTeXDigest.hash(bytes) == entry.sha256 else { throw LaTeXError.changedFile(entry.path) }
            }
        }
        guard textFiles[manifest.mainFile] != nil else { throw LaTeXError.missingFile(manifest.mainFile) }
        var builder = Builder(manifest: manifest, textFiles: textFiles, paths: Set(manifest.files.map(\.path)))
        return try builder.build()
    }

    /// Supplement only a real failed compiler receipt for the same frozen
    /// input. Diagnostic strings are resource candidates, never installation
    /// authorization; the host still probes, validates its owner and applies
    /// the existing environment/network/installation policy.
    public static func supplement(_ original: LaTeXDependencyPlan, compilerMessages: [String]) throws -> LaTeXDependencyPlan {
        var plan = original
        var values = Dictionary(uniqueKeysWithValues: original.requirements.map { ($0.id, $0) })
        let origin = LaTeXDependencyOrigin(path: nil, range: nil, command: "compiler")
        let text = String(compilerMessages.joined(separator: "\n").prefix(1_048_576))
        func captures(_ pattern: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, range: range).compactMap { match in
                guard match.numberOfRanges > 1, let value = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[value])
            }
        }
        func add(_ kind: LaTeXDependencyRequirement.Kind, _ value: String) {
            let key = kind.rawValue + ":" + value
            if var current = values[key] {
                if !current.origins.contains(origin) { current.origins.append(origin) }; values[key] = current
            } else { values[key] = .init(kind: kind, value: value, origins: [origin]) }
        }
        let filePatterns = [
            #"(?i)LaTeX Error:\s*File\s+[`'"]([^`'"\r\n]{1,255})[`'"]\s+not found"#,
            #"! I can't find file\s+[`'"]([^`'"\r\n]{1,255})[`'"]"#
        ]
        let allowedExtensions: Set<String> = ["sty", "cls", "tex", "def", "fd", "clo", "bst", "bbx", "cbx", "lbx", "enc", "map", "tfm"]
        for pattern in filePatterns {
            for name in try captures(pattern) where Builder.safeTeXFilename(name)
                && allowedExtensions.contains((name as NSString).pathExtension.lowercased()) {
                try Task.checkCancellation(); add(.texFile, name)
            }
        }
        for name in try captures(#"The\s+font\s+["“]([^"”\r\n]{1,256})["”]\s+cannot\s+be\s+found"#) {
            guard !name.hasPrefix("-"), !name.contains("\\"), !name.contains("/"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            add(.fontFamily, name)
        }
        let tools: Set<String> = ["bibtex", "biber", "makeindex", "xindy", "makeglossaries", "dvipdfmx", "upmendex"]
        for name in try captures(#"This document requires ([a-z][a-z0-9_-]{0,31}) in the selected environment"#) where tools.contains(name) {
            add(.program, name)
        }
        guard values.count <= 8192 else { throw LaTeXError.limitExceeded("dependency feedback") }
        plan.requirements = values.values.sorted { $0.id < $1.id }
        return plan
    }

    private struct Builder {
        let manifest: LaTeXProjectManifest
        let textFiles: [String: String]
        var visited = Set<String>()
        var queue: [String] = []
        var requirements: [String: LaTeXDependencyRequirement] = [:]
        var references: [LaTeXDependencyReference] = []
        var issues: [LaTeXDependencyIssue] = []
        let paths: Set<String>
        mutating func build() throws -> LaTeXDependencyPlan {
            queue = [manifest.mainFile]
            let engine = [LaTeXEngine.xeLaTeX: "xelatex", .luaLaTeX: "lualatex", .pdfLaTeX: "pdflatex", .latex: "latex"][manifest.engine]!
            add(.program, engine, origin: .init(path: manifest.mainFile, range: nil, command: "engine"))
            var index = 0
            while index < queue.count {
                try Task.checkCancellation()
                guard visited.count < 10_000, requirements.count <= 8192 else { throw LaTeXError.limitExceeded("dependency plan") }
                let path = queue[index]; index += 1
                guard visited.insert(path).inserted, let source = textFiles[path] else { continue }
                let parsed = LaTeXParser.parse(source)
                for command in parsed.commands {
                    try Task.checkCancellation()
                    let origin = LaTeXDependencyOrigin(path: path, range: command.range, command: command.name)
                    let arguments = command.arguments.filter { !$0.optional }.map { literal($0.value) }
                    let argument = arguments.first ?? unbracedArgument(source, after: command.range.end)
                    switch command.name {
                    case "documentclass", "LoadClass", "LoadClassWithOptions":
                        if let value = checked(argument, origin: origin) { try texFile(value, extension: "cls", origin: origin) }
                    case "usepackage", "RequirePackage", "RequirePackageWithOptions":
                        if let value = checked(argument, origin: origin) {
                            for name in split(value) { try texFile(name, extension: "sty", origin: origin) }
                            if split(value).contains("biblatex") {
                                let options = optionValues(command)
                                add(.program, options["backend"] == "bibtex" ? "bibtex" : "biber", origin: origin)
                                for key in ["style", "bibstyle", "citestyle"] {
                                    guard let style = options[key] else { continue }
                                    if key != "citestyle" { try texFile(style, extension: "bbx", origin: origin) }
                                    if key != "bibstyle" { try texFile(style, extension: "cbx", origin: origin) }
                                }
                            }
                        }
                    case "input", "include", "subfile":
                        if let value = checked(argument, origin: origin) { try reference(.source, value, extensions: ["tex", "ltx"], origin: origin) }
                    case "import", "subimport", "includefrom", "subincludefrom":
                        if arguments.count >= 2, let directory = checked(arguments[0], origin: origin), let file = checked(arguments[1], origin: origin) {
                            try reference(.source, directory + (directory.hasSuffix("/") ? "" : "/") + file, extensions: ["tex"], origin: origin)
                        }
                    case "bibliography", "addbibresource":
                        if let value = checked(argument, origin: origin) {
                            for file in split(value) { try reference(.bibliography, file, extensions: ["bib"], origin: origin) }
                            if command.name == "bibliography" { add(.program, "bibtex", origin: origin) }
                        }
                    case "bibliographystyle":
                        if let value = checked(argument, origin: origin) { try texFile(value, extension: "bst", origin: origin) }
                    case "includegraphics", "includesvg":
                        if let value = checked(argument, origin: origin) { try reference(.graphic, value, extensions: ["pdf", "png", "jpg", "jpeg", "eps", "svg"], origin: origin) }
                    case "setmainfont", "setsansfont", "setmonofont", "setmathfont", "setCJKmainfont", "setCJKsansfont", "setCJKmonofont":
                        if let value = checked(argument, origin: origin) {
                            let options = optionValues(command)
                            let fontPath = (options["Path"] ?? "") + value + (options["Extension"] ?? "")
                            let ext = (fontPath as NSString).pathExtension.lowercased()
                            if ["otf", "ttf", "ttc", "pfb", "tfm"].contains(ext) {
                                try reference(.font, fontPath, extensions: [], origin: origin)
                            } else { add(.fontFamily, value, origin: origin) }
                        }
                    case "makeindex": add(.program, "makeindex", origin: origin)
                    case "makeglossaries": add(.program, "makeglossaries", origin: origin)
                    default: break
                    }
                }
            }
            return .init(projectID: manifest.id, revision: manifest.revision, engine: manifest.engine,
                mainFile: manifest.mainFile, inputDigest: LaTeXDigest.hash(try LaTeXDigest.encode(manifest)),
                inspectedFiles: visited.sorted(), requirements: requirements.values.sorted { $0.id < $1.id },
                projectReferences: references, issues: issues)
        }
        mutating func add(_ kind: LaTeXDependencyRequirement.Kind, _ value: String, origin: LaTeXDependencyOrigin) {
            let key = kind.rawValue + ":" + value
            if var existing = requirements[key] {
                if !existing.origins.contains(origin) { existing.origins.append(origin) }; requirements[key] = existing
            } else { requirements[key] = .init(kind: kind, value: value, origins: [origin]) }
        }
        mutating func checked(_ value: String?, origin: LaTeXDependencyOrigin) -> String? {
            guard let value, !value.isEmpty else { return nil }
            guard !value.contains("\\"), !value.contains("#"), !value.contains("{"), !value.contains("}"),
                  value.utf8.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                issues.append(.init(kind: .dynamicReference, value: value, origin: origin)); return nil
            }
            guard !value.hasPrefix("/"), !value.contains(":") else {
                issues.append(.init(kind: .externalReference, value: value, origin: origin)); return nil
            }
            return value
        }
        mutating func texFile(_ value: String, extension ext: String, origin: LaTeXDependencyOrigin) throws {
            let file = (value as NSString).pathExtension.isEmpty ? value + "." + ext : value
            let resolved = candidates(file, origin: origin, extensions: [])
            if resolved.count == 1 {
                let path = resolved[0]
                references.append(.init(kind: .source, requested: file, resolvedPaths: resolved, origin: origin))
                if textFiles[path] != nil, !visited.contains(path), !queue.contains(path) { queue.append(path) }
            } else if resolved.count > 1 {
                references.append(.init(kind: .source, requested: file, resolvedPaths: resolved, origin: origin))
                issues.append(.init(kind: .ambiguousProjectResource, value: file, origin: origin))
            } else if Self.safeTeXFilename(file) {
                add(.texFile, file, origin: origin)
            } else { issues.append(.init(kind: file.contains("/") ? .missingProjectResource : .dynamicReference, value: file, origin: origin)) }
        }
        mutating func reference(_ kind: LaTeXDependencyReference.Kind, _ value: String, extensions: [String], origin: LaTeXDependencyOrigin) throws {
            let resolved = candidates(value, origin: origin, extensions: extensions)
            references.append(.init(kind: kind, requested: value, resolvedPaths: resolved, origin: origin))
            if resolved.isEmpty { issues.append(.init(kind: .missingProjectResource, value: value, origin: origin)) }
            else if resolved.count > 1 { issues.append(.init(kind: .ambiguousProjectResource, value: value, origin: origin)) }
            else if kind == .source, textFiles[resolved[0]] != nil, !visited.contains(resolved[0]), !queue.contains(resolved[0]) { queue.append(resolved[0]) }
        }
        func candidates(_ value: String, origin: LaTeXDependencyOrigin, extensions: [String]) -> [String] {
            let names = (value as NSString).pathExtension.isEmpty && !extensions.isEmpty ? extensions.map { value + "." + $0 } : [value]
            let directory = origin.path.map { ($0 as NSString).deletingLastPathComponent } ?? ""
            for name in names {
                if let clean = normalized(name, relativeTo: ""), paths.contains(clean) { return [clean] }
                if let clean = normalized(name, relativeTo: directory), paths.contains(clean) { return [clean] }
            }
            // The real worker uses project-root// TEXINPUTS/BIBINPUTS. Respect
            // a unique recursive local file without guessing among duplicates.
            let matches = paths.filter { path in names.contains { name in path == name || path.hasSuffix("/" + name) } }.sorted()
            return matches
        }
        func normalized(_ value: String, relativeTo directory: String) -> String? {
            guard !value.hasPrefix("/") else { return nil }
            var parts = directory.split(separator: "/").map(String.init)
            for part in value.split(separator: "/", omittingEmptySubsequences: false) {
                if part == "." { continue }
                if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
                else if part.isEmpty { return nil }
                else { parts.append(String(part)) }
            }
            return try? LaTeXPath.validate(parts.joined(separator: "/"))
        }
        static func safeTeXFilename(_ value: String) -> Bool {
            guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("-"), !value.contains("/"), value != ".", value != ".." else { return false }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+.-")
            return value.unicodeScalars.allSatisfy(allowed.contains)
        }
        func unbracedArgument(_ source: String, after offset: Int) -> String? {
            let bytes = Array(source.utf8); guard offset >= 0, offset < bytes.count else { return nil }
            var index = offset
            while index < bytes.count, [9,10,13,32].contains(bytes[index]) { index += 1 }
            let start = index
            while index < bytes.count, ![9,10,13,32,37,92,123,125].contains(bytes[index]) { index += 1 }
            return index > start ? literal(String(decoding: bytes[start..<index], as: UTF8.self)) : nil
        }
        func literal(_ value: String) -> String {
            let bytes = Array(value.utf8); var output: [UInt8] = []; var index = 0
            while index < bytes.count {
                if bytes[index] == 92, index + 1 < bytes.count { output += bytes[index...index+1]; index += 2 }
                else if bytes[index] == 37 { while index < bytes.count, bytes[index] != 10 { index += 1 } }
                else { output.append([9,10,13].contains(bytes[index]) ? 32 : bytes[index]); index += 1 }
            }
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func split(_ value: String) -> [String] {
            var depth = 0, current = "", values: [String] = []
            for character in value {
                if character == "{" || character == "[" { depth += 1 }
                if character == "}" || character == "]" { depth = max(0, depth - 1) }
                if character == ",", depth == 0 { values.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = "" }
                else { current.append(character) }
            }
            values.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); return values.filter { !$0.isEmpty }
        }
        func optionValues(_ command: LaTeXCommand) -> [String: String] {
            var result: [String: String] = [:]
            for raw in command.arguments.filter(\.optional).flatMap({ split(literal($0.value)) }) {
                let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("{"), value.hasSuffix("}") { value.removeFirst(); value.removeLast() }
                result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = value
            }
            return result
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDALibraryImportEntry: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let name: String
    public let partID: String?
    public let notices: [EDALibraryNotice]
    public var available: Bool { partID != nil && !notices.contains { $0.severity == .blocking } }
}
public struct EDALibraryImportDraft: Sendable {
    public let package: EDALibraryPackage?
    public let entries: [EDALibraryImportEntry]
    /// Even a fully unsupported import retains the complete original input.
    public let originalFiles: [String: Data]
    public var availableCount: Int { entries.filter(\.available).count }
}

public enum EDALibraryImport {
    /// File/directory/archive access is performed by the authorized host.
    /// This adapter accepts only its bounded data snapshot; it never opens
    /// model-supplied paths, follows URLs or installs missing dependencies.
    public static func inspect(files: [String: Data], title: String,
                               cancelled: @Sendable () -> Bool = { false }) throws -> EDALibraryImportDraft {
        guard !files.isEmpty, files.count <= 4_096, files.values.reduce(0, { $0 + $1.count }) <= 128 * 1_024 * 1_024,
              files.allSatisfy({ EDALibraryPackage.safeRelativePath($0.key) && $0.value.count <= 32 * 1_024 * 1_024 }) else { throw EDAError.invalid("library import path/count/size budget") }
        guard !cancelled() else { throw EDAError.cancelled }
        if files.count == 1, let file = files.first,
           ["floeelib", "json"].contains(URL(fileURLWithPath: file.key).pathExtension.lowercased()) {
            let package = try EDALibraryPackage.decode(file.value)
            return .init(package: package, entries: package.parts.map { .init(sourcePath: file.key, name: $0.name, partID: $0.id, notices: $0.notices) }, originalFiles: files)
        }
        var symbols: [String: (Data, String)] = [:]
        var declarations: [String: String] = [:], conflicts: Set<String> = []
        var entries: [EDALibraryImportEntry] = [], parts: [EDALibraryPart] = []
        func namespace(_ path: String) -> String {
            let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent().lastPathComponent
            if parent.hasSuffix(".kicad_symdir") { return String(parent.dropLast(".kicad_symdir".count)) }
            if parent.hasSuffix(".pretty") { return String(parent.dropLast(".pretty".count)) }
            return "Imported"
        }
        for path in files.keys.sorted() where path.hasSuffix(".kicad_sym") {
            if cancelled() { throw EDAError.cancelled }
            let data = files[path]!
            do {
                let node = try EDASExpression.parse(data, cancelled: cancelled)
                guard node.tag == "kicad_symbol_lib" else { throw EDAError.unsupported("symbol library format") }
                symbols[path] = (data, namespace(path))
                for symbol in node.children("symbol") {
                    guard let name = symbol.value() else { continue }
                    let key = namespace(path) + ":" + name
                    if declarations[key] != nil { conflicts.insert(key) }
                    else { declarations[key] = path }
                }
            } catch EDAError.cancelled { throw EDAError.cancelled }
            catch { entries.append(.init(sourcePath: path, name: path, partID: nil,
                notices: [.init("symbol_source_unavailable", .blocking, path: path, detail: String(describing: error))])) }
        }
        for path in symbols.keys.sorted() {
            let (data, ns) = symbols[path]!
            do {
                var dependencies: [String: Data] = [:], visited: Set<String> = []
                func collect(_ source: Data, depth: Int) throws {
                    guard depth < 32 else { throw EDAError.invalid("symbol dependency depth") }
                    let root = try EDASExpression.parse(source, cancelled: cancelled)
                    for symbol in root.children("symbol") {
                        guard let parent = symbol.child("extends")?.value() else { continue }
                        let key = ns + ":" + parent
                        guard !conflicts.contains(key) else { throw EDAError.duplicate("ambiguous symbol dependency " + key) }
                        if visited.insert(key).inserted, let sourcePath = declarations[key], sourcePath != path, let bytes = symbols[sourcePath]?.0 {
                            dependencies[sourcePath] = bytes; try collect(bytes, depth: depth + 1)
                        }
                    }
                }
                try collect(data, depth: 0)
                let result = try EDAKiCadSymbols.read(data, sourcePath: path, namespace: ns, dependencies: dependencies, cancelled: cancelled)
                for name in result.notices.keys.sorted() {
                    var reports = result.notices[name] ?? []
                    if conflicts.contains(ns + ":" + name) {
                        reports.append(.init("symbol_name_conflict", .blocking, path: path, detail: "The same qualified symbol name is declared in multiple files. Original files retained; no declaration was chosen."))
                        entries.append(.init(sourcePath: path, name: name, partID: nil, notices: reports)); continue
                    }
                    if let symbol = result.symbols.first(where: { $0.name == name }) {
                        let id = "symbol:" + ns + ":" + name
                        let origins = [EDALibrarySource(path: path, data: data)] + dependencies.keys.sorted().map { EDALibrarySource(path: $0, data: dependencies[$0]!) }
                        parts.append(.init(id: id, name: name, kind: .symbol, category: "user", aliases: [ns], parameters: symbol.fields,
                            symbol: symbol, sources: origins, notices: reports))
                        entries.append(.init(sourcePath: path, name: name, partID: id, notices: reports))
                    } else { entries.append(.init(sourcePath: path, name: name, partID: nil, notices: reports)) }
                }
            } catch EDAError.cancelled { throw EDAError.cancelled }
            catch { entries.append(.init(sourcePath: path, name: path, partID: nil, notices: [.init("symbol_source_unavailable", .blocking, path: path, detail: String(describing: error))])) }
        }
        for path in files.keys.sorted() where path.hasSuffix(".kicad_mod") {
            if cancelled() { throw EDAError.cancelled }
            do {
                let data = files[path]!, result = try EDAKiCadFootprints.read(data, sourcePath: path, namespace: namespace(path), cancelled: cancelled)
                if let footprint = result.footprint {
                    let id = "footprint:" + namespace(path) + ":" + footprint.name
                    parts.append(.init(id: id, name: footprint.name, kind: .footprint, category: "user", parameters: footprint.fields,
                        footprint: footprint, sources: [result.source], notices: result.notices))
                    entries.append(.init(sourcePath: path, name: footprint.name, partID: id, notices: result.notices))
                } else { entries.append(.init(sourcePath: path, name: path, partID: nil, notices: result.notices)) }
            } catch EDAError.cancelled { throw EDAError.cancelled }
            catch { entries.append(.init(sourcePath: path, name: path, partID: nil, notices: [.init("footprint_source_unavailable", .blocking, path: path, detail: String(describing: error))])) }
        }
        for path in files.keys.sorted() where !path.hasSuffix(".kicad_sym") && !path.hasSuffix(".kicad_mod") {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if !["md", "txt", "license"].contains(ext) && !path.uppercased().contains("LICENSE") {
                entries.append(.init(sourcePath: path, name: path, partID: nil, notices: [.init("file_retained", .warning, path: path, detail: "Not a supported library definition; original retained unchanged.")]))
            }
        }
        let duplicateIDs = Set(Dictionary(grouping: parts, by: \.id).filter { $0.value.count > 1 }.keys)
        if !duplicateIDs.isEmpty {
            parts.removeAll { duplicateIDs.contains($0.id) }
            entries = entries.map { entry in
                guard let id = entry.partID, duplicateIDs.contains(id) else { return entry }
                return .init(sourcePath: entry.sourcePath, name: entry.name, partID: nil,
                    notices: entry.notices + [.init("part_name_conflict", .blocking, path: entry.sourcePath, detail: "The same qualified library entry appears more than once. Original files retained; no entry was overwritten.")])
            }
        }
        let inputHash = EDALibraryDigest.sha256(try EDALibraryDigest.encoded(files))
        let licenseFiles = files.keys.filter { $0.uppercased().contains("LICENSE") || $0.uppercased().contains("COPYING") }.sorted()
        let licenseText = licenseFiles.compactMap { String(data: files[$0]!, encoding: .utf8) }.joined(separator: "\n\n")
        let license = EDALibraryLicense(id: "LicenseRef-UserProvided", attribution: "User-imported library",
            text: licenseText.isEmpty ? "Original user-provided files are retained. Import does not grant redistribution permission." : licenseText,
            modifications: "Native conversion; compatibility findings retain every rejected definition and unsupported item.")
        var package: EDALibraryPackage?
        if !parts.isEmpty {
            let value = EDALibraryPackage(id: "user." + inputHash, version: "1.0.0", title: title,
                parts: parts, licenses: [license], sourcePayloads: files)
            try value.validate(); package = value
        }
        return .init(package: package, entries: entries, originalFiles: files)
    }
}

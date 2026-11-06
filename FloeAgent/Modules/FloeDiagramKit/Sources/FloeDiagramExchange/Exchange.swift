// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramLayout
import ZIPFoundation
import CDiagramCompression

public enum DiagramFormat: String, Codable, CaseIterable, Sendable {
    case floemap, xmind, freemind, opml, markdown, drawio, mermaid, svg, pdf, png
    public var fileExtension: String {
        switch self { case .freemind: "mm"; case .markdown: "md"; case .mermaid: "mmd"; default: rawValue }
    }
}
public struct DiagramExchangeIssue: Codable, Hashable, Sendable {
    public var code: String
    public var detail: String
    public init(_ code: String, _ detail: String) { self.code = code; self.detail = detail }
}
public struct DiagramImportResult: Sendable {
    public var document: DiagramDocument
    public var assets: [UUID: Data]
    public var issues: [DiagramExchangeIssue]
    public init(document: DiagramDocument, assets: [UUID: Data] = [:], issues: [DiagramExchangeIssue] = []) {
        self.document = document; self.assets = assets; self.issues = issues
    }
}
public struct DiagramExportResult: Sendable {
    public var data: Data
    public var format: DiagramFormat
    public var issues: [DiagramExchangeIssue]
    public init(data: Data, format: DiagramFormat, issues: [DiagramExchangeIssue] = []) { self.data = data; self.format = format; self.issues = issues }
}
public enum DiagramExchange {
    public static func importData(_ data: Data, format: DiagramFormat, title: String = "Imported") throws -> DiagramImportResult {
        try Task.checkCancellation()
        guard data.count <= 128*1_024*1_024 else { throw DiagramError.invalid("input size") }
        let result: DiagramImportResult
        switch format {
        case .floemap: result = try nativeImport(data)
        case .xmind: result = try XMindCodec.decode(data)
        case .freemind, .opml: result = try OutlineCodec.decodeXML(data, format: format, title: title)
        case .markdown: result = try OutlineCodec.decodeMarkdown(data, title: title)
        case .drawio: result = try DrawIOCodec.decode(data, title: title)
        case .mermaid: result = try MermaidCodec.decode(data, title: title)
        default: throw DiagramError.unsupported("This is an output format")
        }
        try result.document.validate()
        return result
    }
    public static func export(_ document: DiagramDocument, format: DiagramFormat, pageID: UUID? = nil,
                              assets: (any DiagramAssetResolver)? = nil) async throws -> DiagramExportResult {
        try document.validate(); try Task.checkCancellation()
        switch format {
        case .floemap: return .init(data: try await nativeExport(document, resolver: assets), format: format)
        case .xmind: return try await XMindCodec.encode(document, resolver: assets)
        case .freemind, .opml, .markdown, .mermaid:
            guard let page = pageID.flatMap(document.page) ?? (document.pages.count == 1 ? document.pages.first : nil) else { throw DiagramError.invalid("select a page for outline/text export") }
            if format == .mermaid { return try MermaidCodec.encode(document, page: page) }
            return try OutlineCodec.encode(document, page: page, format: format)
        case .drawio: return try DrawIOCodec.encode(document)
        case .svg:
            guard let page = pageID.flatMap(document.page) ?? document.pages.first else { throw DiagramError.invalid("page") }
            return try await DiagramSVGExporter.export(document, page: page, assets: assets)
        case .pdf, .png:
            return try await DiagramNativeExporter.export(document, format: format, pageID: pageID, resolver: assets)
        }
    }
    public static func save(_ output: DiagramExportResult, to url: URL) throws { try DiagramAtomicFile.write(output.data, to: url) }
    private struct NativeManifest: Codable {
        var format = "org.floe.diagram"
        var version = 1
        var documentDigest: String
        var assetDigests: [String: String]
    }
    private static func nativeExport(_ document: DiagramDocument, resolver: (any DiagramAssetResolver)?) async throws -> Data {
        let body = try DiagramCodec.encode(document)
        var entries = ["diagram.json": body], digests: [String: String] = [:]
        for asset in document.assets {
            try Task.checkCancellation()
            guard let resolver else { throw DiagramError.invalid("asset resolver required") }
            let bytes = try await resolver.data(for: asset)
            guard bytes.count == asset.byteCount, asset.sha256.map({ DiagramCodec.digest(bytes) == $0 }) ?? true else { throw DiagramError.invalid("asset integrity") }
            let path = "assets/"+asset.id.uuidString
            entries[path] = bytes; digests[asset.id.uuidString] = DiagramCodec.digest(bytes)
        }
        entries["manifest.json"] = try DiagramCodec.encode(NativeManifest(documentDigest: DiagramCodec.digest(body), assetDigests: digests))
        return try DiagramZIP.pack(entries)
    }
    private static func nativeImport(_ data: Data) throws -> DiagramImportResult {
        let entries = try DiagramZIP.unpack(data)
        guard let manifestData = entries["manifest.json"], let body = entries["diagram.json"] else { throw DiagramError.invalid("native manifest missing") }
        let manifest = try DiagramCodec.decode(NativeManifest.self, from: manifestData)
        guard manifest.format == "org.floe.diagram", manifest.version == 1, DiagramCodec.digest(body) == manifest.documentDigest else { throw DiagramError.invalid("native manifest integrity") }
        let document = try DiagramCodec.decode(DiagramDocument.self, from: body)
        var assets: [UUID: Data] = [:]
        for asset in document.assets {
            guard let bytes = entries["assets/"+asset.id.uuidString], bytes.count == asset.byteCount,
                  DiagramCodec.digest(bytes) == manifest.assetDigests[asset.id.uuidString],
                  asset.sha256.map({ DiagramCodec.digest(bytes) == $0 }) ?? true else { throw DiagramError.invalid("native asset missing or changed") }
            assets[asset.id] = bytes
        }
        return .init(document: document, assets: assets)
    }
}

enum DiagramZIP {
    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        !path.contains("\0") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    static func unpack(_ data: Data) throws -> [String: Data] {
        let archive = try Archive(data: data, accessMode: .read)
        var result: [String: Data] = [:], total: UInt64 = 0, count = 0
        for entry in archive {
            try Task.checkCancellation(); count += 1
            guard validPath(entry.path), entry.type != .symlink, result[entry.path] == nil,
                  entry.uncompressedSize <= 64*1_024*1_024, count <= 20_000 else { throw DiagramError.invalid("archive entry") }
            total += entry.uncompressedSize
            guard total <= 512*1_024*1_024 else { throw DiagramError.invalid("archive expansion limit") }
            if entry.type == .directory { continue }
            var bytes = Data()
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard bytes.count+chunk.count <= 64*1_024*1_024 else { throw DiagramError.invalid("archive expansion limit") }; bytes.append(chunk)
            }
            result[entry.path] = bytes
        }
        return result
    }
    static func pack(_ entries: [String: Data]) throws -> Data {
        guard entries.count <= 20_000, entries.values.reduce(Int64(0), { $0+Int64($1.count) }) <= 512*1_024*1_024 else { throw DiagramError.invalid("archive output limits") }
        let archive = try Archive(accessMode: .create)
        for path in entries.keys.sorted() {
            try Task.checkCancellation()
            guard validPath(path), let data = entries[path], data.count <= 64*1_024*1_024 else { throw DiagramError.invalid("archive output entry") }
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Date(timeIntervalSince1970: 315_532_800), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position)+size))
            }
        }
        guard let data = archive.data else { throw DiagramError.io("archive serialization") }
        guard data.count <= 128*1_024*1_024 else { throw DiagramError.invalid("archive output exceeds supported input size") }; return data
    }
}
enum DiagramRawDeflate {
    static func decode(_ data: Data, maximum: Int = 32*1_024*1_024) throws -> Data {
        var output = [UInt8](repeating: 0, count: maximum), length = maximum
        let code = data.withUnsafeBytes { bytes in floe_diagram_inflate(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &length) }
        guard code == 0 else { throw DiagramError.invalid("compressed diagram") }
        return Data(output.prefix(length))
    }
    static func encode(_ data: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: max(1_024, data.count+data.count/8+100)), length = output.count
        let code = data.withUnsafeBytes { bytes in floe_diagram_deflate(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &length) }
        guard code == 0 else { throw DiagramError.io("diagram compression") }; return Data(output.prefix(length))
    }
}
enum ExchangeText {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</(?:p|div)>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func stableID(_ namespace: String, _ raw: String) -> UUID {
        if let id = UUID(uuidString: raw) { return id }
        let h = Array(DiagramCodec.digest(Data((namespace+":"+raw).utf8)))
        return UUID(uuidString: String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32]))!
    }
    static func colorHex(_ value: String) -> String {
        let color = DiagramPalette.color(value)
        guard color.alpha > 0 else { return "none" }
        let components = color.components ?? [0,0,0,1]
        return String(format: "#%02X%02X%02X",Int((components[0]*255).rounded()),Int((components[1]*255).rounded()),Int((components[2]*255).rounded()))
    }
    static func outlineIssues(_ page: DiagramPage, tasks: [DiagramTask]) -> [DiagramExchangeIssue] {
        var issues: [DiagramExchangeIssue] = []
        if !page.connections.isEmpty { issues.append(.init("relationships", "This outline format does not retain graph connections.")) }
        if page.elements.contains(where: { !$0.kind.isTopic }) { issues.append(.init("shapes", "Shapes and containers are represented as outline entries.")) }
        if page.elements.contains(where: { $0.content.contains(where: { if case .note = $0 { return false }; return true }) }) { issues.append(.init("richContent", "Rich content is converted to readable text; keep the native file.")) }
        if !tasks.isEmpty { issues.append(.init("projectFields", "Assignees, dates and dependencies are not fully preserved by outline interchange.")) }
        return issues
    }
}

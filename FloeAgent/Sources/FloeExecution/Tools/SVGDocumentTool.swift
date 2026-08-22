import Foundation
import Crypto
import FloeCore
import FloeTools

/// Bounded SVG inspection and exact editing. SVG remains visible and editable
/// source; rendering/preview is delegated to the app's browser surface.
public struct SVGDocumentTool: AgentTool {
    public struct Replacement: Decodable, Sendable {
        public var old: String
        public var new: String
        public init(old: String, new: String) { self.old = old; self.new = new }
    }

    public enum Operation: String, Decodable, Sendable { case inspect, edit }

    public struct Arguments: Decodable, Sendable {
        public var operation: Operation
        public var path: String
        public var outputPath: String?
        public var replacements: [Replacement]?

        public init(operation: Operation, path: String, outputPath: String? = nil, replacements: [Replacement]? = nil) {
            self.operation = operation
            self.path = path
            self.outputPath = outputPath
            self.replacements = replacements
        }
    }

    public static let name = "image.svgDocument"
    public static let toolDescription =
        "Inspect or edit an SVG as visible XML source. Inspect reports dimensions, viewBox, element counts, IDs, colors and text. Edit applies bounded exact replacements, writes a new workspace SVG, reopens it, validates XML and reports the saved hash. Use browser preview for rendering. External entities, scripts, foreignObject and remote references are rejected."
    public static let parametersJSON = #"{"type":"object","properties":{"operation":{"type":"string","enum":["inspect","edit"]},"path":{"type":"string","description":"Workspace-relative .svg path"},"outputPath":{"type":"string","description":"Required new .svg path for edit"},"replacements":{"type":"array","maxItems":64,"items":{"type":"object","properties":{"old":{"type":"string"},"new":{"type":"string"}},"required":["old","new"],"additionalProperties":false}}},"required":["operation","path"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard args.path.lowercased().hasSuffix(".svg") else {
            throw FloeError.validationFailed("path must be an SVG file")
        }
        if args.operation == .edit {
            guard let output = args.outputPath, output.lowercased().hasSuffix(".svg"), output != args.path else {
                throw FloeError.validationFailed("edit requires a different workspace-relative outputPath ending in .svg")
            }
            guard let replacements = args.replacements, !replacements.isEmpty, replacements.count <= 64 else {
                throw FloeError.validationFailed("edit requires 1-64 replacements")
            }
            for replacement in replacements {
                guard !replacement.old.isEmpty,
                      replacement.old.utf8.count <= 16 * 1_024,
                      replacement.new.utf8.count <= 16 * 1_024 else {
                    throw FloeError.validationFailed("SVG replacements must be non-empty and bounded")
                }
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.authorizeWorkspacePath(args.path)
        let sourceURL = try Self.workspaceURL(args.path, context: context)
        let sourceData = try Data(floeContentsOf: sourceURL, options: [.mappedIfSafe])
        guard sourceData.count <= 8 * 1_024 * 1_024,
              var source = String(data: sourceData, encoding: .utf8) else {
            return Self.output("status=error error=SVG must be bounded UTF-8 XML", code: 2)
        }
        if let unsafe = Self.unsafeFeature(in: source) {
            return Self.output("status=error error=unsafe SVG feature: \(unsafe)", code: 2)
        }
        switch args.operation {
        case .inspect:
            guard let report = Self.inspect(source) else {
                return Self.output("status=error error=invalid SVG XML", code: 2)
            }
            return Self.output(report, code: 0)
        case .edit:
            for replacement in args.replacements ?? [] {
                guard source.contains(replacement.old) else {
                    return Self.output("status=error error=replacement source was not found", code: 2)
                }
                source = source.replacingOccurrences(of: replacement.old, with: replacement.new)
            }
            guard source.utf8.count <= 8 * 1_024 * 1_024,
                  Self.unsafeFeature(in: source) == nil,
                  let report = Self.inspect(source),
                  let outputPath = args.outputPath else {
                return Self.output("status=error error=edited SVG failed validation", code: 2)
            }
            try context.authorizeWorkspacePath(outputPath)
            let outputURL = try Self.workspaceURL(outputPath, context: context)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: outputURL, options: .atomic)
            let reopened = try Data(floeContentsOf: outputURL)
            guard String(data: reopened, encoding: .utf8).flatMap(Self.inspect) != nil else {
                try? FileManager.default.removeItem(at: outputURL)
                return Self.output("status=error error=saved SVG could not be reopened", code: 2)
            }
            let sha = SHA256.hash(data: reopened).map { String(format: "%02x", $0) }.joined()
            return Self.output("status=saved path=\(outputPath) bytes=\(reopened.count) sha256=\(sha)\n\(report)", code: 0)
        }
    }

    private static func workspaceURL(_ path: String, context: ToolContext) throws -> URL {
        guard let root = context.workspaceRootURL else { throw FloeError.validationFailed("No task workspace is available") }
        let normalized = (path as NSString).standardizingPath
        guard !normalized.hasPrefix("/"), !normalized.hasPrefix("..") else {
            throw FloeError.validationFailed("path must stay inside the task workspace")
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(normalized).standardizedFileURL
        guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else {
            throw FloeError.validationFailed("path escapes the task workspace")
        }
        return url
    }

    private static func unsafeFeature(in source: String) -> String? {
        let lower = source.lowercased()
        let forbidden = [
            "<!doctype", "<!entity", "<script", "<foreignobject", "javascript:",
            "href=\"http://", "href='http://", "href=\"https://", "href='https://"
        ]
        return forbidden.first(where: lower.contains)
    }

    private static func inspect(_ source: String) -> String? {
        let delegate = SVGInspectionDelegate()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRootSVG else { return nil }
        return delegate.report
    }

    private static func output(_ text: String, code: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: code)
    }
}

private final class SVGInspectionDelegate: NSObject, XMLParserDelegate {
    var sawRootSVG = false
    var elementCounts: [String: Int] = [:]
    var ids: [String] = []
    var colors: Set<String> = []
    var textFragments: [String] = []
    var rootAttributes: [String: String] = [:]
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.lowercased()
        if elementCounts.isEmpty { sawRootSVG = name == "svg"; rootAttributes = attributeDict }
        elementCounts[name, default: 0] += 1
        if let id = attributeDict["id"], ids.count < 200 { ids.append(id) }
        for key in ["fill", "stroke", "color", "stop-color"] {
            if let value = attributeDict[key], colors.count < 200 { colors.insert(value) }
        }
        insideText = name == "text" || name == "tspan"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideText, !trimmed.isEmpty, textFragments.count < 200 { textFragments.append(trimmed) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["text", "tspan"].contains(elementName.lowercased()) { insideText = false }
    }

    var report: String {
        let counts = elementCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "status=ok width=\(rootAttributes["width"] ?? "unspecified") height=\(rootAttributes["height"] ?? "unspecified") viewBox=\(rootAttributes["viewBox"] ?? "unspecified") elements={\(counts)} ids=[\(ids.joined(separator: ","))] colors=[\(colors.sorted().joined(separator: ","))] text=[\(textFragments.joined(separator: " | "))]"
    }
}

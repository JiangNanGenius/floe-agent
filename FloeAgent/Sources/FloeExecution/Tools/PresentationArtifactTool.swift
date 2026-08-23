import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools

public struct PresentationTableDocument: Codable, Sendable, Equatable {
    public var title: String?
    public var columns: [String]
    public var rows: [[String]]

    public init(title: String? = nil, columns: [String], rows: [[String]]) {
        self.title = title
        self.columns = columns
        self.rows = rows
    }
}

public struct PresentationChartDocument: Codable, Sendable, Equatable {
    public enum ChartType: String, Codable, Sendable { case line, bar, area, pie, scatter }
    public struct Point: Codable, Sendable, Equatable {
        public var label: String
        public var value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value }
    }
    public struct Series: Codable, Sendable, Equatable {
        public var name: String
        public var points: [Point]
        public init(name: String, points: [Point]) { self.name = name; self.points = points }
    }

    public var title: String?
    public var type: ChartType
    public var series: [Series]

    public init(title: String? = nil, type: ChartType, series: [Series]) {
        self.title = title
        self.type = type
        self.series = series
    }
}

/// Produces bounded, digest-addressed rich results that the conversation UI
/// can render natively. HTML remains useful for interactive local reports but
/// receives a strict CSP and no network, frame, plug-in, form, or host bridge.
public struct PresentationArtifactTool: AgentTool {
    public enum Kind: String, Decodable, Sendable { case table, chart, web }

    public struct Arguments: Decodable, Sendable {
        public var kind: Kind
        public var title: String?
        public var columns: [String]?
        public var rows: [[String]]?
        public var chartType: PresentationChartDocument.ChartType?
        public var series: [PresentationChartDocument.Series]?
        public var html: String?

        public init(
            kind: Kind,
            title: String? = nil,
            columns: [String]? = nil,
            rows: [[String]]? = nil,
            chartType: PresentationChartDocument.ChartType? = nil,
            series: [PresentationChartDocument.Series]? = nil,
            html: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.columns = columns
            self.rows = rows
            self.chartType = chartType
            self.series = series
            self.html = html
        }
    }

    public static let name = "presentation.create"
    public static let toolDescription =
        "Create a rich conversation result. Use table for native structured rows, chart for native line/bar/area/pie/scatter charts, or web for an interactive self-contained HTML preview. Web previews may use inline CSS and JavaScript but cannot access the network, frames, forms, plug-ins, native bridges, or arbitrary files. The result is saved, hash-verified, displayed inline, and can be shared."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "kind":{"type":"string","enum":["table","chart","web"]},
        "title":{"type":"string","maxLength":160},
        "columns":{"type":"array","maxItems":32,"items":{"type":"string","maxLength":200}},
        "rows":{"type":"array","maxItems":500,"items":{"type":"array","maxItems":32,"items":{"type":"string","maxLength":1000}}},
        "chartType":{"type":"string","enum":["line","bar","area","pie","scatter"]},
        "series":{"type":"array","maxItems":16,"items":{"type":"object","properties":{"name":{"type":"string","maxLength":100},"points":{"type":"array","maxItems":2000,"items":{"type":"object","properties":{"label":{"type":"string","maxLength":100},"value":{"type":"number"}},"required":["label","value"],"additionalProperties":false}},"required":["name","points"],"additionalProperties":false}}},
        "html":{"type":"string","description":"Self-contained HTML, max 512 KiB"}
      },
      "required":["kind"],
      "additionalProperties":false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let rootURLProvider: @Sendable () throws -> URL

    public init(rootURLProvider: @escaping @Sendable () throws -> URL = {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("FloeAgent", isDirectory: true)
    }) {
        self.rootURLProvider = rootURLProvider
    }

    public func validate(_ args: Arguments) throws {
        if let title = args.title, title.count > 160 {
            throw FloeError.validationFailed("title exceeds 160 characters")
        }
        switch args.kind {
        case .table:
            guard let columns = args.columns, !columns.isEmpty, columns.count <= 32,
                  let rows = args.rows, rows.count <= 500,
                  rows.allSatisfy({ $0.count == columns.count }),
                  columns.allSatisfy({ $0.count <= 200 }),
                  rows.flatMap({ $0 }).allSatisfy({ $0.count <= 1_000 }) else {
                throw FloeError.validationFailed("table requires 1...32 columns and up to 500 rectangular rows")
            }
        case .chart:
            guard args.chartType != nil, let series = args.series,
                  !series.isEmpty, series.count <= 16,
                  series.reduce(0, { $0 + $1.points.count }) <= 2_000,
                  series.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 && !$0.points.isEmpty }),
                  series.flatMap({ $0.points }).allSatisfy({ $0.label.count <= 100 && $0.value.isFinite }) else {
                throw FloeError.validationFailed("chart requires a type and 1...16 finite series with at most 2000 total points")
            }
        case .web:
            guard let html = args.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  html.utf8.count <= 512 * 1_024 else {
                throw FloeError.validationFailed("web requires non-empty self-contained HTML up to 512 KiB")
            }
            let folded = html.lowercased()
            guard !["<iframe", "<frame", "<object", "<embed", "<base", "<form"].contains(where: folded.contains) else {
                throw FloeError.validationFailed("web preview cannot contain frames, plug-ins, base URLs, or forms")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        let document: Data
        let mimeType: String
        let fileExtension: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch args.kind {
        case .table:
            document = try encoder.encode(PresentationTableDocument(
                title: args.title, columns: args.columns ?? [], rows: args.rows ?? []
            ))
            mimeType = "application/vnd.floe.table+json"
            fileExtension = "table.json"
        case .chart:
            document = try encoder.encode(PresentationChartDocument(
                title: args.title, type: args.chartType ?? .line, series: args.series ?? []
            ))
            mimeType = "application/vnd.floe.chart+json"
            fileExtension = "chart.json"
        case .web:
            document = Data(Self.sandboxedHTML(args.html ?? "").utf8)
            mimeType = "text/html"
            fileExtension = "html"
        }
        guard document.count <= 1 * 1_024 * 1_024 else {
            throw FloeError.validationFailed("rendered presentation exceeds 1 MiB")
        }
        let digest = SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let relativeDirectory = "PresentationArtifacts/\(context.runID.uuidString)"
        let root = try rootURLProvider().standardizedFileURL
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).\(fileExtension)"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try document.write(to: url, options: [.atomic])
        let artifact = ToolArtifactReference(
            id: id,
            relativePath: "\(relativeDirectory)/\(fileName)",
            mimeType: mimeType,
            byteCount: document.count,
            sha256: digest
        )
        return ToolExecutionOutput(
            summary: "created \(args.kind.rawValue) presentation\(args.title.map { ": \($0)" } ?? "")",
            fullOutputSHA256: digest,
            artifacts: [artifact]
        )
    }

    private static func sandboxedHTML(_ html: String) -> String {
        let policy = "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'; navigate-to 'none'"
        let meta = #"<meta http-equiv="Content-Security-Policy" content=""# + policy + #"">"#
        if let head = html.range(of: "<head", options: .caseInsensitive),
           let closing = html[head.lowerBound...].firstIndex(of: ">") {
            var result = html
            result.insert(contentsOf: meta, at: result.index(after: closing))
            return result
        }
        return "<!doctype html><html><head>\(meta)<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body>\(html)</body></html>"
    }
}

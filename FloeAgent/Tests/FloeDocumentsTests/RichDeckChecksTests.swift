// Ported from Local/Private/build191-feedback/ppt/tests/RichDeckChecks.swift.
// Structure-level checks only: they do not prove native engine or real Office
// UI behaviour. Requires the FloeDocuments chart-workbook marker patch so the
// generated deck embeds ppt/embeddings/floe-chart-data-<n>.xlsx.
import Foundation
import Testing
import ZIPFoundation
import Crypto
import FloeCore
import FloeTools
@testable import FloeDocuments

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): return message }
    }
}

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") throws {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        let extra = detail()
        failed.append(name)
        print("FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-rich-ppt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func readEntry(_ url: URL, _ path: String) throws -> Data {
    let archive = try Archive(url: url, accessMode: .read)
    guard let entry = archive[path] else { throw CheckFailure.failed("missing entry \(path)") }
    var data = Data()
    _ = try archive.extract(entry) { data.append($0) }
    return data
}

func entryPaths(_ url: URL) throws -> [String] {
    let archive = try Archive(url: url, accessMode: .read)
    return archive.map(\.path)
}

func text(_ url: URL, _ path: String) throws -> String {
    guard let value = String(data: try readEntry(url, path), encoding: .utf8) else {
        throw CheckFailure.failed("entry \(path) is not UTF-8")
    }
    return value
}

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

func barChart() -> OfficePresentationChart {
    OfficePresentationChart(
        chartType: .bar,
        title: "Revenue",
        categories: ["Alpha", "Beta", "Gamma"],
        series: [
            .init(name: "2025", values: [12, 24, 18]),
            .init(name: "2026", values: [15, 30, 27])
        ]
    )
}

func richDeck(at url: URL) throws {
    let slides: [OfficePresentationSlide] = [
        OfficePresentationSlide(
            title: "Rich deck",
            bullets: ["First", "Second"],
            notes: "[Sources] https://example.com",
            objects: [
                .init(kind: .shape, name: "Accent", layout: .left, shape: .ellipse, fillColor: "#2563EB"),
                .init(
                    kind: .text, name: "Callout", layout: .right,
                    text: ["Editable text box", "第二段"], fillColor: "#F1F5F9", fontSize: 20, bold: true
                ),
                .init(kind: .image, name: "Logo", x: 685800, y: 457200, width: 914400, height: 914400, imageBase64: tinyPNG.base64EncodedString()),
                .init(kind: .image, name: "Logo copy", x: 1800000, y: 457200, width: 914400, height: 914400, imageBase64: tinyPNG.base64EncodedString()),
                .init(kind: .chart, name: "Bar chart", x: 685800, y: 1600200, width: 5029200, height: 4114800, chart: barChart())
            ]
        ),
        OfficePresentationSlide(
            title: "More charts",
            bullets: [],
            objects: [
                .init(kind: .chart, name: "Line chart", layout: .right, chart: .init(
                    chartType: .line,
                    categories: ["Q1", "Q2", "Q3"],
                    series: [.init(name: "Growth", values: [1.5, 2.25, 3.75])]
                )),
                .init(kind: .chart, name: "Pie chart", layout: .left, chart: .init(
                    chartType: .pie,
                    categories: ["A", "B", "C"],
                    series: [.init(name: "Share", values: [50, 30, 20])]
                ))
            ]
        )
    ]
    try OfficeDocumentBuilder.createPresentation(at: url, title: "Fallback", slides: slides)
}

func run() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 1. Backwards-compatible deck without objects.
    let basic = root.appendingPathComponent("basic.pptx")
    try OfficeDocumentBuilder.createPresentation(
        at: basic,
        title: "Basic",
        slides: [.init(title: "Opening", bullets: ["One"], notes: "notes")]
    )
    let basicSnapshot = try OfficeDocumentService.inspect(url: basic)
    try check("basic deck inspects as pptx", basicSnapshot.kind == .presentation)
    try check("basic deck keeps title/bullet/notes text", ["Opening", "One", "notes"].allSatisfy { basicSnapshot.fields.map(\.text).contains($0) })
    try check("basic deck passes strict save validation", (try? OfficeNativeSaveValidation.validate(basic)) != nil)

    // 2. Rich deck with objects, images and editable charts.
    let rich = root.appendingPathComponent("rich.pptx")
    try richDeck(at: rich)
    if let evidence = ProcessInfo.processInfo.environment["FLOE_PPT_EVIDENCE"], !evidence.isEmpty {
        let directory = URL(fileURLWithPath: evidence, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("rich-deck.pptx")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: rich, to: destination)
        print("EVIDENCE copied rich deck to \(destination.path)")
    }
    let richSnapshot = try OfficeDocumentService.inspect(url: rich)
    try check("rich deck inspects", richSnapshot.kind == .presentation)
    try check("rich deck exposes text box text", richSnapshot.fields.map(\.text).contains("Editable text box"))
    try check("rich deck exposes second paragraph", richSnapshot.fields.map(\.text).contains("第二段"))
    try check("rich deck passes strict save validation", (try? OfficeNativeSaveValidation.validate(rich)) != nil)

    let paths = try entryPaths(rich)
    try check("rich deck has media image part", paths.contains("ppt/media/image1.png"), "entries: \(paths.filter { $0.hasPrefix("ppt/media") })")
    try check("rich deck deduplicates identical images", !paths.contains("ppt/media/image2.png"))
    let media = try readEntry(rich, "ppt/media/image1.png")
    try check("media bytes are the supplied PNG", media == tinyPNG)

    let slide1 = try text(rich, "ppt/slides/slide1.xml")
    try check("slide contains picture element", slide1.contains("<p:pic>"))
    try check("slide contains graphic frame", slide1.contains("<p:graphicFrame>"))
    try check("slide contains preset shape geometry", slide1.contains(#"prst="ellipse""#))
    try check("slide contains two image blips", slide1.components(separatedBy: "<a:blip r:embed=").count == 3)
    let slide1Rels = try text(rich, "ppt/slides/_rels/slide1.xml.rels")
    try check("slide has image relationship", slide1Rels.contains(#"Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image""#))
    try check("slide has chart relationship", slide1Rels.contains(#"Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart""#))
    let imageRelationshipCount = slide1Rels.components(separatedBy: "relationships/image").count - 1
    try check("duplicate images reuse one slide relationship", imageRelationshipCount == 1, "\(imageRelationshipCount)")
    let blipEmbeds = slide1.components(separatedBy: "<a:blip r:embed=\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
    try check("both picture shapes reference one relationship", Set(blipEmbeds).count == 1 && blipEmbeds.count == 2, "\(blipEmbeds)")

    let chartPaths = paths.filter { $0.hasPrefix("ppt/charts/") && $0.hasSuffix(".xml") }
    try check("rich deck has three chart parts", chartPaths.count == 3, "\(chartPaths)")
    var checkedFormulas = 0
    for chartPath in chartPaths {
        let chart = try text(rich, chartPath)
        try check("\(chartPath) has externalData", chart.contains("<c:externalData r:id=\"rId1\">"))
        try check("\(chartPath) has number references", chart.contains("<c:numRef>"))
        let formulas = chart.components(separatedBy: "<c:f>").dropFirst().compactMap { $0.components(separatedBy: "</c:f>").first }
        for formula in formulas {
            checkedFormulas += 1
            try check("\(chartPath) formula is an Excel range: \(formula)", formula.hasPrefix("Sheet1!$") && Double(formula) == nil && !formula.hasPrefix("label "))
        }
        let rels = try text(rich, "ppt/charts/_rels/\(chartPath.split(separator: "/").last!).rels")
        try check("\(chartPath) relationship is a package to embeddings", rels.contains("relationships/package") && rels.contains("Target=\"../embeddings/floe-chart-data-"))
    }
    try check("formula count is non-trivial", checkedFormulas >= 12, "\(checkedFormulas)")

    let embeddingPaths = paths.filter { $0.hasPrefix("ppt/embeddings/") && $0.hasSuffix(".xlsx") }
    try check("rich deck has three embedded workbooks", embeddingPaths.count == 3, "\(embeddingPaths)")
    // Expected workbook content per chart: bar (12/24, Alpha/Gamma), line
    // (1.5/2.25, Q1/Q3), pie (50/30, A/C).
    let expectedWorkbookContent: [(values: [String], labels: [String])] = [
        (["<v>12</v>", "<v>24</v>"], ["Alpha", "Gamma"]),
        (["<v>1.5</v>", "<v>2.25</v>"], ["Q1", "Q3"]),
        (["<v>50</v>", "<v>30</v>"], ["A", "C"])
    ]
    for (index, path) in embeddingPaths.enumerated() {
        let data = try readEntry(rich, path)
        try check("\(path) is non-empty", data.count > 0)
        let archive = try Archive(data: data, accessMode: .read)
        try check("\(path) contains xl/workbook.xml", archive["xl/workbook.xml"] != nil)
        if let sheetEntry = archive["xl/worksheets/sheet1.xml"] {
            var sheetData = Data()
            _ = try archive.extract(sheetEntry) { sheetData.append($0) }
            let sheet = String(decoding: sheetData, as: UTF8.self)
            let expected = expectedWorkbookContent[index]
            try check("\(path) stores the numeric series values", expected.values.allSatisfy { sheet.contains($0) })
            try check("\(path) stores category labels", expected.labels.allSatisfy { sheet.contains($0) })
        } else {
            try check("\(path) contains xl/worksheets/sheet1.xml", false)
        }
    }

    // Every XML part must parse as well-formed before any consumer sees it.
    var malformed: [String] = []
    for path in paths where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
        let data = try readEntry(rich, path)
        let parser = XMLParser(data: data)
        if !parser.parse() { malformed.append(path) }
    }
    try check("all rich deck XML parts are well-formed", malformed.isEmpty, "\(malformed)")

    let contentTypes = try text(rich, "[Content_Types].xml")
    try check("content types declare chart override", contentTypes.contains("drawingml.chart+xml"))
    try check("content types declare png default", contentTypes.contains(#"Extension="png""#))
    try check("content types declare xlsx default", contentTypes.contains(#"Extension="xlsx""#))

    // 3. Strict validation still rejects a chart that lost its workbook references.
    let broken = root.appendingPathComponent("broken.pptx")
    try FileManager.default.copyItem(at: rich, to: broken)
    var replacements: [String: Data] = [:]
    let originalChart = try text(broken, "ppt/charts/chart1.xml")
    let brokenChart = originalChart
        .replacingOccurrences(of: "Sheet1!$A$2:$A$4", with: "label 0")
        .replacingOccurrences(of: "<c:externalData r:id=\"rId1\">", with: "")
    replacements["ppt/charts/chart1.xml"] = Data(brokenChart.utf8)
    let brokenArchive = try Archive(url: broken, accessMode: .read)
    let output = try Archive(url: root.appendingPathComponent("broken-out.pptx"), accessMode: .create)
    for entry in brokenArchive where entry.type == .file {
        let data: Data
        if let replacement = replacements[entry.path] { data = replacement }
        else {
            var current = Data()
            _ = try brokenArchive.extract(entry) { current.append($0) }
            data = current
        }
        try output.addFloeEntry(path: entry.path, data: data)
    }
    try check("strict validation rejects a chart with a lost workbook", (try? OfficeNativeSaveValidation.validate(root.appendingPathComponent("broken-out.pptx"))) == nil)

    // 4. DOCX title mapping and core properties.
    let docx = root.appendingPathComponent("brief.docx")
    try OfficeDocumentBuilder.createWord(at: docx, title: "Launch brief", paragraphs: ["First paragraph"])
    let word = try OfficeDocumentService.inspect(url: docx)
    try check("word title field is labelled Title", word.fields.first(where: { $0.label == "Title" })?.text == "Launch brief")
    let core = try text(docx, "docProps/core.xml")
    try check("word core properties carry the title", core.contains("<dc:title>Launch brief</dc:title>"))
    if let titleField = word.fields.first(where: { $0.label == "Title" }) {
        let updated = try OfficeDocumentService.update(sourceURL: docx, updates: [titleField.id: "Renamed"], expectedSHA256: word.sha256)
        try check("word title stays editable through updateText", updated.fields.contains(where: { $0.label == "Title" && $0.text == "Renamed" }))
    } else {
        try check("word title field exists for update", false)
    }

    // 5. Bounds and unsafe content fail closed.
    let mismatch = root.appendingPathComponent("mismatch.pptx")
    var mismatchThrown = false
    do {
        try OfficeDocumentBuilder.createPresentation(at: mismatch, title: "Bad", slides: [.init(title: "Bad", objects: [
            .init(kind: .chart, chart: .init(chartType: .bar, categories: ["A", "B"], series: [.init(name: "S", values: [1])]))
        ])])
    } catch { mismatchThrown = true }
    try check("chart with mismatched values fails closed", mismatchThrown)

    let unsafe = root.appendingPathComponent("unsafe.pptx")
    var unsafeThrown = false
    do {
        try OfficeDocumentBuilder.createPresentation(at: unsafe, title: "Bad", slides: [.init(title: "Bad", objects: [
            .init(kind: .image, x: 0, y: 0, width: 914400, height: 914400, imageBase64: Data("<svg/>".utf8).base64EncodedString())
        ])])
    } catch { unsafeThrown = true }
    try check("non PNG/JPEG/GIF image fails closed", unsafeThrown)

    let outside = root.appendingPathComponent("outside.pptx")
    var outsideThrown = false
    do {
        try OfficeDocumentBuilder.createPresentation(at: outside, title: "Bad", slides: [.init(title: "Bad", objects: [
            .init(kind: .text, x: 12_000_000, y: 0, width: 914_400, height: 914_400, text: ["too far"])
        ])])
    } catch { outsideThrown = true }
    try check("object outside the canvas fails closed", outsideThrown)

    // 6. Round-trip edit preserves chart and media parts byte-for-byte.
    let editable = root.appendingPathComponent("editable.pptx")
    try richDeck(at: editable)
    let before = try OfficeDocumentService.inspect(url: editable)
    guard let bulletField = before.fields.first(where: { $0.text == "First" }) else {
        throw CheckFailure.failed("no editable bullet field in rich deck")
    }
    let chartBefore = try readEntry(editable, "ppt/charts/chart1.xml")
    let imageBefore = try readEntry(editable, "ppt/media/image1.png")
    _ = try OfficeDocumentService.update(sourceURL: editable, updates: [bulletField.id: "First edited"], expectedSHA256: before.sha256)
    let chartAfter = try readEntry(editable, "ppt/charts/chart1.xml")
    let imageAfter = try readEntry(editable, "ppt/media/image1.png")
    try check("text update preserves chart part", chartBefore == chartAfter)
    try check("text update preserves media part", imageBefore == imageAfter)
    try check("edited deck still passes strict validation", (try? OfficeNativeSaveValidation.validate(editable)) != nil)

    // 7. Tool schema compatibility and tool-level execution (no paid calls, local only).
    let schemaData = Data(PresentationCreateDeckTool.parametersJSON.utf8)
    let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
    try check("createDeck parameter schema is valid JSON", schema != nil && schema?["required"] as? [String] == ["path", "title", "slides"])
    let wordSchema = try JSONSerialization.jsonObject(with: Data(DocumentCreateWordTool.parametersJSON.utf8)) as? [String: Any]
    try check("createWord parameter schema is valid JSON", wordSchema != nil)

    let legacyJSON = Data(#"{"path":"a.pptx","title":"T","slides":[{"title":"S","bullets":["b"]}]}"#.utf8)
    let legacyArgs = try JSONDecoder().decode(PresentationCreateDeckTool.Arguments.self, from: legacyJSON)
    try check("legacy slide JSON still decodes without objects", legacyArgs.slides.count == 1 && legacyArgs.slides[0].objects == nil)

    let richJSON = Data(#"{"path":"rich.pptx","title":"T","slides":[{"title":"S","bullets":[],"objects":[{"kind":"image","imagePath":"logo.png","layout":"center"},{"kind":"chart","layout":"right","chart":{"chartType":"bar","categories":["A","B"],"series":[{"name":"S","values":[1,2]}]}}]}]}"#.utf8)
    let richArgs = try JSONDecoder().decode(PresentationCreateDeckTool.Arguments.self, from: richJSON)
    try check("rich slide JSON decodes objects", richArgs.slides[0].objects?.count == 2)

    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try tinyPNG.write(to: workspace.appendingPathComponent("logo.png"))
    let context = ToolContext(runID: UUID(), workspaceRootURL: workspace, cancellation: CancellationToken())
    let deckOutput = try await PresentationCreateDeckTool(rootProvider: { workspace }).execute(richArgs, context: context)
    try check("createDeck tool reports image and chart counts", deckOutput.summary.contains("images=1") && deckOutput.summary.contains("charts=1"), deckOutput.summary)
    let deckURL = workspace.appendingPathComponent("rich.pptx")
    let deckPaths = try entryPaths(deckURL)
    try check("tool-created deck embeds the workspace image", deckPaths.contains("ppt/media/image1.png"))
    try check("tool-created deck embeds the chart workbook", deckPaths.contains("ppt/embeddings/floe-chart-data-1.xlsx"))
    try check("tool-created deck passes strict validation", (try? OfficeNativeSaveValidation.validate(deckURL)) != nil)

    let wordArgs = try JSONDecoder().decode(DocumentCreateWordTool.Arguments.self, from: Data(#"{"path":"w.docx","title":"T","paragraphs":["p"]}"#.utf8))
    let wordOutput = try await DocumentCreateWordTool(rootProvider: { workspace }).execute(wordArgs, context: context)
    try check("createWord reports no fillable fields and a mapped Title style", wordOutput.summary.contains("fillableFields=0") && wordOutput.summary.contains("titleStyle=Title"), wordOutput.summary)
    if !failed.isEmpty { throw CheckFailure.failed(failed.joined(separator: ", ")) }
}


@Suite("FloeDocuments.RichDeckStructure")
struct RichDeckChecksTests {
    /// Rich createDeck: objects, charts with embedded workbook, strict save
    /// validation acceptance/rejection and DOCX title/field mapping.
    @Test("rich createDeck, chart workbook and strict save validation")
    func richDeckStructure() async throws {
        try await run()
    }
}

//
//  CADDrawingBOMTableExportTests.swift
//  FloeCADKitTests
//
//  Focused E09/E17 output-completeness regression through the REAL document,
//  assembly and drawing services:
//
//  * nine distinct part definitions (including one shared definition with two
//    occurrences across nested subassemblies) produce exactly nine BOM rows;
//  * the complete CSV export is independent read back with an RFC 4180 parser:
//    every row, ID, item number, live quantity and engineering value survives
//    Chinese text, long strings, quotes, commas and embedded newlines;
//  * the vector sheet either carries all nine rows and all six columns across
//    SVG/PDF/DXF, or a sheet that cannot fit them refuses `bom_output_incomplete`
//    with actualRows/capacity/nextAction and no partial table;
//  * that refusal leaves the original drawing bytes untouched (no half
//    artifact), while the full CSV export still succeeds;
//  * removing the selected named exploded view blocks CSV and vector export
//    until undo restores it.
//
// This is source only for root to register/run. It does not construct a
// parallel CSV, BOM or file-commit path; it exercises `CADDrawingService`
// exportData and the same typed assembly/drawing commands the App uses.
//

import XCTest
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
@testable import FloeCAD

@MainActor
final class CADDrawingBOMTableExportTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADBOMTableExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("bom-table.floecad"), name: "BOM Table")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Real command fixtures

    @discardableResult
    private func run(_ json: String, file: StaticString = #filePath,
                     line: UInt = #line) -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(min: [Double] = [0, 0], max: [Double] = [10, 10],
                         height: Double = 10) throws -> UUID {
        let sketch = try XCTUnwrap(
            run(#"{"op":"sketch.create","args":{"name":"Box"}}"#)["sketchID"] as? String)
        _ = run("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],"max":[\(max[0]),\(max[1])]}]}}
        """)
        let response = run("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":\(height)}}
        """)
        let bodyID = try XCTUnwrap((response["producedBodyIDs"] as? [String])?.first
                                   ?? (response["changedBodyIDs"] as? [String])?.first)
        return try XCTUnwrap(UUID(uuidString: bodyID))
    }

    private func service() -> CADAssemblyService {
        CADAssemblyService(document: document)
    }

    private func addSubassembly(name: String, parentID: String? = nil) throws -> String {
        var args: [String: Any] = ["name": name]
        if let parentID { args["parentID"] = parentID }
        let reply = service().handle(action: "addSubassembly", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func addInstance(_ bodyID: UUID, name: String, parentID: String? = nil,
                             position: [Double]? = nil) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID.uuidString, "name": name]
        if let parentID { args["parentID"] = parentID }
        if let position { args["transform"] = ["position": position] }
        let reply = service().handle(action: "addInstance", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func setPartMetadata(_ instanceID: String, partNumber: String,
                                 material: String, version: String) {
        let reply = service().handle(action: "setPartMetadata", args: [
            "instanceID": instanceID,
            "partNumber": partNumber,
            "material": material,
            "version": version,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
    }

    private func renameBody(_ bodyID: UUID, to name: String) {
        // This is the same Items-panel rename command; it trims outer
        // whitespace only, so the embedded newline/quote/comma stay in the
        // stored body name and exercise RFC 4180 quoting end to end.
        document.viewModel().renameItem(.body(BodyID(raw: bodyID)), to: name)
    }

    private func assembly() throws -> CADAssembly {
        try CADAssembly.decode(from: document.session.document.assemblyData)
    }

    private func frontPageID(_ reply: [String: Any],
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "",
                       file: file, line: line)
        let pages = try XCTUnwrap(reply["pages"] as? [[String: Any]])
        return try XCTUnwrap(pages.first { $0["kind"] as? String == "front" }?["id"] as? String)
    }

    // MARK: - Fixture

    private struct ExpectedRow {
        let name: String
        let partNumber: String
        let material: String
        let version: String
        let quantity: Int
        /// Short, ASCII, unambiguously unique prefix that must survive vector
        /// cell shortening on an A3 sheet.
        let vectorPrefix: String
    }

    private struct Fixture {
        let pageID: String
        let pageUUID: UUID
        let viewID: String
        let viewName: String
        let bodies: [UUID]
        let expected: [String: ExpectedRow]
        let bomRows: [[String: Any]]
    }

    private static let longName =
        "超长零件名称-总成A\n第二行\"引号\",逗号-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let longPartNumber =
        "PN-LONG-0002-超长料号-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789"
    private static let longMaterial =
        "6061-T6 铝合金 \"阳极氧化\"\n第二行材料说明"
    private static let longVersion =
        "=REV(\"D\",4),中文版本"
    private static let viewName = "BOM Export View"

    private static let expectedCSVHeader: [String] = [
        "sheet", "pageID", "viewName", "viewID", "pageRevision", "liveRevision",
        "bomItemID", "itemNumber", "partDefinitionID", "name", "partNumber",
        "material", "version", "quantity", "instanceIDs", "liveInstanceIDs",
        "stale", "missingInstanceIDs", "capturedQuantity", "capturedPartNumber",
        "capturedMaterial", "capturedVersion", "metadataChanged", "missingBody",
    ]

    private func makeNineRowFixture() throws -> Fixture {
        // Nine distinct bodies: one shared definition has two occurrences
        // (across two subassemblies), the other eight are distinct. The BOM
        // therefore has nine rows and ten placed part instances.
        let bodies = try (0..<9).map { index in
            try makeBox(min: [Double(index) * 15, 0],
                        max: [Double(index) * 15 + 10, 10], height: 10)
        }
        let upper = try addSubassembly(name: "Upper")
        let lower = try addSubassembly(name: "Lower")
        var instanceIDs: [String] = []
        instanceIDs.append(try addInstance(bodies[0], name: "Shared upper",
                                           parentID: upper, position: [0, 0, 0]))
        instanceIDs.append(try addInstance(bodies[0], name: "Shared lower",
                                           parentID: lower, position: [0, 25, 0]))
        for index in 1..<5 {
            instanceIDs.append(try addInstance(
                bodies[index], name: "Upper part \(index)", parentID: upper,
                position: [Double(index) * 15, 0, 0]))
        }
        for index in 5..<9 {
            instanceIDs.append(try addInstance(
                bodies[index], name: "Lower part \(index)", parentID: lower,
                position: [Double(index) * 15, 25, 0]))
        }

        let bodyNames = [
            "共享零件", Self.longName, "长料号零件", "长材料零件", "公式版本零件",
            "零件5", "零件6", "零件7", "零件8",
        ]
        for (index, bodyID) in bodies.enumerated() {
            renameBody(bodyID, to: bodyNames[index])
        }

        // Shared definition: one record reached through either occurrence.
        setPartMetadata(instanceIDs[0], partNumber: "PN-0000,共享",
                        material: "钢\"45#\"\n调质", version: "A\"0")
        setPartMetadata(instanceIDs[2], partNumber: "PN-0001",
                        material: "铝", version: "A1")
        setPartMetadata(instanceIDs[3], partNumber: Self.longPartNumber,
                        material: "钛合金", version: "B2")
        setPartMetadata(instanceIDs[4], partNumber: "PN-0003",
                        material: Self.longMaterial, version: "C3")
        setPartMetadata(instanceIDs[5], partNumber: "PN-0004",
                        material: "铜", version: Self.longVersion)
        for index in 5..<9 {
            setPartMetadata(instanceIDs[index + 1], partNumber: "PN-000\(index)",
                            material: "材料\(index)", version: "V\(index)")
        }

        var expected: [String: ExpectedRow] = [:]
        expected[bodies[0].uuidString] = ExpectedRow(
            name: bodyNames[0], partNumber: "PN-0000,共享",
            material: "钢\"45#\"\n调质", version: "A\"0", quantity: 2,
            vectorPrefix: "PN-0000")
        expected[bodies[1].uuidString] = ExpectedRow(
            name: bodyNames[1], partNumber: "PN-0001", material: "铝",
            version: "A1", quantity: 1, vectorPrefix: "PN-0001")
        expected[bodies[2].uuidString] = ExpectedRow(
            name: bodyNames[2], partNumber: Self.longPartNumber,
            material: "钛合金", version: "B2", quantity: 1,
            vectorPrefix: "PN-LONG-0002")
        expected[bodies[3].uuidString] = ExpectedRow(
            name: bodyNames[3], partNumber: "PN-0003",
            material: Self.longMaterial, version: "C3", quantity: 1,
            vectorPrefix: "PN-0003")
        expected[bodies[4].uuidString] = ExpectedRow(
            name: bodyNames[4], partNumber: "PN-0004", material: "铜",
            version: Self.longVersion, quantity: 1, vectorPrefix: "PN-0004")
        for index in 5..<9 {
            expected[bodies[index].uuidString] = ExpectedRow(
                name: bodyNames[index], partNumber: "PN-000\(index)",
                material: "材料\(index)", version: "V\(index)", quantity: 1,
                vectorPrefix: "PN-000\(index)")
        }

        let entered = try assembly().occurrences(includeHidden: true)
            .filter { $0.isDrawablePart }
            .map { occurrence -> [String: Any] in
                ["instanceID": occurrence.instance.id.uuidString]
            }
        let viewReply = service().handle(action: "addExplodedView", args: [
            "name": Self.viewName,
            "direction": [1.0, 0.0, 0.0],
            "distanceMM": 25.0,
            "entries": entered,
        ])
        XCTAssertEqual(viewReply["ok"] as? Bool, true, viewReply["message"] as? String ?? "")
        let viewID = try XCTUnwrap(viewReply["id"] as? String)

        let drawing = CADDrawingService(document: document)
        let sheet = drawing.handle(action: "assemblySheet", args: [
            "title": "BOM Export", "explodedViewID": viewID,
        ])
        let pageID = try frontPageID(sheet)
        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        let bom = drawing.handle(action: "setBOM", args: [
            "pageID": pageID, "showBOM": true,
        ])
        XCTAssertEqual(bom["ok"] as? Bool, true, bom["message"] as? String ?? "")
        let rows = try XCTUnwrap(bom["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 9, "nine definitions must produce nine rows, not a capped eight")
        XCTAssertEqual(Set(rows.compactMap { $0["partDefinitionID"] as? String }).count, 9)

        return Fixture(pageID: pageID, pageUUID: pageUUID, viewID: viewID,
                       viewName: Self.viewName, bodies: bodies, expected: expected,
                       bomRows: rows)
    }

    // MARK: - RFC 4180 read-back (independent of the exporter)

    private func parseCSV(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r":
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                case "\n":
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }
        XCTAssertFalse(inQuotes, "unterminated CSV quote")
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func record(header: [String], row: [String]) -> [String: String] {
        guard row.count == header.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(header, row))
    }

    private func csvRecords(_ data: Data) throws -> [[String: String]] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let table = try parseCSV(text)
        let header = try XCTUnwrap(table.first)
        XCTAssertEqual(header, Self.expectedCSVHeader)
        return table.dropFirst().map { row in
            XCTAssertEqual(row.count, header.count, "every row must have the header's exact width")
            return record(header: header, row: row)
        }
    }

    private func svgLayerTexts(_ svg: String, layer: String) -> [String] {
        guard let start = svg.range(of: "<g id=\"\(layer)\"") else { return [] }
        let tail = svg[start.lowerBound...]
        guard let end = tail.range(of: "</g>") else { return [] }
        let body = String(tail[..<end.upperBound])
        let pattern = #"<text[^>]*>([^<]*)</text>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[valueRange])
        }
    }

    private func dxfBOMTexts(_ dxf: String) -> [String] {
        let lines = dxf.components(separatedBy: "\n")
        var pairs: [(String, String)] = []
        var index = 0
        while index + 1 < lines.count {
            pairs.append((lines[index], lines[index + 1]))
            index += 2
        }
        var result: [String] = []
        for start in pairs.indices where pairs[start].0 == "0" && pairs[start].1 == "TEXT" {
            var layer = ""
            var value = ""
            var cursor = start + 1
            while cursor < pairs.count, pairs[cursor].0 != "0" {
                if pairs[cursor].0 == "8" { layer = pairs[cursor].1 }
                if pairs[cursor].0 == "1" { value = pairs[cursor].1 }
                cursor += 1
            }
            if layer == "BOM" { result.append(value) }
        }
        return result
    }

    private func pdfText(_ data: Data) throws -> String {
#if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            XCTFail("PDFKit could not open the exported PDF")
            return ""
        }
        return document.string ?? ""
#else
        throw XCTSkip("PDFKit is unavailable on this test host")
#endif
    }

    private func assertVectorCoverage(_ texts: [String], fixture: Fixture,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let joined = texts.joined(separator: "\n")
        for header in ["Part no.", "Material", "Rev", "Qty"] {
            XCTAssertTrue(joined.contains(header), "missing vector column \(header)",
                          file: file, line: line)
        }
        for bodyID in fixture.bodies {
            guard let expected = fixture.expected[bodyID.uuidString] else {
                XCTFail("fixture is missing expected row \(bodyID.uuidString)",
                        file: file, line: line)
                continue
            }
            XCTAssertTrue(joined.contains(expected.vectorPrefix),
                          "vector BOM is missing row \(bodyID.uuidString) prefix",
                          file: file, line: line)
        }
    }

    // MARK: - Complete CSV

    func testCompleteCSVExportsAllNineRowsWithExactEngineeringText() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        let data = try drawing.exportData(pageID: fixture.pageUUID, format: "csv")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\r\n"), "RFC 4180 rows end with CRLF")
        XCTAssertFalse(text.hasPrefix("\u{FEFF}"), "the table is exact UTF-8 without a hidden BOM")

        let records = try csvRecords(data)
        XCTAssertEqual(records.count, 9, "the full table must contain every BOM row")
        var seen = Set<String>()
        for record in records {
            let definitionID = try XCTUnwrap(record["partDefinitionID"])
            let expected = try XCTUnwrap(fixture.expected[definitionID])
            seen.insert(definitionID)
            XCTAssertEqual(record["sheet"], "Front")
            XCTAssertEqual(record["pageID"], fixture.pageID)
            XCTAssertEqual(record["viewName"], fixture.viewName)
            XCTAssertEqual(record["viewID"], fixture.viewID)
            XCTAssertNotNil(Int(record["liveRevision"] ?? ""),
                            "each row is correlated with a live revision")
            let expectedRow = try XCTUnwrap(fixture.bomRows.first {
                ($0["partDefinitionID"] as? String) == definitionID
            })
            XCTAssertEqual(record["bomItemID"], expectedRow["id"] as? String)
            let expectedItemNumber = try XCTUnwrap(expectedRow["itemNumber"] as? Int)
            XCTAssertEqual(record["itemNumber"], String(expectedItemNumber))
            XCTAssertEqual(record["instanceIDs"],
                           (expectedRow["instanceIDs"] as? [String] ?? [])
                               .joined(separator: ";"))
            XCTAssertEqual(record["liveInstanceIDs"],
                           (expectedRow["liveInstanceIDs"] as? [String] ?? [])
                               .joined(separator: ";"))
            XCTAssertEqual(record["name"], expected.name)
            XCTAssertEqual(record["partNumber"], expected.partNumber)
            XCTAssertEqual(record["material"], expected.material)
            XCTAssertEqual(record["version"], expected.version)
            XCTAssertEqual(Int(record["quantity"] ?? "") ?? -1, expected.quantity)
            XCTAssertEqual(record["capturedQuantity"], record["quantity"])
            XCTAssertEqual(record["capturedPartNumber"], expected.partNumber)
            XCTAssertEqual(record["stale"], "false")
            XCTAssertEqual(record["metadataChanged"], "false")
            XCTAssertEqual(record["missingBody"], "false")
            XCTAssertEqual((record["itemNumber"]?.isEmpty ?? true), false)
        }
        XCTAssertEqual(seen, Set(fixture.expected.keys))
        XCTAssertEqual(Set(records.compactMap { Int($0["itemNumber"] ?? "") }),
                       Set(1...9))

        let shared = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[0].uuidString
        })
        XCTAssertEqual(shared["quantity"], "2")
        XCTAssertEqual(shared["instanceIDs"]?.split(separator: ";").count ?? 0, 2)
        XCTAssertEqual(shared["liveInstanceIDs"]?.split(separator: ";").count ?? 0, 2)

        let longNameRow = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[1].uuidString
        })
        XCTAssertEqual(longNameRow["name"], Self.longName)
        XCTAssertTrue(longNameRow["name"]?.contains("\n") == true)
        XCTAssertTrue(longNameRow["name"]?.contains("\"") == true)

        let longPartRow = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[2].uuidString
        })
        XCTAssertEqual(longPartRow["partNumber"], Self.longPartNumber)

        let longMaterialRow = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[3].uuidString
        })
        XCTAssertEqual(longMaterialRow["material"], Self.longMaterial)
        XCTAssertTrue(longMaterialRow["material"]?.contains("\n") == true)

        let formulaRow = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[4].uuidString
        })
        XCTAssertEqual(formulaRow["version"], Self.longVersion,
                       "formula-looking text is preserved literally in CSV")

        // The whole artifact stays UTF-8, not a lossy printable-ASCII table.
        XCTAssertTrue(text.contains(Self.longName))
        XCTAssertTrue(text.contains(Self.longMaterial))
    }

    // MARK: - Vector coverage

    func testVectorBOMIncludesAllNineRowsAcrossSVGPDFDXF() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        let geometry = drawing.pageGeometry(pageID: fixture.pageUUID)
        XCTAssertEqual(geometry["ok"] as? Bool, true, geometry["message"] as? String ?? "")
        let bom = try XCTUnwrap(geometry["bom"] as? [String: Any])
        let output = try XCTUnwrap(bom["bomOutput"] as? [String: Any])
        XCTAssertEqual(output["totalRows"] as? Int, 9)
        XCTAssertEqual(output["vectorComplete"] as? Bool, true)
        XCTAssertEqual(output["requiredColumnsFit"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(output["capacity"] as? Int ?? 0, 9)
        let previewTexts = (geometry["texts"] as? [[String: Any]] ?? [])
            .filter { $0["layer"] as? String == "bom" }
            .compactMap { $0["text"] as? String }
        assertVectorCoverage(previewTexts, fixture: fixture)

        let svg = try drawing.exportData(pageID: fixture.pageUUID, format: "svg")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let svgTexts = svgLayerTexts(svgText, layer: "BOM_TEXT")
        assertVectorCoverage(svgTexts, fixture: fixture)

        let dxf = try drawing.exportData(pageID: fixture.pageUUID, format: "dxf")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        assertVectorCoverage(dxfBOMTexts(dxfText), fixture: fixture)

        let pdf = try drawing.exportData(pageID: fixture.pageUUID, format: "pdf")
        let pdfContent = try pdfText(pdf)
        assertVectorCoverage([pdfContent], fixture: fixture)
    }

    // MARK: - Honest overflow + full-table fallback

    func testSmallSheetBOMFailsClosedWhileCompleteCSVRemainsAvailable() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        let resized = drawing.handle(action: "updatePage", args: [
            "pageID": fixture.pageID,
            "paper": "custom",
            "customWidthMM": 120.0,
            "customHeightMM": 80.0,
        ])
        XCTAssertEqual(resized["ok"] as? Bool, true, resized["message"] as? String ?? "")

        let beforeBytes = document.session.document.drawingsData
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: workDir.path).sorted()
        let geometry = drawing.pageGeometry(pageID: fixture.pageUUID)
        let bom = try XCTUnwrap(geometry["bom"] as? [String: Any])
        XCTAssertEqual(bom["entryCount"] as? Int, 9)
        let output = try XCTUnwrap(bom["bomOutput"] as? [String: Any])
        XCTAssertEqual(output["totalRows"] as? Int, 9)
        XCTAssertEqual(output["vectorComplete"] as? Bool, false)
        XCTAssertEqual(output["capacity"] as? Int, 6)
        XCTAssertEqual(output["previewRows"] as? Int, 4)
        XCTAssertEqual(output["requiredColumnsFit"] as? Bool, true)
        let previewTexts = (geometry["texts"] as? [[String: Any]] ?? [])
            .filter { $0["layer"] as? String == "bom" }
            .compactMap { $0["text"] as? String }
        let previewJoined = previewTexts.joined(separator: "\n")
        XCTAssertTrue(previewJoined.contains("of 9"), "preview shows total/continuation")
        XCTAssertTrue(previewJoined.contains("CSV: full table"))

        for format in ["svg", "pdf", "dxf"] {
            XCTAssertThrowsError(try drawing.exportData(pageID: fixture.pageUUID,
                                                         format: format)) { error in
                guard let cadError = error as? CADDocumentError else {
                    XCTFail("expected CADDocumentError for \(format), got \(error)")
                    return
                }
                XCTAssertEqual(cadError.code, "bom_output_incomplete")
                XCTAssertEqual(cadError.details["actualRows"], "9")
                XCTAssertEqual(cadError.details["capacity"], "6")
                XCTAssertEqual(cadError.details["requiredColumns"], "6")
                XCTAssertEqual(cadError.details["fullTableFormat"], "csv")
                XCTAssertTrue(cadError.details["nextAction"]?.contains("format=csv") == true)
            }
        }

        // Refusal is before any artifact promotion and does not rewrite the
        // drawing set. (The App's nativeExport only calls createBinaryFile
        // after exportData succeeds; this service-level assertion proves the
        // failed path produced no bytes and no mutation.)
        XCTAssertEqual(document.session.document.drawingsData, beforeBytes)
        let afterFiles = try FileManager.default.contentsOfDirectory(atPath: workDir.path).sorted()
        XCTAssertEqual(afterFiles, beforeFiles, "no half artifact and no temporary output")

        let csv = try drawing.exportData(pageID: fixture.pageUUID, format: "csv")
        let records = try csvRecords(csv)
        XCTAssertEqual(records.count, 9, "the CSV fallback still carries every row")
        let shared = try XCTUnwrap(records.first {
            $0["partDefinitionID"] == fixture.bodies[0].uuidString
        })
        XCTAssertEqual(shared["material"], fixture.expected[fixture.bodies[0].uuidString]?.material)

        // Restoring an A3-sized sheet restores complete vector output; the
        // failure was a supported bound, not a permanent export ban.
        let restored = drawing.handle(action: "updatePage", args: [
            "pageID": fixture.pageID,
            "paper": "custom",
            "customWidthMM": 297.0,
            "customHeightMM": 420.0,
        ])
        XCTAssertEqual(restored["ok"] as? Bool, true, restored["message"] as? String ?? "")
        let svg = try drawing.exportData(pageID: fixture.pageUUID, format: "svg")
        let svgTexts = svgLayerTexts(try XCTUnwrap(String(data: svg, encoding: .utf8)),
                                     layer: "BOM_TEXT")
        XCTAssertTrue(svgTexts.joined(separator: "\n").contains("PN-0008"))
    }

    // MARK: - Missing named view

    func testMissingNamedViewBlocksCSVAndVectorUntilUndo() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        XCTAssertNoThrow(try drawing.exportData(pageID: fixture.pageUUID, format: "csv"))

        let removed = service().handle(action: "removeExplodedView", args: ["id": fixture.viewID])
        XCTAssertEqual(removed["ok"] as? Bool, true, removed["message"] as? String ?? "")
        let missing = drawing.pageGeometry(pageID: fixture.pageUUID)
        XCTAssertEqual(missing["missingExplodedView"] as? Bool, true)
        XCTAssertEqual(missing["outputBlocked"] as? Bool, true)
        for format in ["csv", "svg", "pdf", "dxf"] {
            XCTAssertThrowsError(try drawing.exportData(pageID: fixture.pageUUID,
                                                         format: format)) { error in
                XCTAssertEqual((error as? CADDocumentError)?.code, "missing_exploded_view",
                               "\(format) must refuse before touching a stale page")
            }
        }

        document.session.undo()
        XCTAssertEqual((drawing.pageGeometry(pageID: fixture.pageUUID))["missingExplodedView"]
            as? Bool, false)
        let csv = try drawing.exportData(pageID: fixture.pageUUID, format: "csv")
        let records = try csvRecords(csv)
        XCTAssertEqual(records.count, 9)
    }
}

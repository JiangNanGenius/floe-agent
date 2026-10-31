//
//  CADDrawingBOMTableExportTests.swift
//  FloeCADKitTests
//
//  Focused E09/E17 output-completeness regression through the REAL document,
//  assembly and drawing services:
//
//  * nine distinct part definitions (including one shared definition with two
//    occurrences across nested subassemblies) produce exactly nine BOM rows;
//  * the complete CSV export is independently read back with a byte-level
//    RFC 4180 parser: every row, ID, item number, live quantity and engineering
//    value survives Chinese text, long strings, quotes, commas and embedded
//    CRLF/LF newlines;
//  * the real production CSV and representative SVG/PDF/DXF bytes are attached
//    to the .xcresult before the temporary fixture is deleted;
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
import CoreGraphics
import CoreText
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

    // Deliberately mix precomposed and combining Latin, Han, quotes, a
    // surrogate-pair flag, a ZWJ family emoji and a variation-selector flag.
    // A UTF-16 or Character-count truncator can split these sequences; the
    // vector fitter must return whole graphemes plus one ellipsis.
    private static let graphemeName =
        "e\u{301}👩🏽‍👩🏽‍👧🏽‍👧🏽超长零件名称-总成A \"引号\",逗号-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let graphemePartNumber =
        "PN-🇦🇺-e\u{301}-超长料号-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let graphemeMaterial =
        "材料-e\u{301}-🏳️‍🌈 \"阳极氧化\" 6061-T6-0123456789"
    private static let graphemeVersion =
        "=REV(\"D\",4)-中文-e\u{301}-👩🏽‍👩🏽‍👧🏽‍👧🏽"

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

    private struct GraphemeFixture {
        let pageID: String
        let pageUUID: UUID
        let name: String
        let partNumber: String
        let material: String
        let version: String
    }

    private func makeGraphemeFixture() throws -> GraphemeFixture {
        let body = try makeBox()
        let instance = try addInstance(body, name: "Grapheme part")
        renameBody(body, to: Self.graphemeName)
        setPartMetadata(instance, partNumber: Self.graphemePartNumber,
                        material: Self.graphemeMaterial, version: Self.graphemeVersion)
        let entered = try assembly().occurrences(includeHidden: true)
            .filter { $0.isDrawablePart }
            .map { occurrence -> [String: Any] in
                ["instanceID": occurrence.instance.id.uuidString]
            }
        let viewReply = service().handle(action: "addExplodedView", args: [
            "name": "Grapheme BOM View",
            "direction": [1.0, 0.0, 0.0],
            "distanceMM": 25.0,
            "entries": entered,
        ])
        XCTAssertEqual(viewReply["ok"] as? Bool, true, viewReply["message"] as? String ?? "")
        let viewID = try XCTUnwrap(viewReply["id"] as? String)
        let drawing = CADDrawingService(document: document)
        let sheet = drawing.handle(action: "assemblySheet", args: [
            "title": "Grapheme BOM", "explodedViewID": viewID,
        ])
        let pageID = try frontPageID(sheet)
        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        let bom = drawing.handle(action: "setBOM", args: [
            "pageID": pageID, "showBOM": true,
        ])
        XCTAssertEqual(bom["ok"] as? Bool, true, bom["message"] as? String ?? "")
        let rows = try XCTUnwrap(bom["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["name"] as? String, Self.graphemeName)
        XCTAssertEqual(row["partNumber"] as? String, Self.graphemePartNumber)
        XCTAssertEqual(row["material"] as? String, Self.graphemeMaterial)
        XCTAssertEqual(row["version"] as? String, Self.graphemeVersion)
        return GraphemeFixture(pageID: pageID, pageUUID: pageUUID,
                               name: Self.graphemeName,
                               partNumber: Self.graphemePartNumber,
                               material: Self.graphemeMaterial,
                               version: Self.graphemeVersion)
    }

    // MARK: - RFC 4180 read-back (independent of the exporter)

    /// Independent RFC 4180 reader over UTF-8 bytes. Swift's `Character`
    /// treats a CRLF pair as one extended grapheme cluster, so a
    /// character-based reader sees neither "\r" nor "\n"; the byte reader
    /// keeps CRLF record separators and CRLF inside quoted fields distinct.
    private enum CSVReadbackError: Error, CustomStringConvertible {
        case unterminatedQuote(offset: Int)
        case unexpectedQuote(offset: Int)
        case unexpectedByteAfterQuote(offset: Int)
        case invalidUTF8(offset: Int)

        var description: String {
            switch self {
            case let .unterminatedQuote(offset):
                return "unterminated CSV quote at byte \(offset)"
            case let .unexpectedQuote(offset):
                return "quote inside an unquoted CSV field at byte \(offset)"
            case let .unexpectedByteAfterQuote(offset):
                return "unexpected byte after a closing CSV quote at byte \(offset)"
            case let .invalidUTF8(offset):
                return "field starting at byte \(offset) is not valid UTF-8"
            }
        }
    }

    private func parseCSV(_ text: String) throws -> [[String]] {
        let bytes = Array(text.utf8)
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var fieldStart = 0
        var index = 0
        var inQuotes = false
        var afterClosingQuote = false

        func finishField() throws {
            guard let value = String(bytes: field, encoding: .utf8) else {
                throw CSVReadbackError.invalidUTF8(offset: fieldStart)
            }
            row.append(value)
            field.removeAll(keepingCapacity: true)
            afterClosingQuote = false
        }

        func finishRecord() throws {
            try finishField()
            rows.append(row)
            row = []
            fieldStart = index
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == 0x22 {
                    // A doubled quote is one literal quote; a lone quote closes
                    // the field and must be followed by a delimiter or record end.
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    afterClosingQuote = true
                    index += 1
                    continue
                }
                // Preserve CR/LF and every other byte inside the quoted field.
                field.append(byte)
                index += 1
                continue
            }
            if afterClosingQuote {
                switch byte {
                case 0x2C: // comma
                    try finishField()
                    index += 1
                    fieldStart = index
                case 0x0D: // CR or CRLF
                    if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                        index += 1
                    }
                    try finishRecord()
                    index += 1
                case 0x0A: // LF
                    try finishRecord()
                    index += 1
                default:
                    throw CSVReadbackError.unexpectedByteAfterQuote(offset: index)
                }
                continue
            }
            switch byte {
            case 0x22: // opening quote
                guard field.isEmpty else {
                    throw CSVReadbackError.unexpectedQuote(offset: index)
                }
                inQuotes = true
                fieldStart = index
                index += 1
            case 0x2C: // comma
                try finishField()
                index += 1
                fieldStart = index
            case 0x0D: // CR or CRLF
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
                try finishRecord()
                index += 1
            case 0x0A: // LF
                try finishRecord()
                index += 1
            default:
                field.append(byte)
                index += 1
            }
        }
        if inQuotes {
            throw CSVReadbackError.unterminatedQuote(offset: fieldStart)
        }
        if afterClosingQuote || !field.isEmpty || !row.isEmpty {
            try finishField()
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

    /// Keep real production export bytes in the .xcresult for root's
    /// independent viewer/reader. Attachments are made before tearDown deletes
    /// the temporary document directory.
    private func attach(_ data: Data, name: String,
                        uniformTypeIdentifier: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(data.isEmpty, "attachment \(name) must contain real export bytes",
                       file: file, line: line)
        let attachment = XCTAttachment(data: data,
                                       uniformTypeIdentifier: uniformTypeIdentifier)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTFail("PDFKit is unavailable on this test host; PDF coverage cannot be skipped")
        return ""
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

    // MARK: - Independent vector geometry probes

    private struct BOMVectorCell {
        let x: Double
        let y: Double
        let height: Double
        let text: String
    }

    private struct BOMVectorTable {
        let verticals: [Double]
        let minPoint: SIMD2<Double>
        let maxPoint: SIMD2<Double>
    }

    private struct BOMVectorLine {
        let a: SIMD2<Double>
        let b: SIMD2<Double>
    }

    private struct DXFCell {
        let x: Double
        let height: Double
        let text: String
    }

    private func vectorFlatten(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func svgGroupBody(_ svg: String, id: String) -> String? {
        guard let start = svg.range(of: "<g id=\"\(id)\"") else { return nil }
        let tail = svg[start.lowerBound...]
        guard let end = tail.range(of: "</g>") else { return nil }
        return String(tail[..<end.upperBound])
    }

    private func xmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func matchDouble(_ match: NSTextCheckingResult,
                             _ text: String, _ index: Int) -> Double? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Double(text[range])
    }

    private func svgBOMCells(_ svg: String) -> [BOMVectorCell] {
        guard let body = svgGroupBody(svg, id: "BOM_TEXT") else { return [] }
        let pattern = #"<text x="([^"]+)" y="([^"]+)" font-size="([^"]+)">([^<]*)</text>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let x = matchDouble(match, body, 1),
                  let y = matchDouble(match, body, 2),
                  let height = matchDouble(match, body, 3),
                  let textRange = Range(match.range(at: 4), in: body) else {
                return nil
            }
            return BOMVectorCell(
                x: x, y: y, height: height,
                text: xmlUnescaped(String(body[textRange])))
        }
    }

    private func svgBOMTable(_ svg: String) -> BOMVectorTable? {
        guard let body = svgGroupBody(svg, id: "BOM") else { return nil }
        let pattern = #"<line x1="([^"]+)" y1="([^"]+)" x2="([^"]+)" y2="([^"]+)"/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var verticals = Set<Double>()
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for match in regex.matches(in: body, range: range) {
            guard let x1 = matchDouble(match, body, 1),
                  let y1 = matchDouble(match, body, 2),
                  let x2 = matchDouble(match, body, 3),
                  let y2 = matchDouble(match, body, 4) else { continue }
            minX = Swift.min(minX, Swift.min(x1, x2))
            maxX = Swift.max(maxX, Swift.max(x1, x2))
            minY = Swift.min(minY, Swift.min(y1, y2))
            maxY = Swift.max(maxY, Swift.max(y1, y2))
            if abs(x1 - x2) < 1e-9 {
                verticals.insert(x1)
            }
        }
        guard minX.isFinite, minY.isFinite else { return nil }
        return BOMVectorTable(verticals: verticals.sorted(),
                              minPoint: SIMD2(minX, minY),
                              maxPoint: SIMD2(maxX, maxY))
    }

    private func svgLayerLines(_ svg: String, layer: String) -> [BOMVectorLine] {
        guard let body = svgGroupBody(svg, id: layer) else { return [] }
        let pattern = #"<line x1="([^"]+)" y1="([^"]+)" x2="([^"]+)" y2="([^"]+)"/>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            guard let x1 = matchDouble(match, body, 1),
                  let y1 = matchDouble(match, body, 2),
                  let x2 = matchDouble(match, body, 3),
                  let y2 = matchDouble(match, body, 4) else { return nil }
            return BOMVectorLine(a: SIMD2(x1, y1), b: SIMD2(x2, y2))
        }
    }

    private func dxfPairs(_ dxf: String) -> [(String, String)] {
        let lines = dxf.components(separatedBy: "\n")
        var pairs: [(String, String)] = []
        var index = 0
        while index + 1 < lines.count {
            pairs.append((lines[index], lines[index + 1]))
            index += 2
        }
        return pairs
    }

    private func dxfBOM(_ dxf: String) -> (cells: [DXFCell], table: BOMVectorTable)? {
        let pairs = dxfPairs(dxf)
        var cells: [DXFCell] = []
        var verticals = Set<Double>()
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var index = 0
        while index < pairs.count {
            guard pairs[index].0 == "0" else { index += 1; continue }
            let kind = pairs[index].1
            var cursor = index + 1
            var layer = ""
            var x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0
            var textX = 0.0, textHeight = 0.0, text = ""
            while cursor < pairs.count, pairs[cursor].0 != "0" {
                let code = pairs[cursor].0
                let value = pairs[cursor].1
                switch code {
                case "8":
                    layer = value
                case "10":
                    x1 = Double(value) ?? x1
                    textX = x1
                case "20":
                    y1 = Double(value) ?? y1
                case "11":
                    x2 = Double(value) ?? x2
                case "21":
                    y2 = Double(value) ?? y2
                case "40":
                    textHeight = Double(value) ?? textHeight
                case "1":
                    text = value
                default:
                    break
                }
                cursor += 1
            }
            if layer == "BOM" {
                if kind == "LINE" {
                    minX = Swift.min(minX, Swift.min(x1, x2))
                    maxX = Swift.max(maxX, Swift.max(x1, x2))
                    minY = Swift.min(minY, Swift.min(y1, y2))
                    maxY = Swift.max(maxY, Swift.max(y1, y2))
                    if abs(x1 - x2) < 1e-9 {
                        verticals.insert(x1)
                    }
                } else if kind == "TEXT" {
                    cells.append(DXFCell(x: textX, height: textHeight, text: text))
                }
            }
            index = cursor
        }
        guard minX.isFinite, minY.isFinite else { return nil }
        return (cells, BOMVectorTable(verticals: verticals.sorted(),
                                      minPoint: SIMD2(minX, minY),
                                      maxPoint: SIMD2(maxX, maxY)))
    }

    private func coreTextAdvance(_ text: String, height: Double) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName("Helvetica" as CFString, height, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func columnBounds(for x: Double,
                              in table: BOMVectorTable) -> (left: Double, right: Double)? {
        guard let left = table.verticals.last(where: { $0 <= x + 1e-6 }),
              let right = table.verticals.first(where: { $0 > x + 1e-6 }) else {
            return nil
        }
        return (left, right)
    }

    private func assertVectorCellFits(_ cell: BOMVectorCell,
                                      table: BOMVectorTable,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        guard let bounds = columnBounds(for: cell.x, in: table) else {
            XCTFail("vector cell '\(cell.text)' at x=\(cell.x) has no column",
                    file: file, line: line)
            return
        }
        let advance = coreTextAdvance(cell.text, height: cell.height)
        XCTAssertGreaterThanOrEqual(cell.x, bounds.left + 1.0 - 1e-6,
                                    "cell '\(cell.text)' starts before its column padding",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(cell.x + advance, bounds.right - 1.0 + 1e-6,
                                 "cell '\(cell.text)' advance \(advance) crosses "
                                    + "column \(bounds.left)..\(bounds.right)",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(advance, bounds.right - bounds.left - 2.0 + 1e-6,
                                 "cell '\(cell.text)' is wider than its padded column",
                                 file: file, line: line)
    }

    private func segmentIntersectsRect(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                                       min: SIMD2<Double>, max: SIMD2<Double>) -> Bool {
        var t0 = 0.0
        var t1 = 1.0
        let delta = b - a
        let p = [-delta.x, delta.x, -delta.y, delta.y]
        let q = [a.x - min.x, max.x - a.x, a.y - min.y, max.y - a.y]
        for index in 0..<4 {
            if abs(p[index]) < 1e-12 {
                if q[index] < 0 { return false }
                continue
            }
            let ratio = q[index] / p[index]
            if p[index] < 0 {
                t0 = Swift.max(t0, ratio)
            } else {
                t1 = Swift.min(t1, ratio)
            }
        }
        return t0 <= t1
    }

    private func rectsOverlap(_ aMin: SIMD2<Double>, _ aMax: SIMD2<Double>,
                              _ bMin: SIMD2<Double>, _ bMax: SIMD2<Double>) -> Bool {
        aMin.x < bMax.x - 1e-6 && aMax.x > bMin.x + 1e-6
            && aMin.y < bMax.y - 1e-6 && aMax.y > bMin.y + 1e-6
    }

    // MARK: - Complete CSV

    func testCompleteCSVExportsAllNineRowsWithExactEngineeringText() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        let data = try drawing.exportData(pageID: fixture.pageUUID, format: "csv")
        attach(data, name: "bom-full-table.csv",
               uniformTypeIdentifier: "public.comma-separated-values-text")
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

        // RFC 4180 doubles quotes inside quoted fields. Assert the exact
        // escaped UTF-8 cells as well as the independently decoded values
        // above; unescaped source text is not a raw CSV byte subsequence.
        let quotedName = "\"" + Self.longName.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let quotedMaterial = "\"" + Self.longMaterial.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        XCTAssertTrue(text.contains(quotedName))
        XCTAssertTrue(text.contains(quotedMaterial))
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
        XCTAssertNil(output["previewRows"],
                     "a complete vector table must not advertise a continuation")
        XCTAssertNil(output["nextAction"],
                     "a complete vector table needs no CSV fallback")
        XCTAssertEqual((bom["entries"] as? [[String: Any]])?.count, 9,
                       "pageGeometry must expose every BOM row even though the table text "
                         + "itself is generated only by the vector sheet renderer")

        let svg = try drawing.exportData(pageID: fixture.pageUUID, format: "svg")
        attach(svg, name: "bom-vector.svg", uniformTypeIdentifier: "public.svg-image")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let svgTexts = svgLayerTexts(svgText, layer: "BOM_TEXT")
        assertVectorCoverage(svgTexts, fixture: fixture)

        let dxf = try drawing.exportData(pageID: fixture.pageUUID, format: "dxf")
        attach(dxf, name: "bom-vector.dxf", uniformTypeIdentifier: "public.data")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        assertVectorCoverage(dxfBOMTexts(dxfText), fixture: fixture)

        let pdf = try drawing.exportData(pageID: fixture.pageUUID, format: "pdf")
        attach(pdf, name: "bom-vector.pdf", uniformTypeIdentifier: "com.adobe.pdf")
        let pdfContent = try pdfText(pdf)
        assertVectorCoverage([pdfContent], fixture: fixture)
    }

    /// Independent geometry check on the actual exported SVG/DXF: each BOM
    /// cell's measured CoreText advance stays inside the column separators that
    /// the exporter itself wrote. The sheet must also move the complete table
    /// clear of projected model lines instead of drawing through them.
    func testActualVectorBOMCellsFitMeasuredColumnsAndClearProjection() throws {
        let fixture = try makeNineRowFixture()
        let drawing = CADDrawingService(document: document)
        let geometry = drawing.pageGeometry(pageID: fixture.pageUUID)
        XCTAssertEqual(geometry["ok"] as? Bool, true, geometry["message"] as? String ?? "")
        let bom = try XCTUnwrap(geometry["bom"] as? [String: Any])
        let output = try XCTUnwrap(bom["bomOutput"] as? [String: Any])
        XCTAssertEqual(output["vectorComplete"] as? Bool, true)
        XCTAssertEqual(output["vectorTextComplete"] as? Bool, false,
                       "long mixed-script cells are shortened, so the exact-CSV notice "
                         + "must be truthful")
        XCTAssertEqual(output["tableZone"] as? String, "aboveProjection",
                       "the complete table must avoid the projected model band")

        let svg = try drawing.exportData(pageID: fixture.pageUUID, format: "svg")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let svgCells = svgBOMCells(svgText)
        let svgTable = try XCTUnwrap(svgBOMTable(svgText))
        XCTAssertEqual(svgCells.count, 60, "six headers plus 9 x 6 row cells")
        for cell in svgCells {
            assertVectorCellFits(cell, table: svgTable)
        }

        let dxf = try drawing.exportData(pageID: fixture.pageUUID, format: "dxf")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        let dxfBOMValue = try XCTUnwrap(dxfBOM(dxfText))
        XCTAssertEqual(dxfBOMValue.cells.count, 60)
        for cell in dxfBOMValue.cells {
            assertVectorCellFits(BOMVectorCell(x: cell.x, y: 0,
                                               height: cell.height, text: cell.text),
                                 table: dxfBOMValue.table)
        }

        // The four long values still shorten, with one ellipsis, and the
        // retained prefix is a whole-grapheme prefix of the real value.
        let longValues = [Self.longName, Self.longPartNumber,
                          Self.longMaterial, Self.longVersion].map { vectorFlatten($0) }
        for value in longValues {
            let match = svgCells.first { cell in
                guard cell.text.hasSuffix("…") else { return false }
                let prefix = String(cell.text.dropLast())
                return !prefix.isEmpty && value.hasPrefix(prefix)
            }
            let cell = try XCTUnwrap(match, "no shortened vector cell for \(value)")
            XCTAssertLessThan(cell.text.count, value.count)
        }

        // The table rectangle must clear every projected GEOMETRY segment,
        // stay inside the frame and avoid the title block.
        let modelLines = svgLayerLines(svgText, layer: "GEOMETRY")
        XCTAssertFalse(modelLines.isEmpty, "the fixture must project real geometry")
        for line in modelLines {
            XCTAssertFalse(segmentIntersectsRect(line.a, line.b,
                                                min: svgTable.minPoint,
                                                max: svgTable.maxPoint),
                           "projected geometry \(line) crosses the BOM table")
        }
        let frameMin = SIMD2(8.0, 8.0)
        let frameMax = SIMD2(297.0 - 8.0, 420.0 - 8.0)
        XCTAssertGreaterThanOrEqual(svgTable.minPoint.x, frameMin.x - 1e-6)
        XCTAssertGreaterThanOrEqual(svgTable.minPoint.y, frameMin.y - 1e-6)
        XCTAssertLessThanOrEqual(svgTable.maxPoint.x, frameMax.x + 1e-6)
        XCTAssertLessThanOrEqual(svgTable.maxPoint.y, frameMax.y + 1e-6)
        let titleMin = SIMD2(169.0, 390.0)
        let titleMax = SIMD2(289.0, 412.0)
        XCTAssertFalse(rectsOverlap(svgTable.minPoint, svgTable.maxPoint,
                                    titleMin, titleMax),
                       "the BOM table must not cover the title block")
    }

    /// Combining marks, ZWJ emoji and flags survive the width fit as whole
    /// graphemes. The test reads the actual SVG/DXF cell text, not a private
    /// fitter value, and independently measures each cell with CoreText.
    func testActualVectorBOMFitPreservesGraphemeClusters() throws {
        let fixture = try makeGraphemeFixture()
        let drawing = CADDrawingService(document: document)
        // A narrow but tall sheet still exports the complete table (width
        // 100 mm: 8/34/22.4/18/9.6/8 columns). That exercises minimum-width
        // columns, not just the roomy A3 layout.
        let resized = drawing.handle(action: "updatePage", args: [
            "pageID": fixture.pageID,
            "paper": "custom",
            "customWidthMM": 250.0,
            "customHeightMM": 420.0,
        ])
        XCTAssertEqual(resized["ok"] as? Bool, true, resized["message"] as? String ?? "")
        let svg = try drawing.exportData(pageID: fixture.pageUUID, format: "svg")
        attach(svg, name: "bom-grapheme.svg",
               uniformTypeIdentifier: "public.svg-image")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let svgCells = svgBOMCells(svgText)
        let svgTable = try XCTUnwrap(svgBOMTable(svgText))
        XCTAssertEqual(svgCells.count, 12, "six headers plus one six-column row")
        let headers = ["#", "Part", "Qty", "Part no.", "Material", "Rev"]
        let values = ["1", fixture.name, "1", fixture.partNumber,
                      fixture.material, fixture.version].map { vectorFlatten($0) }
        for index in 0..<6 {
            XCTAssertEqual(svgCells[index].text, headers[index])
            assertVectorCellFits(svgCells[index], table: svgTable)
            let cell = svgCells[6 + index]
            assertVectorCellFits(cell, table: svgTable)
            if cell.text != values[index] {
                XCTAssertTrue(cell.text.hasSuffix("…"),
                              "changed cell \(cell.text) must end with one ellipsis")
                let prefix = String(cell.text.dropLast())
                XCTAssertTrue(values[index].hasPrefix(prefix),
                              "fit '\(cell.text)' split a grapheme or changed the value")
            }
        }
        XCTAssertGreaterThanOrEqual(svgCells.filter { $0.text.hasSuffix("…") }.count, 4,
                                    "the long name, part, material and version must shorten")

        let dxf = try drawing.exportData(pageID: fixture.pageUUID, format: "dxf")
        attach(dxf, name: "bom-grapheme.dxf",
               uniformTypeIdentifier: "public.data")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        let dxfBOMValue = try XCTUnwrap(dxfBOM(dxfText))
        XCTAssertEqual(dxfBOMValue.cells.count, 12)
        for index in 0..<6 {
            let cell = dxfBOMValue.cells[6 + index]
            assertVectorCellFits(BOMVectorCell(x: cell.x, y: 0,
                                               height: cell.height, text: cell.text),
                                 table: dxfBOMValue.table)
            if cell.text != values[index] {
                XCTAssertTrue(cell.text.hasSuffix("…"))
                XCTAssertTrue(values[index].hasPrefix(String(cell.text.dropLast())),
                              "DXF fit '\(cell.text)' split a grapheme")
            }
        }
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
        XCTAssertEqual(output["fullTableFormat"] as? String, "csv")
        let nextAction = try XCTUnwrap(output["nextAction"] as? String)
        XCTAssertTrue(nextAction.contains("format=csv"),
                      "the preview status offers the complete CSV fallback")
        XCTAssertTrue(nextAction.contains("complete table"),
                      "the fallback names the complete BOM table")

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
        attach(csv, name: "bom-small-sheet-fallback.csv",
               uniformTypeIdentifier: "public.comma-separated-values-text")
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

#if canImport(SwiftUI) && canImport(UIKit)
// MARK: - Drawing preview BOM status (focused pure mapping + UI source contract)

/// The preview mapping must stay additive: a service reply without
/// `bom.bomOutput` keeps the existing rows/count summary, and only the four
/// provided status fields drive the capacity/shortening notice. The panel is
/// checked at the source level because presenting it requires the full App.
@MainActor
final class CADDrawingBOMUIMappingTests: XCTestCase {

    private func preview(_ reply: [String: Any]) -> CADDrawingPreview {
        CADDrawingPreview(reply: reply)
    }

    private func reply(bomOutput: [String: Any]?, rows: Int) -> [String: Any] {
        let entries: [[String: Any]] = (0..<rows).map { index in
            ["itemNumber": index + 1, "name": "Part \(index + 1)", "quantity": 1]
        }
        let page: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Sheet",
            "kind": "front",
        ]
        var bom: [String: Any] = ["entries": entries]
        if let bomOutput { bom["bomOutput"] = bomOutput }
        return ["page": page, "bom": bom]
    }

    func testLegacyReplyWithoutBOMOutputKeepsRowsAndNoLimit() {
        let value = preview(reply(bomOutput: nil, rows: 2))
        XCTAssertEqual(value.bomRows.count, 2)
        XCTAssertNil(value.bomOutput)
        XCTAssertEqual(value.bomTotalRows, 2)
        XCTAssertFalse(value.bomOutput?.isLimited == true)
    }

    func testCapacityOverflowUsesOnlyProvidedStatusFields() throws {
        let value = preview(reply(bomOutput: [
            "totalRows": 9,
            "capacity": 4,
            "vectorComplete": false,
            "previewRows": 4,
            "nextAction": "Export the complete table as CSV with drawing.export format=csv.",
        ], rows: 9))
        let output = try XCTUnwrap(value.bomOutput)
        XCTAssertEqual(output.totalRows, 9)
        XCTAssertEqual(output.capacity, 4)
        XCTAssertEqual(output.vectorComplete, false)
        XCTAssertNil(output.vectorTextComplete,
                     "an absent field must stay absent, not become false")
        XCTAssertTrue(output.showsCapacityLimit)
        XCTAssertFalse(output.showsTextShortening)
        XCTAssertTrue(output.isLimited)
        XCTAssertEqual(value.bomTotalRows, 9)
    }

    func testTopLevelBOMOutputRemainsCompatible() throws {
        let status: [String: Any] = [
            "totalRows": 2,
            "capacity": 2,
            "vectorComplete": true,
        ]
        let output = try XCTUnwrap(CADDrawingBOMOutputStatus(reply: ["bomOutput": status]))
        XCTAssertEqual(output.totalRows, 2)
        XCTAssertEqual(output.capacity, 2)
        XCTAssertEqual(output.vectorComplete, true)
        XCTAssertNil(output.vectorTextComplete)
        XCTAssertFalse(output.isLimited)
    }

    func testShortenedVectorTextIsReportedSeparately() throws {
        let value = preview(reply(bomOutput: [
            "totalRows": 3,
            "capacity": 3,
            "vectorComplete": true,
            "vectorTextComplete": false,
        ], rows: 3))
        let output = try XCTUnwrap(value.bomOutput)
        XCTAssertFalse(output.showsCapacityLimit)
        XCTAssertTrue(output.showsTextShortening)
        XCTAssertTrue(output.isLimited)
        XCTAssertEqual(value.bomTotalRows, 3)
    }

    func testSummaryShowsActualSubsetAndTrueTotal() {
        let partial = preview(reply(bomOutput: ["totalRows": 12], rows: 3))
        XCTAssertEqual(partial.bomSummaryRowCount, 3)
        XCTAssertEqual(partial.bomTotalRows, 12)
        let complete = preview(reply(bomOutput: ["totalRows": 2], rows: 9))
        XCTAssertEqual(complete.bomSummaryRowCount, 8)
        XCTAssertEqual(complete.bomTotalRows, 9,
                       "a stale total cannot hide rows actually returned")
    }

}
#endif

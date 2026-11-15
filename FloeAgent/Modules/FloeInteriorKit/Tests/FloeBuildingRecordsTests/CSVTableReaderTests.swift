import Foundation
import XCTest
@testable import FloeBuildingRecords

final class CSVTableReaderTests: XCTestCase {
    func testQuotedCommasNewlinesAndDoubledQuotes() throws {
        let text = "品牌,型号,数量,单位,房间,备注\r\n"
            + "A,\"M-1,2\",2,个,厨房,\"第一行\r\n第二行，含逗号\"\r\n"
            + "B,\"M\"\"2\",3,台,客厅,ok\r\n"
        let table = try CSVTableReader.parse(Data(text.utf8))
        XCTAssertEqual(table.delimiter, .comma)
        XCTAssertEqual(table.header, ["品牌", "型号", "数量", "单位", "房间", "备注"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0].fields[1], "M-1,2")
        XCTAssertEqual(table.rows[0].fields[5], "第一行\n第二行，含逗号")
        XCTAssertEqual(table.rows[1].fields[1], "M\"2")
        XCTAssertEqual(table.rows[0].startLine, 2)
        XCTAssertEqual(table.rows[1].startLine, 4)
        XCTAssertTrue(table.rows[0].rawRecord.contains("\r\n第二行"))
        XCTAssertTrue(table.rows[0].rawRecord.contains("\"M-1,2\""))
    }

    func testUTF8BOMAndCRLF() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("a,b\r\n1,2\r\n".utf8))
        let table = try CSVTableReader.parse(data)
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].fields, ["1", "2"])
        XCTAssertEqual(table.rows[0].startLine, 2)
    }

    func testUTF16LittleEndianBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("a,b\n1,2\n".data(using: .utf16LittleEndian)!)
        let table = try CSVTableReader.parse(data)
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows[0].fields, ["1", "2"])
    }

    func testSelectedTabDelimiter() throws {
        let table = try CSVTableReader.parse(
            Data("a\tb\n1\t2\n".utf8),
            options: CSVParseOptions(delimiter: .tab)
        )
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows[0].fields, ["1", "2"])
    }

    func testAutoSemicolonDelimiter() throws {
        let table = try CSVTableReader.parse(Data("a;b\n1;2\n".utf8))
        XCTAssertEqual(table.delimiter, .semicolon)
        XCTAssertEqual(table.header, ["a", "b"])
    }

    func testMalformedQuotedFields() {
        XCTAssertThrowsError(try CSVTableReader.parse(Data("a,b\n\"unterminated".utf8))) { error in
            XCTAssertEqual(error as? CSVParseError, .unterminatedQuotedField(recordIndex: 1))
        }
        XCTAssertThrowsError(try CSVTableReader.parse(Data("a,b\nx\"y,z\n".utf8))) { error in
            XCTAssertEqual(error as? CSVParseError, .quoteInUnquotedField(recordIndex: 1))
        }
        XCTAssertThrowsError(try CSVTableReader.parse(Data("a,b\n\"x\"y,z\n".utf8))) { error in
            XCTAssertEqual(error as? CSVParseError, .unexpectedCharacterAfterClosingQuote(recordIndex: 1))
        }
    }

    func testLimitsFailClosed() {
        XCTAssertThrowsError(
            try CSVTableReader.parse(
                Data("a,b\n1,2\n3,4\n".utf8),
                options: CSVParseOptions(maxRows: 1)
            )
        ) { error in
            XCTAssertEqual(error as? CSVParseError, .tooManyRows(limit: 1))
        }
        XCTAssertThrowsError(
            try CSVTableReader.parse(
                Data("a,b\n1,2,3\n".utf8),
                options: CSVParseOptions(maxColumns: 2)
            )
        ) { error in
            XCTAssertEqual(error as? CSVParseError, .tooManyColumns(recordIndex: 1, limit: 2))
        }
        XCTAssertThrowsError(
            try CSVTableReader.parse(
                Data("ab,cd\nabc,1\n".utf8),
                options: CSVParseOptions(maxFieldCharacters: 2)
            )
        ) { error in
            XCTAssertEqual(error as? CSVParseError, .fieldTooLong(recordIndex: 1, column: 0, limit: 2))
        }
        XCTAssertThrowsError(
            try CSVTableReader.parse(
                Data("a,b\n".utf8),
                options: CSVParseOptions(maxBytes: 3)
            )
        ) { error in
            XCTAssertEqual(error as? CSVParseError, .inputTooLarge(limit: 3, actual: 4))
        }
    }

    func testHeaderlessAndInconsistentRows() throws {
        let headerless = try CSVTableReader.parse(
            Data("1,2\n3,4\n".utf8),
            options: CSVParseOptions(hasHeaderRow: false)
        )
        XCTAssertNil(headerless.header)
        XCTAssertEqual(headerless.rows.count, 2)
        XCTAssertEqual(headerless.rows[0].recordIndex, 0)

        let inconsistent = try CSVTableReader.parse(Data("a,b\n1\n2,3,4\n".utf8))
        XCTAssertEqual(inconsistent.rows[0].fields, ["1"])
        XCTAssertEqual(inconsistent.rows[1].fields, ["2", "3", "4"])
    }

    func testEmptyAndHeaderOnly() throws {
        XCTAssertThrowsError(try CSVTableReader.parse(Data())) { error in
            XCTAssertEqual(error as? CSVParseError, .emptyInput)
        }
        XCTAssertThrowsError(try CSVTableReader.parse(Data("\n\n".utf8))) { error in
            XCTAssertEqual(error as? CSVParseError, .noRecords)
        }
        let headerOnly = try CSVTableReader.parse(Data("a,b\n".utf8))
        XCTAssertEqual(headerOnly.header, ["a", "b"])
        XCTAssertTrue(headerOnly.rows.isEmpty)
    }

    func testExtractionTableKeepsLocatorsAndRawRows() throws {
        let table = try CSVTableReader.parse(Data("a,b\n1,2\n".utf8))
        let extraction = try table.extractionTable()
        XCTAssertEqual(extraction.adapterIdentifier, "csv-v1")
        XCTAssertEqual(extraction.headers, ["a", "b"])
        XCTAssertEqual(extraction.rows.count, 1)
        XCTAssertEqual(extraction.rows[0].sourceRowKey, "row:2")
        XCTAssertEqual(extraction.rows[0].lineNumber, 2)
        XCTAssertEqual(extraction.rows[0].values, ["1", "2"])
        XCTAssertEqual(
            extraction.rows[0].locator,
            .spreadsheet(sheetName: nil, row: 2, cell: nil)
        )
    }
}

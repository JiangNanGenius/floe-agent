import Foundation
import Testing
@testable import FloeWorkspace

@Suite("Delimited literal records")
struct DelimitedTableTests {
    @Test func literalGoldenWithPhysicalLines() throws {
        let csv = "name,value,note\r\n\"oil,粉\",001,\"one\r\ntwo \"\"quoted\"\"\"\r\n\r\nlast,,\r\n"
        var rows: [DelimitedTable.Record] = []
        try DelimitedTable.scan(csv, delimiter: .comma) { rows.append($0) }
        #expect(rows == [
            .init(number: 1, lineStart: 1, lineEnd: 1, cells: ["name","value","note"]),
            .init(number: 2, lineStart: 2, lineEnd: 3, cells: ["oil,粉","001","one\r\ntwo \"quoted\""]),
            .init(number: 3, lineStart: 4, lineEnd: 4, cells: [""]),
            .init(number: 4, lineStart: 5, lineEnd: 5, cells: ["last","",""])
        ])
        var tab: [DelimitedTable.Record] = []
        try DelimitedTable.scan("a\t\"x\ty\"\t\"\"\n", delimiter: .tab) { tab.append($0) }
        #expect(tab.first?.cells == ["a","x\ty",""])
    }
    @Test func strictQuotesHaveActualLocations() throws {
        for (input,code,line,column) in [("中\"x", "unexpected_quote",1,2),("\"a\"x", "after_quote",1,4),("\"a\nb", "unterminated_quote",2,2)] {
            do { try DelimitedTable.scan(input, delimiter: .comma) { _ in }; Issue.record("Accepted illegal quote: \(code)") }
            catch let e as DelimitedTable.Failure { #expect(e.code == code); #expect(e.record == 1); #expect(e.line == line); #expect(e.column == column) }
        }
    }
    @Test func emptyAndTerminatorSemantics() throws {
        for (text,expected) in [("",[[String]]()),("\n",[[""]]),("\n\n",[[""],[""]]),(",",[["",""]]),("\"\"",[[""]]),("\r\n",[[""]]),("a\r\nb\rc\n",[["a"],["b"],["c"]])] {
            var rows: [[String]] = []
            try DelimitedTable.scan(text, delimiter: .comma) { rows.append($0.cells) }
            #expect(rows == expected)
        }
    }
    @Test func budgetPagingRetainsEveryWholeRecord() throws {
        let input = "h\n" + (0..<40).map { "\"row\($0), \"\"quoted\"\"\"\n" }.joined()
        var offset = 0, all: [DelimitedTable.Record] = [], pages = 0
        while true {
            let page = try DelimitedTable.page(input, delimiter: .comma, hasHeader: true, offset: offset, limit: 9, maximumPageBytes: 512)
            #expect(page.totalRecords == 41); #expect(page.totalDataRows == 40); #expect(page.header?.cells == ["h"])
            #expect(!page.rows.isEmpty); all += page.rows; pages += 1
            if let next = page.nextOffset { #expect(next == offset + page.rows.count); offset = next } else { break }
        }
        #expect(pages > 4); #expect(all.map(\.number) == Array(2...41))
        #expect(all.map(\.cells) == (0..<40).map { ["row\($0), \"quoted\""] })
        #expect(throws: DelimitedTable.Failure.self) { try DelimitedTable.page("\"" + String(repeating: "x",count: 600) + "\"", delimiter: .comma, hasHeader: false, offset: 0, limit: 1, maximumPageBytes: 256) }
    }
    @Test func fileEncodingAndRealSourceChangeFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("values.csv")
        let original = Data([0xFF,0xFE]) + "值,n\r\n中文,001\r\n".data(using: .utf16LittleEndian)!
        try original.write(to: url)
        let guardPath = WorkspacePathGuard(rootURL: root)
        let result = try WorkspaceDelimitedFile.read(path: "values.csv", pathGuard: guardPath) { source,text in (source,text) }
        #expect(result.0.encoding == .utf16LittleEndian); #expect(result.0.bomBytes == 2); #expect(result.0.byteCount == original.count)
        #expect(result.1 == "值,n\r\n中文,001\r\n")
        #expect(throws: DelimitedTable.Failure.self) {
            try WorkspaceDelimitedFile.read(path: "values.csv", pathGuard: guardPath) { _,text in
                try Data("replacement".utf8).write(to: url, options: .atomic); return text
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "replacement")
        #expect(throws: WorkspaceToolError.self) { try WorkspaceDelimitedFile.read(path: "values.csv", pathGuard: guardPath, expectedSHA256: result.0.sha256) { _,text in text } }
        try Data([0xEF,0xBB,0xBF,0x61,0x2C,0xFF]).write(to: url)
        #expect(throws: DelimitedTable.Failure.self) { try WorkspaceDelimitedFile.read(path: "values.csv", pathGuard: guardPath) { _,text in text } }
        #expect(throws: DelimitedTable.Failure.self) { try WorkspaceDelimitedFile.read(path: "values.csv", pathGuard: guardPath, encoding: .utf16BigEndian) { _,text in text } }
    }
    @Test func workspaceRootReplacementDoesNotAdoptForeignBytes() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("workspace"), old = parent.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("1\n".utf8).write(to: root.appendingPathComponent("input.csv"))
        let pathGuard = WorkspacePathGuard(rootURL: root)
        #expect(throws: DelimitedTable.Failure.self) {
            try WorkspaceDelimitedFile.read(path: "input.csv", pathGuard: pathGuard) { _,value in
                try FileManager.default.moveItem(at: root, to: old)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try Data("9\n".utf8).write(to: root.appendingPathComponent("input.csv"))
                return value
            }
        }
        #expect(try String(contentsOf: root.appendingPathComponent("input.csv"), encoding: .utf8) == "9\n")
        #expect(try String(contentsOf: old.appendingPathComponent("input.csv"), encoding: .utf8) == "1\n")
    }
    @Test func realCancellationAndResourceLimits() throws {
        #expect(throws: CancellationError.self) { try DelimitedTable.scan("a,b\n", delimiter: .comma, checkCancellation: { throw CancellationError() }) { _ in } }
        #expect(throws: DelimitedTable.Failure.self) { try DelimitedTable.scan(String(repeating: "x",count: DelimitedTable.maximumFieldBytes + 1), delimiter: .comma) { _ in } }
        #expect(throws: DelimitedTable.Failure.self) { try DelimitedTable.scan(Array(repeating: "",count: 257).joined(separator: ","), delimiter: .comma) { _ in } }
    }
}

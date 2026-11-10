import Foundation
import Testing
@testable import FloeMacBridgeProtocol

@Suite("Authenticated Mac bridge response payloads")
struct BridgeResponseValidationTests {
    private func invalid(_ body: () throws -> Void) {
        do { try body(); Issue.record("Malformed response was accepted") }
        catch BridgeFailure.invalidResponse { }
        catch { Issue.record("Wrong response classification: \(error)") }
    }
    private func file(_ path: String) -> BridgeValue {
        .object(["path": .string(path), "size": .integer(3), "sha256": .string(String(repeating: "a", count: 64))])
    }
    private func poll(alive: Bool, code: BridgeValue = .null) -> [String: BridgeValue] {
        ["data": .string(Data("abc".utf8).base64EncodedString()), "offset": .integer(3),
         "totalBytes": .integer(3), "alive": .bool(alive), "exitCode": code]
    }

    @Test func wireOneWorkspaceAndTransferIdentifiersRemainCompatible() throws {
        #expect(try BridgeResponseValidation.workspaceRoot(["root": .string("/Users/fixture/Workspace")]) == "/Users/fixture/Workspace")
        let id = UUID().uuidString
        #expect(try BridgeResponseValidation.transferID(["transferID": .string(id)]) == id)
        invalid { _ = try BridgeResponseValidation.workspaceRoot([:]) }
        invalid { _ = try BridgeResponseValidation.transferID(["transferID": .string("")]) }
    }

    @Test func completeEmptyListIsDistinctFromMissingOrMalformedFiles() throws {
        let empty = try BridgeResponseValidation.fileListPage(["files": .array([]), "next": .null], offset: 0, seenPaths: [])
        #expect(empty.files.isEmpty && empty.next == nil)
        for value: [String: BridgeValue] in [["next": .null], ["files": .string("bad"), "next": .null],
                                           ["files": .array([.null]), "next": .null],
                                           ["files": .array([.object(["path": .string("original.txt")])]), "next": .null]] {
            invalid { _ = try BridgeResponseValidation.fileListPage(value, offset: 0, seenPaths: []) }
        }
    }

    @Test func paginationMustAdvanceExactlyAndCannotLoseOrDuplicateRows() throws {
        let first = try BridgeResponseValidation.fileListPage(["files": .array([file("a.txt")]), "next": .integer(1)], offset: 0, seenPaths: [])
        #expect(first.files.count == 1 && first.next == 1)
        let last = try BridgeResponseValidation.fileListPage(["files": .array([file("b.txt")]), "next": .null], offset: 1, seenPaths: ["a.txt"])
        #expect(last.files.count == 1 && last.next == nil)
        for next: BridgeValue in [.integer(0), .integer(-1), .integer(2), .string("1")] {
            invalid { _ = try BridgeResponseValidation.fileListPage(["files": .array([file("a.txt")]), "next": next], offset: 0, seenPaths: []) }
        }
        invalid { _ = try BridgeResponseValidation.fileListPage(["files": .array([file("a.txt")]), "next": .null], offset: 1, seenPaths: ["a.txt"]) }
        invalid { _ = try BridgeResponseValidation.fileListPage(["files": .array([file("a.txt"), file("a.txt")]), "next": .null], offset: 0, seenPaths: []) }
        invalid { _ = try BridgeResponseValidation.fileListPage(["files": .array([])], offset: 0, seenPaths: []) }
    }

    @Test func invalidFileIdentityOrMetadataNeverBecomesADeletionSnapshot() {
        for row: BridgeValue in [file("../outside"), file("/outside"), file("a//b"),
                                .object(["path": .string("a"), "size": .integer(-1), "sha256": .string(String(repeating: "a", count: 64))]),
                                .object(["path": .string("a"), "size": .integer(1), "sha256": .string("invalid")])] {
            invalid { _ = try BridgeResponseValidation.fileListPage(["files": .array([row]), "next": .null], offset: 0, seenPaths: []) }
        }
    }

    @Test func fileChunksRequireValidBytesAndMatchingPosition() throws {
        let bytes = Data("abc".utf8)
        let page: [String: BridgeValue] = ["data": .string(bytes.base64EncodedString()), "offset": .integer(3)]
        #expect(try BridgeResponseValidation.fileChunk(page, offset: 0, totalBytes: 3) == bytes)
        invalid { _ = try BridgeResponseValidation.fileChunk(page, offset: 0, totalBytes: 2) }
        invalid { _ = try BridgeResponseValidation.fileChunk(["data": .string("!"), "offset": .integer(0)], offset: 0, totalBytes: 1) }
        invalid { _ = try BridgeResponseValidation.fileChunk(["data": .string(""), "offset": .integer(0)], offset: 0, totalBytes: 1) }
        invalid { _ = try BridgeResponseValidation.fileChunk(["data": page["data"]!], offset: 0, totalBytes: 3) }
    }

    @Test func liveAndConfirmedExitPollsRetainTheirActualMeaning() throws {
        let live = try BridgeResponseValidation.poll(poll(alive: true), offset: 0)
        #expect(live.alive && live.exitCode == nil && !live.outcomeUnknown)
        let ended = try BridgeResponseValidation.poll(poll(alive: false, code: .integer(7)), offset: 0)
        #expect(!ended.alive && ended.exitCode == 7 && ended.data == Data("abc".utf8))
        var saved = poll(alive: false)
        saved["outcomeUnknown"] = .bool(true)
        let unknown = try BridgeResponseValidation.poll(saved, offset: 0)
        #expect(unknown.outcomeUnknown && unknown.exitCode == nil && !unknown.alive)
    }

    @Test func missingOrContradictoryTerminalFieldsCannotInventExitZero() {
        for key in ["alive", "exitCode", "offset", "totalBytes", "data"] {
            var value = poll(alive: false, code: .integer(0)); value[key] = nil
            invalid { _ = try BridgeResponseValidation.poll(value, offset: 0) }
        }
        invalid { _ = try BridgeResponseValidation.poll(poll(alive: false), offset: 0) }
        invalid { _ = try BridgeResponseValidation.poll(poll(alive: true, code: .integer(0)), offset: 0) }
        var wrong = poll(alive: true); wrong["data"] = .string("broken base64!")
        invalid { _ = try BridgeResponseValidation.poll(wrong, offset: 0) }
    }

    @Test func liveAppendBetweenStatusAndReadDoesNotDiscardSignedBytes() throws {
        var value = poll(alive: true); value["totalBytes"] = .integer(1)
        let live = try BridgeResponseValidation.poll(value, offset: 0)
        #expect(live.totalBytes == 3 && live.offset == 3 && live.data.count == 3 && live.exitCode == nil)
        value["alive"] = .bool(false); value["exitCode"] = .integer(0)
        invalid { _ = try BridgeResponseValidation.poll(value, offset: 0) }
    }
}

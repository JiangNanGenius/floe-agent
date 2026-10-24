// FloeAndroidWorkspaceTests — Android-authored bounded tree/list/search
// contracts. Authored (job-b6c74b42a49d4f45, G04-R1 files-domain), NOT
// executed in this source lane. These pin the §6 tool-table ceilings the
// ORIGINAL service enforces (≤200 entries/page, ≤100 search hits with
// ≤200-character context, VCS/build directory pruning, secret exclusion) —
// the same bounds the LSP/AI/editor consumers rely on.

import XCTest
import Foundation
@testable import FloeWorkspace

final class WorkspaceSearchAndListBoundTests: XCTestCase {
    private var root: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ws-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testListPagesAtTwoHundredAndSortsDirectoriesFirst() throws {
        try service.createDirectory("zdir")
        for index in 1...250 {
            try service.createFile("f\(index).txt", content: "x")
        }
        let page1 = try service.listDirectory("", pageToken: nil)
        XCTAssertEqual(page1.entries.count, WorkspaceFileService.pageSize)
        XCTAssertEqual(page1.nextPageToken, "200")
        XCTAssertEqual(page1.entries.first?.relativePath, "zdir", "directories sort before files")
        XCTAssertEqual(page1.entries.first?.isDirectory, true)

        let page2 = try service.listDirectory("", pageToken: page1.nextPageToken)
        XCTAssertEqual(page2.entries.count, 51) // 250 files + 1 dir - 200
        XCTAssertNil(page2.nextPageToken)
        // Out-of-range tokens clamp instead of crashing.
        let clamped = try service.listDirectory("", pageToken: "999999")
        XCTAssertTrue(clamped.entries.isEmpty)
        XCTAssertNil(clamped.nextPageToken)
    }

    func testListFiltersByNameAndKind() throws {
        try service.createFile("Alpha.txt", content: "1")
        try service.createFile("beta.md", content: "2")
        try service.createDirectory("AlphaDir")

        let byName = try service.listDirectory("", pageToken: nil, nameContains: "alph")
        XCTAssertEqual(Set(byName.entries.map(\.relativePath)), ["Alpha.txt", "AlphaDir"],
                       "nameContains is case-insensitive and applied before pagination")

        let filesOnly = try service.listDirectory("", pageToken: nil, includeDirectories: false)
        XCTAssertTrue(filesOnly.entries.allSatisfy { !$0.isDirectory })
        XCTAssertEqual(filesOnly.entries.count, 2)

        let dirsOnly = try service.listDirectory("", pageToken: nil, includeFiles: false)
        XCTAssertEqual(dirsOnly.entries.map(\.relativePath), ["AlphaDir"])

        let missing = try? service.listDirectory("nope", pageToken: nil)
        XCTAssertNil(missing, "listing a missing directory must throw, not return an empty page")
        XCTAssertThrowsError(try service.listDirectory("Alpha.txt", pageToken: nil)) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .invalidArguments("path is not a directory: Alpha.txt"))
        }
    }

    func testContentSearchHonoursHitCapContextLengthAndPrunesInternals() throws {
        let shared = "NEEDLE"
        for index in 1...150 {
            try service.createFile("match\(index).txt",
                                   content: "quiet line\n\(shared) in file\n")
        }
        // A matching file hidden in a pruned directory must not be searchable.
        // node_modules/.pem are deliberately NON-hidden so the search-time
        // prune/secret branches actually run (hidden entries are skipped
        // earlier by the enumerator).
        try service.createDirectory("node_modules")
        try service.createFile("node_modules/leak.txt", content: shared)
        // Nor behind the secret extension exclusion (created RAW: the guard
        // would refuse the service-side write itself).
        try Data(shared.utf8).write(to: root.appendingPathComponent("keys.pem"))
        try service.createDirectory(".git")
        try service.createFile(".git/COMMIT_EDIT", content: shared)
        try Data(shared.utf8).write(to: root.appendingPathComponent(".env"))
        // A very long matching line must not smuggle more than the cap.
        let longLine = shared + String(repeating: "x", count: 2_000)
        try service.createFile("long.txt", content: longLine + "\n")

        let hits = try service.search(query: shared)
        XCTAssertEqual(hits.count, WorkspaceFileService.maxSearchHits,
                       "150 matches must clamp to exactly 100 hits")
        for hit in hits {
            XCTAssertFalse(hit.relativePath.hasPrefix(".git/"), "pruned directory leaked: \(hit.relativePath)")
            XCTAssertFalse(hit.relativePath.hasPrefix("node_modules/"), "pruned directory leaked: \(hit.relativePath)")
            XCTAssertNotEqual(hit.relativePath, ".env", "secret file leaked")
            XCTAssertNotEqual(hit.relativePath, "keys.pem", "secret file leaked")
            XCTAssertLessThanOrEqual(hit.context.count, WorkspaceFileService.maxHitContextCharacters)
            XCTAssertGreaterThanOrEqual(hit.lineNumber, 1)
        }
        XCTAssertThrowsError(try service.search(query: "   ")) { error in
            XCTAssertEqual(error as? WorkspaceToolError,
                           .invalidArguments("query must not be empty"))
        }
        // The long-line cap is asserted on a SINGLE-file scope so enumeration
        // order cannot hide the fixture: searching the file itself.
        let single = try service.search(query: shared, in: "long.txt")
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].context.count, WorkspaceFileService.maxHitContextCharacters)
        XCTAssertTrue(single[0].context.hasPrefix(shared))
        XCTAssertEqual(single[0].lineNumber, 1)
    }

    func testNameSearchCapsResultsAndMarksDirectories() throws {
        for index in 1...120 { try service.createFile("hit\(index).log", content: "x") }
        let hits = try service.searchFileNames(query: "hit", maxResults: 500)
        XCTAssertEqual(hits.count, WorkspaceFileService.maxSearchHits,
                       "maxResults must clamp to 100, never 500")
        XCTAssertThrowsError(try service.searchFileNames(query: ""))
    }

    func testNameSearchMarksDirectoriesWithTrailingSlash() throws {
        try service.createFile("hit1.log", content: "x")
        try service.createDirectory("hitdir")
        let hits = try service.searchFileNames(query: "hit")
        XCTAssertEqual(Set(hits), ["hit1.log", "hitdir/"], "directory hit carries trailing /")
    }
}

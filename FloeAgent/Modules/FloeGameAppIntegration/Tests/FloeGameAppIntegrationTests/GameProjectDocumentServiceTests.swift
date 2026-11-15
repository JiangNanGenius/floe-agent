// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameAppIntegration

final class GameProjectDocumentServiceTests: XCTestCase {
    private var root: URL!
    private var repository: FileGameProjectRepository!
    private var projectID: UUID!
    private var owner: GameProjectOwner!
    private var service: GameProjectDocumentService!
    private var context: GameProjectContext!
    private var revision: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-doc-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = try FileGameProjectRepository(directory: root.appendingPathComponent("History"))
        projectID = UUID()
        owner = .space(recordID: projectID)
        let created = try await repository.createProject(projectID: projectID, owner: owner, title: "Doc test")
        let text = "Hello game\n第二行🚀\nthird line\n"
        let binary = Data([0, 1, 2, 3, 0xFF])
        let saved = try await repository.commit(projectID, owner: owner,
            expectedRevision: created.revision, changes: [
                .write(try GameRelativePath("src/main.txt"), Data(text.utf8)),
                .write(try GameRelativePath("assets/unknown.bin"), binary)
            ])
        revision = saved.revision
        context = try GameProjectContext(projectID: projectID, owner: owner,
            rootURL: root.appendingPathComponent("Files"), savedRevision: revision)
        service = GameProjectDocumentService(repository: repository,
            maximumTextBytes: 1_024 * 1_024, maximumPageBytes: 8, maximumWriteBytes: 64 * 1_024)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    func testDirectoryPageListsFilesAndDirectoriesWithoutChangingThem() async throws {
        let page = try await service.list(context, limit: 1)
        XCTAssertEqual(page.revision, revision)
        XCTAssertEqual(page.totalEntries, 4)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.path.value, "assets")
        XCTAssertNotNil(page.nextOffset)
        let next = try await service.list(context, offset: page.nextOffset!, limit: 10)
        XCTAssertEqual(next.entries.map(\.path.value), ["assets/unknown.bin", "src", "src/main.txt"])
        XCTAssertNil(next.nextOffset)
        let directRoot = try await service.list(context, directory: ".")
        XCTAssertEqual(directRoot.entries.map(\.path.value), ["assets", "src"])
        let nested = try await service.list(context, directory: "src")
        XCTAssertEqual(nested.entries.map(\.path.value), ["src/main.txt"])
        XCTAssertEqual(nested.entries.first?.bytes, 36)
    }

    func testBoundedUTF8PagingNeverSplitsACodePoint() async throws {
        var offset = 0
        var text = ""
        while true {
            let page = try await service.read(context, path: try GameRelativePath("src/main.txt"),
                                              offset: offset, limit: 5)
            text += page.text
            if let next = page.nextOffset { offset = next } else { break }
        }
        XCTAssertEqual(text, "Hello game\n第二行🚀\nthird line\n")
        // The engine must not return a page whose bytes are invalid UTF-8.
        let page = try await service.read(context, path: try GameRelativePath("src/main.txt"),
                                          offset: 0, limit: 5)
        XCTAssertEqual(String(decoding: Data(page.text.utf8), as: UTF8.self), page.text)
    }

    func testBinaryAndStaleContextAreRejected() async throws {
        do {
            _ = try await service.read(context, path: try GameRelativePath("assets/unknown.bin"))
            XCTFail("Binary content must not be returned as text")
        } catch let error as GameDocumentError {
            XCTAssertEqual(error, .binaryFile(try GameRelativePath("assets/unknown.bin")))
        }
        try await repository.commit(projectID, owner: owner, expectedRevision: revision,
            changes: [.write(try GameRelativePath("src/main.txt"), Data("new".utf8))])
        do {
            _ = try await service.read(context, path: try GameRelativePath("src/main.txt"))
            XCTFail("A stale saved revision must be rejected")
        } catch let error as GameDocumentError {
            guard case .staleRevision = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testCASEditReadsBackAndPreservesUnknownFiles() async throws {
        let result = try await service.commit(context, expectedRevision: revision,
            changes: [
                .write(try GameRelativePath("src/main.txt"), Data("edited".utf8)),
                .write(try GameRelativePath("src/new.txt"), Data("created".utf8))
            ])
        XCTAssertEqual(result.parent, revision)
        let editedContext = try GameProjectContext(projectID: projectID, owner: owner,
            rootURL: root.appendingPathComponent("Files"), savedRevision: result.revision)
        let read = try await service.read(editedContext, path: try GameRelativePath("src/main.txt"))
        XCTAssertEqual(read.text, "edited")
        let unknown = try await service.read(editedContext, path: try GameRelativePath("src/new.txt"))
        XCTAssertEqual(unknown.text, "created")
        do {
            _ = try await service.commit(context, expectedRevision: revision,
                changes: [.write(try GameRelativePath("src/main.txt"), Data("stale".utf8))])
            XCTFail("The previous revision must not be writable after a save")
        } catch let error as GameDocumentError {
            guard case .staleRevision = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testRelocateHistoryAndExplicitRestoreKeepPreviousBytes() async throws {
        let moved = try await service.relocate(context, expectedRevision: revision,
            moves: [try GameFileRelocation(from: try GameRelativePath("src/main.txt"),
                                           to: try GameRelativePath("src/renamed.txt"))])
        XCTAssertEqual(moved.parent, revision)
        let movedContext = try GameProjectContext(projectID: projectID, owner: owner,
            rootURL: root.appendingPathComponent("Files"), savedRevision: moved.revision)
        let history = try await service.history(movedContext, limit: 8)
        XCTAssertGreaterThanOrEqual(history.count, 2)
        XCTAssertEqual(history.first?.revision, moved.revision)
        let old = try await service.readHistorical(movedContext, historicalRevision: revision,
            path: try GameRelativePath("src/main.txt"))
        XCTAssertTrue(old.text.contains("Hello game"))
        let restored = try await service.restore(movedContext, expectedRevision: moved.revision,
            historicalRevision: revision)
        XCTAssertEqual(restored.parent, moved.revision)
        let restoredContext = try GameProjectContext(projectID: projectID, owner: owner,
            rootURL: root.appendingPathComponent("Files"), savedRevision: restored.revision)
        let read = try await service.read(restoredContext, path: try GameRelativePath("src/main.txt"))
        XCTAssertEqual(read.text, "Hello game\n第二行🚀\nthird line\n")
    }

    func testTinyPageCannotRepeatAnOffsetInsideAMultibyteCharacter() async throws {
        let path = try GameRelativePath("src/main.txt"), offset = "Hello game\n".utf8.count
        for start in [offset, offset + 1] {
            do {
                _ = try await service.read(context, path: path, offset: start, limit: 1)
                XCTFail("A truncated code point cannot form a page")
            } catch let error as GameDocumentError {
                XCTAssertEqual(error, .invalidPageLimit(1))
            }
        }
        let page = try await service.read(context, path: path, offset: offset + 1, limit: 3)
        XCTAssertEqual(page.text, "第")
        XCTAssertEqual(page.nextOffset, offset + 3)
    }
}

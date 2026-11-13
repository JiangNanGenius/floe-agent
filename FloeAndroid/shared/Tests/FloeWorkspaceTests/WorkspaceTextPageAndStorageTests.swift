// FloeWorkspaceTests — N113 lightweight text policy, paging and source
// finalization contracts.
//
// Source-only: authored, NOT executed in this lane. Real temporary files and
// the real production service prove byte-exact BOM/CRLF/emoji round trips,
// 64 KiB pages reaching EOF for 256 KiB/410 KiB documents, strict binary
// refusal, and CAS-preserving sourcePath finalization.

import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeWorkspace

final class WorkspaceTextPageAndStorageTests: XCTestCase {
    private var root: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-n113-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func raw(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    // MARK: - Policy / decode

    func testBroadTextPolicyKeepsNonTextFamiliesNative() {
        for path in [
            "script.py", "page.html", "data.csv", "notes.rst", "paper.tex",
            "conf.json5", "README", "Makefile", "unknown.foobar", "Dockerfile",
        ] {
            XCTAssertTrue(WorkspaceTextPolicy.isTextualPath(path), path)
        }
        for path in ["photo.png", "report.docx", "sheet.xlsx", "archive.zip", "video.mp4"] {
            XCTAssertFalse(WorkspaceTextPolicy.isTextualPath(path), path)
        }
        XCTAssertEqual(WorkspaceTextPolicy.kind(forPath: "page.html"), .code)
        XCTAssertEqual(WorkspaceTextPolicy.kind(forPath: "data.csv"), .text)
        XCTAssertEqual(WorkspaceTextPolicy.kind(forPath: "unknown.foobar"), .unknown)
        XCTAssertEqual(WorkspaceTextPolicy.kind(forPath: "README"), .text)
    }

    func testDecodeUTF8PreservesBomDoubleBomCRLFAndEmoji() {
        let text = "\u{FEFF}\u{FEFF}first\r\nsecond 😀 中文\r\n"
        let data = Data(text.utf8)
        XCTAssertEqual(WorkspaceTextPolicy.decodeUTF8(data), text)
        XCTAssertEqual(Data(WorkspaceTextPolicy.decodeUTF8(data)!.utf8), data)
        XCTAssertNil(WorkspaceTextPolicy.decodeUTF8(Data([0x41, 0x00, 0x42])))
        XCTAssertNil(WorkspaceTextPolicy.decodeUTF8(Data([0x41, 0x80])))
        XCTAssertNil(WorkspaceTextPolicy.decodeUTF8(
            Data([0xFF, 0xFE, 0x68, 0x00])))
    }

    // MARK: - 64 KiB pages reach real EOF

    func test256And410KiBPagesReassembleThroughEof() throws {
        for target in [256 * 1024, 410 * 1024] {
            let unit = "line — 😀 中文\r\n"
            let unitBytes = unit.utf8.count
            var text = "\u{FEFF}"
            var size = text.utf8.count
            while size < target {
                text += unit
                size += unitBytes
            }
            let bytes = Data(text.utf8)
            let name = "large-\(target).txt"
            try bytes.write(to: root.appendingPathComponent(name))

            var offset = 0
            var rebuilt = Data()
            var pages = 0
            while true {
                let page = try service.readFile(name, byteOffset: offset)
                pages += 1
                XCTAssertEqual(page.totalBytes, bytes.count)
                XCTAssertEqual(page.byteOffset, offset)
                XCTAssertLessThanOrEqual(page.text.utf8.count,
                                         WorkspaceFileService.readChunkBytes)
                if pages == 1 {
                    XCTAssertTrue(page.truncated)
                    XCTAssertGreaterThan(page.text.utf8.count,
                                         WorkspaceFileService.readChunkBytes - 4)
                }
                rebuilt.append(Data(page.text.utf8))
                guard let next = page.nextOffset else { break }
                XCTAssertGreaterThan(next, offset)
                offset = next
                XCTAssertLessThanOrEqual(pages, 16)
            }
            XCTAssertEqual(rebuilt, bytes, "all 64 KiB pages must reassemble the exact file")
            XCTAssertEqual(offset, bytes.count, "the last page must end exactly at EOF")
            XCTAssertEqual(try service.readFileForEditing(name).text, text)
        }
    }

    func testPageOffsetMustBeAUTF8Boundary() throws {
        let text = "a😀b"
        try Data(text.utf8).write(to: root.appendingPathComponent("emoji.txt"))
        // "a" + first byte of the four-byte emoji is a valid boundary; the
        // second byte is a continuation and must be refused without skipping
        // any bytes.
        let inside = try service.readFile("emoji.txt", byteOffset: 1)
        XCTAssertNil(inside.nextOffset) // tiny file, whole content
        XCTAssertThrowsError(try service.readFile("emoji.txt", byteOffset: 2)) { error in
            guard case WorkspaceToolError.invalidArguments = error else {
                return XCTFail("expected a typed boundary refusal, got \(error)")
            }
        }
    }

    // MARK: - Source finalization

    func testSourceFinalizationPreservesDraftAndExactBytes() throws {
        let draft = "\u{FEFF}\u{FEFF}first\r\nsecond 😀\r\n"
        try Data(draft.utf8).write(to: root.appendingPathComponent("draft.txt"))
        let digest = FloeDigest.sha256Hex(Data(draft.utf8))
        let result = try service.writeFileFromSource(
            "target.txt", sourcePath: "draft.txt", expectedSourceSHA256: digest)
        XCTAssertEqual(result.content, draft)
        XCTAssertEqual(try raw("target.txt"), Data(draft.utf8))
        XCTAssertEqual(try raw("draft.txt"), Data(draft.utf8))
        XCTAssertEqual(result.outcome.sha256, digest)

        // No target precondition means create-only: an existing original is
        // never overwritten and its bytes stay intact.
        XCTAssertThrowsError(try service.writeFileFromSource(
            "target.txt", sourcePath: "draft.txt", expectedSourceSHA256: digest)) { error in
            guard case WorkspaceToolError.alreadyExistsOverwritable = error else {
                return XCTFail("expected create-only refusal, got \(error)")
            }
        }
        XCTAssertEqual(try raw("target.txt"), Data(draft.utf8))
    }

    func testWriteFileToolSourcePathFinalizesThroughTheRealToolRoute() async throws {
        let draft = "\u{FEFF}tool draft\r\n😀\r\n"
        try Data(draft.utf8).write(to: root.appendingPathComponent("tool-draft.txt"))
        let rootURL = root!
        let environment = WorkspaceToolEnvironment(rootProvider: { rootURL })
        let context = ToolContext(runID: UUID(), workspaceRootURL: rootURL,
                                  cancellation: CancellationToken())
        let tool = WorkspaceWriteFileTool(environment: environment)
        _ = try await tool.execute(
            WorkspaceWriteFileTool.Arguments(
                path: "tool-target.txt", sourcePath: "tool-draft.txt",
                expectedSourceSHA256: FloeDigest.sha256Hex(Data(draft.utf8))),
            context: context)
        XCTAssertEqual(try raw("tool-target.txt"), Data(draft.utf8))
        XCTAssertEqual(try raw("tool-draft.txt"), Data(draft.utf8))
        // Create-only without a target precondition: the just-written target
        // is never silently replaced by a retry.
        do {
            _ = try await tool.execute(
                WorkspaceWriteFileTool.Arguments(
                    path: "tool-target.txt", sourcePath: "tool-draft.txt",
                    expectedSourceSHA256: FloeDigest.sha256Hex(Data(draft.utf8))),
                context: context)
            XCTFail("create-only finalization must refuse an existing target")
        } catch {
            guard case WorkspaceToolError.alreadyExistsOverwritable = error else {
                XCTFail("expected create-only refusal, got \(error)")
                return
            }
        }
        XCTAssertEqual(try raw("tool-target.txt"), Data(draft.utf8))
    }

    func testSourceFinalizationCASAndCancellationPreserveOriginal() throws {
        try Data("draft".utf8).write(to: root.appendingPathComponent("draft-cas.txt"))
        try Data("original".utf8).write(to: root.appendingPathComponent("target-cas.txt"))
        let sourceDigest = FloeDigest.sha256Hex(Data("draft".utf8))
        XCTAssertThrowsError(try service.writeFileFromSource(
            "target-cas.txt", sourcePath: "draft-cas.txt",
            expectedSourceSHA256: sourceDigest,
            expectedSHA256: FloeDigest.sha256Hex(Data("different".utf8)))) { error in
            guard case WorkspaceToolError.conflict = error else {
                return XCTFail("expected target conflict, got \(error)")
            }
        }
        XCTAssertEqual(try raw("target-cas.txt"), Data("original".utf8))

        XCTAssertThrowsError(try service.writeFileFromSource(
            "target-cas.txt", sourcePath: "draft-cas.txt",
            expectedSourceSHA256: FloeDigest.sha256Hex(Data("stale".utf8)),
            expectedSHA256: FloeDigest.sha256Hex(Data("original".utf8)))) { error in
            guard case WorkspaceToolError.conflict = error else {
                return XCTFail("expected source conflict, got \(error)")
            }
        }
        XCTAssertEqual(try raw("target-cas.txt"), Data("original".utf8))

        let cancelled = CancellationToken()
        cancelled.cancel()
        XCTAssertThrowsError(try service.writeFileFromSource(
            "never.txt", sourcePath: "draft-cas.txt",
            expectedSourceSHA256: sourceDigest, cancellation: cancelled))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("never.txt").path))
        XCTAssertEqual(try raw("draft-cas.txt"), Data("draft".utf8))
        // Source and target may never be the same file.
        XCTAssertThrowsError(try service.writeFileFromSource(
            "draft-cas.txt", sourcePath: "draft-cas.txt",
            expectedSourceSHA256: sourceDigest))
    }

    func testAppendAndReplaceRoutesPreserveExactBomCrlfAndEmoji() async throws {
        let initial = "\u{FEFF}\u{FEFF}first\r\nsecond 😀\r\n"
        try Data(initial.utf8).write(to: root.appendingPathComponent("append.txt"))
        let rootURL = root!
        let environment = WorkspaceToolEnvironment(rootProvider: { rootURL })
        let context = ToolContext(runID: UUID(), workspaceRootURL: rootURL,
                                  cancellation: CancellationToken())
        _ = try await WorkspaceTextEdit.apply(
            path: "append.txt",
            expectedSHA256: FloeDigest.sha256Hex(Data(initial.utf8)),
            environment: environment, context: context) { $0 + "tail 😀\r\n" }
        let appended = initial + "tail 😀\r\n"
        XCTAssertEqual(try raw("append.txt"), Data(appended.utf8))

        _ = try await WorkspaceTextEdit.apply(
            path: "append.txt",
            expectedSHA256: FloeDigest.sha256Hex(Data(appended.utf8)),
            environment: environment, context: context) { original in
                guard let range = original.range(of: "second") else {
                    throw WorkspaceToolError.invalidArguments("missing test marker")
                }
                return original.replacingCharacters(in: range, with: "SECOND")
            }
        let replaced = appended.replacingOccurrences(of: "second", with: "SECOND")
        XCTAssertEqual(try raw("append.txt"), Data(replaced.utf8))
        XCTAssertEqual(try service.readFileForEditing("append.txt").text, replaced)
    }

    func testEditableReadRejectsBinaryAndOversizedButPagedReadStillPages() throws {
        var binary = Data("PK".utf8)
        binary.append(0)
        try binary.write(to: root.appendingPathComponent("fake.zip"))
        XCTAssertThrowsError(try service.readFileForEditing("fake.zip"))
        XCTAssertThrowsError(try service.readFile("fake.zip"))

        let big = Data(repeating: 0x61, count: 5 * 1024 * 1024)
        try big.write(to: root.appendingPathComponent("huge.txt"))
        XCTAssertThrowsError(try service.readFileForEditing("huge.txt")) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .tooLarge(limit: 4 * 1024 * 1024))
        }
        let first = try service.readFile("huge.txt")
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.totalBytes, big.count)
        XCTAssertEqual(first.byteOffset, 0)
        XCTAssertEqual(first.bytesReturned, WorkspaceFileService.readChunkBytes)
    }
}

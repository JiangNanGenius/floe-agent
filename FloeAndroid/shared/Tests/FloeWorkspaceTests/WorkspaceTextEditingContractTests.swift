// FloeAndroidWorkspaceTests — Android-authored text-edit authority contracts.
// Authored (job-b6c74b42a49d4f45, G04-R1 files-domain) but NOT executed in
// this source lane; Main's grouped host cohort runs them together with the
// mirrored original suites, and the Android build compiles the same targets.
// Host-runnable: no UIKit, no networking, no device, no credential.
//
// These tests exercise BEHAVIOURAL CONTRACTS of the ported authority
// (WorkspaceTextEdit decode/check, complete editable reads, encoding and
// line-ending preservation, size caps) — they do not re-implement or mirror
// the production logic.

import XCTest
import Foundation
import FloeCore
@testable import FloeWorkspace

final class WorkspaceTextEditingContractTests: XCTestCase {
    private var root: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ws-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func rawBytes(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    /// `decode` is the single text gate behind `readFileForEditing` and
    /// `applyPatch`: any NUL byte or invalid UTF-8 must be a typed refusal,
    /// never a replacement-character decode that could be written back.
    func testDecodeRejectsBinaryAndInvalidUTF8() throws {
        XCTAssertNoThrow(try WorkspaceTextEdit.decode(Data("plain ✓ 中文\r\n".utf8)))
        var withNUL = Data("abc".utf8); withNUL.insert(0, at: 1)
        XCTAssertThrowsError(try WorkspaceTextEdit.decode(withNUL)) { error in
            guard case WorkspaceToolError.invalidArguments = error else {
                return XCTFail("expected typed invalidArguments, got \(error)")
            }
        }
        // Lone continuation byte: not valid UTF-8.
        XCTAssertThrowsError(try WorkspaceTextEdit.decode(Data([0x41, 0x80])))
        // UTF-16 LE BOM content contains NUL bytes → refuses, the file must
        // go through the reader codec path, not be recoded and re-saved.
        let utf16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]) // "hi" in UTF-16LE with BOM
        XCTAssertThrowsError(try WorkspaceTextEdit.decode(utf16))
    }

    /// `check` binds a write to the exact bytes that were transformed.
    func testCheckIsCaseInsensitiveExactBinding() throws {
        let digest = FloeDigest.sha256Hex(Data("abc".utf8))
        XCTAssertNoThrow(try WorkspaceTextEdit.check(nil, actual: digest))
        XCTAssertNoThrow(try WorkspaceTextEdit.check(digest.uppercased(), actual: digest))
        XCTAssertThrowsError(try WorkspaceTextEdit.check("0" + digest.dropFirst(), actual: digest)) { error in
            guard case WorkspaceToolError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    /// The editor must NEVER be handed a truncated window it could save over
    /// the original: tool reads stay chunked, editable reads are complete or
    /// fail closed.
    func testEditableReadIsCompleteWhereToolReadTruncates() throws {
        var big = String()
        while big.utf8.count < 200_000 { big += "editable-window-line-\(big.utf8.count)\n" }
        try service.createFile("wide.txt", content: big)

        let chunked = try service.readFile("wide.txt")
        XCTAssertTrue(chunked.truncated, "64 KiB tool read of a 200 KB file must report truncation")
        XCTAssertLessThan(chunked.text.utf8.count, WorkspaceFileService.readChunkBytes)
        XCTAssertEqual(chunked.totalLines, WorkspaceFileService.lineCount(of: big))

        let editable = try service.readFileForEditing("wide.txt")
        XCTAssertFalse(editable.truncated)
        XCTAssertEqual(editable.byteOffset, 0)
        XCTAssertEqual(editable.text, big)
        // Saving exactly what the editor loaded is a clean CAS write.
        let outcome = try service.writeFile(
            "wide.txt", content: editable.text,
            expectedMtime: (try service.metadata("wide.txt")).mtime,
            expectedSHA256: FloeDigest.sha256Hex(Data(big.utf8)))
        XCTAssertEqual(outcome.sha256, editable.text.sha256ForTest)
    }

    /// Editable reads fail closed at the shared 4 MiB write cap instead of
    /// loading a document the editor could not save back atomically.
    func testEditableReadRefusesFilesOverWriteCap() throws {
        let bytes = Data(repeating: 0x61, count: 5 * 1024 * 1024) // 'a' * 5 MiB
        try bytes.write(to: root.appendingPathComponent("huge.txt"))
        XCTAssertThrowsError(try service.readFileForEditing("huge.txt")) { error in
            XCTAssertEqual(error as? WorkspaceToolError,
                           .tooLarge(limit: 4 * 1024 * 1024))
        }
        // The chunked tool read still works within its own cap — refusing the
        // editable load is not a refusal to read at all.
        XCTAssertNoThrow(try service.readFile("huge.txt"))
    }

    func testEditableReadRefusesBinaryByContent() throws {
        var data = Data("PK\u{0}\u{1}fake-zip-prefix".utf8); data.append(0)
        try data.write(to: root.appendingPathComponent("fake.zip"))
        XCTAssertThrowsError(try service.readFileForEditing("fake.zip")) { error in
            guard case WorkspaceToolError.invalidArguments(let reason) = error else {
                return XCTFail("expected typed invalidArguments, got \(error)")
            }
            XCTAssertTrue(reason.contains("not editable text"))
        }
    }

    /// Line endings are document content: CRLF, CR-less LF, mixed and a
    /// UTF-8 BOM must survive the full load→edit→save round trip byte-exact.
    func testLineEndingsAndBOMSurviveRoundTrip() throws {
        let bom = "\u{FEFF}"
        let crlf = bom + "first\r\nsecond\r\n\r\nmixed tail\r"
        try service.createFile("keep.txt", content: crlf)
        let loaded = try service.readFileForEditing("keep.txt")
        XCTAssertEqual(loaded.text, crlf)
        XCTAssertEqual(try rawBytes("keep.txt"), Data(crlf.utf8),
                       "createFile must write exactly the UTF-8 bytes of the content")
        let outcome = try service.writeFile(
            "keep.txt", content: loaded.text + "appended\r\n",
            expectedSHA256: FloeDigest.sha256Hex(Data(crlf.utf8)))
        XCTAssertEqual(try rawBytes("keep.txt"), Data((crlf + "appended\r\n").utf8))
        XCTAssertEqual(outcome.sha256, FloeDigest.sha256Hex(try rawBytes("keep.txt")))
    }

    /// A write larger than the cap is refused before anything touches disk,
    /// and the previous file remains intact (recoverable write contract).
    func testOversizeWriteLeavesExistingFileIntact() throws {
        try service.createFile("capped.txt", content: "original\n")
        let oversized = String(repeating: "x", count: 4 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try service.writeFile("capped.txt", content: oversized)) { error in
            XCTAssertEqual(error as? WorkspaceToolError, .tooLarge(limit: 4 * 1024 * 1024))
        }
        XCTAssertEqual(try rawBytes("capped.txt"), Data("original\n".utf8))
        let inventory = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(inventory, ["capped.txt"], "refused write must leave no temp residue")
    }

    /// The path classification the editor bridge consults: same text bytes in
    /// an office extension are still refused, and unknown extensions are
    /// decided by content, never by a silent text coercion.
    func testTextPolicyRefusesTypedNonTextAndBinaryContent() {
        XCTAssertEqual(WorkspaceTextPolicy.decision(forPath: "notes.md", data: Data("# hi".utf8)), .allowed)
        XCTAssertEqual(WorkspaceTextPolicy.decision(forPath: "sheet.xlsx", data: Data("pretend-utf8".utf8)),
                       .refusedNonTextPath(.office))
        XCTAssertEqual(WorkspaceTextPolicy.decision(forPath: "mystery", data: Data([0x00, 0x01])),
                       .refusedBinaryContent)
        XCTAssertTrue(WorkspaceTextPolicy.isTextualPath("Makefile"))
        XCTAssertFalse(WorkspaceTextPolicy.isTextualPath("photo.png"))
    }
}

private extension String {
    var sha256ForTest: String { FloeDigest.sha256Hex(Data(self.utf8)) }
}

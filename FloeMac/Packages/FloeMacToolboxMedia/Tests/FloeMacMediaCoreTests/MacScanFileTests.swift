import XCTest
@testable import FloeMacMediaCore
import FloeToolboxUtilities

final class MacScanFileTests: XCTestCase {
    private func makePNG() throws -> Data {
        let image = try XCTUnwrap(MacTestFixtures.colorImage(width: 32, height: 24))
        return try MacTestFixtures.pngData(for: image)
    }

    // MARK: - Reader

    func testReaderAcceptsRegularFile() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("page.png")
        let data = try makePNG()
        try data.write(to: url)
        XCTAssertEqual(try MacFileImageReader.readImageData(at: url), data)
    }

    func testReaderRejectsDirectoryAndSymlink() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try MacFileImageReader.readImageData(at: directory)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .fileNotRegular)
        }
        let target = directory.appendingPathComponent("target.png")
        try makePNG().write(to: target)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MacFileImageReader.readImageData(at: link)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .fileIsSymbolicLink)
        }
    }

    func testReaderEnforcesSizeAndEmptyFile() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 100).write(to: url)
        XCTAssertThrowsError(try MacFileImageReader.readImageData(at: url, maximumBytes: 8)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .fileTooLarge)
        }
        let empty = directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertThrowsError(try MacFileImageReader.readImageData(at: empty)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .unreadable)
        }
    }

    func testReaderRefusesSelectionReplacedAfterOpening() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("selected.png")
        let original = directory.appendingPathComponent("original.png")
        let replacement = directory.appendingPathComponent("other.png")
        try makePNG().write(to: selected)
        try Data("other".utf8).write(to: replacement)
        XCTAssertThrowsError(try MacFileImageReader.readImageData(at: selected, afterOpen: {
            try FileManager.default.moveItem(at: selected, to: original)
            try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: replacement)
        })) { error in
            XCTAssertEqual(error as? MacMediaFailure, .unreadable)
        }
    }

    // MARK: - Writer

    func testWriterWritesExactBytesWithPrivatePermissions() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.pdf")
        let data = Data("pdf-bytes".utf8)
        try MacSafeFileWriter.write(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWriterRejectsSymlinkDestination() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        try Data("old".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data("new".utf8), to: link)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .writeFailed("destination-symbolic-link"))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testWriterRejectsMissingParentAndEmptyPayload() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("nested/export.txt")
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data("x".utf8), to: missing)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .writeFailed("parent-missing"))
        }
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data(), to: directory.appendingPathComponent("x.txt"))) { error in
            XCTAssertEqual(error as? MacMediaFailure, .emptyExport)
        }
    }

    func testWriterRejectsOversizedPayload() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(count: MacSafeFileWriter.maximumBytes + 1)
        let url = directory.appendingPathComponent("oversize.bin")
        XCTAssertThrowsError(try MacSafeFileWriter.write(data, to: url)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .exportTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterPreservesExistingDestination() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: destination)
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data("replacement".utf8), to: destination)) { error in
            XCTAssertEqual(error as? MacMediaFailure, .writeFailed("destination-exists"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testWriterPrecommitFailuresLeaveNoOutputOrStaging() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for injected in [MacSafeFileWriter.Checkpoint.staged, .verified, .beforeCommit] {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try MacSafeFileWriter.write(Data("data".utf8), to: destination, checkpoint: { checkpoint in
                if checkpoint == injected { throw MacMediaFailure.writeFailed("injected") }
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testWriterDoesNotOverwriteDestinationCreatedAtCommit() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("raced.txt")
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data("ours".utf8), to: destination, checkpoint: { checkpoint in
            if checkpoint == .beforeCommit { try Data("other writer".utf8).write(to: destination) }
        })) { error in
            XCTAssertEqual(error as? MacMediaFailure, .writeFailed("destination-exists"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("other writer".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["raced.txt"])
    }

    func testWriterRejectsSymlinkCreatedAtCommit() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("link.txt")
        let target = directory.appendingPathComponent("target.txt")
        try Data("original".utf8).write(to: target)
        XCTAssertThrowsError(try MacSafeFileWriter.write(Data("ours".utf8), to: destination, checkpoint: { checkpoint in
            if checkpoint == .beforeCommit {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            }
        })) { error in
            XCTAssertEqual(error as? MacMediaFailure, .writeFailed("destination-symbolic-link"))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }

    func testCancellationBeforeCommitDoesNotPublish() async throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.txt")
        let task = Task {
            try MacSafeFileWriter.write(Data("unpublished".utf8), to: destination, checkpoint: { checkpoint in
                if checkpoint == .beforeCommit { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do {
            try await task.value
            XCTFail("cancelled export unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation wins before the publish step.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testArtifactWriterMatchesDataWriter() throws {
        let directory = try MacTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = MacExportArtifact(format: .txt, data: Data("hello".utf8),
                                          suggestedFilename: "floe-scan-x.txt")
        let url = directory.appendingPathComponent("artifact.txt")
        try MacSafeFileWriter.write(artifact, to: url)
        XCTAssertEqual(try Data(contentsOf: url), artifact.data)
    }

    // MARK: - Naming

    func testSuggestedNamesAreDeterministicAndFormatted() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(MacExportNaming.suggestedName(format: .png, date: date, timeZone: utc),
                       "floe-scan-20260102-030405.png")
        XCTAssertEqual(MacExportNaming.suggestedName(format: .pdf, prefix: "floe-sound", date: date, timeZone: utc),
                       "floe-sound-20260102-030405.pdf")
        XCTAssertEqual(MacExportNaming.suggestedName(format: .csv, date: date, timeZone: utc),
                       "floe-scan-20260102-030405.csv")
    }
}

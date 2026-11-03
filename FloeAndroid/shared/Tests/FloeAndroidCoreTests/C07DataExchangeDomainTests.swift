// SPDX-License-Identifier: MPL-2.0
//
// C07 production-adapter contract tests that do not need a live App root:
// exclusive no-overwrite project writes, hash readback, ownership-name
// sanitization and the trusted owner shape. The live composition/DB path is
// exercised by Main after all C01-C08 source closes.
import XCTest
import Foundation
import Crypto
import FloeAndroidDataExchange
@testable import FloeAndroidCore

final class C07DataExchangeDomainTests: XCTestCase {
    private final class Root {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("c07-domain-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func file(_ name: String, _ data: Data) throws -> URL {
            let target = url.appendingPathComponent(name)
            try data.write(to: target)
            return target
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testExclusiveWriteVerifiesAndRefusesOverwrite() throws {
        let root = try Root()
        let data = Data("project bytes".utf8)
        let source = try root.file("source.bin", data)
        let destination = root.url.appendingPathComponent("project/a.txt")
        XCTAssertThrowsError(
            try C07POSIX.writeExclusive(
                source: source, destination: destination,
                expectedBytes: Int64(data.count), expectedSHA256: digest(data))
        ) // parent missing: no implicit project directory is created
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try C07POSIX.writeExclusive(
            source: source, destination: destination,
            expectedBytes: Int64(data.count), expectedSHA256: digest(data))
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertThrowsError(
            try C07POSIX.writeExclusive(
                source: source, destination: destination,
                expectedBytes: Int64(data.count), expectedSHA256: digest(data))
        ) { error in
            guard case C07DataExchangeError.storageUnavailable = error else {
                return XCTFail("expected exclusive-create refusal, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testHashMismatchLeavesNoDestinationFile() throws {
        let root = try Root()
        let data = Data("tamper".utf8)
        let source = try root.file("source.bin", data)
        let destination = root.url.appendingPathComponent("a.txt")
        XCTAssertThrowsError(
            try C07POSIX.writeExclusive(
                source: source, destination: destination,
                expectedBytes: Int64(data.count),
                expectedSHA256: String(repeating: "0", count: 64))
        ) { error in
            guard case C07DataExchangeError.hashMismatch = error else {
                return XCTFail("expected hashMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testProjectWriteRefusesSymlinkedDestinationAncestor() throws {
        let root = try Root()
        let outside = root.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        let victim = try root.file("outside/victim.txt", Data("victim".utf8))
        let project = root.url.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("linked"),
            withDestinationURL: outside)
        let data = Data("project bytes".utf8)
        let source = try root.file("source.bin", data)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: source.deletingLastPathComponent(),
                sourceRelativePath: source.lastPathComponent,
                destinationRoot: project,
                destinationRelativePath: "linked/victim.txt",
                expectedSize: Int64(data.count))) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))
    }

    func testProjectWriteCreatesOwnedDirectoriesUnderRoot() throws {
        let root = try Root()
        let data = Data("nested project bytes".utf8)
        let source = try root.file("source.bin", data)
        let project = root.url.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project)
        try C07POSIX.writeExclusive(
            sourceRoot: source.deletingLastPathComponent(),
            sourceRelativePath: source.lastPathComponent,
            destinationRoot: project,
            destinationRelativePath: "a/b/c.txt",
            expectedBytes: Int64(data.count),
            expectedSHA256: digest(data),
            createDestinationParents: true)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(
            "a/b/c.txt")), data)
        let values = try project.appendingPathComponent("a/b")
            .resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        XCTAssertTrue(values.isDirectory == true)
        XCTAssertTrue(values.isSymbolicLink != true)
    }

    func testProjectNameSanitizationPreservesAUsefulName() {
        XCTAssertEqual(
            C07LiveRestoreSink.safeProjectName("  Docs / 2026 \\ final  "),
            "Docs - 2026 - final")
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(C07LiveRestoreSink.safeProjectName(long).count, 80)
        XCTAssertEqual(C07LiveRestoreSink.safeProjectName("   "), "Restored project")
    }

    func testOwnerTokenIsBoundedAndASCII() throws {
        let valid = try C07ExchangeOwner(token: String(repeating: "a", count: 32),
                                         nativeEpoch: 7)
        XCTAssertEqual(valid.nativeEpoch, 7)
        XCTAssertThrowsError(try C07ExchangeOwner(token: "short", nativeEpoch: 7))
        XCTAssertThrowsError(try C07ExchangeOwner(
            token: String(repeating: "é", count: 16), nativeEpoch: 7))
        XCTAssertThrowsError(try C07ExchangeOwner(
            token: String(repeating: "a", count: 32), nativeEpoch: 0))
    }
}

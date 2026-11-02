// SPDX-License-Identifier: MPL-2.0
//
// C07 descriptor-safe streaming I/O regressions.
//
// These run on the host against real temporary directories: leaf/ancestor
// symlink swaps on BOTH sides, duplicate/collision, changed/oversize/
// unreadable sources, cancellation cleanup, secret/root escape and exact
// user-content fidelity. A refusal must leave every pre-existing byte
// untouched and must never create the destination.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidDataExchange

final class C07RootedFileIOTests: XCTestCase {
    private final class Roots {
        let root: URL
        let source: URL
        let destination: URL
        let outside: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("c07-rooted-\(UUID().uuidString)",
                                        isDirectory: true)
            source = root.appendingPathComponent("src", isDirectory: true)
            destination = root.appendingPathComponent("dst", isDirectory: true)
            outside = root.appendingPathComponent("outside", isDirectory: true)
            for url in [root, source, destination, outside] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ root: URL, _ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
    }

    /// Thread-safe call counter for the `@Sendable` cancellation hooks below.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let payload = Data(
        "user content with uuid-like text 550E8400-E29B-41D4-A716-446655440000 "
            .utf8)
        + Data([0x00, 0xFF, 0x10])
        + Data(" 和 emoji 🚀".utf8)

    func testVerifiedCopyRoundTripsExactBytes() throws {
        let roots = try Roots()
        let data = payload
        try roots.file(roots.source, "a/b/payload.bin", data)
        let result = try C07FileSystem.copyVerified(
            sourceRoot: roots.source,
            sourceRelativePath: "a/b/payload.bin",
            destinationRoot: roots.destination,
            destinationRelativePath: "x/y/payload.bin")
        XCTAssertEqual(result.byteCount, Int64(data.count))
        XCTAssertEqual(result.sha256, digest(data))
        XCTAssertEqual(
            try Data(contentsOf: roots.destination.appendingPathComponent(
                "x/y/payload.bin")), data)
    }

    func testSourceLeafSymlinkIsRefusedAndTouchesNothing() throws {
        let roots = try Roots()
        let secret = try roots.file(roots.outside, "secret.txt", payload)
        let link = roots.source.appendingPathComponent("decoy")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: secret)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "decoy",
                destinationRoot: roots.destination,
                destinationRelativePath: "out.bin")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("out.bin").path))
        XCTAssertEqual(try Data(contentsOf: secret), payload)
    }

    func testSourceAncestorSymlinkIsRefusedAndTouchesNothing() throws {
        let roots = try Roots()
        try roots.file(roots.outside, "real/file.txt", payload)
        let link = roots.source.appendingPathComponent("planted")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: roots.outside)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "planted/real/file.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "file.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("file.txt").path))
    }

    func testDestinationAncestorSymlinkIsRefusedAndWritesNowhere() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        try roots.file(roots.outside, "victim.txt", Data("keep".utf8))
        let link = roots.destination.appendingPathComponent("planted")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: roots.outside)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "planted/victim.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: roots.outside.appendingPathComponent("victim.txt")),
            Data("keep".utf8))
    }

    func testDestinationLeafSymlinkIsRefusedAndPreservesTarget() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let target = try roots.file(roots.destination, "target.txt",
                                    Data("original".utf8))
        let link = roots.destination.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "link.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }

    func testExistingDestinationIsRefusedAndPreserved() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let existing = try roots.file(
            roots.destination, "exists.txt", Data("do not overwrite".utf8))
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "exists.txt")) { error in
            guard case C07DataExchangeError.storageUnavailable = error else {
                return XCTFail("expected exclusive-create refusal, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: existing),
                       Data("do not overwrite".utf8))
    }

    func testSizeMismatchAndOversizeAreRefused() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "a.txt",
                expectedSize: Int64(payload.count + 1))) { error in
            guard case C07DataExchangeError.sizeMismatch = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "b.txt",
                maximum: Int64(payload.count - 1))) { error in
            guard case C07DataExchangeError.entryTooLarge = error else {
                return XCTFail("expected entryTooLarge, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("b.txt").path))
    }

    func testDirectorySourceIsRefused() throws {
        let roots = try Roots()
        try roots.file(roots.source, "dir/inner.txt", payload)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "dir",
                destinationRoot: roots.destination,
                destinationRelativePath: "dir-copy")) { error in
            guard case C07DataExchangeError.specialFileUnsupported = error else {
                return XCTFail("expected specialFileUnsupported, got \(error)")
            }
        }
    }

    func testUnreadableSourceFailsClosedWithoutDestination() throws {
        let roots = try Roots()
        let url = try roots.file(roots.source, "locked.txt", payload)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "locked.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "locked.txt")) { error in
            guard case C07DataExchangeError.storageUnavailable = error else {
                return XCTFail("expected storageUnavailable, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("locked.txt").path))
    }

    func testCancellationRemovesOnlyThePartialDestination() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "cancelled.txt",
                shouldCancel: { true })) { error in
            guard case C07DataExchangeError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("cancelled.txt").path))
    }

    func testRootEscapePathsAreRefused() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        for bad in ["../escape.txt", "a/../../escape.txt", "/absolute.txt",
                    "a//b.txt", "a/./b.txt"] {
            XCTAssertThrowsError(
                try C07FileSystem.copyVerified(
                    sourceRoot: roots.source,
                    sourceRelativePath: bad,
                    destinationRoot: roots.destination,
                    destinationRelativePath: "x.txt"),
                "expected refusal for \(bad)") { error in
                guard case C07DataExchangeError.unsafePath = error else {
                    return XCTFail("expected unsafePath for \(bad), got \(error)")
                }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: roots.destination.path), [])
    }

    func testLegitimateRootAliasIsCanonicalizedNotFollowedAsAuthorization() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        // /var is the legitimate Darwin alias of /private/var; passing the
        // aliased spelling must canonicalize to the same owned root and
        // succeed, while a symlink INSIDE the tree is still refused.
        let resolved = roots.source.resolvingSymlinksInPath().path
        let aliased = resolved.hasPrefix("/private/")
            ? String(resolved.dropFirst("/private".count))
            : resolved
        let result = try C07FileSystem.copyVerified(
            sourceRoot: URL(fileURLWithPath: aliased, isDirectory: true),
            sourceRelativePath: "in.txt",
            destinationRoot: roots.destination,
            destinationRelativePath: "alias.txt")
        XCTAssertEqual(result.sha256, digest(payload))
    }

    func testWriteFileIsExclusiveAndVerifiesDigest() throws {
        let roots = try Roots()
        let written = try C07RootedFileIO.writeFile(
            payload, destinationRoot: roots.destination,
            destinationRelativePath: "w.txt", mode: 0o444)
        XCTAssertEqual(written.sha256, digest(payload))
        XCTAssertThrowsError(
            try C07RootedFileIO.writeFile(
                payload, destinationRoot: roots.destination,
                destinationRelativePath: "w.txt", mode: 0o444)) { error in
            guard case C07DataExchangeError.storageUnavailable = error else {
                return XCTFail("expected exclusive-create refusal, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try C07RootedFileIO.writeFile(
                payload, destinationRoot: roots.destination,
                destinationRelativePath: "w2.txt",
                expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case C07DataExchangeError.hashMismatch = error else {
                return XCTFail("expected hashMismatch, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent("w2.txt").path))
        let values = try roots.destination.appendingPathComponent("w.txt")
            .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertTrue(values.isRegularFile == true)
        XCTAssertTrue(values.isSymbolicLink != true)
    }

    func testCopyPreservesArbitraryUserContentByteForByte() throws {
        let roots = try Roots()
        // Content that looks like an identity must NOT be rewritten: this is
        // a byte stream, not an identity column.
        let tricky = Data(
            #"{"id":"550e8400-e29b-41d4-a716-446655440000","note":".."}"#
                .utf8)
        try roots.file(roots.source, "tricky.json", tricky)
        let result = try C07FileSystem.copyVerified(
            sourceRoot: roots.source,
            sourceRelativePath: "tricky.json",
            destinationRoot: roots.destination,
            destinationRelativePath: "tricky.json")
        XCTAssertEqual(result.sha256, digest(tricky))
        XCTAssertEqual(try Data(contentsOf: roots.destination
            .appendingPathComponent("tricky.json")), tricky)
    }

    // MARK: - Root admission and anchored ancestor mutation

    func testPlantedRootSymlinkIsRefusedInsteadOfAdoptingItsTarget() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let plantedSource = roots.root.appendingPathComponent(
            "planted-source", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: plantedSource, withDestinationURL: roots.source)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: plantedSource,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "from-linked-root.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent(
                "from-linked-root.txt").path))

        let plantedDestination = roots.root.appendingPathComponent(
            "planted-destination", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: plantedDestination, withDestinationURL: roots.destination)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: plantedDestination,
                destinationRelativePath: "to-linked-root.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.destination.appendingPathComponent(
                "to-linked-root.txt").path))
    }

    func testRootAncestorSymlinkIsRefusedWithoutResolvingToItsTarget() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let realParent = roots.root.appendingPathComponent(
            "real-parent", isDirectory: true)
        let realRoot = realParent.appendingPathComponent(
            "destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realRoot, withIntermediateDirectories: true)
        let linkedParent = roots.root.appendingPathComponent(
            "linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent, withDestinationURL: realParent)
        let rootThroughLink = linkedParent.appendingPathComponent(
            "destination", isDirectory: true)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: rootThroughLink,
                destinationRelativePath: "escaped.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: realRoot.appendingPathComponent("escaped.txt").path))
    }

    func testRootSwapToSymlinkIsRefusedWithoutOutsideCreation() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        try roots.file(roots.outside, "keep.txt", Data("keep".utf8))
        let movedRoot = roots.root.appendingPathComponent(
            "moved-destination", isDirectory: true)
        try FileManager.default.moveItem(at: roots.destination, to: movedRoot)
        try FileManager.default.createSymbolicLink(
            at: roots.destination, withDestinationURL: roots.outside)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "a/b/out.txt")) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: roots.outside.path),
            ["keep.txt"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: movedRoot.appendingPathComponent("a").path))
    }

    func testAncestorSymlinkCannotMakeDirectoryCreationLeaveTheRoot() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let existing = roots.destination.appendingPathComponent(
            "a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing, withIntermediateDirectories: true)
        let outsideDirectory = roots.outside.appendingPathComponent(
            "created", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: existing.appendingPathComponent("b"),
            withDestinationURL: outsideDirectory)
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "a/b/c/file.txt",
                createDestinationParents: true)) { error in
            guard case C07DataExchangeError.symlinkUnsupported = error else {
                return XCTFail("expected symlinkUnsupported, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.outside.appendingPathComponent("c").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: existing.appendingPathComponent("b/c").path))
    }

    func testRootSwapDuringStreamKeepsHeldDescriptorsAndWritesNothingOutside() throws {
        let roots = try Roots()
        let data = payload
        try roots.file(roots.source, "in.txt", data)
        let sourceRoot = roots.source
        let outsideRoot = roots.outside
        let displacedSource = roots.root.appendingPathComponent(
            "source-displaced", isDirectory: true)
        let swaps = Counter()
        let result = try C07FileSystem.copyVerified(
            sourceRoot: sourceRoot,
            sourceRelativePath: "in.txt",
            destinationRoot: roots.destination,
            destinationRelativePath: "held.txt",
            shouldCancel: {
                if swaps.next() == 1 {
                    let manager = FileManager()
                    _ = try? manager.moveItem(
                        at: sourceRoot, to: displacedSource)
                    _ = try? manager.createSymbolicLink(
                        at: sourceRoot, withDestinationURL: outsideRoot)
                }
                return false
            })
        XCTAssertEqual(result.sha256, digest(data))
        XCTAssertEqual(
            try Data(contentsOf: roots.destination.appendingPathComponent(
                "held.txt")), data)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: displacedSource.appendingPathComponent("in.txt").path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: outsideRoot.path), [])
    }

    // MARK: - Destination identity and source lifetime

    func testFailureCleanupPreservesAReplacementAtTheDestinationName() throws {
        let roots = try Roots()
        try roots.file(roots.source, "in.txt", payload)
        let destination = roots.destination.appendingPathComponent(
            "replace-me.txt")
        let replacement = Data("someone else's file".utf8)
        let replacements = Counter()
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "in.txt",
                destinationRoot: roots.destination,
                destinationRelativePath: "replace-me.txt",
                shouldCancel: {
                    if replacements.next() == 1 {
                        let manager = FileManager()
                        _ = try? manager.removeItem(at: destination)
                        _ = try? replacement.write(to: destination)
                    }
                    return true
                })) { error in
            guard case C07DataExchangeError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    func testSourceChangedDuringStreamFailsAndRemovesOnlyItsDestination() throws {
        let roots = try Roots()
        let original = Data(
            repeating: 0x41,
            count: C07DataExchangeLimits.copyChunkBytes * 2 + 17)
        let source = try roots.file(roots.source, "changing.bin", original)
        let sibling = try roots.file(
            roots.destination, "sibling.txt", Data("keep".utf8))
        let destination = roots.destination.appendingPathComponent(
            "changed.bin")
        let reads = Counter()
        XCTAssertThrowsError(
            try C07FileSystem.copyVerified(
                sourceRoot: roots.source,
                sourceRelativePath: "changing.bin",
                destinationRoot: roots.destination,
                destinationRelativePath: "changed.bin",
                shouldCancel: {
                    if reads.next() == 2 {
                        if let handle = try? FileHandle(forWritingTo: source) {
                            _ = try? handle.seekToEnd()
                            try? handle.write(contentsOf: Data([0x42]))
                            try? handle.close()
                        }
                    }
                    return false
                })) { error in
            guard case C07DataExchangeError.storageUnavailable = error else {
                return XCTFail("expected sourceChanged refusal, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
    }
}

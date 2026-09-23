// FloeWorkspaceTests — native archive engine contracts.
//
// These tests exercise the real engine (no guest, no stub codec): every
// container format round-trips, the platform `tar`/`gzip`/`bzip2`/`xz` tools
// read what we write and we read what they write, and the shared safety policy
// holds for traversal names, symlink escapes, self-inclusion, overwrite
// refusal and cancellation.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeTools

@Suite("FloeWorkspace.ArchiveEngine")
struct ArchiveEngineTests {

    // MARK: - fixtures

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let cancel = CancellationToken()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-archive-engine-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        func url(_ relative: String) -> URL {
            root.appendingPathComponent(relative)
        }

        func service() -> ArchiveBrowserService {
            ArchiveBrowserService(rootProvider: { [root] in root })
        }

        /// Runs a command; returns (status, stdout+stderr).
        @discardableResult
        func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        static func toolPath(_ name: String) -> String? {
            for candidate in ["/usr/bin/\(name)", "/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }

        /// Creates a realistic tree: nested files, an empty directory and a
        /// symlink, plus non-ASCII names.
        func makeTree() throws {
            try write("project/readme.txt", "hello archive")
            try write("project/notes/中文 说明.md", "中文内容")
            try write("project/notes/deep/data.bin", String(repeating: "0123456789", count: 64))
            try FileManager.default.createDirectory(at: url("project/empty dir"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: url("project/readme.link").path,
                withDestinationPath: "readme.txt"
            )
        }
    }

    // MARK: - round trips

    @Test("Every container format round-trips files, empty dirs, links and Chinese names", arguments: ["zip", "tar", "tgz", "tbz2", "txz"])
    func containerRoundTrip(format: String) async throws {
        let f = try Fixture()
        try f.makeTree()
        let engine = ArchiveEngine.self
        let destination = f.url("pack.\(format == "tgz" ? "tar.gz" : format == "tbz2" ? "tar.bz2" : format == "txz" ? "tar.xz" : format)")

        let progressEvents = Counter()
        let summary = try engine.create(
            format: format,
            sources: [f.url("project")],
            destination: destination,
            progress: { _ in progressEvents.increment() },
            cancellation: f.cancel
        )
        #expect(summary.entries == 3, "summary was: \(summary.line(source: "project", destination: nil))")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(progressEvents.value > 0)

        // list through the engine
        let listing = try engine.list(format: format, source: destination, cancellation: f.cancel)
        let paths = listing.entries.map(\.path)
        #expect(paths.contains { $0.hasSuffix("project/readme.txt") })
        #expect(paths.contains { $0.hasSuffix("project/notes/中文 说明.md") })
        #expect(paths.contains { $0.hasSuffix("project/empty dir/") || $0.hasSuffix("project/empty dir") })
        #expect(listing.entries.contains { $0.isDirectory })
        #expect(!listing.truncated)

        let extractDestination = f.url("out-\(format)")
        let extracted = try engine.extract(format: format, source: destination, destination: extractDestination, cancellation: f.cancel)
        #expect(extracted.entries == 3)
        #expect(try f.read("out-\(format)/project/notes/中文 说明.md") == "中文内容")
        #expect(try f.read("out-\(format)/project/readme.txt") == "hello archive")
        // Empty directory survives the round trip.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: f.url("out-\(format)/project/empty dir").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.url("out-\(format)/project/empty dir").path).isEmpty)
        // Symlink is preserved with its target (not dereferenced).
        if format == "zip" {
            // ZIPFoundation records symlinks only on Unix-made entries; the
            // engine reports what it preserved either way.
            #expect(extracted.linksPreserved + extracted.skipped >= 1)
        } else {
            #expect(extracted.linksPreserved == 1, "links=\(extracted.linksPreserved) summary=\(extracted)")
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: f.url("out-\(format)/project/readme.link").path)
            #expect(target == "readme.txt")
        }
    }

    @Test("System tar reads our compressed tar output and we read system tar output", arguments: ["tgz", "tbz2", "txz"])
    func tarInterop(format: String) async throws {
        let f = try Fixture()
        try f.write("interop/a.txt", "alpha")
        try f.makeTree()
        let tar = try #require(Fixture.toolPath("tar"))
        let engine = ArchiveEngine.self
        let name = format == "tgz" ? "ours.tar.gz" : (format == "tbz2" ? "ours.tar.bz2" : "ours.tar.xz")
        let ours = f.url(name)
        _ = try engine.create(format: format, sources: [f.url("interop")], destination: ours, cancellation: f.cancel)

        let flag = format == "tgz" ? "-tzf" : (format == "tbz2" ? "-tjf" : "-tJf")
        let (status, listing) = try f.run(tar, [flag, ours.path])
        #expect(status == 0, "system tar failed: \(listing)")
        #expect(listing.contains("interop/a.txt"), "listing was: \(listing)")

        // System-created archive -> our reader.
        let source = f.url("system")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try f.write("system/b.txt", "beta")
        let createFlag = format == "tgz" ? "-czf" : (format == "tbz2" ? "-cjf" : "-cJf")
        let systemArchive = f.url("system-\(format).tar")
        let (createStatus, createOutput) = try f.run(tar, [createFlag, systemArchive.path, "-C", source.path, "."])
        #expect(createStatus == 0, "\(createOutput)")
        let listing2 = try engine.list(format: format, source: systemArchive, cancellation: f.cancel)
        #expect(listing2.entries.contains { $0.path.contains("b.txt") })
        let out = f.url("system-out-\(format)")
        let extracted = try engine.extract(format: format, source: systemArchive, destination: out, cancellation: f.cancel)
        #expect(extracted.entries >= 1)
        #expect(try f.read("system-out-\(format)/b.txt") == "beta")
    }

    @Test("Single-file gzip/bzip2/xz round-trip and interoperate with the platform tools")
    func singleFileInterop() async throws {
        let f = try Fixture()
        let payload = String(repeating: "floe compression payload 中文 ", count: 200)
        try f.write("blob.txt", payload)
        let engine = ArchiveEngine.self
        for (format, cli) in [("gz", "gzip"), ("bz2", "bzip2"), ("xz", "xz")] {
            let archive = f.url("blob.txt.\(format)")
            let created = try engine.create(format: format, sources: [f.url("blob.txt")], destination: archive, cancellation: f.cancel)
            #expect(created.entries == 1)
            #expect(created.uncompressedBytes == Int64(payload.utf8.count))

            // Decompress with our engine and compare.
            let restored = f.url("restored-\(format).txt")
            _ = try engine.decompress(format: format, source: archive, destination: restored, cancellation: f.cancel)
            #expect(try f.read("restored-\(format).txt") == payload)

            // The platform tool must read our archive.
            if let tool = Fixture.toolPath(cli) {
                let decompressedFlag = cli == "gzip" ? "-dc" : (cli == "bzip2" ? "-dc" : "-dc")
                let (status, output) = try f.run(tool, [decompressedFlag, archive.path])
                #expect(status == 0, "\(cli) failed on our archive: \(output)")
                #expect(output == payload, "\(cli) output mismatch")
            }

            // ... and we must read the platform tool's archive.
            if let tool = Fixture.toolPath(cli) {
                let systemArchive = f.url("system.\(format)")
                let (status, shellOutput) = try f.run(
                    "/bin/sh",
                    ["-c", "'\(tool)' -c '\(f.url("blob.txt").path)' > '\(systemArchive.path)'"]
                )
                #expect(status == 0, "\(cli) system compress failed: \(shellOutput)")
                let roundTrip = f.url("system-restored-\(format).txt")
                _ = try engine.decompress(format: format, source: systemArchive, destination: roundTrip, cancellation: f.cancel)
                #expect(try f.read("system-restored-\(format).txt") == payload)
            }
        }
    }

    // MARK: - safety and policy

    @Test("Traversal and absolute entries are skipped, links escaping the root are refused")
    func hostileEntries() async throws {
        let f = try Fixture()
        // Hand-build a tar with hostile names (the writer does not sanitize;
        // the extractor must).
        let buffer = DataByteSink()
        var writer = TarStreamWriter(sink: buffer)
        try writer.addFile(name: "../evil.txt", size: 4, mode: 0o644, mtime: Date()) { _ in } from: { DataByteSource(Data("evil".utf8)) }
        try writer.addFile(name: "ok/safe.txt", size: 4, mode: 0o644, mtime: Date()) { _ in } from: { DataByteSource(Data("safe".utf8)) }
        try writer.addSymlink(name: "escape.link", target: "../../outside", mode: 0o777, mtime: Date())
        try writer.finish()
        let hostile = f.url("hostile.tar")
        try buffer.data.write(to: hostile)

        let summary = try ArchiveEngine.extract(format: "tar", source: hostile, destination: f.url("safe-out"), cancellation: f.cancel)
        #expect(summary.entries == 1)
        #expect(summary.skipped >= 2)
        #expect(summary.linksSkipped == 1)
        #expect(try f.read("safe-out/ok/safe.txt") == "safe")
        #expect(!f.exists("evil.txt"))
        #expect(!f.exists("escape.link"))
        #expect(!f.exists("safe-out/escape.link"))
    }

    @Test("Creating an archive inside its own source is refused")
    func selfInclusion() throws {
        let f = try Fixture()
        try f.write("project/a.txt", "a")
        let destination = f.url("project/pack.zip")
        #expect(throws: ArchiveEngineError.self) {
            _ = try ArchiveEngine.create(
                format: "zip",
                sources: [f.url("project")],
                destination: destination,
                cancellation: f.cancel
            )
        }
        #expect(!f.exists("project/pack.zip"))
    }

    @Test("Existing destinations are never overwritten and staging leaves no partial output")
    func neverOverwrites() throws {
        let f = try Fixture()
        try f.write("a.txt", "a")
        try f.write("pack.zip", "already here")
        #expect(throws: ArchiveEngineError.self) {
            _ = try ArchiveEngine.create(format: "zip", sources: [f.url("a.txt")], destination: f.url("pack.zip"), cancellation: f.cancel)
        }
        #expect(try f.read("pack.zip") == "already here")
        // No staging leftovers.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
            .filter { $0.hasPrefix(".floe-archive-") }
        #expect(leftovers.isEmpty, "leftovers: \(leftovers)")
    }

    @Test("A cancelled operation throws and leaves no destination")
    func cancellation() throws {
        let f = try Fixture()
        try f.write("big/one.bin", String(repeating: "x", count: 512 * 1024))
        try f.write("big/two.bin", String(repeating: "y", count: 512 * 1024))
        let token = CancellationToken()
        token.cancel()
        #expect(throws: FloeError.self) {
            _ = try ArchiveEngine.create(format: "tgz", sources: [f.url("big")], destination: f.url("big.tar.gz"), cancellation: token)
        }
        #expect(!f.exists("big.tar.gz"))
    }

    @Test("Metadata the format cannot carry is reported, not dropped")
    func metadataHonesty() throws {
        let f = try Fixture()
        try f.write("m/a.txt", "a")
        let zip = try ArchiveEngine.create(format: "zip", sources: [f.url("m")], destination: f.url("m.zip"), cancellation: f.cancel)
        #expect(zip.metadataNotices.contains { $0.contains("uidGidNotPreserved") })
        let tar = try ArchiveEngine.create(format: "tar", sources: [f.url("m")], destination: f.url("m.tar"), cancellation: f.cancel)
        #expect(tar.metadataNotices.contains { $0.contains("uidGidNotPreserved") })
        #expect(tar.metadataNotices.contains { $0.contains("xattrsACLsNotCarried") })
    }

    @Test("A pathological archive is refused instead of buffering without bound")
    func boundedBzip2() throws {
        let f = try Fixture()
        try f.write("fake.bz2", String(repeating: "not bzip2", count: 1024))
        var tiny = ArchiveLimits()
        tiny.oneShotBufferLimit = 128
        #expect(throws: ArchiveEngineError.self) {
            _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("fake.bz2"), destination: f.url("out.bin"), limits: tiny, cancellation: f.cancel)
        }
    }

    /// Thread-safe counter for progress callbacks.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test("AppleDouble sidecars never enter an archive")
    func appleDoubleSkipped() throws {
        // The policy is enforced at the name level (extraction and any
        // create path that receives such a name) and Foundation's own
        // enumeration already hides `._*` entries on Darwin.
        #expect(try ArchiveEngine.safeEntryName("mixed/._a.txt", isDirectory: false) == nil)
        #expect(try ArchiveEngine.safeEntryName("._a.txt", isDirectory: false) == nil)

        let f = try Fixture()
        try f.write("mixed/a.txt", "a")
        try Data("resource fork noise".utf8).write(to: f.url("mixed/._a.txt"))
        let summary = try ArchiveEngine.create(
            format: "zip",
            sources: [f.url("mixed")],
            destination: f.url("mixed.zip"),
            cancellation: f.cancel
        )
        #expect(summary.entries == 1, "summary was: \(summary.line(source: "mixed", destination: nil))")
        let listing = try ArchiveEngine.list(format: "zip", source: f.url("mixed.zip"), cancellation: f.cancel)
        #expect(!listing.entries.contains { $0.path.contains("._a.txt") })
        #expect(listing.entries.contains { $0.path == "mixed/a.txt" })
    }

    @Test("Multi-select compression defaults to zip and packs every selected item")
    func multiSelectCreate() throws {
        let f = try Fixture()
        try f.write("one/a.txt", "a")
        try f.write("two/b.txt", "b")
        let destination = f.url("bundle.zip")
        let summary = try ArchiveEngine.create(
            format: "zip",
            sources: [f.url("one"), f.url("two")],
            destination: destination,
            cancellation: f.cancel
        )
        #expect(summary.entries == 2)
        let listing = try ArchiveEngine.list(format: "zip", source: destination, cancellation: f.cancel)
        let paths = Set(listing.entries.map(\.path))
        #expect(paths.contains("one/a.txt"))
        #expect(paths.contains("two/b.txt"))
    }
}

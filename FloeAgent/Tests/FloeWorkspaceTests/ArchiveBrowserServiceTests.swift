// FloeWorkspaceTests — archive browser contract.
//
// The browser must list zip/tar/7z without a Linux runtime, refuse formats
// that need one with a truthful reason, keep bounded extraction and reject
// traversal entries, and parse the shared listing format the IDE sidebar
// renders. Everything runs against the real, native archive services.

import Foundation
import Testing
import ZIPFoundation
@testable import FloeWorkspace
import FloeCore
import FloeTools

@Suite("FloeWorkspace.ArchiveBrowser")
struct ArchiveBrowserServiceTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let cancel = CancellationToken()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-archive-browser-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var service: ArchiveBrowserService {
            ArchiveBrowserService(rootProvider: { [root] in root })
        }

        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func makeZip(named relative: String, entries: [(String, String)]) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let archive = try #require(Archive(url: url, accessMode: .create))
            for (name, content) in entries {
                let data = Data(content.utf8)
                try archive.addEntry(
                    with: name,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        data.subdata(in: Int(position)..<Int(position) + size)
                    }
                )
            }
        }
    }

    @Test("A zip lists entries with kinds and sizes before any extraction")
    func listsZipEntries() async throws {
        let f = try Fixture()
        try f.makeZip(named: "docs.zip", entries: [
            ("readme.txt", "hello"),
            ("nested/data.csv", "a,b\n1,2\n")
        ])

        let listing = try await f.service.listing(
            relativePath: "docs.zip", rootURL: f.root, cancellation: f.cancel
        )
        #expect(listing.format == "zip")
        #expect(listing.truncated == false)
        #expect(listing.entries.count == 2)
        let readme = try #require(listing.entries.first { $0.path == "readme.txt" })
        #expect(readme.isDirectory == false)
        #expect(readme.size == 5)
        #expect(listing.entries.contains { $0.path == "nested/data.csv" })
    }

    @Test("Compressed containers browse natively; only RAR and unknown formats report why")
    func unsupportedFormatsAreTruthful() async throws {
        let f = try Fixture()
        try f.write("notes.txt", "x")
        // Build a real tar.gz with the engine, then browse it.
        _ = try ArchiveEngine.create(
            format: "tgz",
            sources: [f.root.appendingPathComponent("notes.txt")],
            destination: f.root.appendingPathComponent("bundle.tar.gz"),
            cancellation: f.cancel
        )
        let listing = try await f.service.listing(relativePath: "bundle.tar.gz", rootURL: f.root, cancellation: f.cancel)
        #expect(listing.format == "tgz")
        #expect(listing.entries.contains { $0.path.hasSuffix("notes.txt") })

        // A single-file archive lists its one logical payload.
        let single = try ArchiveEngine.create(
            format: "gz",
            sources: [f.root.appendingPathComponent("notes.txt")],
            destination: f.root.appendingPathComponent("raw.gz"),
            cancellation: f.cancel
        )
        #expect(single.entries == 1)
        let singleListing = try await f.service.listing(relativePath: "raw.gz", rootURL: f.root, cancellation: f.cancel)
        #expect(singleListing.entries.map(\.path) == ["raw"] || singleListing.entries.count == 1)

        for (name, format) in [("legacy.rar", "rar"), ("mystery", "unknown")] {
            do {
                _ = try await f.service.listing(relativePath: name, rootURL: f.root, cancellation: f.cancel)
                Issue.record("\(name) must not browse")
            } catch let error as ArchiveBrowseError {
                guard case .unsupportedFormat(let reported, let reason) = error else {
                    Issue.record("unexpected error for \(name): \(error)")
                    continue
                }
                #expect(reported == format)
                #expect(!reason.isEmpty)
                if format == "rar" {
                    #expect(reason.contains("signed decoder"), "reason was: \(reason)")
                }
            }
        }
    }

    @Test("Compressed archives extract and decompress through the shared service")
    func compressedExtraction() async throws {
        let f = try Fixture()
        try f.write("src/one.txt", "one")
        try f.write("src/two.txt", "two")
        _ = try ArchiveEngine.create(
            format: "txz",
            sources: [f.root.appendingPathComponent("src")],
            destination: f.root.appendingPathComponent("bundle.tar.xz"),
            cancellation: f.cancel
        )
        let summary = try await f.service.extract(
            relativePath: "bundle.tar.xz", destinationDir: "unpacked", rootURL: f.root, cancellation: f.cancel
        )
        #expect(summary.contains("entries=2"))
        #expect(try String(contentsOf: f.root.appendingPathComponent("unpacked/src/two.txt"), encoding: .utf8) == "two")

        // Single-file decompression writes one new file and never overwrites.
        _ = try ArchiveEngine.create(
            format: "gz",
            sources: [f.root.appendingPathComponent("src/one.txt")],
            destination: f.root.appendingPathComponent("one.txt.gz"),
            cancellation: f.cancel
        )
        let decompressed = try await f.service.decompress(
            relativePath: "one.txt.gz", destinationFile: "one-restored.txt", rootURL: f.root, cancellation: f.cancel
        )
        #expect(decompressed.contains("entries=1"))
        #expect(try String(contentsOf: f.root.appendingPathComponent("one-restored.txt"), encoding: .utf8) == "one")
    }

    @Test("Multi-select compression defaults to zip through the service")
    func multiSelectCompression() async throws {
        let f = try Fixture()
        try f.write("one/a.txt", "a")
        try f.write("two/b.txt", "b")
        let summary = try await f.service.createArchive(
            sources: ["one", "two"],
            destinationFile: "bundle.zip",
            rootURL: f.root,
            cancellation: f.cancel
        )
        #expect(summary.contains("entries=2"))
        let listing = try await f.service.listing(relativePath: "bundle.zip", rootURL: f.root, cancellation: f.cancel)
        let paths = Set(listing.entries.map(\.path))
        #expect(paths.contains("one/a.txt"))
        #expect(paths.contains("two/b.txt"))
    }

    @Test("Extraction is bounded, refuses overwrites and stays inside the workspace")
    func boundedExtractionAndNoOverwrite() async throws {
        let f = try Fixture()
        try f.makeZip(named: "docs.zip", entries: [("readme.txt", "hello")])

        let summary = try await f.service.extract(
            relativePath: "docs.zip", destinationDir: "out", rootURL: f.root, cancellation: f.cancel
        )
        #expect(summary.contains("entries=1"))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out/readme.txt").path))

        do {
            _ = try await f.service.extract(
                relativePath: "docs.zip", destinationDir: "out", rootURL: f.root, cancellation: f.cancel
            )
            Issue.record("an existing destination must never be overwritten")
        } catch let error as ArchiveBrowseError {
            #expect(error.localizedDescription.contains("already exists"))
        }
    }

    /// The browser never materializes a traversal entry: the shared service
    /// either refuses the archive or skips the hostile entry, and in both
    /// cases nothing is written outside the destination directory.
    @Test("A traversal entry never escapes the destination directory")
    func traversalEntryNeverEscapes() async throws {
        let f = try Fixture()
        let archiveURL = f.root.appendingPathComponent("evil.zip")
        let archive = try #require(Archive(url: archiveURL, accessMode: .create))
        let payload = Data("pwned".utf8)
        try archive.addEntry(
            with: "../evil.txt",
            type: .file,
            uncompressedSize: Int64(payload.count),
            compressionMethod: .deflate,
            provider: { position, size in payload.subdata(in: Int(position)..<Int(position) + size) }
        )

        do {
            let summary = try await f.service.extract(
                relativePath: "evil.zip", destinationDir: "out", rootURL: f.root, cancellation: f.cancel
            )
            // Reaching here is allowed only when the hostile entry was skipped
            // rather than written.
            #expect(summary.contains("skipped=") || summary.contains("entries=0"), "summary was: \(summary)")
        } catch let error as ArchiveBrowseError {
            #expect(!error.localizedDescription.isEmpty)
        }
        let escaped = f.root.deletingLastPathComponent().appendingPathComponent("evil.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out/evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("evil.txt").path))
    }

    @Test("The shared listing text parses into the browser's entries")
    func listingParsingIsStable() {
        let text = """
        status=ok action=list format=7z source=a.7z entries=3 truncated=true
        file\t12\tone.txt
        dir\t0\tfolder
        file\t7\tfolder/two.bin
        malformed row without tabs
        """
        let listing = ArchiveBrowserService.parseListing(text, format: "7z")
        #expect(listing.truncated)
        #expect(listing.entries.count == 3)
        #expect(listing.entries[1].isDirectory)
        #expect(listing.entries[1].path == "folder")
        #expect(listing.entries[2].size == 7)
    }

    @Test("bz2/tbz2 decoding is refused with the reason the capability set states")
    func bzip2DecodeRefusal() async throws {
        let f = try Fixture()
        try f.write("note.txt", "bzip2 payload")
        let service = f.service

        // Creation stays available: the engine writes both variants natively.
        _ = try ArchiveEngine.create(
            format: "tbz2",
            sources: [f.root.appendingPathComponent("note.txt")],
            destination: f.root.appendingPathComponent("pack.tar.bz2"),
            cancellation: f.cancel
        )
        _ = try ArchiveEngine.create(
            format: "bz2",
            sources: [f.root.appendingPathComponent("note.txt")],
            destination: f.root.appendingPathComponent("note.txt.bz2"),
            cancellation: f.cancel
        )

        // The advertised capability matches the behavior: bz2/tbz2 stay in the
        // create-capable sets but are listed as decode-unsupported.
        #expect(ArchiveBrowserService.decodeUnsupportedFormats == ["tbz2", "bz2"])
        #expect(ArchiveBrowserService.nativeFormats.contains("tbz2"))
        #expect(ArchiveBrowserService.singleFileFormats.contains("bz2"))
        #expect(!ArchiveBrowserService.decodeUnsupportedReason.isEmpty)

        // Listing a tar.bz2 has to decode it: refused with the honest reason.
        do {
            _ = try await service.listing(relativePath: "pack.tar.bz2", rootURL: f.root, cancellation: f.cancel)
            Issue.record("tbz2 listing must be refused")
        } catch let error as ArchiveBrowseError {
            guard case .unsupportedFormat(let format, let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(format == "tbz2")
            #expect(reason == ArchiveBrowserService.decodeUnsupportedReason)
        }
        // Extraction of the same container is refused too.
        do {
            _ = try await service.extract(
                relativePath: "pack.tar.bz2", destinationDir: "tbz2-out", rootURL: f.root, cancellation: f.cancel
            )
            Issue.record("tbz2 extraction must be refused")
        } catch let error as ArchiveBrowseError {
            guard case .unsupportedFormat(let format, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(format == "tbz2")
        }
        // Decompressing a single-file .bz2 is refused as well.
        do {
            _ = try await service.decompress(
                relativePath: "note.txt.bz2", destinationFile: "note-restored.txt", rootURL: f.root, cancellation: f.cancel
            )
            Issue.record("bz2 decompression must be refused")
        } catch let error as ArchiveBrowseError {
            guard case .unsupportedFormat(let format, let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(format == "bz2")
            #expect(reason == ArchiveBrowserService.decodeUnsupportedReason)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("tbz2-out").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("note-restored.txt").path))

        // The single-file listing of .bz2 stays honest: one logical payload,
        // no decode (so it is not refused).
        let bz2Listing = try await service.listing(relativePath: "note.txt.bz2", rootURL: f.root, cancellation: f.cancel)
        #expect(bz2Listing.format == "bz2")
        #expect(bz2Listing.entries.count == 1)
    }

    @Test("Format inference matches the archive tool's own extension rules")
    func formatInference() {
        #expect(ArchiveBrowserService.format(for: "a.zip") == "zip")
        #expect(ArchiveBrowserService.format(for: "a.tar") == "tar")
        #expect(ArchiveBrowserService.format(for: "a.7z") == "7z")
        #expect(ArchiveBrowserService.format(for: "A.TAR.GZ") == "tgz")
        #expect(ArchiveBrowserService.format(for: "a.tbz2") == "tbz2")
        #expect(ArchiveBrowserService.format(for: "a.txz") == "txz")
        #expect(ArchiveBrowserService.nativeFormats == ["zip", "tar", "tgz", "tbz2", "txz", "7z"])
        #expect(ArchiveBrowserService.singleFileFormats == ["gz", "bz2", "xz"])
    }
}

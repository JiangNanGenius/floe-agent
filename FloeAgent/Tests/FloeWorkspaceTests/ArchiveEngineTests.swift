// FloeWorkspaceTests — native archive engine contracts.
//
// These tests exercise the real engine (no guest, no stub codec): every
// container format round-trips, the platform `tar`/`gzip`/`bzip2`/`xz` tools
// read what we write and we read what they write, and the shared safety policy
// holds for traversal names, symlink escapes, self-inclusion, overwrite
// refusal and cancellation.
//
// The adversarial half pins the resource and corruption contracts:
//   * decompression budgets are enforced *before* output is appended, so an
//     expansion bomb fails with bounded memory; bzip2 uses the SDK's streaming
//     libbz2 through `CFloeArchive`, so bz2/tbz2 decode has the same bound;
//     gzip members are located by decoding (stored blocks containing the gzip
//     magic, concatenated members, trailing data and truncation all covered)
//     and bzip2 members the same way (concatenation, trailing garbage,
//     truncation, mid-stream corruption);
//   * malformed / truncated tar archives never commit output or leave
//     staging partials.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeTools
import CFloeArchive
#if canImport(Darwin)
import Darwin
#endif

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

        func writeBytes(_ relative: String, _ bytes: [UInt8]) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func readBytes(_ relative: String) throws -> [UInt8] {
            [UInt8](try Data(contentsOf: root.appendingPathComponent(relative)))
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        func url(_ relative: String) -> URL {
            root.appendingPathComponent(relative)
        }

        /// Staging directories/files the engine is supposed to clean up.
        func stagingLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(".floe-archive-") }
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

        // MARK: adversarial builders

        /// Deterministic bytes for boundary-oriented fixtures.
        static func pseudoRandomBytes(count: Int, seed: UInt64) -> [UInt8] {
            var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var result: [UInt8] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                result.append(UInt8(truncatingIfNeeded: state >> 33))
            }
            return result
        }

        /// A gzip file whose payload is a single stored DEFLATE block: the
        /// compressed bytes literally contain the payload, which is how the
        /// old magic-scan misdetected embedded `1f 8b 08` as another member.
        static func storedGzip(_ payload: [UInt8]) -> Data {
            precondition(payload.count <= 65_535, "stored-block fixture is single-block only")
            var data = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
            let count = payload.count
            var block = Data([0x01, UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)])
            let nlen = UInt16(truncatingIfNeeded: ~count)
            block.append(UInt8(truncatingIfNeeded: nlen))
            block.append(UInt8(truncatingIfNeeded: nlen >> 8))
            block.append(contentsOf: payload)
            data.append(block)
            var crc = ArchiveCRC32.checksum(Data(payload)).littleEndian
            withUnsafeBytes(of: &crc) { data.append(contentsOf: $0) }
            var isize = UInt32(truncatingIfNeeded: count).littleEndian
            withUnsafeBytes(of: &isize) { data.append(contentsOf: $0) }
            return data
        }

        /// A checksum-valid 512-byte tar header with chosen field values, so
        /// the malformed-numeric cases are not filtered by a bad checksum.
        static func tarHeader(
            name: String,
            size: Int64,
            typeflag: Character = "0",
            sizeField: [UInt8]? = nil,
            modeField: [UInt8]? = nil,
            mtimeField: [UInt8]? = nil
        ) -> Data {
            var block = [UInt8](repeating: 0, count: 512)
            let nameBytes = Array(name.utf8.prefix(100))
            if !nameBytes.isEmpty { block.replaceSubrange(0..<nameBytes.count, with: nameBytes) }
            func octalField(_ value: Int64, length: Int) -> [UInt8] {
                let text = String(value, radix: 8)
                let padded = String(repeating: "0", count: max(0, length - 1 - text.count)) + text
                var bytes = Array(padded.utf8.prefix(length - 1))
                bytes.append(0)
                return bytes
            }
            block.replaceSubrange(100..<108, with: modeField ?? octalField(Int64(0o644), length: 8))
            block.replaceSubrange(108..<116, with: octalField(0, length: 8))
            block.replaceSubrange(116..<124, with: octalField(0, length: 8))
            block.replaceSubrange(124..<136, with: sizeField ?? octalField(size, length: 12))
            block.replaceSubrange(136..<148, with: mtimeField ?? octalField(1_700_000_000, length: 12))
            block[156] = typeflag.asciiValue ?? 0x30
            block.replaceSubrange(257..<262, with: Array("ustar".utf8))
            block.replaceSubrange(263..<265, with: Array("00".utf8))
            for index in 148..<156 { block[index] = 0x20 }
            let sum = block.reduce(0) { $0 + Int($1) }
            let text = String(sum, radix: 8)
            let padded = String(repeating: "0", count: max(0, 6 - text.count)) + text
            let checksum = Array(padded.utf8)
            block.replaceSubrange(148..<(148 + checksum.count), with: checksum)
            block[154] = 0
            block[155] = 0x20
            return Data(block)
        }

        /// One complete tar entry (header + payload + padding).
        static func tarEntry(name: String, _ content: String) -> Data {
            let payload = Data(content.utf8)
            let padding = Data(repeating: 0, count: (512 - payload.count % 512) % 512)
            return tarHeader(name: name, size: Int64(payload.count)) + payload + padding
        }
    }

    // MARK: - helpers

    /// Extracts/creates and requires exactly `ArchiveEngineError.corrupt`,
    /// then checks that nothing was committed and no staging is left behind.
    private func expectCorrupt(
        _ f: Fixture,
        destination: String,
        _ label: String,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
            Issue.record("\(label): expected the archive to be refused")
        } catch let error as ArchiveEngineError {
            guard case .corrupt = error else {
                Issue.record("\(label): unexpected error \(error)")
                return
            }
        }
        #expect(!f.exists(destination), "\(label): destination must not exist")
        #expect(try f.stagingLeftovers().isEmpty, "\(label): staging leftovers")
    }

    // MARK: - round trips

    @Test("Every container format round-trips files, empty dirs, links and Chinese names", arguments: ["zip", "tar", "tgz", "txz"])
    func containerRoundTrip(format: String) async throws {
        let f = try Fixture()
        try f.makeTree()
        let engine = ArchiveEngine.self
        let destination = f.url("pack.\(format == "tgz" ? "tar.gz" : format == "txz" ? "tar.xz" : format)")

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
        let name = format == "tgz" ? "ours.tar.gz" : format == "tbz2" ? "ours.tar.bz2" : "ours.tar.xz"
        let ours = f.url(name)
        _ = try engine.create(format: format, sources: [f.url("interop")], destination: ours, cancellation: f.cancel)

        // macOS bsdtar: -z gzip, -j bzip2, -J xz. This is macOS tool
        // interoperability, not a Linux-device result.
        let flag = format == "tgz" ? "-tzf" : format == "tbz2" ? "-tjf" : "-tJf"
        let (status, listing) = try f.run(tar, [flag, ours.path])
        #expect(status == 0, "system tar failed: \(listing)")
        #expect(listing.contains("interop/a.txt"), "listing was: \(listing)")

        // System-created archive -> our reader.
        let source = f.url("system")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try f.write("system/b.txt", "beta")
        let createFlag = format == "tgz" ? "-czf" : format == "tbz2" ? "-cjf" : "-cJf"
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

    @Test("bzip2 and tar.bz2 create, list, extract and decompress natively with bounded streaming")
    func bzip2RoundTrip() async throws {
        let f = try Fixture()
        try f.makeTree()
        let engine = ArchiveEngine.self

        // Container: our writer -> platform bsdtar reads it -> our list/extract.
        let tbz2 = f.url("pack.tar.bz2")
        let created = try engine.create(format: "tbz2", sources: [f.url("project")], destination: tbz2, cancellation: f.cancel)
        #expect(created.entries == 3)
        // The one-shot buffered path is gone: no buffering note remains.
        #expect(!created.notes.contains("bzip2Buffered"))
        if let tar = Fixture.toolPath("tar") {
            // macOS bsdtar, not a Linux-device result.
            let (status, listing) = try f.run(tar, ["-tjf", tbz2.path])
            #expect(status == 0, "system tar failed: \(listing)")
            #expect(listing.contains("project/readme.txt"), "listing was: \(listing)")
        }
        let listing = try engine.list(format: "tbz2", source: tbz2, cancellation: f.cancel)
        #expect(listing.entries.contains { $0.path.hasSuffix("readme.txt") })
        let extracted = try engine.extract(format: "tbz2", source: tbz2, destination: f.url("tbz2-out"), cancellation: f.cancel)
        #expect(extracted.entries == 3)
        #expect(try f.read("tbz2-out/project/readme.txt") == "hello archive")
        #expect(try f.read("tbz2-out/project/notes/中文 说明.md") == "中文内容")

        // Single file: our writer -> platform bzip2 reads it -> our decode.
        let bz2 = f.url("readme.txt.bz2")
        let createdSingle = try engine.create(format: "bz2", sources: [f.url("project/readme.txt")], destination: bz2, cancellation: f.cancel)
        #expect(createdSingle.uncompressedBytes == 13)
        if let bzip2 = Fixture.toolPath("bzip2") {
            let (status, output) = try f.run(bzip2, ["-dc", bz2.path])
            #expect(status == 0, "\(bzip2) failed: \(output)")
            #expect(output == "hello archive")
        }
        let decompressed = try engine.decompress(format: "bz2", source: bz2, destination: f.url("readme-restored.txt"), cancellation: f.cancel)
        #expect(decompressed.uncompressedBytes == 13)
        #expect(try f.read("readme-restored.txt") == "hello archive")

        // Platform-created bzip2 -> our bounded decode (macOS tool).
        if let bzip2 = Fixture.toolPath("bzip2") {
            let systemBz2 = f.url("system.txt.bz2")
            let (status, output) = try f.run(
                "/bin/sh",
                ["-c", "'\(bzip2)' -c '\(f.url("project/readme.txt").path)' > '\(systemBz2.path)'"]
            )
            #expect(status == 0, "system bzip2 failed: \(output)")
            _ = try engine.decompress(format: "bz2", source: systemBz2, destination: f.url("system-restored.txt"), cancellation: f.cancel)
            #expect(try f.read("system-restored.txt") == "hello archive")
        }
    }

    @Test("A bzip2 expansion bomb hits the decode budget before output is appended")
    func bzip2BombBounded() throws {
        let f = try Fixture()
        try f.writeBytes("bomb.bin", [UInt8](repeating: 0, count: 8 * 1024 * 1024))
        let bz2 = f.url("bomb.bin.bz2")
        _ = try ArchiveEngine.create(format: "bz2", sources: [f.url("bomb.bin")], destination: bz2, cancellation: f.cancel)

        var limits = ArchiveLimits()
        limits.maxTotalBytes = 64 * 1024
        do {
            _ = try ArchiveEngine.decompress(
                format: "bz2",
                source: bz2,
                destination: f.url("bomb.out"),
                limits: limits,
                cancellation: f.cancel
            )
            Issue.record("expected the budget to refuse the expansion")
        } catch let error as ArchiveEngineError {
            guard case .limitExceeded = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!f.exists("bomb.out"))
        #expect(try f.stagingLeftovers().isEmpty)

        // Codec level: `reserve` runs before the append, so the produced count
        // can never pass the declared cap — libbz2's own fixed working state is
        // larger than the budget, which must not matter.
        let budget = ArchiveDecodeBudget(maxOutputBytes: 64 * 1024, cancellation: nil)
        let source = try Bzip2DecodingSource(url: bz2, budget: budget)
        var refused = false
        do {
            while let chunk = try source.read(max: 256 * 1024), !chunk.isEmpty {}
        } catch {
            refused = true
        }
        #expect(refused)
        #expect(budget.producedBytes > 0)
        #expect(budget.producedBytes <= 64 * 1024)

        // With room in the budget the same stream decodes to exactly 8 MiB.
        var roomy = ArchiveLimits()
        roomy.maxTotalBytes = 32 * 1024 * 1024
        _ = try ArchiveEngine.decompress(
            format: "bz2",
            source: bz2,
            destination: f.url("bomb-restored.bin"),
            limits: roomy,
            cancellation: f.cancel
        )
        #expect(try f.readBytes("bomb-restored.bin") == [UInt8](repeating: 0, count: 8 * 1024 * 1024))
    }

    @Test("Concatenated bzip2 members decode in sequence; trailing garbage and truncation are refused")
    func bzip2MemberBoundaries() throws {
        let f = try Fixture()
        let first = Fixture.pseudoRandomBytes(count: 200_000, seed: 11)
        let second = Fixture.pseudoRandomBytes(count: 33_333, seed: 22)
        try f.writeBytes("first.bin", first)
        try f.writeBytes("second.bin", second)
        _ = try ArchiveEngine.create(format: "bz2", sources: [f.url("first.bin")], destination: f.url("first.bz2"), cancellation: f.cancel)
        _ = try ArchiveEngine.create(format: "bz2", sources: [f.url("second.bin")], destination: f.url("second.bz2"), cancellation: f.cancel)

        // Concatenated members the way the `bzip2` tool emits them.
        let joined = try Data(contentsOf: f.url("first.bz2")) + (try Data(contentsOf: f.url("second.bz2")))
        try joined.write(to: f.url("joined.bz2"))

        _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("joined.bz2"), destination: f.url("joined.bin"), cancellation: f.cancel)
        #expect(try f.readBytes("joined.bin") == first + second)

        // Codec level: both members are counted, and their boundary comes from
        // the decoder's consumed byte count, not a magic scan.
        let budget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: nil)
        let source = try Bzip2DecodingSource(url: f.url("joined.bz2"), budget: budget)
        var decoded = Data()
        while let chunk = try source.read(max: 64 * 1024) { decoded.append(chunk) }
        #expect(source.membersDecoded == 2)
        #expect(decoded == Data(first + second))

        // Trailing bytes that are not another stream must be refused, not ignored.
        var garbage = joined
        garbage.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
        try garbage.write(to: f.url("garbage.bz2"))
        try expectCorrupt(f, destination: "garbage.out", "trailing garbage") {
            _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("garbage.bz2"), destination: f.url("garbage.out"), cancellation: f.cancel)
        }

        // A truncated final member is refused before anything is committed.
        let truncated = joined.prefix(joined.count - 4)
        try Data(truncated).write(to: f.url("truncated.bz2"))
        try expectCorrupt(f, destination: "truncated.out", "truncated stream") {
            _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("truncated.bz2"), destination: f.url("truncated.out"), cancellation: f.cancel)
        }

        // A byte flipped inside the compressed payload fails the stream/block
        // integrity checks instead of producing corrupted output.
        var corrupt = joined
        corrupt[corrupt.startIndex + corrupt.count / 2] ^= 0xFF
        try corrupt.write(to: f.url("corrupt.bz2"))
        try expectCorrupt(f, destination: "corrupt.out", "corrupted stream") {
            _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("corrupt.bz2"), destination: f.url("corrupt.out"), cancellation: f.cancel)
        }

        // An empty file is not a valid bzip2 stream.
        try Data().write(to: f.url("empty.bz2"))
        try expectCorrupt(f, destination: "empty.out", "empty input") {
            _ = try ArchiveEngine.decompress(format: "bz2", source: f.url("empty.bz2"), destination: f.url("empty.out"), cancellation: f.cancel)
        }
    }

    // MARK: - bzip2 lifecycle

    /// Drives the `CFloeArchive` shim directly: returns the terminal status and
    /// whether libbz2's block state was still owned when the terminal status
    /// was reached. `destroy` is then called on every path.
    private func driveDecoder(_ data: Data) -> (status: Int32, stateHeld: Int32) {
        guard let decoder = floe_bz2_decoder_create() else {
            return (FLOE_BZ2_MEMORY, 0)
        }
        var window = [UInt8](repeating: 0, count: 4096)
        var offset = 0
        var status: Int32 = FLOE_BZ2_OK
        while status == FLOE_BZ2_OK {
            var consumed = 0
            var produced = 0
            status = data.withUnsafeBytes { raw -> Int32 in
                let source = raw.baseAddress.map {
                    $0.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                }
                return window.withUnsafeMutableBufferPointer { destination -> Int32 in
                    floe_bz2_decoder_process(
                        decoder, source, data.count - offset,
                        destination.baseAddress, destination.count,
                        &consumed, &produced
                    )
                }
            }
            offset += consumed
            if status == FLOE_BZ2_OK && consumed == 0 && produced == 0 && offset >= data.count {
                status = FLOE_BZ2_ERROR
            }
        }
        let held = floe_bz2_decoder_state_active(decoder)
        floe_bz2_decoder_destroy(decoder)
        return (status, held)
    }

    /// Same for the encoder: streams `data`, finishes, and reports whether the
    /// encoder state was released by the terminal `FLOE_BZ2_FINISHED`.
    private func driveEncoder(_ data: Data) -> (status: Int32, stateHeld: Int32) {
        guard let encoder = floe_bz2_encoder_create(9) else {
            return (FLOE_BZ2_MEMORY, 0)
        }
        var window = [UInt8](repeating: 0, count: 4096)
        var offset = 0
        var status: Int32 = FLOE_BZ2_OK
        while true {
            let finish: Int32 = offset >= data.count ? 1 : 0
            var consumed = 0
            var produced = 0
            status = data.withUnsafeBytes { raw -> Int32 in
                let source = raw.baseAddress.map {
                    $0.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                }
                return window.withUnsafeMutableBufferPointer { destination -> Int32 in
                    floe_bz2_encoder_process(
                        encoder, source, data.count - offset,
                        destination.baseAddress, destination.count,
                        finish, &consumed, &produced
                    )
                }
            }
            offset += consumed
            if status != FLOE_BZ2_OK { break }
            if finish == 1 && consumed == 0 && produced == 0 { break }
        }
        let held = floe_bz2_encoder_state_active(encoder)
        floe_bz2_encoder_destroy(encoder)
        return (status, held)
    }

    /// libbz2 lifecycle contract, read from the shim itself: a stream that ends
    /// successfully releases its multi-MiB block state at the terminal
    /// transition (the pre-fix code skipped `BZ2_bz*End` there and leaked it
    /// until the handle was freed), while error/abandoned streams still own the
    /// state that `destroy` releases. A coarse heap-growth guard repeats full
    /// create/process/destroy cycles through the Swift wrappers: the old code
    /// retained ~11 MiB per completed stream, >200 MiB over the rounds below.
    @Test("bzip2 stream lifecycles release libbz2 state on every terminal path")
    func bzip2LifecycleReleasesState() throws {
        let f = try Fixture()
        let payload = Fixture.pseudoRandomBytes(count: 300_000, seed: 7)
        try f.writeBytes("life.bin", payload)
        _ = try ArchiveEngine.create(
            format: "bz2",
            sources: [f.url("life.bin")],
            destination: f.url("life.bz2"),
            cancellation: f.cancel
        )
        let compressed = try Data(contentsOf: f.url("life.bz2"))
        var corrupt = compressed
        corrupt[corrupt.startIndex + corrupt.count / 2] ^= 0xFF
        try corrupt.write(to: f.url("corrupt.bz2"))
        let truncated = Data(compressed.prefix(compressed.count / 2))
        try truncated.write(to: f.url("truncated.bz2"))

        // Successful decode: state must already be released at STREAM_END.
        let good = driveDecoder(compressed)
        #expect(good.status == FLOE_BZ2_STREAM_END)
        #expect(good.stateHeld == 0, "decoder kept libbz2 state after a successful stream end")

        // Corrupt stream: detected as an error, and destroy releases the state.
        let bad = driveDecoder(corrupt)
        #expect(bad.status == FLOE_BZ2_ERROR)
        #expect(bad.stateHeld == 1, "corrupt stream should still own its state for destroy to release")

        // Abandoned/truncated stream: same held-until-destroy contract.
        let partial = driveDecoder(truncated)
        #expect(partial.status == FLOE_BZ2_ERROR)
        #expect(partial.stateHeld == 1)

        // Successful encode: state must already be released at FINISHED.
        let encoded = driveEncoder(Data(payload))
        #expect(encoded.status == FLOE_BZ2_FINISHED)
        #expect(encoded.stateHeld == 0, "encoder kept libbz2 state after a successful finish")

        // Repeat full wrapper lifecycles and guard against heap growth.
        func wrapperRound() throws {
            let budget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: nil)
            let source = try Bzip2DecodingSource(url: f.url("life.bz2"), budget: budget)
            var decoded = Data()
            while let chunk = try source.read(max: 64 * 1024) { decoded.append(chunk) }
            #expect(decoded == Data(payload))
            #expect(source.membersDecoded == 1)
            do {
                let errorBudget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: nil)
                let badSource = try Bzip2DecodingSource(url: f.url("corrupt.bz2"), budget: errorBudget)
                while let chunk = try badSource.read(max: 64 * 1024) { _ = chunk }
                Issue.record("corrupted stream decoded")
            } catch is ArchiveCodecError {
                // expected
            }
            let partialBudget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: nil)
            let partialSource = try Bzip2DecodingSource(url: f.url("truncated.bz2"), budget: partialBudget)
            do {
                _ = try partialSource.read(max: 1024)
            } catch is ArchiveCodecError {
                // Expected: the abandoned decoder is destroyed on release.
            }
            var encodedOut = Data()
            let writer = try Bzip2StreamWriter { encodedOut.append($0) }
            try writer.write(Data(payload))
            try writer.finish()
            #expect(!encodedOut.isEmpty)
        }

        #if canImport(Darwin)
        try wrapperRound() // warm-up
        let before = mallocInUseBytes()
        for _ in 0..<20 { try wrapperRound() }
        let delta = mallocInUseBytes() - before
        // 20 leaked stream states would be >200 MiB; allocator/test noise stays
        // well under this bound.
        #expect(delta < 128 * 1024 * 1024, "libbz2 state retained \(delta) bytes over 20 rounds")
        #endif
    }

    #if canImport(Darwin)
    /// Bytes currently allocated in the default malloc zone; used only by the
    /// libbz2 lifecycle leak guard above.
    private func mallocInUseBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return stats.size_in_use
    }
    #endif

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
                let (status, output) = try f.run(tool, ["-dc", archive.path])
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

    // MARK: - decode budgets (P0)

    @Test("A gzip expansion bomb hits the decode budget before output is appended")
    func gzipBombBounded() throws {
        let f = try Fixture()
        try f.writeBytes("bomb.bin", [UInt8](repeating: 0, count: 8 * 1024 * 1024))
        let gz = f.url("bomb.bin.gz")
        _ = try ArchiveEngine.create(format: "gz", sources: [f.url("bomb.bin")], destination: gz, cancellation: f.cancel)

        var limits = ArchiveLimits()
        limits.maxTotalBytes = 64 * 1024
        do {
            _ = try ArchiveEngine.decompress(
                format: "gz",
                source: gz,
                destination: f.url("bomb.out"),
                limits: limits,
                cancellation: f.cancel
            )
            Issue.record("expected the budget to refuse the expansion")
        } catch let error as ArchiveEngineError {
            guard case .limitExceeded = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!f.exists("bomb.out"))
        #expect(try f.stagingLeftovers().isEmpty)

        // Codec level: `reserve` runs before the append, so the produced count
        // can never pass the declared cap (no post-hoc `Data.count` check).
        let budget = ArchiveDecodeBudget(maxOutputBytes: 64 * 1024, cancellation: nil)
        let source = try GzipDecodingSource(url: gz, budget: budget)
        var refused = false
        do {
            while let chunk = try source.read(max: 256 * 1024), !chunk.isEmpty {}
        } catch {
            refused = true
        }
        #expect(refused)
        #expect(budget.producedBytes > 0)
        #expect(budget.producedBytes <= 64 * 1024)
    }

    @Test("An xz expansion bomb hits the decode budget before output is appended")
    func xzBombBounded() throws {
        let f = try Fixture()
        try f.writeBytes("bomb.bin", [UInt8](repeating: 0, count: 8 * 1024 * 1024))
        let xz = f.url("bomb.bin.xz")
        _ = try ArchiveEngine.create(format: "xz", sources: [f.url("bomb.bin")], destination: xz, cancellation: f.cancel)

        var limits = ArchiveLimits()
        limits.maxTotalBytes = 64 * 1024
        do {
            _ = try ArchiveEngine.decompress(
                format: "xz",
                source: xz,
                destination: f.url("bomb.out"),
                limits: limits,
                cancellation: f.cancel
            )
            Issue.record("expected the budget to refuse the expansion")
        } catch let error as ArchiveEngineError {
            guard case .limitExceeded = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!f.exists("bomb.out"))
        #expect(try f.stagingLeftovers().isEmpty)

        let budget = ArchiveDecodeBudget(maxOutputBytes: 64 * 1024, cancellation: nil)
        let source = try VerifiedXZSource(source: try FileByteSource(url: xz), budget: budget)
        var refused = false
        do {
            while let chunk = try source.read(max: 256 * 1024), !chunk.isEmpty {}
        } catch {
            refused = true
        }
        #expect(refused)
        #expect(budget.producedBytes > 0)
        #expect(budget.producedBytes <= 64 * 1024)

        // With room in the budget the same stream decodes fully — the
        // bounded-memory path must not corrupt or truncate a valid archive.
        var roomy = ArchiveLimits()
        roomy.maxTotalBytes = 32 * 1024 * 1024
        let restored = f.url("bomb-restored.bin")
        _ = try ArchiveEngine.decompress(
            format: "xz",
            source: xz,
            destination: restored,
            limits: roomy,
            cancellation: f.cancel
        )
        #expect(try f.readBytes("bomb-restored.bin") == [UInt8](repeating: 0, count: 8 * 1024 * 1024))

        // Codec level: the post-input drain must be retried (a yielded call is
        // not a truncated stream), and exactly the real output is produced.
        let roomyBudget = ArchiveDecodeBudget(maxOutputBytes: 32 * 1024 * 1024, cancellation: nil)
        let largeSource = try VerifiedXZSource(source: try FileByteSource(url: xz), budget: roomyBudget)
        var largeOut = Data()
        while let chunk = try largeSource.read(max: 256 * 1024) { largeOut.append(chunk) }
        #expect(largeOut.count == 8 * 1024 * 1024)
        #expect(roomyBudget.producedBytes == 8 * 1024 * 1024)

        // A large stream written by the platform xz tool (its own index and
        // check framing) must decode through the same bounded path.
        if let xzTool = Fixture.toolPath("xz") {
            let bigFile = f.url("big-zeros.bin")
            try f.writeBytes("big-zeros.bin", [UInt8](repeating: 0, count: 4 * 1024 * 1024))
            let systemXZ = f.url("system-big.xz")
            let (status, toolOutput) = try f.run(
                "/bin/sh",
                ["-c", "'\(xzTool)' -c '\(bigFile.path)' > '\(systemXZ.path)'"]
            )
            #expect(status == 0, "system xz failed: \(toolOutput)")
            let restoredSystem = f.url("system-big-restored.bin")
            _ = try ArchiveEngine.decompress(
                format: "xz",
                source: systemXZ,
                destination: restoredSystem,
                cancellation: f.cancel
            )
            #expect(try f.readBytes("system-big-restored.bin") == [UInt8](repeating: 0, count: 4 * 1024 * 1024))
        }
    }

    @Test("A tar.gz bomb is bounded while decoding, before the entry size check can help")
    func tarGzBombBounded() throws {
        let f = try Fixture()
        // The only entry has a traversal name, so the extractor skips its
        // payload instead of counting it against `maxTotalBytes`; the decode
        // budget for the tar stream itself is what must stop the expansion.
        let payloadSize = 8 * 1024 * 1024
        let buffer = DataByteSink()
        var writer = TarStreamWriter(sink: buffer)
        try writer.addFile(name: "../skip.bin", size: Int64(payloadSize), mode: 0o644, mtime: Date()) { _ in } from: {
            DataByteSource(Data(repeating: 0, count: payloadSize))
        }
        try writer.finish()
        let tar = f.url("bomb.tar")
        try buffer.data.write(to: tar)
        // Compress the tar itself (not a nested tar entry), so the traversal
        // entry is what the extractor decodes and skips.
        let archive = f.url("bomb.tar.gz")
        _ = try ArchiveEngine.create(format: "gz", sources: [tar], destination: archive, cancellation: f.cancel)

        var limits = ArchiveLimits()
        limits.maxTotalBytes = 16 * 1024
        do {
            _ = try ArchiveEngine.extract(
                format: "tgz",
                source: archive,
                destination: f.url("bomb-out"),
                limits: limits,
                cancellation: f.cancel
            )
            Issue.record("expected the budget to refuse the expansion")
        } catch let error as ArchiveEngineError {
            guard case .limitExceeded = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!f.exists("bomb-out"))
        #expect(try f.stagingLeftovers().isEmpty)
    }

    @Test("A tar.bz2 bomb is bounded while decoding, before the entry size check can help")
    func tarBz2BombBounded() throws {
        let f = try Fixture()
        // Same construction as the tar.gz bomb: the only entry has a traversal
        // name, so its payload is skipped by the extractor; the decode budget
        // for the tar stream is what must stop the expansion.
        let payloadSize = 8 * 1024 * 1024
        let buffer = DataByteSink()
        var writer = TarStreamWriter(sink: buffer)
        try writer.addFile(name: "../skip.bin", size: Int64(payloadSize), mode: 0o644, mtime: Date()) { _ in } from: {
            DataByteSource(Data(repeating: 0, count: payloadSize))
        }
        try writer.finish()
        let tar = f.url("bomb.tar")
        try buffer.data.write(to: tar)
        let archive = f.url("bomb.tar.bz2")
        _ = try ArchiveEngine.create(format: "tbz2", sources: [tar], destination: archive, cancellation: f.cancel)

        var limits = ArchiveLimits()
        limits.maxTotalBytes = 16 * 1024
        do {
            _ = try ArchiveEngine.extract(
                format: "tbz2",
                source: archive,
                destination: f.url("bomb-out"),
                limits: limits,
                cancellation: f.cancel
            )
            Issue.record("expected the budget to refuse the expansion")
        } catch let error as ArchiveEngineError {
            guard case .limitExceeded = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(!f.exists("bomb-out"))
        #expect(try f.stagingLeftovers().isEmpty)
    }

    // MARK: - gzip member boundaries (P1)

    @Test("Concatenated gzip members are streamed, boundary-located and verified")
    func gzipConcatenatedMembers() throws {
        let f = try Fixture()
        let first = Fixture.pseudoRandomBytes(count: 32 * 1024, seed: 7)
        let second = Fixture.pseudoRandomBytes(count: 48 * 1024, seed: 11)
        var data = Fixture.storedGzip(first)
        data.append(Fixture.storedGzip(second))
        let file = f.url("members.gz")
        try data.write(to: file)

        // The first member ends well before the file's last bytes, so the
        // reader has to relocate that boundary with the bounded second pass.
        let source = try GzipDecodingSource(
            url: file,
            budget: ArchiveDecodeBudget(maxOutputBytes: 1 << 20, cancellation: nil)
        )
        var decoded = Data()
        while let chunk = try source.read(max: 32 * 1024) { decoded.append(chunk) }
        #expect([UInt8](decoded) == first + second)
        #expect(source.membersDecoded == 2)
        #expect(source.boundaryRelocations >= 1)

        let out = f.url("members.out")
        _ = try ArchiveEngine.decompress(format: "gz", source: file, destination: out, cancellation: f.cancel)
        #expect(try f.readBytes("members.out") == first + second)

        // Corrupting the second member's trailer is detected and nothing is
        // committed.
        var corrupt = data
        corrupt[corrupt.count - 3] ^= 0xFF
        let corruptURL = f.url("corrupt.gz")
        try corrupt.write(to: corruptURL)
        try expectCorrupt(f, destination: "corrupt.out", "corrupt trailer") {
            _ = try ArchiveEngine.decompress(
                format: "gz",
                source: corruptURL,
                destination: f.url("corrupt.out"),
                cancellation: f.cancel
            )
        }
    }

    @Test("Stored blocks containing the gzip magic are not mistaken for members")
    func gzipEmbeddedMagic() throws {
        let f = try Fixture()
        var payload: [UInt8] = []
        for _ in 0..<512 { payload += [0x1F, 0x8B, 0x08, 0x00] }
        let file = f.url("stored.gz")
        try Fixture.storedGzip(payload).write(to: file)

        let source = try GzipDecodingSource(
            url: file,
            budget: ArchiveDecodeBudget(maxOutputBytes: 1 << 20, cancellation: nil)
        )
        var decoded = Data()
        while let chunk = try source.read(max: 1024) { decoded.append(chunk) }
        #expect([UInt8](decoded) == payload)
        #expect(source.membersDecoded == 1)
        #expect(source.boundaryRelocations == 0)

        let out = f.url("stored.out")
        _ = try ArchiveEngine.decompress(format: "gz", source: file, destination: out, cancellation: f.cancel)
        #expect(try f.readBytes("stored.out") == payload)
    }

    @Test("gzip trailing data, a truncated trailer and a truncated payload are refused")
    func gzipBoundaryStrictness() throws {
        let f = try Fixture()
        let payload = [UInt8](repeating: 0x41, count: 4_096)
        let valid = Fixture.storedGzip(payload)

        let trailing = f.url("trailing.gz")
        try (valid + Data([0x00, 0x01, 0x02, 0x03])).write(to: trailing)
        try expectCorrupt(f, destination: "trailing.out", "trailing data") {
            _ = try ArchiveEngine.decompress(format: "gz", source: trailing, destination: f.url("trailing.out"), cancellation: f.cancel)
        }

        let truncatedTrailer = f.url("truncated-trailer.gz")
        try valid.dropLast(5).write(to: truncatedTrailer)
        try expectCorrupt(f, destination: "truncated-trailer.out", "truncated trailer") {
            _ = try ArchiveEngine.decompress(
                format: "gz",
                source: truncatedTrailer,
                destination: f.url("truncated-trailer.out"),
                cancellation: f.cancel
            )
        }

        let truncatedPayload = f.url("truncated-payload.gz")
        try valid.subdata(in: 0..<(valid.count - 64)).write(to: truncatedPayload)
        try expectCorrupt(f, destination: "truncated-payload.out", "truncated payload") {
            _ = try ArchiveEngine.decompress(
                format: "gz",
                source: truncatedPayload,
                destination: f.url("truncated-payload.out"),
                cancellation: f.cancel
            )
        }
    }

    // MARK: - tar corruption (P1)

    @Test("Checksum-valid tar headers with malformed or overflowing numeric fields are refused")
    func tarMalformedNumericFields() throws {
        let f = try Fixture()
        let endMarker = Data(repeating: 0, count: 1_024)
        let cases: [(String, [UInt8], [UInt8]?)] = [
            ("invalid-size", Array("999999999999".utf8), nil),
            ("overflow-size", [0x80] + [UInt8](repeating: 0xFF, count: 11), nil),
            ("negative-size", [UInt8](repeating: 0xFF, count: 12), nil),
            ("invalid-mode", [], Array("88888888".utf8))
        ]
        for (label, sizeField, modeField) in cases {
            let archive = f.url("bad-\(label).tar")
            let header = Fixture.tarHeader(
                name: "bad.txt",
                size: 0,
                sizeField: sizeField.isEmpty ? nil : sizeField,
                modeField: modeField
            )
            try (header + endMarker).write(to: archive)
            try expectCorrupt(f, destination: "bad-\(label)-out", label) {
                _ = try ArchiveEngine.extract(
                    format: "tar",
                    source: archive,
                    destination: f.url("bad-\(label)-out"),
                    cancellation: f.cancel
                )
            }
        }
    }

    @Test("A tar without an end marker, a partial block or trailing garbage is refused")
    func tarTruncationStrictness() throws {
        let f = try Fixture()
        let entry = Fixture.tarEntry(name: "a.txt", "data")
        let headerOnly = Fixture.tarHeader(name: "a.txt", size: 4)

        // 1) entry then a clean end of input: no end-of-archive marker.
        let noEnd = f.url("no-end.tar")
        try entry.write(to: noEnd)
        try expectCorrupt(f, destination: "no-end-out", "missing end marker") {
            _ = try ArchiveEngine.extract(format: "tar", source: noEnd, destination: f.url("no-end-out"), cancellation: f.cancel)
        }
        // The same archive must not produce a partial listing either.
        do {
            _ = try ArchiveEngine.list(format: "tar", source: noEnd, cancellation: f.cancel)
            Issue.record("listing a truncated tar should fail")
        } catch let error as ArchiveEngineError {
            guard case .corrupt = error else { Issue.record("unexpected \(error)"); return }
        }

        // 2) entry then 1..511 bytes of a partial header.
        let partial = f.url("partial.tar")
        try (entry + Data(repeating: 0x11, count: 300)).write(to: partial)
        try expectCorrupt(f, destination: "partial-out", "partial header") {
            _ = try ArchiveEngine.extract(format: "tar", source: partial, destination: f.url("partial-out"), cancellation: f.cancel)
        }

        // 3) header-only EOF: the declared payload never arrives.
        let headerEOF = f.url("header-only.tar")
        try headerOnly.write(to: headerEOF)
        try expectCorrupt(f, destination: "header-only-out", "header-only EOF") {
            _ = try ArchiveEngine.extract(
                format: "tar",
                source: headerEOF,
                destination: f.url("header-only-out"),
                cancellation: f.cancel
            )
        }

        // 4) non-zero garbage after a complete end marker.
        let garbage = f.url("garbage.tar")
        try (entry + Data(count: 1_024) + Data(repeating: 0x58, count: 300)).write(to: garbage)
        try expectCorrupt(f, destination: "garbage-out", "trailing garbage") {
            _ = try ArchiveEngine.extract(format: "tar", source: garbage, destination: f.url("garbage-out"), cancellation: f.cancel)
        }
    }

    @Test("Zero padding after the end marker stays compatible")
    func tarPaddingCompatibility() throws {
        let f = try Fixture()
        let archive = f.url("padded.tar")
        try (Fixture.tarEntry(name: "a.txt", "data") + Data(count: 1_024) + Data(count: 10_240)).write(to: archive)
        let summary = try ArchiveEngine.extract(
            format: "tar",
            source: archive,
            destination: f.url("padded-out"),
            cancellation: f.cancel
        )
        #expect(summary.entries == 1)
        #expect(try f.read("padded-out/a.txt") == "data")
    }

    // MARK: - cancellation

    @Test("Cancellation during a decode stops promptly and leaves no output")
    func cancellationDuringDecode() throws {
        let f = try Fixture()
        try f.writeBytes("big.bin", [UInt8](repeating: 0x5A, count: 4 * 1024 * 1024))
        let gz = f.url("big.bin.gz")
        _ = try ArchiveEngine.create(format: "gz", sources: [f.url("big.bin")], destination: gz, cancellation: f.cancel)

        let token = CancellationToken()
        do {
            _ = try ArchiveEngine.decompress(
                format: "gz",
                source: gz,
                destination: f.url("big.out"),
                progress: { _ in token.cancel() },
                cancellation: token
            )
            Issue.record("expected cancellation")
        } catch is FloeError {
            // expected: FloeError.cancelled
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(!f.exists("big.out"))
        #expect(try f.stagingLeftovers().isEmpty)

        // Codec level: cancellation is polled inside the decode loop, so the
        // next read after `cancel()` stops immediately.
        let codecToken = CancellationToken()
        let budget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: codecToken)
        let source = try GzipDecodingSource(url: gz, budget: budget)
        _ = try source.read(max: 64 * 1024)
        codecToken.cancel()
        do {
            while let chunk = try source.read(max: 64 * 1024) { _ = chunk }
            Issue.record("expected the codec to stop after cancellation")
        } catch is FloeError {
            // expected
        }

        // bzip2 goes through the same contract: engine-level cancellation via
        // the progress callback, and an in-loop poll at codec level.
        let bz2 = f.url("big.bin.bz2")
        _ = try ArchiveEngine.create(format: "bz2", sources: [f.url("big.bin")], destination: bz2, cancellation: f.cancel)
        let token2 = CancellationToken()
        do {
            _ = try ArchiveEngine.decompress(
                format: "bz2",
                source: bz2,
                destination: f.url("big-bz2.out"),
                progress: { _ in token2.cancel() },
                cancellation: token2
            )
            Issue.record("expected cancellation")
        } catch is FloeError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(!f.exists("big-bz2.out"))
        #expect(try f.stagingLeftovers().isEmpty)

        let bz2Token = CancellationToken()
        let bz2Budget = ArchiveDecodeBudget(maxOutputBytes: 16 * 1024 * 1024, cancellation: bz2Token)
        let bz2Source = try Bzip2DecodingSource(url: bz2, budget: bz2Budget)
        _ = try bz2Source.read(max: 64 * 1024)
        bz2Token.cancel()
        do {
            while let chunk = try bz2Source.read(max: 64 * 1024) { _ = chunk }
            Issue.record("expected the bzip2 codec to stop after cancellation")
        } catch is FloeError {
            // expected
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
        #expect(try f.stagingLeftovers().isEmpty)
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

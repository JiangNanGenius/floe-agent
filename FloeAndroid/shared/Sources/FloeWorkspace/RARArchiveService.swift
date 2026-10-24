// FloeWorkspace — bounded native RAR decoder (list/extract), Android module
// port of the ORIGINAL app-side FloeApp/Files/RARArchiveService.swift at
// immutable public source 3fd597b5 (the "app's signed native archive decoder"
// that ArchiveTool's header documents). Deltas, documented and narrow:
//   1. The file moves INSIDE the FloeWorkspace module (Android has no
//      separate app-framework seam for this; the decoder is module source
//      linked against the vendored pinned CArchive target — libarchive 3.8.9
//      compiled from source per Vendor/Archive/libarchive-3.8.9/floe/
//      RECIPE.md, the same upstream version+sha256 that
//      FloeAgent/scripts/bootstrap_libarchive.py pins for the iOS
//      signed XCFramework). `import FloeWorkspace` is therefore dropped;
//      every other statement, guard, limit, message and ordering is
//      byte-equal to the original.
//   2. `enum RARArchiveService` + `run` are `public` so the Android app
//      assembly (Main scope) can register the handler; `process` stays
//      private.
//   3. `RARArchiveService.compressedHandler` mirrors the original
//      ArchiveCompressedBridge.makeHandler() dispatch exactly (rar only;
//      any other format reaching the handler is a caller bug refused with
//      the original message) so Main's wiring is one line.
// Contracts preserved verbatim: list/extract only; encrypted, multipart,
// non-regular, symlink/hardlink, absolute/`~`/backslash/colon/control/`..`
// entries, duplicate-casefolded paths, entry-count, per-entry and aggregate
// 256 MiB size limits, decompressed-size limit, truncation, destination
// re-resolution before the staged commit, cancellation polled per header and
// per data block, `.floe-rar-*` staging removed on every failure path, and
// output-file collision refusal (never overwrite). Input files are parsed,
// never executed.

import Foundation
import CArchive
import FloeCore
import FloeTools

/// Bounded native decoder. Input files and package code are never executed.
public enum RARArchiveService {
    public static func run(_ request: ArchiveCompressedRequest) async throws -> String {
        try await Task.detached(priority: .utility) { try process(request) }.value
    }

    private static func process(_ request: ArchiveCompressedRequest) throws -> String {
        guard ["list", "extract"].contains(request.action) else { throw FloeError.validationFailed("RAR is list/extract only") }
        let guarder = WorkspacePathGuard(rootURL: request.workspaceRoot)
        let source = try guarder.resolve(request.source)
        let manager = FileManager.default
        let destination = try request.destination.map { try guarder.resolve($0) }
        if request.action == "extract" {
            guard let destination, !manager.fileExists(atPath: destination.path) else { throw FloeError.validationFailed("RAR requires a new output directory") }
        }
        guard let reader = archive_read_new() else { throw FloeError.internalError("RAR decoder allocation failed") }
        defer { archive_read_free(reader) }
        func checked(_ code: Int32) throws {
            guard code == ARCHIVE_OK else { throw FloeError.validationFailed("RAR is corrupt, encrypted, multipart or unsupported") }
        }
        try checked(archive_read_support_filter_none(reader))
        try checked(archive_read_support_format_rar(reader))
        try checked(archive_read_support_format_rar5(reader))
        try checked(source.path.withCString { archive_read_open_filename(reader, $0, 65_536) })
        let parent = destination?.deletingLastPathComponent() ?? manager.temporaryDirectory
        if request.action == "extract" { try manager.createDirectory(at: parent, withIntermediateDirectories: true) }
        let staging = parent.appendingPathComponent(".floe-rar-\(UUID())")
        defer { try? manager.removeItem(at: staging) }
        if request.action == "extract" { try manager.createDirectory(at: staging, withIntermediateDirectories: false) }
        let stagingGuard = WorkspacePathGuard(rootURL: staging)
        var entries = 0, total: Int64 = 0, declaredTotal: Int64 = 0, paths = Set<String>(), listing: [[String: Any]] = []
        var entry: OpaquePointer?
        while true {
            try request.cancellation.throwIfCancelled()
            let state = archive_read_next_header(reader, &entry)
            if state == ARCHIVE_EOF { break }
            try checked(state)
            guard let entry, let pointer = archive_entry_pathname_utf8(entry),
                  let path = String(validatingCString: pointer), !path.isEmpty,
                  !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains(":"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !path.split(separator: "/").contains(".."),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  archive_entry_is_encrypted(entry) == 0 else {
                throw FloeError.validationFailed("RAR contains unsafe paths, links or encrypted entries")
            }
            entries += 1
            guard entries <= 5000, paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw FloeError.validationFailed("RAR entry limit or duplicate path") }
            let type = archive_entry_filetype(entry)
            // archive_entry.h uses cast macros that Swift cannot import.
            // These are libarchive's portable AE_IFDIR / AE_IFREG values.
            let isDirectory = type == 0o040000
            guard isDirectory || type == 0o100000 else { throw FloeError.validationFailed("RAR contains a non-regular entry") }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= 256 * 1024 * 1024 else { throw FloeError.validationFailed("RAR size limit") }
            declaredTotal += size
            guard declaredTotal <= 256 * 1024 * 1024 else { throw FloeError.validationFailed("RAR aggregate size limit") }
            let target = try stagingGuard.resolve(path)
            if listing.count < 500 { listing.append(["path": path, "size": size, "directory": isDirectory]) }
            if request.action == "list" || isDirectory {
                if request.action == "extract" { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
                try checked(archive_read_data_skip(reader))
                continue
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !manager.fileExists(atPath: target.path), manager.createFile(atPath: target.path, contents: nil) else { throw FloeError.validationFailed("RAR output path collision") }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536), written: Int64 = 0
            while true {
                try request.cancellation.throwIfCancelled()
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw FloeError.validationFailed("RAR decompression/checksum failure") }
                if count == 0 { break }
                written += Int64(count); total += Int64(count)
                guard written <= size, total <= 256 * 1024 * 1024 else { throw FloeError.validationFailed("RAR decompressed size limit") }
                try output.write(contentsOf: Data(buffer.prefix(count)))
            }
            guard written == size else { throw FloeError.validationFailed("RAR entry is truncated") }
            try output.close()
        }
        try checked(archive_read_close(reader))
        try request.cancellation.throwIfCancelled()
        if request.action == "extract", let destination, let relative = request.destination {
            guard try guarder.resolve(relative) == destination else { throw FloeError.validationFailed("RAR destination changed during extraction") }
            try manager.moveItem(at: staging, to: destination)
        }
        let result: [String: Any] = ["status": "ok", "action": request.action, "format": "rar", "entries": entries,
            "listedEntries": listing, "listingTruncated": entries > listing.count, "writtenBytes": total, "declaredUncompressedBytes": declaredTotal,
            "destinationDir": request.destination as Any? ?? NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Module-side handler seam matching the original
    /// `ArchiveCompressedBridge.makeHandler()` (FloeApp, 3fd597b5): RAR is
    /// routed here; every other format reaching a handler means the native
    /// engine was bypassed and is refused with the original message.
    public static var compressedHandler: ArchiveCompressedHandler {
        { request in
            switch request.format {
            case "rar":
                return try await RARArchiveService.run(request)
            default:
                throw FloeError.invalidConfiguration(
                    "\(request.format) archives are handled natively by the workspace archive tool"
                )
            }
        }
    }
}


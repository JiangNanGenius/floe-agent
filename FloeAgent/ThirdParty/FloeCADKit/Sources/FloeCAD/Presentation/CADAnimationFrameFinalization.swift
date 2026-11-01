//
//  CADAnimationFrameFinalization.swift
//  FloeCADKit
//
//  Original X29-R2 — cancellation-aware, off-main frame bundle finalization.
//
//  R1 built the PNG frame bundle inside `CADAnimationFrameSequenceBuilder.finish`,
//  a SYNCHRONOUS `@MainActor` method: it decoded every staged image with UIKit,
//  re-hashed it, streamed every frame through the ZIP writer, and read the ZIP
//  central directory back, all without an async suspension or a cancellation
//  check. A long bundle therefore monopolized the main actor and the native
//  Cancel/Close/background actions could not be processed until the whole
//  verify+zip pass had finished; an outer check before/after could not make it
//  responsive.
//
//  This file keeps the SAME verified bundle contract and moves that work to a
//  worker off the main actor:
//
//    * the handoff is a frozen Sendable snapshot of this job's staged file URLs
//      and already-captured frame metadata. No document, BRep, renderer,
//      UIImage, UIView or other mutable UIKit ownership crosses the boundary;
//    * verification (byte count, SHA-256, CRC-32, PNG signature, real decode
//      and pixel size, frame-plan time) reads each staged PNG in bounded chunks
//      and checks cancellation at every chunk and frame boundary;
//    * manifest encoding, ZIP assembly, CRC read-back and the ZIP central
//      directory read-back run on the same worker, streaming one chunk at a
//      time. The 512 MiB bundle is never allocated in memory; only one chunk
//      (64 KiB) and, in the decode step, one frame's decode buffer are resident;
//    * the exporting task AWAITS the worker (a structured join). Cancellation
//      cancels the worker and only proceeds to staging removal or promotion
//      after it has exited, so no detached writer can race cleanup;
//    * the staging destination is still promoted only by the existing export
//      lifecycle after its stale/lease/background fence passes.
//
//  ImageIO/CoreGraphics decode is used here instead of UIKit `UIImage`: both
//  read only the immutable staged files, and neither transfers view ownership.
//

#if canImport(AVFoundation) && canImport(RealityKit) && canImport(UIKit)
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// MARK: - Frozen handoff values

/// One frame's immutable bundle metadata. Values only: this is what the
/// manifest records and what the worker verifies against the staged file.
nonisolated struct CADAnimationFrameBundleEntry: Codable, Equatable, Sendable {
    var index: Int
    var file: String
    var timeSeconds: Double
    var presentationValue: Int
    var timescale: Int
    var byteCount: Int
    var sha256: String
    var crc32: UInt32
}

/// Deterministic `manifest.json` embedded at the bundle root.
nonisolated struct CADAnimationFrameBundleManifest: Codable, Equatable, Sendable {
    var format: String
    var schema: String
    var version: Int
    var clipID: String
    var width: Int
    var height: Int
    var frameRate: Int
    var frameCount: Int
    var durationSeconds: Double
    var alpha: String
    var background: String
    var timescale: Int
    var frames: [CADAnimationFrameBundleEntry]
}

/// Everything the worker may read or write, frozen at handoff. It deliberately
/// carries URLs and value metadata only; the renderer, document, BRep and
/// UIKit objects stay on the export path.
nonisolated struct CADAnimationFrameFinalizationSnapshot: Sendable {
    var directory: URL
    var zipURL: URL
    var width: Int
    var height: Int
    var frameRate: Int
    var clipID: UUID
    var duration: Double
    var entries: [CADAnimationFrameBundleEntry]
    var maximumOutputBytes: Int64

    /// Read/write granularity for the worker. One chunk plus (at most) one
    /// decoded frame is resident at a time; the archive is never accumulated.
    static let chunkBytes = 64 * 1024
}

/// Result of the off-main verification pass: the exact manifest bytes to embed
/// and their SHA-256. The entries themselves are already in the snapshot.
nonisolated struct CADAnimationFrameFinalizationVerification: Sendable {
    var manifestData: Data
    var manifestSHA256: String
}

/// Result of the off-main assembly pass. `byteCount` is the real ZIP size.
nonisolated struct CADAnimationFrameFinalizationOutcome: Sendable {
    var byteCount: Int64
    var manifestSHA256: String
    var frameTimes: [Double]
}

// MARK: - Cancellation

/// Cancellation owned by the exporting task. The worker polls this (and its own
/// task cancellation flag) at frame/chunk boundaries; because the exporting
/// task awaits the worker's completion, cancel-before-cleanup is a real join,
/// not a detached writer racing staging removal.
nonisolated final class CADAnimationFrameFinalizationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}

/// Observation points for the DEBUG-only finalization probe. The enum is
/// inert in Release; only the probe class and its call sites are compiled out.
nonisolated enum CADAnimationFrameFinalizationPoint: String, Sendable {
    case verifyingFrame
    case writingFrame
    case readingDirectory
    case cancelled
    case exited
}

#if DEBUG
/// Narrow DEBUG-only observation hook for deterministic owner-lifecycle tests.
/// Production never installs an observer. The exporter itself never waits on
/// the callback; a test that blocks there is responsible for its own bound and
/// for releasing the worker (the test gate below does both).
nonisolated final class CADAnimationFrameFinalizationProbe: @unchecked Sendable {
    nonisolated struct Visit: Sendable {
        var point: CADAnimationFrameFinalizationPoint
        var frameIndex: Int?
        var isMainThread: Bool
    }

    static let shared = CADAnimationFrameFinalizationProbe()
    private let lock = NSLock()
    private var observer: (@Sendable (Visit) -> Void)?

    func setObserver(_ observer: (@Sendable (Visit) -> Void)?) {
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    func report(_ point: CADAnimationFrameFinalizationPoint, index: Int?) {
        lock.lock()
        let observer = self.observer
        lock.unlock()
        observer?(Visit(
            point: point, frameIndex: index, isMainThread: Thread.isMainThread))
    }
}
#endif

// MARK: - Off-main finalizer

nonisolated enum CADAnimationFrameFinalizer {
    /// Stage 1: stream every staged PNG exactly once off the main actor and
    /// verify bytes, digest, CRC, signature, decodability/dimensions and the
    /// frozen frame-plan time. Returns the manifest bytes to embed. Awaits the
    /// worker, so cancellation joins before returning/throwing.
    static func verify(
        _ snapshot: CADAnimationFrameFinalizationSnapshot,
        cancellation: CADAnimationFrameFinalizationCancellation
    ) async throws -> CADAnimationFrameFinalizationVerification {
        try await offMain(cancellation) {
            try verifySynchronously(snapshot, cancellation: cancellation)
        }
    }

    /// Stage 2: stream the verified frames + manifest into the ZIP and read the
    /// central directory back off the main actor. Never allocates the archive.
    /// Awaits the worker for the same cancellation/join guarantee.
    static func assemble(
        _ snapshot: CADAnimationFrameFinalizationSnapshot,
        verification: CADAnimationFrameFinalizationVerification,
        cancellation: CADAnimationFrameFinalizationCancellation
    ) async throws -> CADAnimationFrameFinalizationOutcome {
        try await offMain(cancellation) {
            try assembleSynchronously(
                snapshot, verification: verification, cancellation: cancellation)
        }
    }

    // MARK: Worker lifecycle

    /// Run one synchronous stage on a utility worker. The caller's `await`
    /// waits for the worker to FINISH (not merely for cancellation to be
    /// requested), which is what lets the export remove staging afterwards
    /// without orphaning a writer. `onCancel` cancels both the token the worker
    /// polls and the worker task itself.
    private static func offMain<T: Sendable>(
        _ cancellation: CADAnimationFrameFinalizationCancellation,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: .utility) { () throws -> T in
            defer { reportProbe(.exited, index: nil) }
            try cancellation.check()
            return try body()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            // Order matters for the deterministic test witness: the token is
            // set and observed BEFORE the worker is released/cancelled, so a
            // worker held at a checkpoint cannot resume past the next check.
            cancellation.cancel()
            reportProbe(.cancelled, index: nil)
            worker.cancel()
        }
    }

    private static func reportProbe(_ point: CADAnimationFrameFinalizationPoint,
                                    index: Int?) {
        #if DEBUG
        CADAnimationFrameFinalizationProbe.shared.report(point, index: index)
        #endif
    }

    // MARK: Stage 1 — verification + manifest

    private static func verifySynchronously(
        _ snapshot: CADAnimationFrameFinalizationSnapshot,
        cancellation: CADAnimationFrameFinalizationCancellation
    ) throws -> CADAnimationFrameFinalizationVerification {
        let expectedFrameCount = max(
            1, Int((snapshot.duration * Double(snapshot.frameRate)).rounded()))
        guard snapshot.entries.count == expectedFrameCount else {
            throw CADAnimationExportError.verification(
                "The PNG frame sequence has \(snapshot.entries.count) frames, not \(expectedFrameCount).")
        }
        for entry in snapshot.entries {
            try cancellation.check()
            let expectedFile = String(format: "frame_%06d.png", entry.index)
            guard entry.file == "frames/\(expectedFile)" else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) has an unexpected bundle name.")
            }
            let fileURL = snapshot.directory.appendingPathComponent(expectedFile)
            let measured = try measureFrame(
                fileURL, index: entry.index,
                maximumBytes: snapshot.maximumOutputBytes,
                cancellation: cancellation)
            guard measured.byteCount == entry.byteCount,
                  measured.sha256 == entry.sha256,
                  measured.crc32 == entry.crc32,
                  measured.hasPNGSignature else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) does not match its recorded bytes.")
            }
            let size = try decodedPixelSize(fileURL, index: entry.index)
            guard size.width == snapshot.width,
                  size.height == snapshot.height else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) is \(size.width)×\(size.height), not \(snapshot.width)×\(snapshot.height).")
            }
            let expectedTime = FloeCADDocument.animationFrameTime(
                frame: entry.index, fps: snapshot.frameRate,
                duration: snapshot.duration)
            guard abs(entry.timeSeconds - expectedTime) <= 1e-9 else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) time does not match the frozen frame plan.")
            }
            reportProbe(.verifyingFrame, index: entry.index)
        }
        let manifest = CADAnimationFrameBundleManifest(
            format: CADAnimationExportOutputFormat.pngSequence.rawValue,
            schema: "floe.cad.animation.frames.v1",
            version: 1,
            clipID: snapshot.clipID.uuidString,
            width: snapshot.width, height: snapshot.height,
            frameRate: snapshot.frameRate, frameCount: snapshot.entries.count,
            durationSeconds: snapshot.duration,
            alpha: CADAnimationExportAlpha.opaque.rawValue,
            background: "scene",
            timescale: snapshot.frameRate,
            frames: snapshot.entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let manifestData = try encoder.encode(manifest)
        guard try JSONDecoder().decode(
            CADAnimationFrameBundleManifest.self, from: manifestData) == manifest else {
            throw CADAnimationExportError.verification(
                "The PNG frame manifest did not round-trip.")
        }
        let digest = SHA256.hash(data: manifestData).map {
            String(format: "%02x", $0)
        }.joined()
        return CADAnimationFrameFinalizationVerification(
            manifestData: manifestData, manifestSHA256: digest)
    }

    private struct MeasuredFrame {
        var byteCount: Int
        var sha256: String
        var crc32: UInt32
        var hasPNGSignature: Bool
    }

    /// Hash/CRC/size one staged PNG in 64 KiB chunks. The per-frame read bound
    /// is the file itself plus one chunk; `maximumBytes` refuses a pathological
    /// staged file long before it could become an unbounded allocation.
    private static func measureFrame(
        _ url: URL,
        index: Int,
        maximumBytes: Int64,
        cancellation: CADAnimationFrameFinalizationCancellation
    ) throws -> MeasuredFrame {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var crc = MinimalZipCRC32()
        var byteCount = 0
        var signature = Data()
        while true {
            try cancellation.check()
            let chunk = try handle.read(
                upToCount: CADAnimationFrameFinalizationSnapshot.chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            if signature.count < pngSignature.count {
                signature.append(
                    chunk.prefix(pngSignature.count - signature.count))
            }
            hasher.update(data: chunk)
            crc.update(chunk)
            byteCount += chunk.count
            guard Int64(byteCount) <= maximumBytes else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(index) exceeds the 512 MiB output bound.")
            }
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return MeasuredFrame(
            byteCount: byteCount, sha256: digest, crc32: crc.checksum,
            hasPNGSignature: signature == pngSignature)
    }

    /// Force a real ImageIO decode (not just header metadata) and report the
    /// source pixel dimensions. Runs on the worker against an immutable staged
    /// file; the decoded buffer is released before the next frame.
    private static func decodedPixelSize(
        _ url: URL, index: Int
    ) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CADAnimationExportError.verification(
                "PNG frame \(index) could not be decoded.")
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) != nil else {
            throw CADAnimationExportError.verification(
                "PNG frame \(index) could not be decoded.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CADAnimationExportError.verification(
                "PNG frame \(index) has no readable pixel dimensions.")
        }
        return (width, height)
    }

    // MARK: Stage 2 — streaming ZIP + central-directory read-back

    private static func assembleSynchronously(
        _ snapshot: CADAnimationFrameFinalizationSnapshot,
        verification: CADAnimationFrameFinalizationVerification,
        cancellation: CADAnimationFrameFinalizationCancellation
    ) throws -> CADAnimationFrameFinalizationOutcome {
        let zip = try MinimalZipFileWriter(url: snapshot.zipURL)
        // A deterministic close on every path (finish() also closes; close() is
        // idempotent). This guarantees the staging file handle is released
        // BEFORE the exporting task removes staging after a failure/cancel.
        defer { zip.close() }
        try zip.addFile(path: "manifest.json", data: verification.manifestData)
        for entry in snapshot.entries {
            try cancellation.check()
            reportProbe(.writingFrame, index: entry.index)
            let fileURL = snapshot.directory.appendingPathComponent(
                String(format: "frame_%06d.png", entry.index))
            // The writer verifies the declared CRC and size against the exact
            // bytes it writes; this digest check additionally proves the file
            // was not replaced between stage 1 and stage 2.
            var hasher = SHA256()
            do {
                try zip.addFile(
                    path: entry.file,
                    expectedSize: UInt32(entry.byteCount),
                    expectedCRC: entry.crc32,
                    contentsOf: fileURL,
                    onChunk: { chunk in
                        try cancellation.check()
                        hasher.update(data: chunk)
                    })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) could not be written into the bundle.")
            }
            let digest = hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            guard digest == entry.sha256 else {
                throw CADAnimationExportError.verification(
                    "PNG frame \(entry.index) changed while the bundle was written.")
            }
        }
        let byteCount: Int64
        do {
            byteCount = try zip.finish()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle could not be written.")
        }
        guard byteCount > 1024,
              byteCount <= snapshot.maximumOutputBytes else {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle is empty or exceeds the 512 MiB output bound.")
        }
        var expectedEntries: [(name: String, size: Int, crc: UInt32)] = [
            ("manifest.json", verification.manifestData.count,
             MinimalZipWriter.crc32(verification.manifestData)),
        ]
        expectedEntries.append(contentsOf: snapshot.entries.map {
            (name: $0.file, size: $0.byteCount, crc: $0.crc32)
        })
        reportProbe(.readingDirectory, index: nil)
        try verifyCentralDirectory(
            snapshot.zipURL, expected: expectedEntries,
            cancellation: cancellation)
        return CADAnimationFrameFinalizationOutcome(
            byteCount: byteCount,
            manifestSHA256: verification.manifestSHA256,
            frameTimes: snapshot.entries.map(\.timeSeconds))
    }

    /// Bounded central-directory read-back. Only the final 70 KB tail (EOCD) and
    /// one entry header/name/extra/comment are resident at a time; the archive
    /// is never read wholesale.
    private static func verifyCentralDirectory(
        _ url: URL,
        expected: [(name: String, size: Int, crc: UInt32)],
        cancellation: CADAnimationFrameFinalizationCancellation
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle has no readable size.")
        }
        let fileSize = number.uint64Value
        let tailLength = min(fileSize, 70_000)
        try handle.seek(toOffset: fileSize - tailLength)
        let tailData = try handle.read(upToCount: Int(tailLength)) ?? Data()
        let tail = [UInt8](tailData)
        func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        var eocd = tail.count - 22
        while eocd >= 0 {
            if u32(tail, eocd) == 0x0605_4B50 { break }
            eocd -= 1
        }
        guard eocd >= 0, eocd + 22 <= tail.count,
              u16(tail, eocd + 20) == 0 else {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle has no valid ZIP directory.")
        }
        let entryCount = u16(tail, eocd + 10)
        let centralSize = u32(tail, eocd + 12)
        let centralOffset = u32(tail, eocd + 16)
        guard entryCount == expected.count,
              UInt64(centralOffset) + UInt64(centralSize) <= fileSize else {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle entry table does not match its manifest.")
        }
        try handle.seek(toOffset: UInt64(centralOffset))
        var cursor = 0
        for entry in expected {
            try cancellation.check()
            let header = try readExactly(handle, 46)
            let headerBytes = [UInt8](header)
            guard u32(headerBytes, 0) == 0x0201_4B50 else {
                throw CADAnimationExportError.verification(
                    "The PNG frame bundle has a malformed ZIP entry table.")
            }
            let flags = u16(headerBytes, 8)
            let method = u16(headerBytes, 10)
            let crc = u32(headerBytes, 16)
            let compressed = u32(headerBytes, 20)
            let uncompressed = u32(headerBytes, 24)
            let nameLength = u16(headerBytes, 28)
            let extraLength = u16(headerBytes, 30)
            let commentLength = u16(headerBytes, 32)
            let nameData = try readExactly(handle, nameLength)
            _ = try readExactly(handle, extraLength)
            _ = try readExactly(handle, commentLength)
            let name = String(decoding: nameData, as: UTF8.self)
            guard flags == 0, method == 0,
                  crc == Int(entry.crc),
                  compressed == entry.size,
                  uncompressed == entry.size,
                  name == entry.name else {
                throw CADAnimationExportError.verification(
                    "The PNG frame bundle ZIP entry \(entry.name) does not match its manifest.")
            }
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= centralSize else {
                throw CADAnimationExportError.verification(
                    "The PNG frame bundle has a malformed ZIP entry table.")
            }
        }
        guard cursor == centralSize else {
            throw CADAnimationExportError.verification(
                "The PNG frame bundle has unexpected extra ZIP entries.")
        }
    }

    private static func readExactly(
        _ handle: FileHandle, _ count: Int
    ) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let remaining = count - data.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty else {
                throw CADAnimationExportError.verification(
                    "The PNG frame bundle has a truncated ZIP entry table.")
            }
            data.append(chunk)
        }
        return data
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47,
                                            0x0D, 0x0A, 0x1A, 0x0A])
}

#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import FloeCore
import FloeTools

/// Each output directory owns a live flock until the importer is finished.
/// Crash leftovers are collected only after expiry and only if that lock can
/// be acquired; neither arbitrary paths nor unrelated directory contents are
/// removed.
nonisolated final class StudioFrameStagingLease: @unchecked Sendable {
    let url: URL
    private let rootFD: Int32, directoryFD: Int32, lockFD: Int32, name: String

    private init(url: URL, rootFD: Int32, directoryFD: Int32, lockFD: Int32, name: String) {
        self.url = url; self.rootFD = rootFD; self.directoryFD = directoryFD; self.lockFD = lockFD; self.name = name
    }

    static func create(root override: URL? = nil) throws -> StudioFrameStagingLease {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = override ?? cache.appendingPathComponent("FloeFrameStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw FloeError.validationFailed("Frame staging is unavailable.") }
        collectExpired(root: root, rootFD: rootFD)
        let name = UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { close(rootFD); throw FloeError.validationFailed("Cannot create frame staging.") }
        let directoryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { _ = unlinkat(rootFD, name, AT_REMOVEDIR); close(rootFD); throw FloeError.validationFailed("Cannot open frame staging.") }
        let lockFD = openat(directoryFD, ".lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); _ = unlinkat(directoryFD, ".lock", 0) }
            close(directoryFD); _ = unlinkat(rootFD, name, AT_REMOVEDIR); close(rootFD)
            throw FloeError.validationFailed("Cannot reserve frame staging.")
        }
        return .init(url: root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("output.mp4"),
                     rootFD: rootFD, directoryFD: directoryFD, lockFD: lockFD, name: name)
    }

    private static func removeOwned(rootFD: Int32, directoryFD: Int32, name: String) {
        var opened = stat(), current = stat()
        guard fstat(directoryFD, &opened) == 0,
              fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              (current.st_mode & S_IFMT) == S_IFDIR, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return }
        var file = stat()
        if fstatat(directoryFD, "output.mp4", &file, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (file.st_mode & S_IFMT) == S_IFREG else { return }
            guard unlinkat(directoryFD, "output.mp4", 0) == 0 else { return }
        } else if errno != ENOENT { return }
        guard unlinkat(directoryFD, ".lock", 0) == 0 else { return }
        _ = unlinkat(rootFD, name, AT_REMOVEDIR)
    }

    private static func collectExpired(root: URL, rootFD: Int32) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().timeIntervalSince1970 - 86_400
        for name in names.prefix(128) where UUID(uuidString: name) != nil {
            let directoryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { continue }
            defer { close(directoryFD) }
            var value = stat()
            guard fstat(directoryFD, &value) == 0, value.st_uid == geteuid(),
                  Double(value.st_mtimespec.tv_sec) < cutoff else { continue }
            let lockFD = openat(directoryFD, ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lockFD >= 0 else { continue }
            defer { close(lockFD) }
            var lock = stat()
            guard fstat(lockFD, &lock) == 0, (lock.st_mode & S_IFMT) == S_IFREG,
                  lock.st_uid == geteuid(), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { continue }
            removeOwned(rootFD: rootFD, directoryFD: directoryFD, name: name)
        }
    }

    deinit {
        Self.removeOwned(rootFD: rootFD, directoryFD: directoryFD, name: name)
        close(lockFD); close(directoryFD); close(rootFD)
    }
}

/// Fixed native encoder for task-owned raw frames. No guest-authored code runs
/// in the host; only a bounded BGRA byte stream crosses the workspace boundary.
nonisolated enum StudioFrameSequenceEncoder {
    struct Specification: Codable, Sendable {
        let width: Int
        let height: Int
        let frameRate: Int
        let frameCount: Int
        let expectedSHA256: String

        func validate() throws -> Int {
            guard (2...2048).contains(width), width.isMultiple(of: 2),
                  (2...2048).contains(height), height.isMultiple(of: 2),
                  (1...60).contains(frameRate), (1...36000).contains(frameCount),
                  expectedSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw FloeError.validationFailed("Invalid BGRA frame sequence parameters.")
            }
            let frameBytes = width * height * 4
            guard frameBytes * frameCount <= 536_870_912 else {
                throw FloeError.validationFailed("Frame sequence exceeds the 512 MiB limit.")
            }
            return frameBytes
        }
    }
    struct Result: Sendable {
        let lease: StudioFrameStagingLease
        let sourceSHA256: String
        let outputSHA256: String
        var url: URL { lease.url }
    }

    static func encode(source: URL, workspaceRoot: URL, spec: Specification, cancellation: CancellationToken) async throws -> Result {
        let frameBytes = try spec.validate()
        try cancellation.throwIfCancelled(); try Task.checkCancellation()
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let normalized = source.standardizedFileURL
        guard normalized.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed("Frame file is outside the task workspace.") }
        let components = normalized.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw FloeError.validationFailed("Invalid frame file path.")
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FloeError.validationFailed("Cannot open the task workspace.") }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { throw FloeError.validationFailed("Cannot open the task frame directory.") }
            directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        close(directory)
        guard fd >= 0 else { throw FloeError.validationFailed("Cannot open the task frame file.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size == Int64(frameBytes * spec.frameCount) else {
            throw FloeError.validationFailed("Frame file size does not match its dimensions and count.")
        }
        let lease = try StudioFrameStagingLease.create()
        let output = lease.url
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw FloeError.validationFailed("Video encoder rejected the frame format.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FloeError.validationFailed("Video encoder could not start.") }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { writer.cancelWriting() } }
        var digest = SHA256()
        for index in 0..<spec.frameCount {
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                try cancellation.throwIfCancelled(); try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? FloeError.validationFailed("Video encoder stopped.") }
                guard Date() < deadline else { throw FloeError.validationFailed("Video encoder did not accept a frame.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var data = Data(count: frameBytes)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try cancellation.throwIfCancelled(); try Task.checkCancellation()
                    let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw FloeError.validationFailed("Frame file ended early.") }
                    offset += count
                }
            }
            digest.update(data: data)
            guard let pool = adaptor.pixelBufferPool else { throw FloeError.validationFailed("Video frame pool unavailable.") }
            var buffer: CVPixelBuffer?
            let threshold = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
            let allocationDeadline = Date().addingTimeInterval(30)
            while buffer == nil {
                try cancellation.throwIfCancelled(); try Task.checkCancellation()
                let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, threshold, &buffer)
                if status == kCVReturnWouldExceedAllocationThreshold {
                    guard writer.status == .writing, Date() < allocationDeadline else {
                        throw FloeError.validationFailed("Video encoder did not release a frame.")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                } else if status != kCVReturnSuccess {
                    throw FloeError.validationFailed("Video frame allocation failed.")
                }
            }
            guard let buffer else { throw FloeError.validationFailed("Video frame allocation failed.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw FloeError.validationFailed("Video frame has no storage.")
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer), rowBytes = spec.width * 4
            data.withUnsafeBytes { sourceBytes in
                for row in 0..<spec.height {
                    memcpy(base.advanced(by: row * stride), sourceBytes.baseAddress!.advanced(by: row * rowBytes), rowBytes)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(spec.frameRate))) else {
                throw writer.error ?? FloeError.validationFailed("Video frame encoding failed.")
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FloeError.validationFailed("Frame source changed while encoding.")
        }
        let sourceHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard sourceHash == spec.expectedSHA256 else { throw FloeError.validationFailed("Frame source SHA256 does not match.") }
        try cancellation.throwIfCancelled(); try Task.checkCancellation()
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(spec.frameCount), timescale: CMTimeScale(spec.frameRate)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FloeError.validationFailed("Video encoder could not finish.") }
        finished = true
        try cancellation.throwIfCancelled(); try Task.checkCancellation()
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        guard try await asset.load(.isPlayable), duration.isFinite,
              abs(duration - Double(spec.frameCount) / Double(spec.frameRate)) < max(0.1, 1.0 / Double(spec.frameRate)),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FloeError.validationFailed("Encoded video failed playback verification.")
        }
        let size = try await track.load(.naturalSize)
        guard Int(size.width) == spec.width, Int(size.height) == spec.height else {
            throw FloeError.validationFailed("Encoded video dimensions do not match.")
        }
        let outputFile = try FileHandle(forReadingFrom: output)
        defer { try? outputFile.close() }
        var outputDigest = SHA256(), outputBytes = 0
        while let chunk = try outputFile.read(upToCount: 1_048_576), !chunk.isEmpty {
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            outputBytes += chunk.count
            guard outputBytes <= 536_870_912 else { throw FloeError.validationFailed("Encoded video exceeds the 512 MiB limit.") }
            outputDigest.update(data: chunk)
        }
        let outputHash = outputDigest.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(lease: lease, sourceSHA256: sourceHash, outputSHA256: outputHash)
    }
}

@MainActor enum StudioFrameImportFinalization {
    /// Library bookkeeping is separate from the already committed original.
    /// Its failure is reported in the receipt, never as a failed import.
    static func libraryRefreshPending(_ refresh: @MainActor () async throws -> Void) async -> Bool {
        do { try await refresh(); return false } catch { return true }
    }
}
#endif

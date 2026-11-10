// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import Synchronization
import FloeMusicCore

public struct MusicDJRecordingReceipt: Sendable, Codable, Hashable {
    public let projectID: String
    public let sourceRevision: Int64
    public let frames: Int64
    public let sampleRate: Int
    public let sha256: String
    public let file: URL
    public let recovered: Bool
    public let diagnostic: String?
    public init(projectID: String, sourceRevision: Int64, frames: Int64, sampleRate: Int,
                sha256: String, file: URL, recovered: Bool, diagnostic: String?) {
        self.projectID = projectID; self.sourceRevision = sourceRevision; self.frames = frames
        self.sampleRate = sampleRate; self.sha256 = sha256; self.file = file
        self.recovered = recovered; self.diagnostic = diagnostic
    }
}

/// The tap only copies into one of eight preallocated packets. It never waits
/// for a lock, disk or an actor. A full queue stops capture explicitly and
/// retains the valid prefix as recovery; it never silently drops and resumes.
/// All AVAudioFile state is confined to `writerQueue` after construction.
final class MusicDJRecordingCapture: @unchecked Sendable {
    private let packetLock = NSLock()
    private let accepting = Atomic<Bool>(true)
    private let overflow = Atomic<Bool>(false)
    private final class Packet: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    private var packets: [Packet]
    private let writerQueue = DispatchQueue(label: "floe.music.dj.recording", qos: .utility)
    private var writer: AVAudioFile?
    private var frames: Int64 = 0
    private var error: String?
    private let format: AVAudioFormat
    private let partial: URL
    private let destination: URL
    private let document: MusicDocument
    private let lease: MusicRenderLease
    private let maximumFrames: Int64
    private let capacity: AVAudioFrameCount = 16_384

    static func create(document: MusicDocument, lease: MusicRenderLease, destination: URL,
                       sampleRate: Int, maximumBytes: Int64) async throws -> MusicDJRecordingCapture {
        try lease.validate(document: document)
        guard maximumBytes >= 65_536, maximumBytes <= 2_147_483_648,
              destination.isFileURL, ["wav", "caf"].contains(destination.pathExtension.lowercased()),
              !FileManager.default.fileExists(atPath: destination.path),
              (8_000...192_000).contains(sampleRate) else { throw MusicNativeError.invalid("DJ recording destination or budget") }
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let capture = try Self(document: document, lease: lease, destination: destination,
                                   sampleRate: sampleRate, maximumFrames: maximumBytes / 8)
            do { try Task.checkCancellation() }
            catch { capture.discardBeforeStart(); throw error }
            return capture
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private init(document: MusicDocument, lease: MusicRenderLease, destination: URL,
                 sampleRate: Int, maximumFrames: Int64) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else {
            throw MusicNativeError.invalid("DJ recording format")
        }
        self.document = document; self.lease = lease; self.destination = destination
        self.maximumFrames = maximumFrames; self.format = format
        partial = musicStagingURL(for: destination)
        var pool: [Packet] = []
        for _ in 0..<8 {
            guard let packet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw MusicNativeError.invalid("DJ recording buffer")
            }
            pool.append(Packet(packet))
        }
        packets = pool
        do { writer = try AVAudioFile(forWriting: partial, settings: musicPCMFileSettings(format)) }
        catch { try? FileManager.default.removeItem(at: partial); throw error }
    }

    private func discardBeforeStart() {
        writerQueue.sync { writer = nil; try? FileManager.default.removeItem(at: partial) }
    }
    func drain() async {
        await withCheckedContinuation { continuation in writerQueue.async { continuation.resume() } }
    }
    func invalidateCommit() { lease.invalidate() }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard accepting.load(ordering: .acquiring), !overflow.load(ordering: .acquiring) else { return }
        guard buffer.frameLength > 0, buffer.frameLength <= capacity,
              buffer.format.sampleRate == format.sampleRate, buffer.format.channelCount == 2,
              let input = buffer.floatChannelData, !buffer.format.isInterleaved else {
            overflow.store(true, ordering: .releasing); return
        }
        guard packetLock.try() else {
            if accepting.load(ordering: .acquiring) { overflow.store(true, ordering: .releasing) }
            return
        }
        guard accepting.load(ordering: .acquiring) else { packetLock.unlock(); return }
        guard let owned = packets.popLast(), let output = owned.buffer.floatChannelData else {
            packetLock.unlock(); overflow.store(true, ordering: .releasing); return
        }
        let packet = owned.buffer
        packet.frameLength = buffer.frameLength
        for channel in 0..<2 { output[channel].update(from: input[channel], count: Int(buffer.frameLength)) }
        writerQueue.async { [self] in
            let packet = owned.buffer
            defer { packetLock.withLock { packets.append(owned) } }
            guard error == nil else { return }
            guard frames <= maximumFrames - Int64(packet.frameLength) else {
                error = "Recording reached its file-size budget"; overflow.store(true, ordering: .releasing); return
            }
            do {
                guard let pcm = packet.floatChannelData,
                      (0..<2).allSatisfy({ channel in
                          UnsafeBufferPointer(start: pcm[channel], count: Int(packet.frameLength)).allSatisfy(\.isFinite)
                      }) else { throw MusicNativeError.invalid("non-finite recording PCM") }
                try writer?.write(from: packet); frames += Int64(packet.frameLength)
            } catch { self.error = String(reflecting: error); overflow.store(true, ordering: .releasing) }
        }
        packetLock.unlock()
    }

    func finish(recovery: Bool) async throws -> MusicDJRecordingReceipt {
        accepting.store(false, ordering: .releasing)
        return try await withCheckedThrowingContinuation { continuation in
            packetLock.withLock { writerQueue.async { [self] in
                do {
                    writer = nil
                    guard frames > 0 else {
                        try? FileManager.default.removeItem(at: partial)
                        throw MusicNativeError.invalid("No audio was recorded")
                    }
                    try musicSynchronize(partial)
                    var recover = recovery || overflow.load(ordering: .acquiring)
                    if !recover {
                        do { try lease.validate(document: document) } catch { recover = true }
                    }
                    let hash = try MusicAudioPreparation.hashFile(partial)
                    let output: URL
                    if recover {
                        output = destination.deletingLastPathComponent().appendingPathComponent("recovery-" + UUID().uuidString + "." + destination.pathExtension)
                        try FileManager.default.moveItem(at: partial, to: output)
                    } else {
                        do { try lease.commit(staged: partial, destination: destination); output = destination }
                        catch {
                            recover = true
                            output = destination.deletingLastPathComponent().appendingPathComponent("recovery-" + UUID().uuidString + "." + destination.pathExtension)
                            try FileManager.default.moveItem(at: partial, to: output)
                        }
                    }
                    continuation.resume(returning: .init(projectID: document.id.rawValue, sourceRevision: document.revision,
                        frames: frames, sampleRate: Int(format.sampleRate), sha256: hash, file: output, recovered: recover,
                        diagnostic: error ?? (overflow.load(ordering: .acquiring) ? "Recording stopped because the input queue or format changed" : nil)))
                } catch { continuation.resume(throwing: error) }
            } }
        }
    }
}

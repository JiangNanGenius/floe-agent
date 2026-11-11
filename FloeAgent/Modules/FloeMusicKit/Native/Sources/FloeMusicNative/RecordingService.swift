import AVFoundation
import Foundation
import FloeMusicCore

public struct MusicTakeHandle: Sendable, Hashable {
    public let id: UUID
    public let projectID: String
    public let revision: Int64
    public let ownerToken: String
}

public struct MusicCapturedTake: Sendable {
    public let handle: MusicTakeHandle
    public let file: URL
    public let frames: Int64
}

/// Input adaptation stays host-owned. append receives bounded PCM copied off
/// the realtime tap; this actor never waits inside a hardware audio callback.
/// First qualification uses explicit PCM injection, not a microphone claim.
public actor MusicRecordingService {
    private struct ActiveTake {
        let handle: MusicTakeHandle
        let document: MusicDocument
        let lease: MusicRenderLease
        let partial: URL
        let destination: URL
        let format: AVAudioFormat
        var writer: AVAudioFile?
        var frames: Int64 = 0
    }
    private var active: ActiveTake?
    public init() {}

    public func begin(document: MusicDocument, lease: MusicRenderLease, destination: URL) throws -> MusicTakeHandle {
        guard active == nil, destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(document.tempoMap.sampleRate), channels: 2) else {
            throw MusicNativeError.invalid("recording state or destination")
        }
        try lease.validate(document: document)
        let handle = MusicTakeHandle(id: UUID(), projectID: document.id.rawValue, revision: document.revision, ownerToken: lease.ownerToken)
        let partial = musicStagingURL(for: destination)
        active = ActiveTake(handle: handle, document: document, lease: lease, partial: partial,
                            destination: destination, format: format,
                            writer: try AVAudioFile(forWriting: partial, settings: musicPCMFileSettings(format)))
        return handle
    }

    public func append(interleavedStereo samples: [Float], handle: MusicTakeHandle) throws {
        guard var take = active, take.handle == handle else { throw MusicNativeError.staleOwner }
        try Task.checkCancellation()
        try take.lease.validate(document: take.document)
        guard !samples.isEmpty, samples.count % 2 == 0, samples.count <= 32_768,
              samples.allSatisfy(\.isFinite),
              let buffer = AVAudioPCMBuffer(pcmFormat: take.format, frameCapacity: AVAudioFrameCount(samples.count / 2)),
              let channels = buffer.floatChannelData else { throw MusicNativeError.invalid("recording PCM chunk") }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<samples.count / 2 { channels[0][index] = samples[index * 2]; channels[1][index] = samples[index * 2 + 1] }
        try take.writer?.write(from: buffer)
        take.frames += Int64(buffer.frameLength)
        active = take
    }

    public func finish(_ handle: MusicTakeHandle) throws -> MusicCapturedTake {
        guard var take = active, take.handle == handle else { throw MusicNativeError.staleOwner }
        guard take.frames > 0 else { throw MusicNativeError.invalid("empty take") }
        try take.lease.validate(document: take.document)
        // Close the WAV header, then commit. The take stays `active` until
        // the commit outcome is known: a failed synchronize/commit keeps the
        // same handle recoverable through cancel(), and a successful one
        // clears the slot exactly once (a second finish is a stale owner).
        take.writer = nil
        // Release the actor's old copy of the writer before synchronizing
        // the final WAV header, while retaining the same recovery handle.
        active = take
        do {
            try musicSynchronize(take.partial)
            try take.lease.commit(staged: take.partial, destination: take.destination)
        } catch {
            active = take
            throw error
        }
        active = nil
        return MusicCapturedTake(handle: handle, file: take.destination, frames: take.frames)
    }

    /// Controlled cancellation closes the WAV header and retains recorded
    /// audio as recovery data. It never attaches that data to a new project.
    public func cancel(_ handle: MusicTakeHandle) throws -> MusicCapturedTake? {
        guard var take = active, take.handle == handle else { throw MusicNativeError.staleOwner }
        take.lease.invalidate()
        take.writer = nil; active = nil
        if take.frames == 0 { try FileManager.default.removeItem(at: take.partial); return nil }
        let recovery = take.destination.deletingLastPathComponent().appendingPathComponent("recovery-\(handle.id.uuidString).wav")
        try musicSynchronize(take.partial)
        try FileManager.default.moveItem(at: take.partial, to: recovery)
        return MusicCapturedTake(handle: handle, file: recovery, frames: take.frames)
    }
}

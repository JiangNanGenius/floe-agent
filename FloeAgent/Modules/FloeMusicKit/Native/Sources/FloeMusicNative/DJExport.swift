// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMusicCore

public struct MusicDJExportFailure: Error, Sendable, LocalizedError {
    public let recovery: MusicDJRecordingReceipt?
    public let reason: String
    public var errorDescription: String? { reason }
}

@MainActor private final class MusicDJOfflineAuthority: MusicAudioAuthority {
    func acquirePlayback() throws { throw MusicNativeError.invalid("Offline DJ export cannot open a device route") }
    func releasePlayback() {}
}

/// Exports the same real graph used by the decks, including TimePitch key
/// lock. Offline work can wait for disk; no device audio route is opened.
@MainActor public enum MusicDJExport {
    public static func render(session: MusicDJSession, document: MusicDocument, lease: MusicRenderLease,
                              prepared: [MusicDJPreparedSource], frames: Int64, destination: URL,
                              onProgress: @MainActor (Int64) -> Void = { _ in }) async throws -> MusicDJRecordingReceipt {
        try document.validate(); try session.validate(); try lease.validate(document: document)
        guard frames > 0, frames <= 268_435_456, session.sampleRate == document.tempoMap.sampleRate,
              [session.deckA, session.deckB].contains(where: { $0.assetID != nil && $0.playing }) else {
            throw MusicNativeError.invalid("DJ export needs a loaded playing deck and a positive duration within the 2 GiB PCM budget")
        }
        let transport = try MusicDJTransport(ownerToken: lease.ownerToken, authority: MusicDJOfflineAuthority(),
            sampleRate: session.sampleRate, output: .manual)
        do {
            try transport.apply(session, prepared: prepared, ownerToken: lease.ownerToken)
            try await transport.startRecording(document: document, lease: lease, destination: destination,
                maximumBytes: max(65_536, frames * 8), ownerToken: lease.ownerToken)
            var rendered: Int64 = 0
            while rendered < frames {
                try Task.checkCancellation(); try lease.validate(document: document)
                let count = min(4_096, frames - rendered)
                _ = try transport.renderOffline(frames: UInt32(count), ownerToken: lease.ownerToken)
                try await transport.drainRecording(ownerToken: lease.ownerToken)
                rendered += count; onProgress(rendered)
                await Task.yield()
            }
            let receipt = try await transport.finishRecording(ownerToken: lease.ownerToken)
            try transport.close(ownerToken: lease.ownerToken)
            guard !receipt.recovered, receipt.frames == frames else {
                throw MusicDJExportFailure(recovery: receipt, reason: "The mix export stopped early; the recorded part was retained")
            }
            return receipt
        } catch {
            let retained = try? await transport.finishRecording(recovery: true, ownerToken: lease.ownerToken)
            try? transport.close(ownerToken: lease.ownerToken)
            if let failure = error as? MusicDJExportFailure { throw failure }
            throw MusicDJExportFailure(recovery: retained,
                reason: error is CancellationError ? "Mix export cancelled; any recorded audio was retained" : String(describing: error))
        }
    }
}

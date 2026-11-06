// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation)
import AVFoundation
import FloeMeetings
import Foundation

/// Result of probing an importable audio/video file.
public struct AudioFileInfo: Sendable, Hashable {
    public let duration: MediaTimeRange
    public let hasAudioTrack: Bool
    public let file: URL
}

/// AVFoundation probe used by `MeetingService.importFile`. Read-only: it
/// decodes nothing and uploads nothing.
public enum AudioFileProbe {
    public static func probe(_ file: URL) async throws -> AudioFileInfo {
        guard file.isFileURL else { throw MeetingError.importedFileUnavailable(file.lastPathComponent) }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw MeetingError.importedFileUnavailable(file.lastPathComponent)
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        return AudioFileInfo(
            duration: try MediaTimeRange(start: 0, end: seconds),
            hasAudioTrack: !audioTracks.isEmpty,
            file: file
        )
    }

    /// Adapter matching `MeetingService.importFile`'s duration closure.
    public static func durationRange(_ file: URL) async throws -> MediaTimeRange {
        try await probe(file).duration
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import FloeMeetings

/// Read-only projection of project-owned database rows, never a second index.
struct MeetingRecordingMaterial: Identifiable, Hashable {
    let id: UUID
    let kind: CaptureKind
    let createdAt: Date?
    let state: MeetingRecordingState
    let parts: [CaptureSessionSnapshot]

    var isLive: Bool { kind == .liveRecording }
    var canPlay: Bool { state != .recording && !parts.isEmpty && parts.allSatisfy { $0.state == .stopped && $0.stopReason != .timeout } }
    var title: String {
        if isLive { return IDELanguageRunText.t("录音", "Recording") }
        if let name = parts.first?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return kind == .importedVideo ? IDELanguageRunText.t("导入的视频", "Imported video")
            : IDELanguageRunText.t("导入的音频", "Imported audio")
    }

    static func project(takes: [MeetingRecordingSnapshot], visibleSources: [CaptureSessionSnapshot]) -> [Self] {
        var result = takes.map { take in
            Self(id: take.id, kind: .liveRecording, createdAt: take.createdAt, state: take.state, parts: take.parts)
        }
        let members = Set(takes.flatMap { $0.parts.map(\.id) })
        for source in visibleSources where !members.contains(source.id) {
            if let origin = source.originSessionID,
               visibleSources.contains(where: { $0.id == origin && $0.meetingID == source.meetingID }) { continue }
            result.append(Self(id: source.id.rawValue, kind: source.kind, createdAt: source.startedAt,
                state: [.pending, .capturing, .stopping].contains(source.state) ? .recording : .finished,
                parts: [source]))
        }
        return result.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            return a == b ? $0.id.uuidString > $1.id.uuidString : a > b
        }
    }
}

struct MeetingPlaybackSpan: Equatable {
    let session: CaptureSessionID
    let start: Double
    let duration: Double
    var end: Double { start + duration }
}

/// These coordinates use measured media time; pause wall-clock gaps are absent.
struct MeetingPlaybackTimeline: Equatable {
    let spans: [MeetingPlaybackSpan]
    var duration: Double { spans.last?.end ?? 0 }
    func time(session: CaptureSessionID, localTime: Double) -> Double? {
        guard localTime.isFinite, let span = spans.first(where: { $0.session == session }) else { return nil }
        return span.start + max(0, min(span.duration, localTime))
    }
    func capture(at time: Double) -> (session: CaptureSessionID, time: Double)? {
        guard time.isFinite, let last = spans.last else { return nil }
        let bounded = max(0, min(last.end, time))
        let span = spans.first(where: { bounded < $0.end }) ?? last
        return (span.session, max(0, min(span.duration, bounded - span.start)))
    }
}

@MainActor
struct MeetingPreparedPlayback {
    let item: AVPlayerItem
    let timeline: MeetingPlaybackTimeline
}

/// The meeting session owns preparation and cancellation. No View task owns
/// this composition, no new audio is rendered, and original files are untouched.
@MainActor
enum MeetingRecordingPlayback {
    struct Source {
        let session: CaptureSessionID
        let file: URL
    }
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: UInt64
        let modified: Date
    }
    private static func identity(_ file: URL, root: URL) throws -> FileIdentity {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw PersonalContentError.missingDocument }
        let attrs = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let bytes = attrs[.size] as? NSNumber, bytes.uint64Value > 0,
              let modified = attrs[.modificationDate] as? Date else { throw PersonalContentError.missingDocument }
        return .init(device: device.uint64Value, inode: inode.uint64Value, bytes: bytes.uint64Value, modified: modified)
    }

    static func prepare(sources: [Source], root: URL) async throws -> MeetingPreparedPlayback {
        guard !sources.isEmpty, sources.count <= 1024, Set(sources.map(\.session)).count == sources.count else {
            throw PersonalContentError.invalidProject
        }
        // Preserve the complete native single-file asset (including normal
        // track selection for imported media). Only an explicit multi-part
        // live recording needs a composition.
        if sources.count == 1 {
            try Task.checkCancellation()
            let source = sources[0], before = try identity(sources[0].file, root: root)
            let asset = AVURLAsset(url: source.file)
            let duration = try await withTaskCancellationHandler {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else {
                    throw PersonalContentError.invalidProject
                }
                return try await asset.load(.duration)
            } onCancel: { asset.cancelLoading() }
            try Task.checkCancellation()
            guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0,
                  try identity(source.file, root: root) == before else { throw PersonalContentError.changedDocument }
            return .init(item: AVPlayerItem(asset: asset), timeline: .init(spans: [
                .init(session: source.session, start: 0, duration: duration.seconds)
            ]))
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PersonalContentError.invalidProject
        }
        var cursor = CMTime.zero
        var spans: [MeetingPlaybackSpan] = []
        var identities: [(Source, FileIdentity)] = []
        for source in sources {
            try Task.checkCancellation()
            let before = try identity(source.file, root: root)
            let asset = AVURLAsset(url: source.file)
            let (audio, range) = try await withTaskCancellationHandler {
                guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw PersonalContentError.invalidProject
                }
                return (audio, try await audio.load(.timeRange))
            } onCancel: {
                // This asset is local to this one preparation, never shared
                // with another player, recognizer or recording operation.
                asset.cancelLoading()
            }
            try Task.checkCancellation()
            let seconds = range.duration.seconds
            guard range.isValid, !range.isEmpty, seconds.isFinite, seconds > 0,
                  range.start.seconds.isFinite, cursor.seconds.isFinite,
                  cursor.seconds + seconds <= Double(Int64.max / 2) / 600 else { throw PersonalContentError.invalidProject }
            guard try identity(source.file, root: root) == before else { throw PersonalContentError.changedDocument }
            try track.insertTimeRange(range, of: audio, at: cursor)
            spans.append(.init(session: source.session, start: cursor.seconds, duration: seconds))
            identities.append((source, before))
            cursor = CMTimeAdd(cursor, range.duration)
        }
        try Task.checkCancellation()
        for (source, before) in identities {
            guard try identity(source.file, root: root) == before else { throw PersonalContentError.changedDocument }
        }
        return MeetingPreparedPlayback(item: AVPlayerItem(asset: composition), timeline: .init(spans: spans))
    }
}
#endif

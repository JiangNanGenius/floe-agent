// FloeWorkbench — PreparedVideo: bounded frame/segment proxy cache.
//
// Cache identity includes project, revision, exact frame range and output
// settings. When a newer revision arrives, `PreparedVideoPlanDiffer` computes
// the intervals affected by changed clips/tracks; only entries intersecting
// those intervals are invalidated. Entries wholly outside the change are
// promoted to the newer revision and reused.
//
// A render that finishes after a newer revision/project registration is
// discarded rather than returned as a "late success" for a stale project. The
// cache never deletes or replaces a source asset; it only owns its generated
// proxy files.

import Foundation

// MARK: - Plan diff

public struct PreparedVideoPlanDiff: Sendable, Hashable {
    public let affectedRanges: [PreparedVideoTimeRange]
    public let requiresFullInvalidation: Bool
    public let reasons: [String]

    public init(affectedRanges: [PreparedVideoTimeRange],
                requiresFullInvalidation: Bool,
                reasons: [String]) {
        self.affectedRanges = affectedRanges
        self.requiresFullInvalidation = requiresFullInvalidation
        self.reasons = reasons
    }

    public var isEmpty: Bool {
        !requiresFullInvalidation && affectedRanges.isEmpty
    }
}

public enum PreparedVideoPlanDiffer {
    public static func diff(from previous: PreparedVideoPlan,
                            to next: PreparedVideoPlan) -> PreparedVideoPlanDiff {
        guard previous.id.projectID == next.id.projectID else {
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["project changed"])
        }
        guard previous.timeScale == next.timeScale,
              previous.frameRate == next.frameRate,
              previous.canvas == next.canvas,previous.colorProfile == next.colorProfile else {
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["canvas, color profile, frame rate or timescale changed"])
        }
        guard previous.visualTracks.map(\.id) == next.visualTracks.map(\.id) else {
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["visual track order changed"])
        }
        guard previous.captionStyle == next.captionStyle,
              previous.audio.masterVolume == next.audio.masterVolume,
              previous.audio.tailSeconds == next.audio.tailSeconds else {
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["caption or master audio settings changed"])
        }

        var ranges: [PreparedVideoTimeRange] = []
        var reasons: [String] = []
        let oldAssets = Dictionary(uniqueKeysWithValues: previous.assets.map { ($0.id, $0) })
        let newAssets = Dictionary(uniqueKeysWithValues: next.assets.map { ($0.id, $0) })
        var changedAssets = Set<UUID>()
        for (id, oldAsset) in oldAssets {
            if let newAsset = newAssets[id] {
                if oldAsset != newAsset { changedAssets.insert(id) }
            } else {
                changedAssets.insert(id)
            }
        }
        for (id, _) in newAssets where oldAssets[id] == nil {
            changedAssets.insert(id)
        }
        if !changedAssets.isEmpty {
            for track in previous.visualTracks {
                for clip in track.clips {
                    if let assetID = clip.content.assetID, changedAssets.contains(assetID) {
                        ranges.append(clip.timelineRange)
                        reasons.append("visual asset changed")
                    }
                }
            }
            for track in previous.audio.tracks {
                for clip in track.clips where changedAssets.contains(clip.assetID) {
                    ranges.append(clip.timelineRange)
                    reasons.append("audio asset changed")
                }
            }
            for track in next.visualTracks {
                for clip in track.clips {
                    if let assetID = clip.content.assetID, changedAssets.contains(assetID) {
                        ranges.append(clip.timelineRange)
                        reasons.append("visual asset changed")
                    }
                }
            }
            for track in next.audio.tracks {
                for clip in track.clips where changedAssets.contains(clip.assetID) {
                    ranges.append(clip.timelineRange)
                    reasons.append("audio asset changed")
                }
            }
        }
        let oldTracks = Dictionary(uniqueKeysWithValues: previous.visualTracks.map { ($0.id, $0) })
        let newTracks = Dictionary(uniqueKeysWithValues: next.visualTracks.map { ($0.id, $0) })

        for trackID in previous.visualTracks.map(\.id) {
            guard let oldTrack = oldTracks[trackID], let newTrack = newTracks[trackID] else {
                return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                             reasons: ["visual track identity changed"])
            }
            if oldTrack.opacity != newTrack.opacity || oldTrack.isHidden != newTrack.isHidden {
                ranges.append(contentsOf: oldTrack.clips.map(\.timelineRange))
                ranges.append(contentsOf: newTrack.clips.map(\.timelineRange))
                reasons.append("visual track settings changed")
                continue
            }
            let oldClips = Dictionary(uniqueKeysWithValues: oldTrack.clips.map { ($0.id, $0) })
            let newClips = Dictionary(uniqueKeysWithValues: newTrack.clips.map { ($0.id, $0) })
            for (id, oldClip) in oldClips {
                if let newClip = newClips[id] {
                    if oldClip != newClip {
                        ranges.append(oldClip.timelineRange)
                        ranges.append(newClip.timelineRange)
                        reasons.append("visual clip changed")
                    }
                } else {
                    ranges.append(oldClip.timelineRange)
                    reasons.append("visual clip removed")
                }
            }
            for (id, newClip) in newClips where oldClips[id] == nil {
                ranges.append(newClip.timelineRange)
                reasons.append("visual clip added")
            }
        }

        let oldCaptions = Dictionary(uniqueKeysWithValues: previous.captions.map { ($0.id, $0) })
        let newCaptions = Dictionary(uniqueKeysWithValues: next.captions.map { ($0.id, $0) })
        for (id, oldCaption) in oldCaptions {
            if let newCaption = newCaptions[id] {
                if oldCaption != newCaption {
                    ranges.append(oldCaption.timelineRange)
                    ranges.append(newCaption.timelineRange)
                    reasons.append("caption changed")
                }
            } else {
                ranges.append(oldCaption.timelineRange)
                reasons.append("caption removed")
            }
        }
        for (id, newCaption) in newCaptions where oldCaptions[id] == nil {
            ranges.append(newCaption.timelineRange)
            reasons.append("caption added")
        }

        let oldAudioTracks = Dictionary(uniqueKeysWithValues: previous.audio.tracks.map { ($0.id, $0) })
        let newAudioTracks = Dictionary(uniqueKeysWithValues: next.audio.tracks.map { ($0.id, $0) })
        guard oldAudioTracks.keys.sorted(by: { $0.uuidString < $1.uuidString })
            == newAudioTracks.keys.sorted(by: { $0.uuidString < $1.uuidString }) else {
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["audio track identity changed"])
        }
        for trackID in oldAudioTracks.keys {
            guard let oldTrack = oldAudioTracks[trackID], let newTrack = newAudioTracks[trackID] else {
                return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                             reasons: ["audio track identity changed"])
            }
            if oldTrack.isMuted != newTrack.isMuted
                || oldTrack.volume != newTrack.volume
                || oldTrack.eqBands != newTrack.eqBands
                || oldTrack.dynamics != newTrack.dynamics {
                ranges.append(contentsOf: oldTrack.clips.map(\.timelineRange))
                ranges.append(contentsOf: newTrack.clips.map(\.timelineRange))
                reasons.append("audio track settings changed")
                continue
            }
            let oldClips = Dictionary(uniqueKeysWithValues: oldTrack.clips.map { ($0.id, $0) })
            let newClips = Dictionary(uniqueKeysWithValues: newTrack.clips.map { ($0.id, $0) })
            for (id, oldClip) in oldClips {
                if let newClip = newClips[id] {
                    if oldClip != newClip {
                        ranges.append(oldClip.timelineRange)
                        ranges.append(newClip.timelineRange)
                        reasons.append("audio clip changed")
                    }
                } else {
                    ranges.append(oldClip.timelineRange)
                    reasons.append("audio clip removed")
                }
            }
            for (id, newClip) in newClips where oldClips[id] == nil {
                ranges.append(newClip.timelineRange)
                reasons.append("audio clip added")
            }
        }

        if next.duration < previous.duration {
            if let range = try? PreparedVideoTimeRange(start: next.duration,
                                                       duration: previous.duration.subtracting(next.duration)) {
                ranges.append(range)
                reasons.append("plan duration shortened")
            } else {
                return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                             reasons: ["plan duration changed"])
            }
        }
        return PreparedVideoPlanDiff(affectedRanges: PreparedVideoTimeRange.merged(ranges),
                                     requiresFullInvalidation: false,
                                     reasons: Array(Set(reasons)).sorted())
    }
}

// MARK: - Public cache values

public struct PreparedVideoProxyLimits: Sendable, Hashable {
    public var maximumEntries: Int
    public var maximumBytes: Int64
    public var maximumWindowFrames: Int
    public var maximumWindowSeconds: Double

    public init(maximumEntries: Int = 64, maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
                maximumWindowFrames: Int = 1_800, maximumWindowSeconds: Double = 60) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.maximumWindowFrames = maximumWindowFrames
        self.maximumWindowSeconds = maximumWindowSeconds
    }
}

public struct PreparedVideoProxyResult: Sendable, Hashable {
    public let url: URL
    public let planID: PreparedVideoPlanID
    public let window: PreparedVideoFrameWindow
    public let settings: PreparedVideoOutputSettings
    public let wasCacheHit: Bool
    public let byteCount: Int64
    public let planContentHash: String
}

public struct PreparedVideoProxyEntrySummary: Sendable, Hashable {
    public let planID: PreparedVideoPlanID
    public let range: PreparedVideoTimeRange
    public let settingsIdentity: String
    public let byteCount: Int64
}

public struct PreparedVideoProxySnapshot: Sendable, Hashable {
    public let projectCount: Int
    public let entryCount: Int
    public let totalBytes: Int64
    public let entries: [PreparedVideoProxyEntrySummary]
}

// MARK: - Cache

public actor PreparedVideoProxyCache {
    private struct CacheKey: Hashable {
        var projectID: UUID
        var revision: Int64
        var range: PreparedVideoTimeRange
        var settingsIdentity: String
    }

    private struct Entry {
        var key: CacheKey
        var fileURL: URL
        var byteCount: Int64
        var createdAt: Date
        var lastAccess: Date
    }

    private struct ProjectState {
        var plan: PreparedVideoPlan
        var generation: UInt64
        var entries: [CacheKey: Entry]
    }

    private let directory: URL
    private let renderer: any PreparedVideoWindowRendering
    private let limits: PreparedVideoProxyLimits
    private var projects: [UUID: ProjectState] = [:]

    public init(directory: URL,
                renderer: any PreparedVideoWindowRendering,
                limits: PreparedVideoProxyLimits = PreparedVideoProxyLimits()) throws {
        guard directory.isFileURL else {
            throw PreparedVideoError.cacheLimitExceeded("cache directory must be a file URL")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.renderer = renderer
        self.limits = limits
    }

    /// Registers a frozen revision and promotes unaffected entries. Returns
    /// the exact invalidation decision for the caller/tests.
    @discardableResult
    public func register(plan: PreparedVideoPlan) throws -> PreparedVideoPlanDiff {
        guard plan.id.revision >= 0 else {
            throw PreparedVideoError.invalidPlan("revision must be non-negative")
        }
        guard let state = projects[plan.id.projectID] else {
            projects[plan.id.projectID] = ProjectState(plan: plan, generation: 1, entries: [:])
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: true,
                                         reasons: ["first registered revision"])
        }
        if plan.id.revision < state.plan.id.revision {
            throw PreparedVideoError.staleRevision
        }
        if plan.id.revision == state.plan.id.revision {
            guard plan.contentHash == state.plan.contentHash else {
                throw PreparedVideoError.invalidPlan("the same revision was reused with different content")
            }
            return PreparedVideoPlanDiff(affectedRanges: [], requiresFullInvalidation: false,
                                         reasons: [])
        }

        let diff = PreparedVideoPlanDiffer.diff(from: state.plan, to: plan)
        var newEntries: [CacheKey: Entry] = [:]
        if diff.requiresFullInvalidation {
            for entry in state.entries.values {
                try? FileManager.default.removeItem(at: entry.fileURL)
            }
        } else {
            for entry in state.entries.values {
                let affected = diff.affectedRanges.contains { $0.intersects(entry.key.range) }
                if !affected,
                   let end = try? entry.key.range.endTime(),
                   end <= plan.duration {
                    var promoted = entry
                    promoted.key.revision = plan.id.revision
                    newEntries[promoted.key] = promoted
                } else {
                    try? FileManager.default.removeItem(at: entry.fileURL)
                }
            }
        }
        projects[plan.id.projectID] = ProjectState(plan: plan,
                                                   generation: state.generation + 1,
                                                   entries: newEntries)
        return diff
    }

    public func render(plan: PreparedVideoPlan,
                       range: PreparedVideoTimeRange,
                       settings: PreparedVideoOutputSettings,
                       cancellation: PreparedVideoCancellation = .none) async throws -> PreparedVideoProxyResult {
        try cancellation.check()
        _ = try register(plan: plan)
        guard plan.frameRate == settings.frameRate else {
            throw PreparedVideoError.invalidOutputSettings(
                "proxy export currently requires the output frame rate to match the plan frame rate")
        }
        guard range.timescale == plan.timeScale else {
            throw PreparedVideoError.invalidTime("proxy range must use the plan timescale")
        }
        guard range.start.seconds >= 0,
              range.endSeconds <= plan.duration.seconds + 0.000_001 else {
            throw PreparedVideoError.invalidTime("proxy range lies outside the plan duration")
        }
        guard range.durationSeconds <= limits.maximumWindowSeconds else {
            throw PreparedVideoError.cacheLimitExceeded("proxy window is longer than \(limits.maximumWindowSeconds)s")
        }
        let window = try PreparedVideoFrameWindow(range: range, frameRate: settings.frameRate)
        guard window.frameCount <= limits.maximumWindowFrames else {
            throw PreparedVideoError.cacheLimitExceeded("proxy window exceeds \(limits.maximumWindowFrames) frames")
        }
        let key = CacheKey(projectID: plan.id.projectID, revision: plan.id.revision,
                           range: range, settingsIdentity: settings.identity)
        guard let initialState = projects[plan.id.projectID],
              initialState.plan.id == plan.id else {
            throw PreparedVideoError.staleRevision
        }
        if let entry = initialState.entries[key],
           FileManager.default.fileExists(atPath: entry.fileURL.path) {
            var updated = initialState
            if var cached = updated.entries[key] {
                cached.lastAccess = Date()
                updated.entries[key] = cached
            }
            projects[plan.id.projectID] = updated
            return PreparedVideoProxyResult(url: entry.fileURL, planID: plan.id,
                                            window: window, settings: settings,
                                            wasCacheHit: true, byteCount: entry.byteCount,
                                            planContentHash: plan.contentHash)
        }

        let generation = initialState.generation
        let destination = directory.appendingPathComponent("window-\(UUID().uuidString).mp4")
        let receipt: PreparedVideoWindowReceipt
        do {
            receipt = try await renderer.renderWindow(
                plan: plan, window: window, settings: settings,
                destination: destination, overwrite: false,
                cancellation: cancellation,
                progress: { _ in })
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try cancellation.check()

        guard let current = projects[plan.id.projectID],
              current.plan.id == plan.id,
              current.generation == generation,
              current.plan.contentHash == plan.contentHash else {
            try? FileManager.default.removeItem(at: destination)
            throw PreparedVideoError.superseded
        }
        if let existing = current.entries[key],
           FileManager.default.fileExists(atPath: existing.fileURL.path) {
            try? FileManager.default.removeItem(at: destination)
            return PreparedVideoProxyResult(url: existing.fileURL, planID: plan.id,
                                            window: window, settings: settings,
                                            wasCacheHit: true, byteCount: existing.byteCount,
                                            planContentHash: plan.contentHash)
        }

        let byteCount = receipt.byteCount
        guard byteCount <= limits.maximumBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw PreparedVideoError.cacheLimitExceeded("a single proxy exceeds the cache byte limit")
        }
        var updated = current
        updated.entries[key] = Entry(key: key, fileURL: destination, byteCount: byteCount,
                                     createdAt: Date(), lastAccess: Date())
        try enforceLimits(state: &updated, keeping: key)
        projects[plan.id.projectID] = updated
        return PreparedVideoProxyResult(url: destination, planID: plan.id,
                                        window: window, settings: settings,
                                        wasCacheHit: false, byteCount: byteCount,
                                        planContentHash: plan.contentHash)
    }

    public func snapshot() -> PreparedVideoProxySnapshot {
        let allEntries = projects.values.flatMap { $0.entries.values }
        let summaries = allEntries.map {
            PreparedVideoProxyEntrySummary(planID: PreparedVideoPlanID(projectID: $0.key.projectID,
                                                                       revision: $0.key.revision),
                                           range: $0.key.range,
                                           settingsIdentity: $0.key.settingsIdentity,
                                           byteCount: $0.byteCount)
        }
        return PreparedVideoProxySnapshot(projectCount: projects.count,
                                          entryCount: allEntries.count,
                                          totalBytes: allEntries.reduce(0) { $0 + $1.byteCount },
                                          entries: summaries)
    }

    public func removeAll() {
        for state in projects.values {
            for entry in state.entries.values {
                try? FileManager.default.removeItem(at: entry.fileURL)
            }
        }
        projects.removeAll()
    }

    private func enforceLimits(state: inout ProjectState, keeping key: CacheKey) throws {
        let allEntries = state.entries
        var totalBytes = allEntries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        while state.entries.count > limits.maximumEntries || totalBytes > limits.maximumBytes {
            let candidates = state.entries.values
                .filter { $0.key != key }
                .sorted { $0.lastAccess < $1.lastAccess }
            guard let victim = candidates.first else {
                throw PreparedVideoError.cacheLimitExceeded("cache cannot fit the new proxy")
            }
            state.entries.removeValue(forKey: victim.key)
            totalBytes -= victim.byteCount
            try? FileManager.default.removeItem(at: victim.fileURL)
        }
    }
}

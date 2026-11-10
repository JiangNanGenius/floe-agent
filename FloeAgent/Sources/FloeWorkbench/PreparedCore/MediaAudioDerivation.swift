// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import FloeCore
#if FLOE_AUDIO_HELPER_QUALIFICATION
import FloeWorkbench
#endif

public struct MediaAudioSourceFence: Sendable {
    public let documentID: UUID
    public let documentRevision: Int64
    public let trackID: UUID
    public let clip: MediaPreparedClip
    public let asset: MediaAssetReference
    public let assetRevision: UInt64
    public let sourceSHA256: String
    public let trackVolume: Double
    public let trackMuted: Bool
}
public struct MediaAudioDerivedProduct: Sendable {
    public let asset: MediaAssetReference
    public let sourceAssetID: UUID
    public let originalSourceSHA256: String
    public let processingInputSHA256: String
    public let frames: Int
    public let sampleRate: Double
    public let channelCount: Int
    public init(asset: MediaAssetReference, sourceAssetID: UUID, originalSourceSHA256: String, processingInputSHA256: String,
        frames: Int, sampleRate: Double, channelCount: Int) {
        self.asset = asset; self.sourceAssetID = sourceAssetID; self.originalSourceSHA256 = originalSourceSHA256; self.processingInputSHA256 = processingInputSHA256
        self.frames = frames; self.sampleRate = sampleRate; self.channelCount = channelCount
    }
}
public struct MediaAudioDerivationWork: Sendable {
    public let instruction: MediaPreparedInstruction
    public let target: MediaAudioSourceFence
    public let inputs: [MediaAudioSourceFence]
    fileprivate init(instruction: MediaPreparedInstruction, target: MediaAudioSourceFence, inputs: [MediaAudioSourceFence]) {
        self.instruction = instruction; self.target = target; self.inputs = inputs
    }
}
public struct MediaAudioRetimedInput: Sendable {
    public let plan: PreparedVideoPlan
    public let window: PreparedVideoFrameWindow
    public let sampleRate: Double
}
public enum MediaAudioDerivedClock: Sendable, Equatable {
    /// Noise reduction / source stems: the supplied source interval begins
    /// at zero in the new asset; original speed/reverse/freeze remain intact.
    case sourceInterval
    /// Ducking: render only source retiming into the target timeline clock.
    /// The caller must bypass volume/fades/EQ/dynamics while making that
    /// intermediate. Those saved controls are preserved and applied once.
    case retimedTimeline
}

/// Native-only source/lease/product preparation over the existing coordinator.
/// It adds no document schema, separate journal or authority system. UI/AI
/// callers must retain their existing original/task/network permission checks.
public enum MediaAudioDerivation {
    @concurrent public static func begin(coordinator: MediaPreparedCoordinator, documentID: UUID, targetClipID: UUID, sidechainClipIDs: [UUID] = [],
        verifiedSourceHashes: [UUID: String], actor: MediaPreparedActorKind = .user, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MediaAudioDerivationWork {
        try check(cancelled)
        let current = try await coordinator.loadDocument(id: documentID)
        let target = try capture(current, clipID: targetClipID, verifiedSourceHashes: verifiedSourceHashes)
        guard Set(sidechainClipIDs).count == sidechainClipIDs.count, !sidechainClipIDs.contains(targetClipID), sidechainClipIDs.count <= 32 else {
            throw MediaPreparedCoreError.invalidOperation("choose distinct narration clips separate from the music target")
        }
        let inputs = [target] + (try sidechainClipIDs.map { try capture(current, clipID: $0, verifiedSourceHashes: verifiedSourceHashes) })
        let refs = Set(inputs.map { MediaPreparedObjectRef(kind: .clip, id: $0.clip.id) })
        let instruction = try await coordinator.beginInstruction(documentID: documentID, targets: refs, actor: actor)
        do {
            let latest = try await coordinator.loadDocument(id: documentID)
            for fence in inputs { try validate(fence, in: latest) }
            try check(cancelled)
            return .init(instruction: instruction, target: target, inputs: inputs)
        } catch { try? await coordinator.stop(instruction); throw error }
    }
    @concurrent public static func commitReplacement(_ product: MediaAudioDerivedProduct, clock: MediaAudioDerivedClock, work: MediaAudioDerivationWork,
        coordinator: MediaPreparedCoordinator, assetRoot: URL, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MediaPreparedCommit {
        do {
            try check(cancelled)
            let current = try await coordinator.loadDocument(id: work.instruction.documentID)
            for fence in work.inputs { try validate(fence, in: current); try validateSourceFile(fence, root: assetRoot, cancelled: cancelled) }
            let actions = try replacement(product, clock: clock, fence: work.target, document: current, assetRoot: assetRoot, cancelled: cancelled)
            try check(cancelled)
            let receipt = try await coordinator.apply(actions, instruction: work.instruction)
            try await coordinator.stop(work.instruction)
            // Once the atomic original commit succeeded, late cancellation
            // does not rewrite its truthful saved receipt as a failed edit.
            return receipt
        } catch { try? await coordinator.stop(work.instruction); throw error }
    }
    @concurrent public static func commitStems(vocals: MediaAudioDerivedProduct, accompaniment: MediaAudioDerivedProduct, work: MediaAudioDerivationWork,
        coordinator: MediaPreparedCoordinator, assetRoot: URL, vocalsTitle: String, accompanimentTitle: String,
        cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MediaPreparedCommit {
        do {
            try check(cancelled)
            let current = try await coordinator.loadDocument(id: work.instruction.documentID)
            for fence in work.inputs { try validate(fence, in: current); try validateSourceFile(fence, root: assetRoot, cancelled: cancelled) }
            try validate(vocals, fence: work.target, document: current, root: assetRoot, cancelled: cancelled)
            try validate(accompaniment, fence: work.target, document: current, root: assetRoot, cancelled: cancelled)
            guard vocals.asset.id != accompaniment.asset.id, vocals.asset.relativePath != accompaniment.asset.relativePath,
                  abs(duration(vocals) - work.target.clip.sourceRange.durationSeconds) <= tolerance(vocals),
                  abs(duration(accompaniment) - work.target.clip.sourceRange.durationSeconds) <= tolerance(accompaniment),
                  !vocalsTitle.isEmpty, !accompanimentTitle.isEmpty else { throw MediaPreparedCoreError.invalidOperation("separated stems must cover the same original source interval") }
            var original = work.target.clip; original.isMuted = true
            var voice = try replacingClip(with: vocals, clock: .sourceInterval, original: work.target.clip), music = try replacingClip(with: accompaniment, clock: .sourceInterval, original: work.target.clip)
            voice.id = UUID(); voice.revision = 0; music.id = UUID(); music.revision = 0
            let parent = try requireTrack(work.target.trackID, in: current)
            let a = MediaPreparedTrack(kind: .audio, name: vocalsTitle, isMuted: parent.isMuted, volume: parent.volume, clips: [voice])
            let b = MediaPreparedTrack(kind: .audio, name: accompanimentTitle, isMuted: parent.isMuted, volume: parent.volume, clips: [music])
            let actions: [MediaPreparedOperation] = [
                .init(action: .insertAsset(vocals.asset)), .init(action: .insertAsset(accompaniment.asset)),
                .init(action: .replaceClip(trackID: work.target.trackID, clipID: original.id, expectedRevision: original.revision, clip: original)),
                .init(action: .insertTrack(track: a, index: nil)), .init(action: .insertTrack(track: b, index: nil))]
            try check(cancelled)
            let receipt = try await coordinator.apply(actions, instruction: work.instruction)
            try await coordinator.stop(work.instruction); return receipt
        } catch { try? await coordinator.stop(work.instruction); throw error }
    }
    /// Audio-only adapter over the real fenced clip. The neutral visual context
    /// satisfies the existing render-plan shape; no visual pixels are rendered
    /// or inserted into the project. Audio sample ticks avoid rounding a clip's
    /// boundaries to video frames. The caller uses the SAME window for music
    /// and narration so the sidechain clock has an explicit zero origin.
    public static func retimedInput(fence: MediaAudioSourceFence, sourceURL: URL, window: MediaTimeRange,
        preserveMixControls: Bool, sampleRate: Int32 = 48_000) throws -> MediaAudioRetimedInput {
        guard sourceURL.isFileURL, (8_000...192_000).contains(sampleRate), fence.clip.keyframeTracks.isEmpty,
              fence.clip.sourcePlayback?.holdSeconds == nil else {
            throw MediaPreparedCoreError.invalidOperation("choose non-frozen, non-animated source audio for dialogue ducking")
        }
        let clip = fence.clip
        guard min(clip.timelineRange.endSeconds, window.endSeconds) > max(clip.timelineRange.startSeconds, window.startSeconds) else {
            throw MediaPreparedCoreError.invalidOperation("the narration must overlap the music clip on the timeline")
        }
        if preserveMixControls {
            guard !fence.trackMuted, !clip.isMuted, fence.trackVolume > 0, clip.volume > 0 else {
                throw MediaPreparedCoreError.invalidOperation("unmute the selected narration before using it as a sidechain")
            }
        }
        let scale = sampleRate, rate = try PreparedVideoFrameRate(numerator: sampleRate, denominator: 1)
        func time(_ seconds: Double) throws -> PreparedVideoTime { try .init(seconds: seconds, timescale: scale) }
        func range(_ value: MediaTimeRange) throws -> PreparedVideoTimeRange {
            try .init(start: time(value.startSeconds), duration: time(value.durationSeconds))
        }
        let effects = preserveMixControls ? (clip.audioProcessing ?? .init()) : .init()
        try effects.validate()
        let input = try PreparedVideoAudioClip(id: clip.id, assetID: fence.asset.id, timelineRange: range(clip.timelineRange), sourceRange: range(clip.sourceRange),
            volume: preserveMixControls ? clip.volume : 1, fadeInSeconds: preserveMixControls ? (clip.fadeIn?.seconds ?? 0) : 0,
            fadeOutSeconds: preserveMixControls ? (clip.fadeOut?.seconds ?? 0) : 0, speed: clip.speed, isReversed: clip.sourcePlayback?.isReversed)
        let track = PreparedVideoAudioTrack(id: fence.trackID, name: "Audio processing input", volume: preserveMixControls ? fence.trackVolume : 1,
            eqBands: effects.eqBands, dynamics: effects.dynamics, limiter: effects.limiter, clips: [input])
        let end = max(window.endSeconds, clip.timelineRange.endSeconds)
        let plan = try PreparedVideoPlan(id: .init(projectID: fence.documentID, revision: fence.documentRevision), timeScale: scale, frameRate: rate,
            duration: time(end), canvas: .init(width: 1, height: 1),
            assets: [.init(id: fence.asset.id, url: sourceURL, kind: .audio, contentHash: fence.sourceSHA256)],
            visualTracks: [.init(id: fence.documentID, name: "Audio-only render context", clips: [
                .init(id: fence.asset.id, content: .graphic(.init(shape: .rectangle, width: 1, height: 1, fillColor: .black)),
                    timelineRange: .init(start: time(0), duration: time(end)))])],
            audio: .init(tracks: [track], masterVolume: 1, tailSeconds: 0))
        return try .init(plan: plan, window: .init(range: range(window), frameRate: rate), sampleRate: Double(sampleRate))
    }
    private static func capture(_ document: MediaPreparedDocument, clipID: UUID, verifiedSourceHashes: [UUID: String]) throws -> MediaAudioSourceFence {
        guard document.kind == .video, let selected = document.trackGraph.clip(id: clipID), selected.track.kind == .audio, !selected.track.isLocked,
              let assetID = selected.clip.assetID, let asset = document.asset(assetID), asset.kind == .audio,
              let hash = verifiedSourceHashes[assetID], validHash(hash), asset.contentHash.map({ $0 == hash }) ?? true else {
            throw MediaPreparedCoreError.invalidOperation("choose an unlocked source audio clip with its measured source identity")
        }
        return .init(documentID: document.id, documentRevision: document.revision, trackID: selected.track.id, clip: selected.clip, asset: asset,
            assetRevision: document.assetRevisions?[assetID] ?? 0, sourceSHA256: hash, trackVolume: selected.track.volume, trackMuted: selected.track.isMuted)
    }
    private static func validate(_ fence: MediaAudioSourceFence, in document: MediaPreparedDocument) throws {
        guard document.id == fence.documentID, let current = document.trackGraph.clip(id: fence.clip.id), current.track.id == fence.trackID,
              !current.track.isLocked, current.track.volume == fence.trackVolume, current.track.isMuted == fence.trackMuted,
              current.clip == fence.clip, document.asset(fence.asset.id) == fence.asset,
              (document.assetRevisions?[fence.asset.id] ?? 0) == fence.assetRevision else { throw MediaPreparedCoreError.documentChanged }
    }
    private static func replacement(_ product: MediaAudioDerivedProduct, clock: MediaAudioDerivedClock, fence: MediaAudioSourceFence,
        document: MediaPreparedDocument, assetRoot: URL, cancelled: @escaping @Sendable () -> Bool) throws -> [MediaPreparedOperation] {
        try validate(product, fence: fence, document: document, root: assetRoot, cancelled: cancelled)
        let expected = clock == .sourceInterval ? fence.clip.sourceRange.durationSeconds : fence.clip.timelineRange.durationSeconds
        guard abs(duration(product) - expected) <= tolerance(product) else { throw MediaPreparedCoreError.invalidOperation("processed audio does not cover the chosen source/timeline interval") }
        let clip = try replacingClip(with: product, clock: clock, original: fence.clip)
        return [.init(action: .insertAsset(product.asset)), .init(action: .replaceClip(trackID: fence.trackID, clipID: fence.clip.id, expectedRevision: fence.clip.revision, clip: clip))]
    }
    private static func replacingClip(with product: MediaAudioDerivedProduct, clock: MediaAudioDerivedClock, original: MediaPreparedClip) throws -> MediaPreparedClip {
        var clip = original; clip.assetID = product.asset.id
        clip.sourceRange = try .init(start: .init(value: 0, timescale: 1_000_000), duration: .init(value: Int64((duration(product) * 1_000_000).rounded()), timescale: 1_000_000))
        if clock == .retimedTimeline { clip.speed = 1; clip.sourcePlayback = nil }
        return clip
    }
    private static func validate(_ product: MediaAudioDerivedProduct, fence: MediaAudioSourceFence, document: MediaPreparedDocument, root: URL,
        cancelled: @escaping @Sendable () -> Bool) throws {
        try check(cancelled)
        guard product.sourceAssetID == fence.asset.id, product.originalSourceSHA256 == fence.sourceSHA256, validHash(product.processingInputSHA256),
              product.asset.kind == .audio, product.asset.id != fence.asset.id, document.asset(product.asset.id) == nil,
              let hash = product.asset.contentHash, validHash(hash), let bytes = product.asset.byteCount, bytes > 0,
              product.frames > 0, product.sampleRate.isFinite, (8_000...192_000).contains(product.sampleRate), (1...2).contains(product.channelCount),
              let observedDuration = product.asset.metadata?.durationSeconds, abs(observedDuration - duration(product)) <= tolerance(product),
              safePath(product.asset.relativePath) else { throw MediaPreparedCoreError.invalidOperation("derived audio has no matching source, output identity or sample clock") }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL, url = canonical.appendingPathComponent(product.asset.relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/"), try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == bytes,
              try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: cancelled) == hash else { throw MediaPreparedCoreError.documentChanged }
        let file = try AVAudioFile(forReading: url)
        guard file.length == product.frames, file.processingFormat.sampleRate == product.sampleRate, Int(file.processingFormat.channelCount) == product.channelCount else {
            throw MediaPreparedCoreError.invalidOperation("derived audio header does not match its measured product")
        }
    }
    private static func validateSourceFile(_ fence: MediaAudioSourceFence, root: URL, cancelled: @escaping @Sendable () -> Bool) throws {
        try check(cancelled)
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let url = (fence.asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: fence.asset.relativePath) : canonical.appendingPathComponent(fence.asset.relativePath)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/"), try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: cancelled) == fence.sourceSHA256 else {
            throw MediaPreparedCoreError.documentChanged
        }
    }
    private static func requireTrack(_ id: UUID, in document: MediaPreparedDocument) throws -> MediaPreparedTrack {
        guard let value = document.trackGraph.track(id) else { throw MediaPreparedCoreError.documentChanged }; return value
    }
    private static func duration(_ product: MediaAudioDerivedProduct) -> Double { Double(product.frames) / product.sampleRate }
    private static func tolerance(_ product: MediaAudioDerivedProduct) -> Double { max(2 / product.sampleRate, 0.000_001) }
    private static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) } }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func check(_ cancelled: @escaping @Sendable () -> Bool) throws { if cancelled() || Task.isCancelled { throw CancellationError() } }
}

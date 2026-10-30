//
//  CADAnimationService.swift
//  FloeCADKit
//
//  Document-facing keyframe animation surface. Animation data is an optional
//  document column and every authored change is ONE ordinary undoable
//  `DocumentCommand`; playback, scrubbing, frame capture and export never call
//  `session.perform` and never write the assembly baseline.
//
//  The model is renderer-neutral; the RealityKit playback/capture adapters and
//  the MP4 exporter live in `Presentation/CADAnimation*.swift`.
//

import CryptoKit
import Foundation
import simd

// MARK: - Load state

public nonisolated struct CADAnimationLoadState: Sendable, Equatable {
    public var animation: CADAnimationDocument
    public var issues: [CADAnimationIssue]
    public var hasStoredData: Bool
    public var storedDataSHA256: String?

    public init(animation: CADAnimationDocument = CADAnimationDocument(),
                issues: [CADAnimationIssue] = [],
                hasStoredData: Bool = false,
                storedDataSHA256: String? = nil) {
        self.animation = animation
        self.issues = issues
        self.hasStoredData = hasStoredData
        self.storedDataSHA256 = storedDataSHA256
    }

    public var activeClip: CADAnimationClip? { animation.activeClip }

    public func clip(withID id: UUID) -> CADAnimationClip? {
        animation.clip(withID: id)
    }

    public var isReadable: Bool { issues.isEmpty || !animation.isEmpty }
}

// MARK: - Preset kind

public nonisolated enum CADAnimationPresetKind: String, Sendable, CaseIterable {
    case turntable
    case explodeReturn

    public var localizationKey: String {
        switch self {
        case .turntable: return "cad.animation.preset.turntable"
        case .explodeReturn: return "cad.animation.preset.explode"
        }
    }
}

// MARK: - Document facade

@MainActor
public extension FloeCADDocument {
    /// Decode the optional animation column. A missing column is an empty
    /// animation; corrupt or newer data is reported and leaves geometry, the
    /// assembly and the rest of the document untouched.
    func animationLoadState() -> CADAnimationLoadState {
        let data = session.document.animationData
        guard let data, !data.isEmpty else {
            return CADAnimationLoadState()
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count <= CADAnimationDocument.maximumEncodedBytes else {
            return CADAnimationLoadState(
                animation: CADAnimationDocument(),
                issues: [CADAnimationIssue(
                    id: "animation-too-large", kind: .tooLarge,
                    detail: "The saved animation payload exceeds the 2 MB limit and was not read.")],
                hasStoredData: true, storedDataSHA256: digest)
        }
        do {
            let decoded = try CADAnimationCodec.decode(data)
            guard decoded.schemaVersion <= CADAnimationDocument.currentSchemaVersion else {
                return CADAnimationLoadState(
                    animation: CADAnimationDocument(),
                    issues: [CADAnimationIssue(
                        id: "animation-newer-schema", kind: .newerSchema,
                        detail: "The saved animation uses schema \(decoded.schemaVersion); this build reads schema \(CADAnimationDocument.currentSchemaVersion).")],
                    hasStoredData: true, storedDataSHA256: digest)
            }
            return CADAnimationLoadState(animation: decoded.sanitized(),
                                         issues: [],
                                         hasStoredData: true,
                                         storedDataSHA256: digest)
        } catch {
            return CADAnimationLoadState(
                animation: CADAnimationDocument(),
                issues: [CADAnimationIssue(
                    id: "animation-corrupt", kind: .corruptData,
                    detail: "The saved animation data could not be read; the model and assembly are unchanged.")],
                hasStoredData: true, storedDataSHA256: digest)
        }
    }

    var animationDocument: CADAnimationDocument { animationLoadState().animation }

    /// Snapshot of the live assembly identity for animation evaluation. This
    /// reads the same `assemblyData` and bodies the presentation uses; it is
    /// not a second assembly store.
    func animationSceneContext() -> CADAnimationSceneContext {
        let document = session.document
        let bodiesByID = Dictionary(uniqueKeysWithValues: document.bodies.map { ($0.id.raw, $0) })
        let assembly = (try? CADAssembly.decode(from: document.assemblyData)) ?? CADAssembly()
        var instances: [UUID: CADAnimationSceneContext.Instance] = [:]
        for instance in assembly.instances where !instance.isHidden {
            let sourceID = instance.copiedBodyID ?? instance.bodyID
            instances[instance.id] = CADAnimationSceneContext.Instance(
                id: instance.id,
                sourceBodyID: sourceID,
                sourceRevision: instance.sourceRevision,
                baseline: CADAnimationInstanceValue(
                    translationMM: instance.transform.position,
                    rotation: instance.transform.rotation))
        }
        let snapshot = sceneSnapshot(includeExplodedPreview: false)
        let bounds = Self.animationWorldBounds(snapshot.bodies)
        return CADAnimationSceneContext(
            instances: instances,
            bodyRevisions: Dictionary(uniqueKeysWithValues:
                bodiesByID.map { ($0.key, $0.value.meshRevision) }),
            boundsMinMM: bounds?.min, boundsMaxMM: bounds?.max)
    }

    /// Evaluate one clip without touching the document. `time` is clamped to
    /// the clip duration; pass `frame` through `animationFrameTime` first when
    /// exporting so UI and file metadata agree.
    func evaluateAnimation(clipID: UUID? = nil,
                           time: Double) throws -> CADAnimationEvaluation {
        let state = animationLoadState()
        let resolvedClip = clipID.flatMap { state.animation.clip(withID: $0) }
            ?? (clipID == nil ? state.animation.activeClip : nil)
        guard let clip = resolvedClip else {
            throw CADDocumentError(
                code: clipID == nil ? "no_animation_clip" : "unknown_animation_clip",
                message: clipID == nil
                    ? "This document has no animation clip yet."
                    : "No animation clip has that id.")
        }
        let evaluation = CADAnimationEvaluator.evaluate(
            clip: clip, at: time, context: animationSceneContext())
        var issues = state.issues
        issues.append(contentsOf: evaluation.issues)
        var result = evaluation
        result.issues = issues
        return result
    }

    /// Frame time for an integer frame index at `fps`, matching
    /// `CADAnimationClip.frameCount`.
    nonisolated static func animationFrameTime(frame: Int, fps: Int,
                                               duration: Double) -> Double {
        let rate = min(max(fps, 1), 60)
        let count = max(1, Int((CADAnimationClip.validDuration(duration)
            * Double(rate)).rounded()))
        let index = min(max(frame, 0), count - 1)
        return min(CADAnimationClip.validDuration(duration),
                   Double(index) / Double(rate))
    }

    // MARK: Authored changes (undoable)

    @discardableResult
    func createAnimationClip(name: String? = nil,
                             duration: Double? = nil,
                             isLooping: Bool = true,
                             speed: Double = 1) throws -> CADAnimationClip {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard animation.clips.count < CADAnimationDocument.maximumClips else {
            throw CADDocumentError(code: "animation_clip_limit",
                                   message: "A document can hold at most \(CADAnimationDocument.maximumClips) animation clips.")
        }
        let length = try Self.validatedAnimationDuration(duration)
        let cleanName = Self.validatedAnimationName(
            name ?? "Clip \(animation.clips.count + 1)",
            fallback: "Clip \(animation.clips.count + 1)")
        let clip = CADAnimationClip(name: cleanName, duration: length,
                                    isLooping: isLooping,
                                    speed: CADAnimationClip.validSpeed(speed))
        animation.clips.append(clip)
        animation.activeClipID = clip.id
        _ = try commitAnimation(animation, title: "Add Animation Clip")
        return clip
    }

    @discardableResult
    func updateAnimationClip(id: UUID,
                             name: String? = nil,
                             duration: Double? = nil,
                             isLooping: Bool? = nil,
                             speed: Double? = nil) throws -> CADAnimationClip {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let index = animation.clips.firstIndex(where: { $0.id == id }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        var clip = animation.clips[index]
        if let name { clip.name = Self.validatedAnimationName(name, fallback: clip.name) }
        if let duration { clip.duration = try Self.validatedAnimationDuration(duration) }
        if let isLooping { clip.isLooping = isLooping }
        if let speed { clip.speed = CADAnimationClip.validSpeed(speed) }
        clip = clip.sanitized()
        guard clip.duration >= 0.1 else {
            throw CADDocumentError(code: "bad_animation_duration",
                                   message: "A clip must last at least 0.1 seconds.")
        }
        animation.clips[index] = clip
        _ = try commitAnimation(animation, title: "Edit Animation Clip")
        return clip
    }

    @discardableResult
    func deleteAnimationClip(id: UUID) throws -> CADAnimationDocument {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard animation.clips.contains(where: { $0.id == id }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        animation.clips.removeAll { $0.id == id }
        if animation.activeClipID == id { animation.activeClipID = animation.clips.first?.id }
        return try commitAnimation(animation, title: "Delete Animation Clip")
    }

    @discardableResult
    func setActiveAnimationClip(id: UUID?) throws -> CADAnimationDocument {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        if let id {
            guard animation.clips.contains(where: { $0.id == id }) else {
                throw CADDocumentError(code: "unknown_animation_clip",
                                       message: "No animation clip has that id.")
            }
        }
        animation.activeClipID = id ?? animation.clips.first?.id
        return try commitAnimation(animation, title: "Select Animation Clip")
    }

    @discardableResult
    func addAnimationTrack(clipID: UUID,
                           target: CADAnimationTarget) throws -> CADAnimationTrack {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        guard target.isValid else {
            throw CADDocumentError(code: "bad_animation_target",
                                   message: target.kind == .instance
                                        ? "An instance track needs an instance id."
                                        : "A camera track cannot carry an instance id.")
        }
        var cleanTarget = target
        if target.kind == .instance {
            guard let instanceID = target.instanceID else {
                throw CADDocumentError(code: "bad_animation_target",
                                       message: "An instance track needs an instance id.")
            }
            let context = animationSceneContext()
            guard let instance = context.instances[instanceID] else {
                throw CADDocumentError(
                    code: "unknown_animation_instance",
                    message: "No visible assembly instance has that id. Add or show the instance first.")
            }
            if let bound = target.sourceBodyID, bound != instance.sourceBodyID {
                throw CADDocumentError(
                    code: "animation_source_mismatch",
                    message: "The instance places a different source body than the track names.")
            }
            cleanTarget.sourceBodyID = instance.sourceBodyID
        }
        var clip = animation.clips[clipIndex]
        guard clip.tracks.count < CADAnimationDocument.maximumTracksPerClip else {
            throw CADDocumentError(code: "animation_track_limit",
                                   message: "A clip can hold at most \(CADAnimationDocument.maximumTracksPerClip) tracks.")
        }
        guard !clip.tracks.contains(where: { $0.target.stableKey == cleanTarget.stableKey }) else {
            throw CADDocumentError(code: "duplicate_animation_track",
                                   message: "This clip already animates that object.")
        }
        let track = CADAnimationTrack(target: cleanTarget)
        clip.tracks.append(track)
        animation.clips[clipIndex] = clip
        _ = try commitAnimation(animation, title: "Add Animation Track")
        return track
    }

    @discardableResult
    func deleteAnimationTrack(clipID: UUID, trackID: UUID) throws -> CADAnimationClip {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        guard animation.clips[clipIndex].tracks.contains(where: { $0.id == trackID }) else {
            throw CADDocumentError(code: "unknown_animation_track",
                                   message: "No animation track has that id.")
        }
        animation.clips[clipIndex].tracks.removeAll { $0.id == trackID }
        _ = try commitAnimation(animation, title: "Delete Animation Track")
        return animation.clips[clipIndex]
    }

    @discardableResult
    func setAnimationKeyframe(clipID: UUID,
                              trackID: UUID,
                              keyframeID: UUID? = nil,
                              time: Double,
                              interpolation: CADAnimationInterpolation = .linear,
                              camera: CADAnimationCameraValue? = nil,
                              instance: CADAnimationInstanceValue? = nil,
                              replace: Bool = false) throws -> CADAnimationKeyframe {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        var clip = animation.clips[clipIndex]
        guard let trackIndex = clip.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw CADDocumentError(code: "unknown_animation_track",
                                   message: "No animation track has that id.")
        }
        guard time.isFinite, time >= 0, time <= clip.duration + 1e-9 else {
            throw CADDocumentError(code: "bad_animation_time",
                                   message: "A keyframe must sit between 0 and the clip duration (\(clip.duration) s).")
        }
        let target = clip.tracks[trackIndex].target
        switch target.kind {
        case .camera:
            guard let camera, camera.isValid, instance == nil else {
                throw CADDocumentError(code: "bad_animation_value",
                                       message: "A camera keyframe needs a valid camera value (distance > 0, 10–150° FOV).")
            }
        case .instance:
            guard let instance, instance.isValid, camera == nil else {
                throw CADDocumentError(code: "bad_animation_value",
                                       message: "A part keyframe needs a finite position and a non-zero quaternion.")
            }
        }
        let cleanTime = min(max(time, 0), clip.duration)
        let cleanInstance = instance.map {
            CADAnimationInstanceValue(translationMM: $0.translationMM,
                                      rotation: $0.normalizedRotation)
        }
        var keyframe: CADAnimationKeyframe
        if let keyframeID {
            guard let index = clip.tracks[trackIndex].keyframes.firstIndex(where: { $0.id == keyframeID }) else {
                throw CADDocumentError(code: "unknown_animation_keyframe",
                                       message: "No keyframe has that id on this track.")
            }
            keyframe = CADAnimationKeyframe(
                id: keyframeID, time: cleanTime, interpolation: interpolation,
                camera: camera, instance: cleanInstance)
            clip.tracks[trackIndex].keyframes[index] = keyframe
        } else if let index = clip.tracks[trackIndex].keyframes.firstIndex(where: {
            abs($0.time - cleanTime) < 1e-6
        }) {
            guard replace else {
                throw CADDocumentError(
                    code: "animation_keyframe_exists",
                    message: "A keyframe already exists at this time. Pass replace to update it.")
            }
            keyframe = CADAnimationKeyframe(
                id: clip.tracks[trackIndex].keyframes[index].id,
                time: cleanTime, interpolation: interpolation,
                camera: camera, instance: cleanInstance)
            clip.tracks[trackIndex].keyframes[index] = keyframe
        } else {
            guard clip.tracks[trackIndex].keyframes.count < CADAnimationDocument.maximumKeyframesPerTrack else {
                throw CADDocumentError(
                    code: "animation_keyframe_limit",
                    message: "A track can hold at most \(CADAnimationDocument.maximumKeyframesPerTrack) keyframes.")
            }
            keyframe = CADAnimationKeyframe(
                time: cleanTime, interpolation: interpolation,
                camera: camera, instance: cleanInstance)
            clip.tracks[trackIndex].keyframes.append(keyframe)
        }
        clip.tracks[trackIndex].keyframes = CADAnimationKeyframe.sortedAndDeduplicated(
            clip.tracks[trackIndex].keyframes, maximumTime: clip.duration)
        animation.clips[clipIndex] = clip
        _ = try commitAnimation(animation, title: "Edit Animation Keyframe")
        return keyframe
    }

    /// Convenience for the timeline: ensure the camera track and set one
    /// camera keyframe as ONE undoable step.
    @discardableResult
    func setAnimationCameraKeyframe(clipID: UUID,
                                    time: Double,
                                    camera: CADAnimationCameraValue,
                                    replace: Bool = true) throws -> CADAnimationKeyframe {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        var clip = animation.clips[clipIndex]
        guard time.isFinite, time >= 0, time <= clip.duration + 1e-9 else {
            throw CADDocumentError(code: "bad_animation_time",
                                   message: "A keyframe must sit between 0 and the clip duration.")
        }
        guard camera.isValid else {
            throw CADDocumentError(code: "bad_animation_value",
                                   message: "The camera value is not usable for a keyframe.")
        }
        let cleanTime = min(max(time, 0), clip.duration)
        var trackIndex = clip.tracks.firstIndex { $0.target.kind == .camera }
        if trackIndex == nil {
            guard clip.tracks.count < CADAnimationDocument.maximumTracksPerClip else {
                throw CADDocumentError(code: "animation_track_limit",
                                       message: "A clip can hold at most \(CADAnimationDocument.maximumTracksPerClip) tracks.")
            }
            clip.tracks.append(CADAnimationTrack(target: .camera))
            trackIndex = clip.tracks.count - 1
        }
        guard let index = trackIndex else { throw CADDocumentError(code: "animation_failed", message: "The camera track could not be created.") }
        var keyframes = clip.tracks[index].keyframes
        let keyframe: CADAnimationKeyframe
        if let existing = keyframes.firstIndex(where: { abs($0.time - cleanTime) < 1e-6 }) {
            guard replace else {
                throw CADDocumentError(code: "animation_keyframe_exists",
                                       message: "A keyframe already exists at this time.")
            }
            keyframe = CADAnimationKeyframe(id: keyframes[existing].id, time: cleanTime,
                                            interpolation: .linear, camera: camera)
            keyframes[existing] = keyframe
        } else {
            guard keyframes.count < CADAnimationDocument.maximumKeyframesPerTrack else {
                throw CADDocumentError(code: "animation_keyframe_limit",
                                       message: "A track can hold at most \(CADAnimationDocument.maximumKeyframesPerTrack) keyframes.")
            }
            keyframe = CADAnimationKeyframe(time: cleanTime, interpolation: .linear,
                                            camera: camera)
            keyframes.append(keyframe)
        }
        clip.tracks[index].keyframes = CADAnimationKeyframe.sortedAndDeduplicated(
            keyframes, maximumTime: clip.duration)
        animation.clips[clipIndex] = clip
        _ = try commitAnimation(animation, title: "Edit Animation Keyframe")
        return keyframe
    }

    /// Convenience for a free part keyframe: resolves the instance/source bind,
    /// creates its track when needed, and commits one undoable step.
    @discardableResult
    func setAnimationInstanceKeyframe(clipID: UUID,
                                      instanceID: UUID,
                                      time: Double,
                                      translationMM: SIMD3<Double>,
                                      rotation: SIMD4<Double>,
                                      sourceBodyID: UUID? = nil,
                                      replace: Bool = true) throws -> CADAnimationKeyframe {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        let context = animationSceneContext()
        guard let instance = context.instances[instanceID] else {
            throw CADDocumentError(code: "unknown_animation_instance",
                                   message: "No visible assembly instance has that id.")
        }
        if let sourceBodyID, sourceBodyID != instance.sourceBodyID {
            throw CADDocumentError(code: "animation_source_mismatch",
                                   message: "The instance places a different source body than the keyframe names.")
        }
        let value = CADAnimationInstanceValue(
            translationMM: translationMM,
            rotation: CADAnimationQuaternion.normalize(rotation))
        guard value.isValid else {
            throw CADDocumentError(code: "bad_animation_value",
                                   message: "The part keyframe needs a finite position and a non-zero rotation.")
        }
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        var clip = animation.clips[clipIndex]
        guard time.isFinite, time >= 0, time <= clip.duration + 1e-9 else {
            throw CADDocumentError(code: "bad_animation_time",
                                   message: "A keyframe must sit between 0 and the clip duration.")
        }
        let cleanTime = min(max(time, 0), clip.duration)
        let target = CADAnimationTarget.instance(instanceID,
                                                 sourceBodyID: instance.sourceBodyID)
        var trackIndex = clip.tracks.firstIndex { $0.target.stableKey == target.stableKey }
        if trackIndex == nil {
            guard clip.tracks.count < CADAnimationDocument.maximumTracksPerClip else {
                throw CADDocumentError(code: "animation_track_limit",
                                       message: "A clip can hold at most \(CADAnimationDocument.maximumTracksPerClip) tracks.")
            }
            clip.tracks.append(CADAnimationTrack(target: target))
            trackIndex = clip.tracks.count - 1
        }
        guard let index = trackIndex else { throw CADDocumentError(code: "animation_failed", message: "The part track could not be created.") }
        var keyframes = clip.tracks[index].keyframes
        let keyframe: CADAnimationKeyframe
        if let existing = keyframes.firstIndex(where: { abs($0.time - cleanTime) < 1e-6 }) {
            guard replace else {
                throw CADDocumentError(code: "animation_keyframe_exists",
                                       message: "A keyframe already exists at this time.")
            }
            keyframe = CADAnimationKeyframe(id: keyframes[existing].id, time: cleanTime,
                                            interpolation: .linear, instance: value)
            keyframes[existing] = keyframe
        } else {
            guard keyframes.count < CADAnimationDocument.maximumKeyframesPerTrack else {
                throw CADDocumentError(code: "animation_keyframe_limit",
                                       message: "A track can hold at most \(CADAnimationDocument.maximumKeyframesPerTrack) keyframes.")
            }
            keyframe = CADAnimationKeyframe(time: cleanTime, interpolation: .linear,
                                            instance: value)
            keyframes.append(keyframe)
        }
        clip.tracks[index].keyframes = CADAnimationKeyframe.sortedAndDeduplicated(
            keyframes, maximumTime: clip.duration)
        animation.clips[clipIndex] = clip
        _ = try commitAnimation(animation, title: "Edit Animation Keyframe")
        return keyframe
    }

    @discardableResult
    func removeAnimationKeyframe(clipID: UUID, trackID: UUID,
                                 keyframeID: UUID) throws -> CADAnimationClip {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        guard let clipIndex = animation.clips.firstIndex(where: { $0.id == clipID }) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        guard let trackIndex = animation.clips[clipIndex].tracks.firstIndex(where: { $0.id == trackID }) else {
            throw CADDocumentError(code: "unknown_animation_track",
                                   message: "No animation track has that id.")
        }
        guard animation.clips[clipIndex].tracks[trackIndex].keyframes.contains(where: { $0.id == keyframeID }) else {
            throw CADDocumentError(code: "unknown_animation_keyframe",
                                   message: "No keyframe has that id on this track.")
        }
        animation.clips[clipIndex].tracks[trackIndex].keyframes.removeAll { $0.id == keyframeID }
        _ = try commitAnimation(animation, title: "Delete Animation Keyframe")
        return animation.clips[clipIndex]
    }

    @discardableResult
    func applyAnimationPreset(_ kind: CADAnimationPresetKind,
                              clipID: UUID? = nil,
                              name: String? = nil,
                              duration: Double? = nil,
                              camera: CADAnimationCameraValue? = nil,
                              turns: Double = 1,
                              explodeDistanceMM: Double? = nil,
                              aspect: Double? = nil) throws -> CADAnimationClip {
        let state = animationLoadState()
        try requireWritableAnimation(state)
        var animation = state.animation
        let context = animationSceneContext()
        let clip: CADAnimationClip
        switch kind {
        case .turntable:
            let base = camera ?? CADAnimationCameraValue.fitted(
                boundsMinMM: context.boundsMinMM,
                boundsMaxMM: context.boundsMaxMM,
                aspect: aspect)
            clip = CADAnimationPreset.turntable(
                name: name ?? "Turntable",
                duration: duration ?? CADAnimationDocument.defaultDurationSeconds,
                base: base, turns: turns)
        case .explodeReturn:
            let seeds = context.instances.values
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map { seed in
                    CADAnimationInstanceSeed(instanceID: seed.id,
                                             sourceBodyID: seed.sourceBodyID,
                                             value: seed.baseline)
                }
            guard !seeds.isEmpty else {
                throw CADDocumentError(
                    code: "no_animation_instances",
                    message: "Add placed assembly instances before using the explode preset.")
            }
            if let explodeDistanceMM,
               (!explodeDistanceMM.isFinite || explodeDistanceMM <= 0 || explodeDistanceMM > 1_000_000) {
                throw CADDocumentError(code: "bad_animation_distance",
                                       message: "The explode distance must be a positive millimetre value.")
            }
            clip = CADAnimationPreset.explodeReturn(
                name: name ?? "Explode",
                duration: duration ?? CADAnimationDocument.defaultDurationSeconds,
                seeds: seeds,
                distanceMM: explodeDistanceMM)
        }
        var stored = clip
        if let clipID {
            guard let index = animation.clips.firstIndex(where: { $0.id == clipID }) else {
                throw CADDocumentError(code: "unknown_animation_clip",
                                       message: "No animation clip has that id.")
            }
            let existing = animation.clips[index]
            stored.id = existing.id
            stored.name = name.map { Self.validatedAnimationName($0, fallback: existing.name) }
                ?? existing.name
            stored.isLooping = existing.isLooping
            stored.speed = existing.speed
            animation.clips[index] = stored
        } else {
            guard animation.clips.count < CADAnimationDocument.maximumClips else {
                throw CADDocumentError(code: "animation_clip_limit",
                                       message: "A document can hold at most \(CADAnimationDocument.maximumClips) animation clips.")
            }
            animation.clips.append(stored)
            animation.activeClipID = stored.id
        }
        _ = try commitAnimation(animation, title: "Animation Preset")
        return stored
    }

    // MARK: JSON surface

    /// One JSON-shaped action for the existing `cad.document` bridge. Authored
    /// actions are ordinary undoable document edits; render/capture/export
    /// actions report `needs_async` with the exact facade method to call.
    func animationJSON(_ payload: [String: Any]) -> CADCommandOutcome {
        let action = (payload["action"] as? String) ?? "list"
        do {
            switch action {
            case "list", "query":
                return Self.jsonOutcome(status: 200, object: animationListJSON())

            case "createClip", "create":
                let clip = try createAnimationClip(
                    name: payload.string("name"),
                    duration: payload.double("duration"),
                    isLooping: payload.bool("loop") ?? payload.bool("is_looping") ?? true,
                    speed: payload.double("speed") ?? 1)
                return mutationOutcome(title: "created", clip: clip)

            case "updateClip":
                guard let id = payload.uuid("clip_id") ?? payload.uuid("clipID") else {
                    throw CADDocumentError(code: "missing_clip_id", message: "updateClip needs clip_id.")
                }
                let clip = try updateAnimationClip(
                    id: id,
                    name: payload.string("name"),
                    duration: payload.double("duration"),
                    isLooping: payload.bool("loop") ?? payload.bool("is_looping"),
                    speed: payload.double("speed"))
                return mutationOutcome(title: "updated", clip: clip)

            case "deleteClip":
                guard let id = payload.uuid("clip_id") ?? payload.uuid("clipID") else {
                    throw CADDocumentError(code: "missing_clip_id", message: "deleteClip needs clip_id.")
                }
                _ = try deleteAnimationClip(id: id)
                return mutationOutcome(title: "deleted", clip: animationLoadState().activeClip)

            case "setActiveClip":
                _ = try setActiveAnimationClip(id: payload.uuid("clip_id") ?? payload.uuid("clipID"))
                return mutationOutcome(title: "selected", clip: animationLoadState().activeClip)

            case "addTrack":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID") else {
                    throw CADDocumentError(code: "missing_clip_id", message: "addTrack needs clip_id.")
                }
                let target = try payload.animationTarget()
                let track = try addAnimationTrack(clipID: clipID, target: target)
                return mutationOutcome(title: "track_added", clip: animationLoadState().clip(withID: clipID),
                                       extra: ["track": Self.trackJSON(track)])

            case "deleteTrack":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID"),
                      let trackID = payload.uuid("track_id") ?? payload.uuid("trackID") else {
                    throw CADDocumentError(code: "missing_track_id",
                                           message: "deleteTrack needs clip_id and track_id.")
                }
                let clip = try deleteAnimationTrack(clipID: clipID, trackID: trackID)
                return mutationOutcome(title: "track_deleted", clip: clip)

            case "setCameraKeyframe":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID") else {
                    throw CADDocumentError(code: "missing_clip_id",
                                           message: "setCameraKeyframe needs clip_id.")
                }
                guard let time = payload.double("time") ?? payload.double("time_seconds") else {
                    throw CADDocumentError(code: "missing_keyframe_time",
                                           message: "setCameraKeyframe needs time in seconds.")
                }
                guard let camera = payload.animationCameraValue() else {
                    throw CADDocumentError(
                        code: "bad_animation_value",
                        message: "setCameraKeyframe needs target, distance, azimuth/elevation and fov.")
                }
                let keyframe = try setAnimationCameraKeyframe(
                    clipID: clipID, time: time, camera: camera,
                    replace: payload.bool("replace") ?? true)
                return mutationOutcome(title: "camera_keyframe_set",
                                       clip: animationLoadState().clip(withID: clipID),
                                       extra: ["keyframe": Self.keyframeJSON(keyframe)])

            case "setPartKeyframe":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID") else {
                    throw CADDocumentError(code: "missing_clip_id",
                                           message: "setPartKeyframe needs clip_id.")
                }
                guard let instanceID = payload.uuid("instance_id") ?? payload.uuid("instanceID") else {
                    throw CADDocumentError(code: "missing_instance_id",
                                           message: "setPartKeyframe needs instance_id.")
                }
                guard let time = payload.double("time") ?? payload.double("time_seconds") else {
                    throw CADDocumentError(code: "missing_keyframe_time",
                                           message: "setPartKeyframe needs time in seconds.")
                }
                guard let value = payload.animationInstanceValue() else {
                    throw CADDocumentError(
                        code: "bad_animation_value",
                        message: "setPartKeyframe needs translation_mm and rotation or rotation_degrees.")
                }
                let keyframe = try setAnimationInstanceKeyframe(
                    clipID: clipID, instanceID: instanceID, time: time,
                    translationMM: value.translationMM, rotation: value.rotation,
                    sourceBodyID: payload.uuid("source_body_id") ?? payload.uuid("sourceBodyID"),
                    replace: payload.bool("replace") ?? true)
                return mutationOutcome(title: "part_keyframe_set",
                                       clip: animationLoadState().clip(withID: clipID),
                                       extra: ["keyframe": Self.keyframeJSON(keyframe)])

            case "setKeyframe", "addKeyframe", "updateKeyframe":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID"),
                      let trackID = payload.uuid("track_id") ?? payload.uuid("trackID") else {
                    throw CADDocumentError(code: "missing_track_id",
                                           message: "setKeyframe needs clip_id and track_id.")
                }
                guard let time = payload.double("time") ?? payload.double("time_seconds") else {
                    throw CADDocumentError(code: "missing_keyframe_time",
                                           message: "setKeyframe needs time in seconds.")
                }
                let interpolation = payload.string("interpolation")
                    .flatMap(CADAnimationInterpolation.init(rawValue:)) ?? .linear
                let targetKind = try animationTargetKind(clipID: clipID, trackID: trackID)
                let camera = payload.animationCameraValue()
                let instance = payload.animationInstanceValue()
                switch targetKind {
                case .camera:
                    guard camera != nil else {
                        throw CADDocumentError(
                            code: "bad_animation_value",
                            message: "A camera keyframe needs target, distance, azimuth/elevation and fov.")
                    }
                case .instance:
                    guard instance != nil else {
                        throw CADDocumentError(
                            code: "bad_animation_value",
                            message: "A part keyframe needs translation_mm and rotation or rotation_degrees.")
                    }
                }
                let keyframe = try setAnimationKeyframe(
                    clipID: clipID, trackID: trackID,
                    keyframeID: payload.uuid("keyframe_id") ?? payload.uuid("keyframeID"),
                    time: time, interpolation: interpolation,
                    camera: camera, instance: instance,
                    replace: payload.bool("replace") ?? (action == "updateKeyframe"))
                return mutationOutcome(title: "keyframe_set",
                                       clip: animationLoadState().clip(withID: clipID),
                                       extra: ["keyframe": Self.keyframeJSON(keyframe)])

            case "deleteKeyframe", "removeKeyframe":
                guard let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID"),
                      let trackID = payload.uuid("track_id") ?? payload.uuid("trackID"),
                      let keyframeID = payload.uuid("keyframe_id") ?? payload.uuid("keyframeID") else {
                    throw CADDocumentError(code: "missing_keyframe_id",
                                           message: "deleteKeyframe needs clip_id, track_id and keyframe_id.")
                }
                let clip = try removeAnimationKeyframe(clipID: clipID, trackID: trackID,
                                                       keyframeID: keyframeID)
                return mutationOutcome(title: "keyframe_deleted", clip: clip)

            case "preset":
                guard let raw = payload.string("kind"),
                      let kind = CADAnimationPresetKind(rawValue: raw) else {
                    throw CADDocumentError(code: "bad_preset",
                                           message: "preset kind must be turntable or explodeReturn.")
                }
                let clip = try applyAnimationPreset(
                    kind,
                    clipID: payload.uuid("clip_id") ?? payload.uuid("clipID"),
                    name: payload.string("name"),
                    duration: payload.double("duration"),
                    camera: payload.animationCameraValue(),
                    turns: payload.double("turns") ?? 1,
                    explodeDistanceMM: payload.double("distance_mm") ?? payload.double("distanceMM"))
                return mutationOutcome(title: "preset", clip: clip)

            case "undo":
                guard session.undoStack.canUndo else {
                    throw CADDocumentError(code: "nothing_to_undo",
                                           message: "There is no document edit to undo.")
                }
                session.undo()
                return mutationOutcome(title: "undo", clip: animationLoadState().activeClip)

            case "redo":
                guard session.undoStack.canRedo else {
                    throw CADDocumentError(code: "nothing_to_redo",
                                           message: "There is no document edit to redo.")
                }
                session.redo()
                return mutationOutcome(title: "redo", clip: animationLoadState().activeClip)

            case "evaluate":
                let clipID = payload.uuid("clip_id") ?? payload.uuid("clipID")
                let time = payload.double("time") ?? {
                    if let frame = payload.int("frame") {
                        let state = animationLoadState()
                        let clip = clipID.flatMap { state.animation.clip(withID: $0) }
                            ?? state.animation.activeClip
                        let fps = payload.int("fps") ?? 30
                        return FloeCADDocument.animationFrameTime(
                            frame: frame, fps: fps,
                            duration: clip?.duration ?? 5)
                    }
                    return 0
                }()
                let evaluation = try evaluateAnimation(clipID: clipID, time: time)
                var object = Self.evaluationJSON(evaluation)
                object["ok"] = true
                object["revision"] = revision
                object["change_count"] = liveChangeCount
                return Self.jsonOutcome(status: 200, object: object)

            case "capture":
                return Self.jsonOutcome(status: 400, object: [
                    "ok": false, "error": "needs_async",
                    "message": "Frame capture renders the live RealityKit Present. Call captureAnimationFramePNG(clipID:time:width:height:) on the document.",
                ])

            case "export":
                return Self.jsonOutcome(status: 400, object: [
                    "ok": false, "error": "needs_async",
                    "message": "Video export is a cancellable service task. Call startAnimationExportMP4(clipID:to:settings:) or exportAnimationMP4(...).",
                ])

            default:
                throw CADDocumentError(code: "unknown_animation_action",
                                       message: "Unknown animation action '\(action)'.")
            }
        } catch let error as CADDocumentError {
            return Self.jsonOutcome(status: 400, object: [
                "ok": false, "error": error.code, "message": error.message,
            ])
        } catch {
            return Self.jsonOutcome(status: 400, object: [
                "ok": false, "error": "animation_failed", "message": error.localizedDescription,
            ])
        }
    }

    /// Bounded JSON summary for a bridge `query kind=animation` scope. No
    /// mesh/image/geometry bytes; timeline rows only.
    func animationListJSON() -> [String: Any] {
        var object = animationSummaryJSON(animationLoadState())
        object["ok"] = true
        object["scope"] = "animation"
        object["revision"] = revision
        object["change_count"] = liveChangeCount
        return object
    }

    // MARK: Internals

    private func requireWritableAnimation(_ state: CADAnimationLoadState) throws {
        guard !isReadOnly else {
            throw CADDocumentError(
                code: "document_read_only",
                message: "A document from a newer app version opens read-only; animation cannot be edited.")
        }
        if state.issues.contains(where: { $0.kind == .newerSchema }) {
            throw CADDocumentError(
                code: "animation_newer_schema",
                message: "The saved animation was written by a newer app version and is preserved read-only.")
        }
        if state.issues.contains(where: { $0.kind == .tooLarge }) {
            throw CADDocumentError(
                code: "animation_too_large",
                message: "The saved animation exceeds the readable size limit and is preserved untouched.")
        }
    }

    @discardableResult
    private func commitAnimation(_ candidate: CADAnimationDocument,
                                 title: String) throws -> CADAnimationDocument {
        let clean = candidate.sanitized()
        let data = try CADAnimationCodec.encode(clean)
        guard data.count <= CADAnimationDocument.maximumEncodedBytes else {
            throw CADDocumentError(
                code: "animation_too_large",
                message: "The animation exceeds the 2 MB document limit; remove clips or keyframes.")
        }
        let before = session.document.animationData
        guard before != data else { return clean }
        session.perform(SetAnimationDataCommand(title: title, before: before, after: data))
        return clean
    }

    private func mutationOutcome(title: String,
                                 clip: CADAnimationClip?,
                                 extra: [String: Any] = [:]) -> CADCommandOutcome {
        let state = animationLoadState()
        var object: [String: Any] = [
            "ok": true,
            "mutated": true,
            "result": title,
            "revision": revision,
            "change_count": liveChangeCount,
            "can_undo": session.undoStack.canUndo,
            "can_redo": session.undoStack.canRedo,
            "animation": animationSummaryJSON(state),
        ]
        if let clip { object["clip"] = Self.clipJSON(clip) }
        for (key, value) in extra { object[key] = value }
        return Self.jsonOutcome(status: 200, object: object)
    }

    private func animationSummaryJSON(_ state: CADAnimationLoadState) -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": state.animation.schemaVersion,
            "has_data": state.hasStoredData,
            "clip_count": state.animation.clipCount,
            "track_count": state.animation.trackCount,
            "keyframe_count": state.animation.keyframeCount,
            "clips": state.animation.clips.map(Self.clipJSON),
            "issues": state.issues.map(Self.issueJSON),
        ]
        if let active = state.animation.activeClip {
            object["active_clip_id"] = active.id.uuidString
        } else {
            object["active_clip_id"] = NSNull()
        }
        if let digest = state.storedDataSHA256 { object["data_sha256"] = digest }
        return object
    }

    static func validatedAnimationDuration(_ value: Double?) throws -> Double {
        guard let value else { return CADAnimationDocument.defaultDurationSeconds }
        guard value.isFinite,
              value >= CADAnimationDocument.minimumDurationSeconds,
              value <= CADAnimationDocument.maximumDurationSeconds else {
            throw CADDocumentError(
                code: "bad_animation_duration",
                message: "Animation duration must be between \(CADAnimationDocument.minimumDurationSeconds) and \(CADAnimationDocument.maximumDurationSeconds) seconds.")
        }
        return value
    }

    static func validatedAnimationName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? fallback : trimmed
        return String(name.prefix(CADAnimationDocument.maximumNameLength))
    }

    internal static func animationWorldBounds(_ bodies: [CADSceneBodyResource])
    -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var minimum = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        var found = false
        for body in bodies where !body.isHidden {
            let t = body.transform
            guard t.count == 16, t.allSatisfy({ $0.isFinite }) else { continue }
            let m = simd_double4x4(
                SIMD4(t[0], t[1], t[2], t[3]),
                SIMD4(t[4], t[5], t[6], t[7]),
                SIMD4(t[8], t[9], t[10], t[11]),
                SIMD4(t[12], t[13], t[14], t[15]))
            let a = SIMD3<Double>(body.mesh.boundsMin)
            let b = SIMD3<Double>(body.mesh.boundsMax)
            for x in [a.x, b.x] {
                for y in [a.y, b.y] {
                    for z in [a.z, b.z] {
                        let world = m * SIMD4(x, y, z, 1)
                        minimum = simd_min(minimum, SIMD3(world.x, world.y, world.z))
                        maximum = simd_max(maximum, SIMD3(world.x, world.y, world.z))
                        found = true
                    }
                }
            }
        }
        return found ? (minimum, maximum) : nil
    }

    // MARK: JSON image helpers

    static func clipJSON(_ clip: CADAnimationClip) -> [String: Any] {
        [
            "id": clip.id.uuidString,
            "name": clip.name,
            "duration": clip.duration,
            "loop": clip.isLooping,
            "speed": clip.speed,
            "track_count": clip.tracks.count,
            "keyframe_count": clip.keyframeCount,
            "tracks": clip.tracks.map(trackJSON),
        ]
    }

    static func trackJSON(_ track: CADAnimationTrack) -> [String: Any] {
        var object: [String: Any] = [
            "id": track.id.uuidString,
            "kind": track.target.kind.rawValue,
            "keyframe_count": track.keyframes.count,
            "keyframes": track.keyframes.map(keyframeJSON),
        ]
        if let instanceID = track.target.instanceID {
            object["instance_id"] = instanceID.uuidString
        }
        if let sourceBodyID = track.target.sourceBodyID {
            object["source_body_id"] = sourceBodyID.uuidString
        }
        return object
    }

    static func keyframeJSON(_ keyframe: CADAnimationKeyframe) -> [String: Any] {
        var object: [String: Any] = [
            "id": keyframe.id.uuidString,
            "time": keyframe.time,
            "interpolation": keyframe.interpolation.rawValue,
        ]
        if let camera = keyframe.camera {
            object["camera"] = [
                "target": [camera.target.x, camera.target.y, camera.target.z],
                "distance": camera.distance,
                "azimuth_radians": camera.azimuthRadians,
                "elevation_radians": camera.elevationRadians,
                "fov_y_degrees": camera.fovYDegrees,
            ]
        }
        if let instance = keyframe.instance {
            object["instance"] = [
                "translation_mm": [instance.translationMM.x,
                                   instance.translationMM.y,
                                   instance.translationMM.z],
                "rotation": [instance.rotation.x, instance.rotation.y,
                             instance.rotation.z, instance.rotation.w],
            ]
        }
        return object
    }

    static func issueJSON(_ issue: CADAnimationIssue) -> [String: Any] {
        var object: [String: Any] = [
            "id": issue.id,
            "kind": issue.kind.rawValue,
            "message": FloeCADStrings.text(issue.localizationKey, issue.detail),
            "detail": issue.detail,
        ]
        if let clipID = issue.clipID { object["clip_id"] = clipID.uuidString }
        if let trackID = issue.trackID { object["track_id"] = trackID.uuidString }
        if let instanceID = issue.instanceID { object["instance_id"] = instanceID.uuidString }
        return object
    }

    static func evaluationJSON(_ evaluation: CADAnimationEvaluation) -> [String: Any] {
        var instances: [[String: Any]] = []
        for (id, value) in evaluation.instances.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            instances.append([
                "instance_id": id.uuidString,
                "translation_mm": [value.translationMM.x, value.translationMM.y, value.translationMM.z],
                "rotation": [value.rotation.x, value.rotation.y, value.rotation.z, value.rotation.w],
            ])
        }
        var object: [String: Any] = [
            "clip_id": evaluation.clipID.uuidString,
            "time": evaluation.time,
            "duration": evaluation.duration,
            "instances": instances,
            "issues": evaluation.issues.map(issueJSON),
        ]
        if let camera = evaluation.camera {
            object["camera"] = [
                "target": [camera.target.x, camera.target.y, camera.target.z],
                "distance": camera.distance,
                "azimuth_radians": camera.azimuthRadians,
                "elevation_radians": camera.elevationRadians,
                "fov_y_degrees": camera.fovYDegrees,
            ]
        }
        return object
    }

    private func animationTargetKind(clipID: UUID, trackID: UUID) throws -> CADAnimationTarget.Kind {
        let state = animationLoadState()
        guard let clip = state.animation.clip(withID: clipID) else {
            throw CADDocumentError(code: "unknown_animation_clip",
                                   message: "No animation clip has that id.")
        }
        guard let track = clip.tracks.first(where: { $0.id == trackID }) else {
            throw CADDocumentError(code: "unknown_animation_track",
                                   message: "No animation track has that id.")
        }
        return track.target.kind
    }
}

// MARK: - JSON parse helpers

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func uuid(_ key: String) -> UUID? {
        guard let raw = self[key] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    func vector3(_ key: String) -> SIMD3<Double>? {
        guard let values = self[key] as? [Any], values.count == 3 else { return nil }
        let numbers = values.compactMap { value -> Double? in
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber { return value.doubleValue }
            return nil
        }
        guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD3(numbers[0], numbers[1], numbers[2])
    }

    func vector4(_ key: String) -> SIMD4<Double>? {
        guard let values = self[key] as? [Any], values.count == 4 else { return nil }
        let numbers = values.compactMap { value -> Double? in
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber { return value.doubleValue }
            return nil
        }
        guard numbers.count == 4, numbers.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD4(numbers[0], numbers[1], numbers[2], numbers[3])
    }

    func animationTarget() throws -> CADAnimationTarget {
        if let nested = self["target"] as? [String: Any] {
            return try nested.animationTarget()
        }
        let rawKind = string("kind") ?? string("target_kind") ?? "camera"
        switch rawKind {
        case "camera":
            return .camera
        case "instance", "part":
            guard let instanceID = uuid("instance_id") ?? uuid("instanceID") else {
                throw CADDocumentError(code: "missing_instance_id",
                                       message: "An instance track needs instance_id.")
            }
            return .instance(instanceID,
                             sourceBodyID: uuid("source_body_id") ?? uuid("sourceBodyID"))
        default:
            throw CADDocumentError(code: "bad_animation_target",
                                   message: "Track kind must be camera or instance.")
        }
    }

    func animationCameraValue() -> CADAnimationCameraValue? {
        if let raw = self["camera"] as? [String: Any] {
            return Self.cameraValue(raw)
        }
        return Self.cameraValue(self)
    }

    static func cameraValue(_ raw: [String: Any]) -> CADAnimationCameraValue? {
        let target = raw.vector3("target") ?? raw.vector3("position")
        let distance = raw.double("distance")
        var azimuth = raw.double("azimuth_radians") ?? raw.double("azimuth")
        var elevation = raw.double("elevation_radians") ?? raw.double("elevation")
        if let degrees = raw.double("azimuth_degrees") ?? raw.double("azimuthDegrees") {
            azimuth = degrees * .pi / 180
        }
        if let degrees = raw.double("elevation_degrees") ?? raw.double("elevationDegrees") {
            elevation = degrees * .pi / 180
        }
        let fov = raw.double("fov_y_degrees") ?? raw.double("fov") ?? raw.double("fovY")
        guard let target, let distance, let azimuth, let elevation, let fov else {
            return nil
        }
        let value = CADAnimationCameraValue(
            target: target, distance: distance,
            azimuthRadians: azimuth, elevationRadians: elevation,
            fovYDegrees: fov)
        return value.isValid ? value : nil
    }

    func animationInstanceValue() -> CADAnimationInstanceValue? {
        if let raw = self["instance"] as? [String: Any] {
            return Self.instanceValue(raw)
        }
        return Self.instanceValue(self)
    }

    static func instanceValue(_ raw: [String: Any]) -> CADAnimationInstanceValue? {
        let translation = raw.vector3("translation_mm")
            ?? raw.vector3("translation")
            ?? raw.vector3("position")
        guard let translation else { return nil }
        let rotation: SIMD4<Double>
        if let quaternion = raw.vector4("rotation") ?? raw.vector4("quaternion") {
            rotation = CADAnimationQuaternion.normalize(quaternion)
        } else if let euler = raw.vector3("rotation_degrees") ?? raw.vector3("rotationDegrees") {
            rotation = CADAnimationQuaternion.fromEulerDegrees(euler)
        } else {
            rotation = SIMD4(0, 0, 0, 1)
        }
        let value = CADAnimationInstanceValue(translationMM: translation, rotation: rotation)
        return value.isValid ? value : nil
    }
}

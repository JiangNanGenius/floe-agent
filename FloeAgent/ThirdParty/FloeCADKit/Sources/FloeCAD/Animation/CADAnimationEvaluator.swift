//
//  CADAnimationEvaluator.swift
//  FloeCADKit
//
//  Pure sampling of one animation clip. No renderer, no document mutation and
//  no assembly write: the result is a value the presentation can apply for one
//  transient frame (playback, scrub, capture or export).
//

import Foundation
import simd

public nonisolated enum CADAnimationEvaluator {
    /// Sample `clip` at `time`. Times are clamped to the clip duration. Keys
    /// are sorted here so a decode from an older/hand-edited payload still
    /// samples deterministically.
    public static func evaluate(clip: CADAnimationClip,
                                at time: Double,
                                context: CADAnimationSceneContext) -> CADAnimationEvaluation {
        let duration = CADAnimationClip.validDuration(clip.duration)
        let clamped = time.isFinite ? min(max(time, 0), duration) : 0
        var issues: [CADAnimationIssue] = []
        var camera: CADAnimationCameraValue?
        var instances: [UUID: CADAnimationInstanceValue] = [:]
        var seen = Set<String>()

        for track in clip.tracks {
            if track.keyframes.isEmpty { continue }
            guard track.target.isValid else {
                issues.append(CADAnimationIssue(
                    id: "invalid-target-\(track.id.uuidString)",
                    kind: .invalidTrackValue, clipID: clip.id, trackID: track.id,
                    detail: "The track target is incomplete and was skipped."))
                continue
            }
            guard seen.insert(track.target.stableKey).inserted else {
                issues.append(CADAnimationIssue(
                    id: "duplicate-\(track.id.uuidString)",
                    kind: .duplicateTrack, clipID: clip.id, trackID: track.id,
                    detail: "More than one track targets the same object; only the first is used."))
                continue
            }
            switch track.target.kind {
            case .camera:
                guard let value = sampleCamera(track, at: clamped, clip: clip,
                                               issues: &issues) else { continue }
                camera = value
            case .instance:
                guard let instanceID = track.target.instanceID else { continue }
                guard let instance = context.instances[instanceID] else {
                    issues.append(CADAnimationIssue(
                        id: "missing-instance-\(instanceID.uuidString)",
                        kind: .missingInstance, clipID: clip.id, trackID: track.id,
                        instanceID: instanceID,
                        detail: "An animated assembly instance no longer exists; its baseline placement is used."))
                    continue
                }
                if let bound = track.target.sourceBodyID,
                   bound != instance.sourceBodyID {
                    issues.append(CADAnimationIssue(
                        id: "rebound-\(instanceID.uuidString)-\(track.id.uuidString)",
                        kind: .sourceBindingChanged, clipID: clip.id, trackID: track.id,
                        instanceID: instanceID,
                        detail: "The instance now places a different source body; its saved animation was not applied."))
                    continue
                }
                if context.bodyRevisions[instance.sourceBodyID] == nil {
                    issues.append(CADAnimationIssue(
                        id: "missing-source-\(instanceID.uuidString)-\(track.id.uuidString)",
                        kind: .missingSource, clipID: clip.id, trackID: track.id,
                        instanceID: instanceID,
                        detail: "The instance's source body is missing; its baseline placement is used."))
                    continue
                }
                if let storedRevision = instance.sourceRevision,
                   let liveRevision = context.bodyRevisions[instance.sourceBodyID],
                   storedRevision != liveRevision {
                    issues.append(CADAnimationIssue(
                        id: "source-updated-\(instanceID.uuidString)-\(track.id.uuidString)",
                        kind: .sourceGeometryUpdated, clipID: clip.id, trackID: track.id,
                        instanceID: instanceID,
                        detail: "The placed source body changed after this animation was authored; review the keyframes."))
                }
                guard let value = sampleInstance(track, at: clamped, clip: clip,
                                                 issues: &issues) else { continue }
                instances[instanceID] = value
            }
        }

        return CADAnimationEvaluation(
            clipID: clip.id, time: clamped, duration: duration,
            camera: camera, instances: instances, issues: issues)
    }

    // MARK: Sampling

    static func sampleCamera(_ track: CADAnimationTrack,
                             at time: Double,
                             clip: CADAnimationClip,
                             issues: inout [CADAnimationIssue]) -> CADAnimationCameraValue? {
        let keys = track.keyframes
            .filter { $0.isValid(for: .camera) }
            .sorted { $0.time < $1.time }
        guard !keys.isEmpty else {
            issues.append(CADAnimationIssue(
                id: "empty-camera-\(track.id.uuidString)",
                kind: .invalidTrackValue, clipID: clip.id, trackID: track.id,
                detail: "The camera track has no valid keyframes."))
            return nil
        }
        if keys.count == 1 { return keys[0].camera }
        if time <= keys[0].time { return keys[0].camera }
        if time >= keys[keys.count - 1].time { return keys[keys.count - 1].camera }
        var index = 0
        while index + 1 < keys.count && keys[index + 1].time <= time { index += 1 }
        let start = keys[index]
        let end = keys[min(index + 1, keys.count - 1)]
        guard let a = start.camera, let b = end.camera else { return start.camera }
        let span = end.time - start.time
        let raw = span > 1e-9 ? (time - start.time) / span : 0
        return a.interpolated(to: b, progress: start.interpolation.eased(raw))
    }

    static func sampleInstance(_ track: CADAnimationTrack,
                               at time: Double,
                               clip: CADAnimationClip,
                               issues: inout [CADAnimationIssue]) -> CADAnimationInstanceValue? {
        let keys = track.keyframes
            .filter { $0.isValid(for: .instance) }
            .sorted { $0.time < $1.time }
        guard !keys.isEmpty else {
            issues.append(CADAnimationIssue(
                id: "empty-instance-\(track.id.uuidString)",
                kind: .invalidTrackValue, clipID: clip.id, trackID: track.id,
                instanceID: track.target.instanceID,
                detail: "The part track has no valid keyframes."))
            return nil
        }
        if keys.count == 1 { return keys[0].instance }
        if time <= keys[0].time { return keys[0].instance }
        if time >= keys[keys.count - 1].time { return keys[keys.count - 1].instance }
        var index = 0
        while index + 1 < keys.count && keys[index + 1].time <= time { index += 1 }
        let start = keys[index]
        let end = keys[min(index + 1, keys.count - 1)]
        guard let a = start.instance, let b = end.instance else { return start.instance }
        let span = end.time - start.time
        let raw = span > 1e-9 ? (time - start.time) / span : 0
        return a.interpolated(to: b, progress: start.interpolation.eased(raw))
    }
}

//
//  CADAnimationPlayback.swift
//  FloeCADKit
//
//  RealityKit adapters and the transient playback driver for the animation
//  timeline. A frame is applied directly to the live Present stage; nothing
//  here calls `session.perform`, writes `assemblyData` or touches the undo
//  stack. Baseline placement is restored by `clearAnimation()` whenever
//  playback stops or Present leaves.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import Observation
import simd

// MARK: - Value adapters

@MainActor
enum CADAnimationPresentationAdapter {
    static func cameraValue(_ camera: CADPresentationCamera) -> CADAnimationCameraValue {
        CADAnimationCameraValue(
            target: SIMD3(Double(camera.target.x), Double(camera.target.y),
                          Double(camera.target.z)),
            distance: Double(camera.distance),
            azimuthRadians: Double(camera.azimuthRadians),
            elevationRadians: Double(camera.elevationRadians),
            fovYDegrees: Double(camera.fovYDegrees))
    }

    static func camera(_ value: CADAnimationCameraValue) -> CADPresentationCamera? {
        guard value.isValid else { return nil }
        return CADPresentationCamera(
            target: SIMD3(Float(value.target.x), Float(value.target.y), Float(value.target.z)),
            distance: Float(value.distance),
            azimuthRadians: Float(value.azimuthRadians),
            elevationRadians: Float(value.elevationRadians),
            fovYDegrees: Float(value.fovYDegrees))
    }

    /// Final presentation matrices for the evaluated instance placements.
    /// The instance identity is preserved; each placement is composed onto its
    /// source body's document transform exactly like the static scene builder.
    static func instanceMatrices(_ evaluation: CADAnimationEvaluation,
                                 assembly: CADAssembly,
                                 bodiesByID: [UUID: Body]) -> [UUID: simd_float4x4] {
        guard !evaluation.instances.isEmpty else { return [:] }
        var result: [UUID: simd_float4x4] = [:]
        for (instanceID, value) in evaluation.instances {
            guard let instance = assembly.instance(instanceID) else { continue }
            let sourceID = instance.copiedBodyID ?? instance.bodyID
            guard let body = bodiesByID[sourceID] else { continue }
            var placement = instance.transform
            placement.position = value.translationMM
            placement.rotation = value.normalizedRotation
            guard placement.isPlaceable else { continue }
            let composed = placement.placement3D().composed(onto: body.transform)
            let m = composed.matrix
            let columns = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                           m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                           m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                           m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
            guard let matrix = CADPresentationAxes.matrix(columns) else { continue }
            result[instanceID] = matrix
        }
        return result
    }

    static func instanceMatrices(_ evaluation: CADAnimationEvaluation,
                                 document: FloeCADDocument) -> [UUID: simd_float4x4] {
        let bodies = document.session.document.bodies
        let assembly = (try? CADAssembly.decode(
            from: document.session.document.assemblyData)) ?? CADAssembly()
        return instanceMatrices(
            evaluation, assembly: assembly,
            bodiesByID: Dictionary(uniqueKeysWithValues: bodies.map { ($0.id.raw, $0) }))
    }
}

// MARK: - Playback driver

/// Transient timeline state: play/pause/scrub/loop/speed. It owns no document
/// data and never enrolls an undo command; the authored clip is read once and
/// refreshed when the document changes.
@MainActor
@Observable
final class CADAnimationPlaybackModel {
    private(set) var isPlaying = false
    /// Current playhead in seconds; public so the slider can read it.
    var time: Double = 0
    var loop = true
    var speed: Double = 1
    private(set) var clipID: UUID?
    private(set) var duration: Double = CADAnimationDocument.defaultDurationSeconds
    private(set) var issues: [CADAnimationIssue] = []
    private(set) var isLeased = false

    @ObservationIgnored private weak var document: FloeCADDocument?
    @ObservationIgnored private weak var handle: CADPresentationHandle?
    @ObservationIgnored private var clip: CADAnimationClip?
    @ObservationIgnored private var context: CADAnimationSceneContext?
    @ObservationIgnored private var assembly = CADAssembly()
    @ObservationIgnored private var bodiesByID: [UUID: Body] = [:]
    @ObservationIgnored private var loadIssues: [CADAnimationIssue] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startChangeCount = 0
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var lastTick = Date()

    deinit { ticker?.cancel() }

    var hasClip: Bool { clipID != nil }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    // MARK: Attachment

    func attach(document: FloeCADDocument, handle: CADPresentationHandle,
                clipID: UUID?) {
        stop()
        self.document = document
        self.handle = handle
        self.clipID = clipID
        synchronize(with: document.animationLoadState())
        self.clipID = clipID.flatMap { document.animationDocument.clip(withID: $0) }?.id
            ?? document.animationDocument.activeClip?.id
        if let selected = self.clipID,
           let selectedClip = document.animationDocument.clip(withID: selected) {
            configure(selectedClip)
        }
        refreshFence()
    }

    /// Keep the timeline in sync with the live document after an authored
    /// edit. Playing stops because the stage is about to be rebuilt.
    func documentDidChange(_ state: CADAnimationLoadState) {
        if isPlaying { stop() }
        synchronize(with: state)
        time = min(max(time, 0), duration)
        refreshFence()
    }

    private func synchronize(with state: CADAnimationLoadState) {
        loadIssues = state.issues
        let selected = clipID.flatMap { state.animation.clip(withID: $0) }
            ?? state.animation.activeClip
        configure(selected)
        context = document?.animationSceneContext()
        if let document {
            assembly = (try? CADAssembly.decode(
                from: document.session.document.assemblyData)) ?? CADAssembly()
            bodiesByID = Dictionary(uniqueKeysWithValues:
                document.session.document.bodies.map { ($0.id.raw, $0) })
        }
        issues = loadIssues
    }

    private func configure(_ clip: CADAnimationClip?) {
        guard let clip else {
            self.clip = nil
            clipID = nil
            duration = CADAnimationDocument.defaultDurationSeconds
            time = 0
            issues = loadIssues
            return
        }
        if clipID != clip.id {
            time = 0
            loop = clip.isLooping
            speed = clip.speed
        }
        self.clip = clip
        clipID = clip.id
        duration = clip.duration
    }

    func setLoop(_ value: Bool) { loop = value }

    func setSpeed(_ value: Double) {
        speed = CADAnimationClip.validSpeed(value)
    }

    private func refreshFence() {
        guard let document, let controller = handle?.controller else { return }
        startChangeCount = document.liveChangeCount
        startGeneration = controller.renderGeneration
        isLeased = controller.isAnimationLeased
    }

    // MARK: Transport

    func play() {
        guard !isPlaying, let document, let handle,
              let controller = handle.controller, clipID != nil, clip != nil else { return }
        if time >= duration - 1e-6 { time = 0 }
        refreshFence()
        if controller.isAnimationLeased {
            isLeased = true
            return
        }
        isPlaying = true
        lastTick = Date()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                let now = Date()
                let delta = min(max(now.timeIntervalSince(self.lastTick), 0), 0.25)
                self.lastTick = now
                self.advance(by: delta * self.speed)
            }
        }
    }

    func pause() {
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    /// Return to the document baseline and camera pose. This is the only
    /// action that releases a scrubbed frame.
    func stop() {
        pause()
        time = 0
        issues = loadIssues
        handle?.controller?.clearAnimation()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func scrub(to newTime: Double) {
        pause()
        let clamped = min(max(newTime.isFinite ? newTime : 0, 0), duration)
        time = clamped
        refreshFence()
        applyCurrentFrame()
    }

    /// Re-apply the current frame after a stage rebuild while the user holds a
    /// paused/scrubbed pose.
    func reapply() {
        guard !isPlaying else { return }
        refreshFence()
        applyCurrentFrame()
    }

    // MARK: Frame loop

    private func advance(by delta: Double) {
        guard let controller = handle?.controller, clip != nil else {
            stop()
            return
        }
        isLeased = controller.isAnimationLeased
        if isLeased {
            // An export owns the renderer; stop advancing rather than
            // interleaving frames into the file.
            pause()
            return
        }
        let next = time + delta
        if loop {
            time = duration > 0 ? next.truncatingRemainder(dividingBy: duration) : 0
        } else if next >= duration {
            time = duration
            applyCurrentFrame()
            pause()
            return
        } else {
            time = next
        }
        applyCurrentFrame()
    }

    private func applyCurrentFrame() {
        guard let document, let handle, let controller = handle.controller,
              let clip, let context else { return }
        if document.liveChangeCount != startChangeCount
            || controller.renderGeneration != startGeneration {
            stop()
            return
        }
        let evaluation = CADAnimationEvaluator.evaluate(
            clip: clip, at: time, context: context)
        let camera = evaluation.camera.flatMap(CADAnimationPresentationAdapter.camera)
        let matrices = CADAnimationPresentationAdapter.instanceMatrices(
            evaluation, assembly: assembly, bodiesByID: bodiesByID)
        let token = String(format: "anim|%@|%.6f|%d",
                           clip.id.uuidString, evaluation.time, matrices.count)
        let applied = controller.applyAnimation(
            camera: camera, instanceTransforms: matrices,
            token: token, expectedGeneration: startGeneration,
            lease: nil)
        if !applied, controller.renderGeneration != startGeneration {
            stop()
            return
        }
        issues = loadIssues + evaluation.issues
    }

    /// Camera value for a keyframe capture: the live view if Present is
    /// ready, else the saved pose, else nil (no fabricated value).
    func cameraValueForKeyframe(handle: CADPresentationHandle) -> CADAnimationCameraValue? {
        guard let camera = handle.currentCamera ?? handle.savedCamera else { return nil }
        return CADAnimationPresentationAdapter.cameraValue(camera)
    }

    /// Transient frame data used by the exporter so it renders exactly the
    /// same evaluation as playback without reading the document per frame.
    func exportFrame(at time: Double) -> (evaluation: CADAnimationEvaluation,
                                          camera: CADPresentationCamera?,
                                          matrices: [UUID: simd_float4x4])? {
        guard let clip, let context else { return nil }
        let evaluation = CADAnimationEvaluator.evaluate(
            clip: clip, at: time, context: context)
        return (evaluation,
                evaluation.camera.flatMap(CADAnimationPresentationAdapter.camera),
                CADAnimationPresentationAdapter.instanceMatrices(
                    evaluation, assembly: assembly, bodiesByID: bodiesByID))
    }

    var currentClip: CADAnimationClip? { clip }
    var currentContext: CADAnimationSceneContext? { context }
}

#endif

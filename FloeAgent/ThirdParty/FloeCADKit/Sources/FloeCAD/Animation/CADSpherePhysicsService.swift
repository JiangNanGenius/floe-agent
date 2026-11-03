// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

private actor CADSpherePhysicsWorker {
    static let shared = CADSpherePhysicsWorker()
    func compute(_ definition: CADSpherePhysicsDefinition, cacheID: UUID, clipID: UUID,
                 cancellation: CADMeshCancellation, externalCancellation: (any MeshImportCancellationChecking)?,
                 before: (@Sendable () -> Void)?,
                 after: (@Sendable () -> Void)?) throws -> CADSpherePhysicsCache {
        before?()
        let cache = try CADSpherePhysicsKernel.compute(definition, cacheID: cacheID, clipID: clipID, cancellation: cancellation, externalCancellation: externalCancellation)
        after?(); return cache
    }
}

@MainActor
public final class CADSpherePhysicsService {
    public nonisolated static let stateDidChange = Notification.Name("FloeCADSpherePhysicsStateDidChange")
    public nonisolated static let reads: Set<String> = ["physics.get", "physics.status", "physics.cancel"]
    public nonisolated static let mutations: Set<String> = ["physics.configure", "physics.run", "physics.clear"]
    private struct Run { let id: UUID; let cancellation: CADMeshCancellation }
    private static var active: [ObjectIdentifier: Run] = [:]
    #if DEBUG
    static var testBeforeCompute: (@Sendable () -> Void)?
    static var testBeforeCommit: (@Sendable () -> Void)?
    #endif
    private let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document = document }

    @discardableResult
    static func cancel(for document: FloeCADDocument) -> Bool {
        guard let run = active[ObjectIdentifier(document)] else { return false }
        run.cancellation.cancel(); return true // request only; caller joins compute
    }

    func handleSync(action: String, args: [String: Any]) -> [String: Any] {
        if action == "physics.run" { return ["ok": false, "mutated": false, "error": "needs_async", "message": "Use the existing async scene service for simulation."] }
        do { return try light(action, args) } catch { return failure(error) }
    }

    public func handle(action: String, args: [String: Any],
                       externalCancellation: (any MeshImportCancellationChecking)? = nil) async -> [String: Any] {
        do {
            guard externalCancellation?.isCancelled != true else { throw CADSpherePhysicsError.cancelled }
            if action != "physics.run" { return try light(action, args) }
            try writable(args)
            let key = ObjectIdentifier(document)
            guard Self.active[key] == nil, Self.active.count < 2 else { throw CADSpherePhysicsError.busy }
            guard let record = try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData) else { throw CADSpherePhysicsError.invalid }
            try validateSources(record.definition)
            let count = document.liveChangeCount, definitionSHA = CADSpherePhysicsKernel.digest(record.definition)
            let runID = UUID(), cacheID = UUID(), clipID = record.cache?.clipID ?? UUID(), cancellation = CADMeshCancellation()
            Self.active[key] = Run(id: runID, cancellation: cancellation)
            NotificationCenter.default.post(name: Self.stateDidChange, object: document)
            defer {
                if Self.active[key]?.id == runID {
                    Self.active[key] = nil
                    NotificationCenter.default.post(name: Self.stateDidChange, object: document)
                }
            }
            #if DEBUG
            let before = Self.testBeforeCompute, after = Self.testBeforeCommit
            #else
            let before: (@Sendable () -> Void)? = nil, after: (@Sendable () -> Void)? = nil
            #endif
            let worker = Task.detached(priority: .userInitiated) {
                try await CADSpherePhysicsWorker.shared.compute(record.definition, cacheID: cacheID, clipID: clipID,
                    cancellation: cancellation, externalCancellation: externalCancellation, before: before, after: after)
            }
            let cache = try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
            guard !Task.isCancelled, !cancellation.isCancelled, externalCancellation?.isCancelled != true else { throw CADSpherePhysicsError.cancelled }
            guard !document.isClosed, document.liveChangeCount == count,
                  Self.active[key]?.id == runID,
                  let current = try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData),
                  CADSpherePhysicsKernel.digest(current.definition) == definitionSHA else { throw CADSpherePhysicsError.stale }
            try writable([:]); try validateSources(current.definition)
            var completed = current; completed.cache = cache; try completed.validate()
            let state = document.animationLoadState()
            guard state.issues.isEmpty else { throw CADSpherePhysicsError.invalid }
            var animation = state.animation
            var clip = CADAnimationClip(id: clipID, name: current.definition.name, duration: current.definition.duration, isLooping: false)
            clip.physicsCacheID = cache.id
            if let index = animation.clips.firstIndex(where: { $0.id == clipID }) {
                guard animation.clips[index].physicsCacheID == current.cache?.id else { throw CADSpherePhysicsError.stale }
                animation.clips[index] = clip
            } else {
                guard animation.clips.count < CADAnimationDocument.maximumClips else { throw CADSpherePhysicsError.budget }
                animation.clips.append(clip)
            }
            animation.activeClipID = clipID; animation.schemaVersion = max(animation.schemaVersion, CADAnimationDocument.physicsSchemaVersion)
            guard externalCancellation?.isCancelled != true else { throw CADSpherePhysicsError.cancelled }
            try commit(completed, animation: animation, externalCancellation: externalCancellation)
            return ["ok": true, "mutated": true, "cache_id": cache.id.uuidString, "clip_id": clipID.uuidString,
                    "frames_sha256": cache.framesSHA256, "state_count": cache.frames.count, "contacts": cache.contactCount,
                    "step_hz": 240, "collision_shape": "explicit_sphere_proxy", "change_count": document.liveChangeCount]
        } catch { return failure(error) }
    }

    private func failure(_ error: Error) -> [String: Any] {
        if let value = error as? CADSpherePhysicsError { return ["ok": false, "mutated": false, "error": value.rawValue, "message": value.localizedDescription] }
        if let value = error as? CADDocumentError { return ["ok": false, "mutated": false, "error": value.code, "message": value.message] }
        return ["ok": false, "mutated": false, "error": "invalid_sphere_physics", "message": error.localizedDescription]
    }

    private func writable(_ args: [String: Any]) throws {
        guard !document.isClosed else { throw CADSpherePhysicsError.stale }
        if let block = document.session.writeBlock { throw CADDocumentError(code: block.code, message: block.message) }
        guard !document.isReadOnly else { throw CADDocumentError(code: "read_only", message: "The document is read-only.") }
        guard !Task.isCancelled else { throw CADSpherePhysicsError.cancelled }
        if let raw = args["expected_change_count"] {
            let pin = try number(raw, fallback: -1)
            guard pin.rounded() == pin, pin == Double(document.liveChangeCount) else { throw CADSpherePhysicsError.stale }
        }
    }

    private func light(_ action: String, _ args: [String: Any]) throws -> [String: Any] {
        guard !document.isClosed else { throw CADSpherePhysicsError.stale }
        if action == "physics.cancel" {
            guard let run = Self.active[ObjectIdentifier(document)] else { return ["ok": true, "mutated": false, "cancel_requested": false] }
            guard args["run_id"] as? String == run.id.uuidString else { throw CADSpherePhysicsError.stale }
            run.cancellation.cancel()
            return ["ok": true, "mutated": false, "cancel_requested": true, "run_id": run.id.uuidString]
        }
        if action == "physics.get" || action == "physics.status" {
            let record = try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData)
            let run = Self.active[ObjectIdentifier(document)]
            let current = record.map { (try? validateSources($0.definition)) != nil } ?? false
            var result: [String: Any] = ["ok": true, "mutated": false, "running": run != nil,
                "cancel_requested": run?.cancellation.isCancelled ?? false, "change_count": document.liveChangeCount,
                "state": run != nil ? "running" : (record == nil ? "empty" : (current ? (record?.cache == nil ? "configured" : "ready") : "stale")),
                "step_hz": 240, "collision_shape": "explicit_sphere_proxy", "ground_sleep_mm_s": 1,
                "scope": "frictionless spheres and one static horizontal plane; no CAD-exact contacts, angular dynamics, cloth, particles or fluids"]
            if let run { result["run_id"] = run.id.uuidString }
            if let record { result["duration"] = record.definition.duration; result["sphere_count"] = record.definition.spheres.count }
            if let cache = record?.cache { result["cache_id"] = cache.id.uuidString; result["clip_id"] = cache.clipID.uuidString; result["frames_sha256"] = cache.framesSHA256; result["state_count"] = cache.frames.count }
            if action == "physics.get" {
                if let record {
                    let value = record.definition
                    result["definition_id"] = value.id.uuidString
                    result["parameters"] = ["duration": value.duration, "gravity_y": value.gravityY,
                        "floor_y": value.floorY, "floor_restitution": value.floorRestitution,
                        "spheres": value.spheres.map { sphere -> [String: Any] in
                            ["instance_id": sphere.instanceID.uuidString, "radius_mm": sphere.radiusMM,
                             "mass_kg": sphere.massKG, "restitution": sphere.restitution,
                             "velocity_mm_s": [sphere.velocityMMPerSecond.x, sphere.velocityMMPerSecond.y, sphere.velocityMMPerSecond.z]]
                        }]
                }
                let assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
                result["candidates"] = document.animationTrackCandidates().compactMap { candidate -> [String: Any]? in
                    guard let body = document.session.document.bodies.first(where: { $0.id.raw == candidate.sourceBodyID }),
                          let instance = assembly.instance(candidate.instanceID),
                          assembly.parentInstanceID(of: instance.id) == nil,
                          instance.transform.isPlaceable else { return nil }
                    let bounds = body.render.localAABB, center = (SIMD3<Double>(bounds.min) + SIMD3<Double>(bounds.max)) / 2
                    let localRadius: Double
                    if case let .sphere(radius)? = body.primitive { localRadius = radius }
                    else { localRadius = simd_length(SIMD3<Double>(bounds.max - bounds.min)) / 2 }
                    let radius = localRadius * body.transform.scale * instance.transform.scale.x
                    return ["instance_id": candidate.instanceID.uuidString, "name": candidate.name,
                            "radius_mm": max(0.01, radius), "center_local_mm": [center.x, center.y, center.z]]
                }
            }
            return result
        }
        try writable(args)
        guard Self.active[ObjectIdentifier(document)] == nil else { throw CADSpherePhysicsError.busy }
        let animationState = document.animationLoadState()
        guard animationState.issues.isEmpty else { throw CADSpherePhysicsError.invalid }
        if action == "physics.clear" {
            guard let current = try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData) else { return ["ok": true, "mutated": false] }
            var animation = animationState.animation
            if let cache = current.cache { animation.clips.removeAll { $0.id == cache.clipID && $0.physicsCacheID == cache.id } }
            if let selected = animation.activeClipID, !animation.clips.contains(where: { $0.id == selected }) { animation.activeClipID = animation.clips.first?.id }
            try commit(nil, animation: animation)
            return ["ok": true, "mutated": true]
        }
        guard action == "physics.configure", let rows = args["spheres"] as? [[String: Any]], (1...16).contains(rows.count) else { throw CADSpherePhysicsError.invalid }
        var definition = CADSpherePhysicsDefinition()
        definition.name = String((args["name"] as? String ?? FloeCADStrings.text("cad.physics.defaultName", "Sphere proxies")).prefix(80))
        definition.duration = try number(args["duration"], fallback: 2)
        definition.gravityY = try number(args["gravity_y"], fallback: -9810)
        definition.floorY = try number(args["floor_y"], fallback: 0)
        definition.floorRestitution = try number(args["floor_restitution"], fallback: 0.7)
        for row in rows {
            guard let text = row["instance_id"] as? String, let id = UUID(uuidString: text) else { throw CADSpherePhysicsError.invalid }
            let captured = try source(id, localCenter: vector(row["center_local_mm"]))
            definition.spheres.append(CADSpherePhysicsBody(instanceID: id, sourceBodyID: captured.bodyID,
                sourceSHA256: captured.sha, localCenterMM: captured.localCenter, initialCenterMM: captured.center,
                initialPlacement: captured.placement, worldCenterOffsetMM: captured.center - captured.placement.translationMM,
                radiusMM: try number(row["radius_mm"], fallback: -1), massKG: try number(row["mass_kg"], fallback: 1),
                restitution: try number(row["restitution"], fallback: 0.7), velocityMMPerSecond: try vector(row["velocity_mm_s"]) ?? .zero))
        }
        definition.spheres.sort { $0.instanceID.uuidString < $1.instanceID.uuidString }
        try definition.validate()
        let old = try CADSpherePhysicsCodec.record(document.session.document.sceneSettingsData)
        var animation = animationState.animation
        if let cache = old?.cache { animation.clips.removeAll { $0.id == cache.clipID && $0.physicsCacheID == cache.id } }
        // Configuration itself is physics intent, even before a clip exists.
        // A schema-2 animation writer must open this document read-only rather
        // than drop new scene settings while the shared package floor is 7.
        animation.schemaVersion = max(animation.schemaVersion, CADAnimationDocument.physicsSchemaVersion)
        try commit(CADSpherePhysicsRecord(definition: definition), animation: animation, showGround: true)
        return ["ok": true, "mutated": true, "definition_id": definition.id.uuidString, "sphere_count": definition.spheres.count]
    }

    private nonisolated struct SourceIdentity: Codable {
        var instanceID: UUID; var bodyID: UUID; var geometrySHA256: String
        var bodyTransform: Transform3D; var instanceTransform: CADTransform
    }
    private func source(_ id: UUID, localCenter: SIMD3<Double>?) throws
        -> (bodyID: UUID, sha: String, localCenter: SIMD3<Double>, center: SIMD3<Double>, placement: CADAnimationInstanceValue) {
        let assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        guard assembly.parentInstanceID(of: id) == nil, let instance = assembly.instance(id), !instance.isSubassembly, !instance.isHidden,
              let bodyID = instance.resolvedBodyID, let body = document.session.document.bodies.first(where: { $0.id.raw == bodyID }),
              instance.transform.isPlaceable, !body.render.positions.isEmpty, !body.render.indices.isEmpty,
              body.render.positions.count <= 1_000_000 else { throw CADSpherePhysicsError.invalid }
        let bounds = body.render.localAABB
        let local = localCenter ?? (SIMD3<Double>(bounds.min) + SIMD3<Double>(bounds.max)) / 2
        let world = instance.transform.placement3D().composed(onto: body.transform)
        let identity = SourceIdentity(instanceID: id, bodyID: bodyID, geometrySHA256: try CADUVRecord.geometryDigest(body.render),
                                      bodyTransform: body.transform, instanceTransform: instance.transform)
        return (bodyID, CADSpherePhysicsKernel.digest(identity), local, world.applying(to: local),
                CADAnimationInstanceValue(translationMM: instance.transform.position, rotation: instance.transform.rotation))
    }

    func validateSources(_ definition: CADSpherePhysicsDefinition) throws {
        for sphere in definition.spheres {
            let current = try source(sphere.instanceID, localCenter: sphere.localCenterMM)
            guard current.bodyID == sphere.sourceBodyID, current.sha == sphere.sourceSHA256,
                  current.center == sphere.initialCenterMM, current.placement == sphere.initialPlacement else { throw CADSpherePhysicsError.stale }
        }
    }
    private func number(_ raw: Any?, fallback: Double) throws -> Double {
        guard let raw else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw CADSpherePhysicsError.invalid }
        return value.doubleValue
    }
    private func vector(_ raw: Any?) throws -> SIMD3<Double>? {
        guard let raw else { return nil }
        guard let array = raw as? [Any], array.count == 3 else { throw CADSpherePhysicsError.invalid }
        return try SIMD3(number(array[0], fallback: 0), number(array[1], fallback: 0), number(array[2], fallback: 0))
    }

    private func commit(_ record: CADSpherePhysicsRecord?, animation: CADAnimationDocument, showGround: Bool = false,
                        externalCancellation: (any MeshImportCancellationChecking)? = nil) throws {
        if let record { try record.validate() }
        var settings = document.cameraSceneSettings(); settings.spherePhysics = record
        if showGround { var appearance = document.viewAppearance; appearance.floorVisible = true; settings.presentation = appearance }
        let scene = try JSONEncoder().encode(settings), animationData = try CADAnimationCodec.encode(animation.sanitized())
        guard animationData.count <= CADAnimationDocument.maximumEncodedBytes else { throw CADSpherePhysicsError.budget }
        guard !Task.isCancelled, externalCancellation?.isCancelled != true else { throw CADSpherePhysicsError.cancelled }
        document.session.perform(CompositeCommand(title: FloeCADStrings.text("cad.physics.command", "Sphere physics"), commands: [
            SetSceneSettingsDataCommand(before: document.session.document.sceneSettingsData, after: scene),
            SetAnimationDataCommand(title: "Sphere physics", before: document.session.document.animationData, after: animationData)]))
        guard document.session.document.sceneSettingsData == scene, document.session.document.animationData == animationData else { throw CADSpherePhysicsError.stale }
    }
}

@MainActor extension FloeCADDocument {
    func spherePhysicsPlayback() -> CADSpherePhysicsPlayback? {
        guard viewOverlayState.activeSection == nil,
              let record = try? CADSpherePhysicsCodec.record(session.document.sceneSettingsData), let cache = record.cache,
              (try? CADSpherePhysicsService(document: self).validateSources(record.definition)) != nil else { return nil }
        return CADSpherePhysicsPlayback(definition: record.definition, cache: cache)
    }
    func validatePhysicsAnimationClip(_ clip: CADAnimationClip) throws {
        guard let id = clip.physicsCacheID else { return }
        guard let playback = spherePhysicsPlayback(), playback.cache.id == id,
              playback.cache.clipID == clip.id, clip.tracks.isEmpty,
              abs(clip.duration - playback.definition.duration) <= 1e-9 else { throw CADSpherePhysicsError.stale }
    }
}

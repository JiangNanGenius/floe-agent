// SPDX-License-Identifier: MPL-2.0
// Bounded frictionless sphere proxies + one static horizontal plane. This
// lives in the existing animation module, not a general CAD contact engine.
import Foundation
import simd

public nonisolated struct CADSpherePhysicsBody: Codable, Equatable, Sendable {
    public var instanceID: UUID
    public var sourceBodyID: UUID
    /// Immutable source/initial-state snapshot, never the assembly authority.
    public var sourceSHA256: String
    public var localCenterMM: SIMD3<Double>
    public var initialCenterMM: SIMD3<Double>
    public var initialPlacement: CADAnimationInstanceValue
    public var worldCenterOffsetMM: SIMD3<Double>
    public var radiusMM: Double
    public var massKG: Double
    public var restitution: Double
    public var velocityMMPerSecond: SIMD3<Double>
}

public nonisolated struct CADSpherePhysicsDefinition: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var id: UUID = UUID()
    public var name: String = "Sphere proxies"
    public var duration: Double = 2
    public var gravityY: Double = -9810 // mm / s²
    public var floorY: Double = 0
    public var floorRestitution: Double = 0.7
    public var spheres: [CADSpherePhysicsBody] = []
    public var stepCount: Int { Int((duration * 240).rounded()) }

    func validate() throws {
        guard version == 1, !name.isEmpty, name.count <= 80,
              duration.isFinite, (0.1...10).contains(duration),
              abs(duration * 240 - (duration * 240).rounded()) <= 1e-8,
              gravityY.isFinite, (-1e6...0).contains(gravityY), floorY.isFinite, abs(floorY) <= 1e6,
              floorRestitution.isFinite, (0...1).contains(floorRestitution),
              (1...16).contains(spheres.count), Set(spheres.map(\.instanceID)).count == spheres.count,
              spheres.map(\.instanceID.uuidString) == spheres.map(\.instanceID.uuidString).sorted() else { throw CADSpherePhysicsError.invalid }
        for sphere in spheres {
            guard sphere.sourceSHA256.count == 64, sphere.sourceSHA256.allSatisfy(\.isHexDigit),
                  Self.vector(sphere.localCenterMM), Self.vector(sphere.initialCenterMM), Self.vector(sphere.worldCenterOffsetMM),
                  Self.vector(sphere.velocityMMPerSecond), sphere.initialPlacement.isValid,
                  sphere.radiusMM.isFinite, (0.01...1e6).contains(sphere.radiusMM),
                  sphere.massKG.isFinite, (1e-6...1e6).contains(sphere.massKG),
                  sphere.restitution.isFinite, (0...1).contains(sphere.restitution),
                  sphere.initialCenterMM.y >= floorY + sphere.radiusMM - 1e-7 else { throw CADSpherePhysicsError.invalid }
        }
        for i in spheres.indices { for j in spheres.indices where j > i {
            guard simd_distance(spheres[i].initialCenterMM, spheres[j].initialCenterMM)
                    >= spheres[i].radiusMM + spheres[j].radiusMM - 1e-7 else { throw CADSpherePhysicsError.overlap }
        }}
    }
    private static func vector(_ value: SIMD3<Double>) -> Bool {
        (0..<3).allSatisfy { value[$0].isFinite && abs(value[$0]) <= 1e9 }
    }
}

public nonisolated struct CADSpherePhysicsFrame: Codable, Equatable, Sendable {
    public var positions: [SIMD3<Double>]
    public var velocities: [SIMD3<Double>]
}

public nonisolated struct CADSpherePhysicsContact: Codable, Equatable, Sendable {
    public var time: Double
    public var a: Int
    public var b: Int? // nil = plane
    public var incomingNormalSpeed: Double
    public var outgoingNormalSpeed: Double
    public var impulseKGMMPerSecond: Double
}

public nonisolated struct CADSpherePhysicsCache: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var solverVersion: Int = 1
    public var id: UUID
    public var clipID: UUID
    public var definitionSHA256: String
    public var framesSHA256: String
    /// Every 240 Hz state, including initial and final, max 2401. Output
    /// rates dividing 240 sample exact stored states. Other times use linear
    /// cache interpolation; no re-simulation or keyframe fitting on playback.
    public var frames: [CADSpherePhysicsFrame]
    public var contactCount: Int
    /// Bounded numerical witness, not an unbounded event log.
    public var contacts: [CADSpherePhysicsContact]
}

public nonisolated struct CADSpherePhysicsRecord: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var definition: CADSpherePhysicsDefinition
    public var cache: CADSpherePhysicsCache?
    func validate() throws {
        guard version == 1 else { throw CADSpherePhysicsError.invalid }
        try definition.validate()
        if let cache {
            guard cache.version == 1, cache.solverVersion == 1,
                  cache.definitionSHA256 == CADSpherePhysicsKernel.digest(definition),
                  cache.frames.count == definition.stepCount + 1,
                  cache.frames.count <= 2401, cache.contacts.count <= 256,
                  cache.contactCount >= cache.contacts.count, cache.contactCount <= 8192,
                  cache.framesSHA256 == CADSpherePhysicsKernel.digest(cache.frames) else { throw CADSpherePhysicsError.invalid }
            for contact in cache.contacts {
                guard contact.time.isFinite, (0...definition.duration).contains(contact.time),
                      definition.spheres.indices.contains(contact.a),
                      contact.b.map({ definition.spheres.indices.contains($0) && $0 != contact.a }) ?? true,
                      contact.incomingNormalSpeed.isFinite, contact.outgoingNormalSpeed.isFinite,
                      contact.impulseKGMMPerSecond.isFinite, contact.impulseKGMMPerSecond >= 0 else { throw CADSpherePhysicsError.invalid }
            }
            for frame in cache.frames {
                guard frame.positions.count == definition.spheres.count,
                      frame.velocities.count == definition.spheres.count,
                      (frame.positions + frame.velocities).allSatisfy({ p in (0..<3).allSatisfy { p[$0].isFinite && abs(p[$0]) <= 1e9 } }) else { throw CADSpherePhysicsError.invalid }
            }
        }
    }
}

public nonisolated struct CADSpherePhysicsPlayback: Equatable, Sendable {
    public var definition: CADSpherePhysicsDefinition
    public var cache: CADSpherePhysicsCache
    func values(at time: Double) -> [UUID: CADAnimationInstanceValue] {
        let step = min(max(time, 0), definition.duration) * 240
        let a = min(Int(step.rounded(.down)), cache.frames.count - 1), b = min(a + 1, cache.frames.count - 1)
        let t = step - Double(a)
        var result: [UUID: CADAnimationInstanceValue] = [:]
        for (index, sphere) in definition.spheres.enumerated() {
            let center = cache.frames[a].positions[index] * (1 - t) + cache.frames[b].positions[index] * t
            result[sphere.instanceID] = CADAnimationInstanceValue(
                translationMM: center - sphere.worldCenterOffsetMM, rotation: sphere.initialPlacement.rotation)
        }
        return result
    }
}

nonisolated enum CADSpherePhysicsError: String, Error, LocalizedError {
    case invalid = "invalid_sphere_physics"
    case overlap = "physics_initial_overlap"
    case stale = "physics_source_changed"
    case cancelled = "physics_cancelled"
    case budget = "physics_budget"
    case contact = "physics_contact_unresolved"
    case busy = "physics_worker_busy"
    var errorDescription: String? {
        switch self {
        case .invalid: FloeCADStrings.text("cad.physics.invalid", "Check the sphere proxy and simulation values.")
        case .overlap: FloeCADStrings.text("cad.physics.overlap", "Separate the sphere proxies before simulating.")
        case .stale: FloeCADStrings.text("cad.physics.stale", "The source changed. Configure and simulate the proxies again.")
        case .cancelled: FloeCADStrings.text("cad.physics.cancelled", "Simulation was cancelled. No new cache was applied.")
        case .budget: FloeCADStrings.text("cad.physics.budget", "This simulation exceeded its limits. Reduce its duration or contacts.")
        case .contact: FloeCADStrings.text("cad.physics.contact", "These contacts could not be resolved within the supported scope.")
        case .busy: FloeCADStrings.text("cad.physics.busy", "A simulation is finishing. Wait for it to stop before starting another.")
        }
    }
}

nonisolated enum CADSpherePhysicsKernel {
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map(CADMaterialTexture.digest) ?? ""
    }

    /// Velocity-Verlet kick/drift/kick. The drift uses analytic swept sphere
    /// and sphere/plane time-of-impact, avoiding per-frame overlap tunnelling.
    /// Gravity between impacts is a fixed-step numerical approximation; no
    /// exact CAD contact or arbitrary stacking/constraints are claimed.
    static func compute(_ definition: CADSpherePhysicsDefinition, cacheID: UUID, clipID: UUID,
                        cancellation: CADMeshCancellation,
                        externalCancellation: (any MeshImportCancellationChecking)? = nil) throws -> CADSpherePhysicsCache {
        try definition.validate()
        let started = ProcessInfo.processInfo.systemUptime, dt = 1.0 / 240, tolerance = 1e-7
        var positions = definition.spheres.map(\.initialCenterMM), velocities = definition.spheres.map(\.velocityMMPerSecond)
        var frames = [CADSpherePhysicsFrame(positions: positions, velocities: velocities)]
        var contacts: [CADSpherePhysicsContact] = [], contactCount = 0
        func check() throws {
            if cancellation.kernelIsCancelled() || externalCancellation?.isCancelled == true { throw CADSpherePhysicsError.cancelled }
            if ProcessInfo.processInfo.systemUptime - started > 20 { throw CADSpherePhysicsError.budget }
        }
        for step in 0..<definition.stepCount {
            try check()
            var resting = [Bool](repeating: false, count: positions.count)
            var touchedPlane = [Bool](repeating: false, count: positions.count)
            for i in positions.indices {
                let floor = definition.floorY + definition.spheres[i].radiusMM
                resting[i] = positions[i].y <= floor + tolerance && velocities[i].y <= 0 && abs(velocities[i].y) <= 1
                if resting[i] { velocities[i].y = 0 }
                else { velocities[i].y += definition.gravityY * dt / 2 }
            }
            var remaining = dt, elapsed = 0.0, events = 0
            while remaining > 1e-13 {
                try check()
                var earliest = remaining + 1, hitA: Int?, hitB: Int?
                for i in positions.indices {
                    if velocities[i].y < -1e-10 {
                        let t = (definition.floorY + definition.spheres[i].radiusMM - positions[i].y) / velocities[i].y
                        let timeTolerance = tolerance / max(1, abs(velocities[i].y))
                        if t >= -timeTolerance, t <= remaining + timeTolerance, min(remaining, max(0, t)) < earliest {
                            earliest = min(remaining, max(0, t)); hitA = i; hitB = nil
                        }
                    }
                    for j in positions.indices where j > i {
                        let d = positions[j] - positions[i], v = velocities[j] - velocities[i]
                        let radius = definition.spheres[i].radiusMM + definition.spheres[j].radiusMM
                        let aa = simd_dot(v, v), bb = simd_dot(d, v), cc = simd_dot(d, d) - radius * radius
                        guard aa > 1e-20, bb < -1e-10 else { continue }
                        let discriminant = bb * bb - aa * cc
                        guard discriminant >= 0 else { continue }
                        // Stable first root; a touching approaching pair fires
                        // at zero without an arbitrary time/position nudge.
                        let denominator = -bb + sqrt(discriminant)
                        let t = cc <= 0 ? 0 : cc / denominator
                        let timeTolerance = tolerance / max(1, sqrt(aa))
                        if t >= 0, t <= remaining + timeTolerance, min(remaining, t) < earliest {
                            earliest = min(remaining, t); hitA = i; hitB = j
                        }
                    }
                }
                guard let a = hitA else {
                    for i in positions.indices { positions[i] += velocities[i] * remaining }
                    elapsed += remaining; remaining = 0; break
                }
                for i in positions.indices { positions[i] += velocities[i] * earliest }
                elapsed += earliest; remaining -= earliest
                events += 1; contactCount += 1
                guard events <= 256, contactCount <= 8192 else { throw CADSpherePhysicsError.contact }
                let incoming: Double, outgoing: Double, impulse: Double
                if let b = hitB {
                    let distance = simd_distance(positions[a], positions[b])
                    let radius = definition.spheres[a].radiusMM + definition.spheres[b].radiusMM
                    guard distance > 1e-12, distance >= radius - 1e-5 else { throw CADSpherePhysicsError.contact }
                    let normal = (positions[b] - positions[a]) / distance
                    incoming = simd_dot(velocities[b] - velocities[a], normal)
                    let inverseA = 1 / definition.spheres[a].massKG, inverseB = 1 / definition.spheres[b].massKG
                    let restitution = min(definition.spheres[a].restitution, definition.spheres[b].restitution)
                    impulse = -(1 + restitution) * incoming / (inverseA + inverseB)
                    velocities[a] -= normal * (impulse * inverseA); velocities[b] += normal * (impulse * inverseB)
                    outgoing = simd_dot(velocities[b] - velocities[a], normal)
                    resting[a] = false; resting[b] = false
                } else {
                    touchedPlane[a] = true
                    incoming = velocities[a].y
                    let restitution = min(definition.floorRestitution, definition.spheres[a].restitution)
                    velocities[a].y = -restitution * incoming
                    // Explicit 1 mm/s ground sleep, reported in the actual
                    // post-impact witness rather than a fabricated rebound.
                    if velocities[a].y <= 1 { velocities[a].y = 0; resting[a] = true }
                    outgoing = velocities[a].y
                    impulse = definition.spheres[a].massKG * (outgoing - incoming)
                }
                if contacts.count < 256 {
                    contacts.append(.init(time: min(definition.duration, Double(step) * dt + elapsed), a: a, b: hitB,
                        incomingNormalSpeed: incoming, outgoingNormalSpeed: outgoing, impulseKGMMPerSecond: impulse))
                }
            }
            for i in positions.indices {
                if !resting[i] { velocities[i].y += definition.gravityY * dt / 2 }
                let floor = definition.floorY + definition.spheres[i].radiusMM
                // The static plane's normal reaction prevents the final
                // gravity kick from creating an inward resting velocity.
                if (resting[i] || touchedPlane[i]), positions[i].y <= floor + tolerance, velocities[i].y < 0 { velocities[i].y = 0 }
                guard positions[i].y >= floor - 1e-5,
                      (0..<3).allSatisfy({ positions[i][$0].isFinite && velocities[i][$0].isFinite
                          && abs(positions[i][$0]) <= 1e9 && abs(velocities[i][$0]) <= 1e9 }) else { throw CADSpherePhysicsError.contact }
                for j in positions.indices where j > i {
                    guard simd_distance(positions[i], positions[j]) >= definition.spheres[i].radiusMM
                        + definition.spheres[j].radiusMM - 1e-5 else { throw CADSpherePhysicsError.contact }
                }
            }
            frames.append(.init(positions: positions, velocities: velocities))
        }
        try check()
        let cache = CADSpherePhysicsCache(id: cacheID, clipID: clipID,
            definitionSHA256: digest(definition), framesSHA256: digest(frames), frames: frames,
            contactCount: contactCount, contacts: contacts)
        guard let data = try? JSONEncoder().encode(cache), data.count <= 16 * 1024 * 1024 else { throw CADSpherePhysicsError.budget }
        return cache
    }
}

nonisolated enum CADSpherePhysicsCodec {
    static func record(_ sceneData: Data?) throws -> CADSpherePhysicsRecord? {
        guard let sceneData else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else { throw CADSpherePhysicsError.invalid }
        guard let raw = root["spherePhysics"], !(raw is NSNull) else { return nil }
        guard let row = raw as? [String: Any], Set(row.keys).isSubset(of: ["version", "definition", "cache"]),
              let definition = row["definition"] as? [String: Any],
              Set(definition.keys).isSubset(of: ["version", "id", "name", "duration", "gravityY", "floorY", "floorRestitution", "spheres"]),
              let spheres = definition["spheres"] as? [[String: Any]], spheres.count <= 16,
              spheres.allSatisfy({ sphere in
                  guard Set(sphere.keys).isSubset(of: ["instanceID", "sourceBodyID", "sourceSHA256", "localCenterMM", "initialCenterMM", "initialPlacement", "worldCenterOffsetMM", "radiusMM", "massKG", "restitution", "velocityMMPerSecond"]),
                        let placement = sphere["initialPlacement"] as? [String: Any],
                        Set(placement.keys).isSubset(of: ["translationMM", "rotation"]) else { return false }
                  return true
              }) else { throw CADSpherePhysicsError.invalid }
        if let rawCache = row["cache"], !(rawCache is NSNull) {
            guard let cache = rawCache as? [String: Any],
                  Set(cache.keys).isSubset(of: ["version", "solverVersion", "id", "clipID", "definitionSHA256", "framesSHA256", "frames", "contactCount", "contacts"]),
                  let frames = cache["frames"] as? [[String: Any]], frames.count <= 2401,
                  frames.allSatisfy({ Set($0.keys) == Set(["positions", "velocities"]) }),
                  let contacts = cache["contacts"] as? [[String: Any]], contacts.count <= 256,
                  contacts.allSatisfy({ Set($0.keys).isSubset(of: ["time", "a", "b", "incomingNormalSpeed", "outgoingNormalSpeed", "impulseKGMMPerSecond"]) }) else { throw CADSpherePhysicsError.invalid }
        }
        let bytes = try JSONSerialization.data(withJSONObject: row)
        guard bytes.count <= 16 * 1024 * 1024 else { throw CADSpherePhysicsError.budget }
        let result = try JSONDecoder().decode(CADSpherePhysicsRecord.self, from: bytes)
        try result.validate()
        return result
    }
}

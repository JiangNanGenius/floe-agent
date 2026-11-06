// SPDX-License-Identifier: MPL-2.0
// Real volumetric intersection reuses the product's pinned Apache-2.0
// Manifold 3.5.4 C facade. AABB rejection is only the broad phase. No inferred
// penetration depth, centre-distance proxy, hole filling or mesh repair.
import Foundation
import simd
import ManifoldShim

public nonisolated enum CADBuildingLocalCoordination {
    private static let maximumCandidatePairs = 2_048
    private static let minimumOverlapVolumeM3 = 1e-12

    public static func evaluate(input: Data,
                                cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let request = try CADBuildingLocalStudyInput.read(input, action: "mep", cancelled: cancelled)
        let kinds = Dictionary(uniqueKeysWithValues: request.model.elements.map { ($0.id, $0.kind) })
        let structuralKinds: Set<CADBuildingElement.Kind> = [.wall, .slab, .roof, .beam, .column]
        var systems: [Part] = [], structures: [Part] = []
        for geometry in request.geometry {
            try CADBuildingLocalStudyInput.checkCancellation(cancelled)
            guard let kind = kinds[geometry.elementID] else { continue }
            if kind == .pipe || kind == .duct { systems.append(Part(geometry)) }
            else if structuralKinds.contains(kind) { structures.append(Part(geometry)) }
        }
        let represented = Set(request.geometry.map(\.elementID))
        let relevant = request.model.elements.filter { $0.kind == .pipe || $0.kind == .duct || structuralKinds.contains($0.kind) }
        let missing = relevant.filter { !represented.contains($0.id) }.map { $0.id.uuidString }
        guard !systems.isEmpty, !structures.isEmpty else {
            return try result(["status": "notEvaluated", "reason": "Add saved pipe or duct meshes and building solids to run coordination.",
                "clashes": [], "missingElementIDs": missing, "systemSizing": false, "codeApproval": false])
        }
        let context = try Context(deadline: deadline, cancelled: cancelled)
        // Validate closed/oriented solids once. Invalid/open inputs remain
        // explicit unevaluated bodies; they never become a 'no clash' result.
        var supported = Set<UUID>(), unsupported: [[String: Any]] = []
        for part in systems + structures {
            try context.check()
            let checked = try run(context, source: part, tool: nil, origin: part.centre)
            if checked.status == 0, checked.volume.isFinite, checked.volume > 0 {
                supported.insert(part.bodyID)
            } else {
                unsupported.append(["elementID": part.elementID.uuidString, "bodyID": part.bodyID.uuidString,
                    "reason": checked.message.isEmpty ? "A closed outward-oriented solid is required." : checked.message])
            }
        }
        var candidates = 0, rejectedByBounds = 0, tested = 0, skipped = 0
        var clashes: [[String: Any]] = [], unknownPairs: [[String: Any]] = []
        for system in systems {
            for structure in structures {
                try context.check()
                if !system.overlapsBounds(structure) { rejectedByBounds += 1; continue }
                candidates += 1
                guard candidates <= maximumCandidatePairs else {
                    throw CADBuildingLocalComputationError.budget("The local coordination exceeds 2,048 overlapping mesh pairs. Split the study into fewer elements.")
                }
                guard supported.contains(system.bodyID), supported.contains(structure.bodyID) else { skipped += 1; continue }
                // Rebase BOTH operands into one pair-local frame before the
                // Float32 adapter. Large site offsets must not consume the
                // precision needed to distinguish nearby small components.
                let origin = (simd_min(system.lower, structure.lower) + simd_max(system.upper, structure.upper)) / 2
                let intersection = try run(context, source: system, tool: structure, origin: origin)
                tested += 1
                if intersection.status == 4 { continue } // Real Boolean is empty.
                guard intersection.status == 0, intersection.volume.isFinite, intersection.volume >= 0 else {
                    unknownPairs.append(["a": system.elementID.uuidString, "b": structure.elementID.uuidString,
                        "bodyA": system.bodyID.uuidString, "bodyB": structure.bodyID.uuidString,
                        "reason": intersection.message.isEmpty ? "The solid intersection could not be evaluated." : intersection.message])
                    continue
                }
                guard intersection.volume > minimumOverlapVolumeM3 else { continue }
                var row: [String: Any] = ["a": system.elementID.uuidString, "b": structure.elementID.uuidString,
                    "bodyA": system.bodyID.uuidString, "bodyB": structure.bodyID.uuidString,
                    "overlapVolumeM3": intersection.volume, "intersectionTriangleCount": intersection.triangles]
                if let bounds = intersection.bounds {
                    row["intersectionBoundsM"] = [[bounds.0.x, bounds.0.y, bounds.0.z], [bounds.1.x, bounds.1.y, bounds.1.z]]
                }
                clashes.append(row)
            }
        }
        try context.check()
        let complete = unsupported.isEmpty && unknownPairs.isEmpty && missing.isEmpty
        let status = complete ? "evaluated" : tested == 0 ? "notEvaluated" : "partiallyEvaluated"
        return try result(["status": status, "method": "Manifold closed-mesh volumetric intersection",
            "clashes": clashes, "evaluatedMeshPairs": tested, "candidateMeshPairs": candidates,
            "broadPhaseRejectedPairs": rejectedByBounds, "unevaluatedMeshPairs": skipped + unknownPairs.count,
            "unevaluatedBodies": unsupported, "unevaluatedPairs": unknownPairs, "missingElementIDs": missing,
            "minimumReportedOverlapVolumeM3": minimumOverlapVolumeM3,
            "coordinatePrecision": "Float32 in a shared pair-local translated frame",
            "penetrationDepthComputed": false, "clearanceComputed": false,
            "systemSizing": false, "codeApproval": false])
    }

    private static func result(_ coordination: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["coordination": coordination,
            "backendVersions": ["Manifold": "3.5.4", "FloeCoordination": "volumetric-pairs-1"]], options: .sortedKeys)
    }
    private nonisolated struct Part {
        let elementID: UUID, bodyID: UUID
        let vertices: [[Double]], indices: [UInt32]
        let lower: SIMD3<Double>, upper: SIMD3<Double>
        var centre: SIMD3<Double> { (lower + upper) / 2 }
        init(_ geometry: CADBuildingLocalStudyInput.Geometry) {
            elementID = geometry.elementID; bodyID = geometry.bodyID
            vertices = geometry.verticesM; indices = geometry.indices
            var low = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
            for p in vertices { let point = SIMD3(p[0], p[1], p[2]); low = simd_min(low, point); high = simd_max(high, point) }
            lower = low; upper = high
        }
        func overlapsBounds(_ other: Part) -> Bool {
            lower.x < other.upper.x && upper.x > other.lower.x
                && lower.y < other.upper.y && upper.y > other.lower.y
                && lower.z < other.upper.z && upper.z > other.lower.z
        }
        func packed(relativeTo origin: SIMD3<Double>, context: Context) throws -> [Float] {
            var output: [Float] = []; output.reserveCapacity(vertices.count * 3)
            for (index, p) in vertices.enumerated() {
                if index % 512 == 0 { try context.check() }
                let point = SIMD3(p[0], p[1], p[2]) - origin
                guard [point.x, point.y, point.z].allSatisfy({ $0.isFinite && abs($0) <= 1e6 }) else {
                    throw CADBuildingLocalComputationError.budget("A component spans too large a coordinate range for the local mesh kernel.")
                }
                output.append(Float(point.x)); output.append(Float(point.y)); output.append(Float(point.z))
            }
            return output
        }
    }
    private nonisolated struct NativeResult {
        let status: Int32, volume: Double, message: String, triangles: Int
        let bounds: (SIMD3<Double>, SIMD3<Double>)?
    }
    private static func run(_ context: Context, source: Part, tool: Part?, origin: SIMD3<Double>) throws -> NativeResult {
        try context.check()
        let a = try source.packed(relativeTo: origin, context: context)
        let b = try tool?.packed(relativeTo: origin, context: context) ?? []
        let secondIndices = tool?.indices ?? []
        let raw = a.withUnsafeBufferPointer { xyz in source.indices.withUnsafeBufferPointer { triangles in
            b.withUnsafeBufferPointer { other in secondIndices.withUnsafeBufferPointer { otherTriangles in
                floe_manifold_boolean(context.raw, xyz.baseAddress, source.vertices.count, triangles.baseAddress, triangles.count,
                    tool == nil ? nil : other.baseAddress, tool?.vertices.count ?? 0, otherTriangles.baseAddress, otherTriangles.count, 2)
            } }
        } }
        guard let raw else { throw CADBuildingLocalComputationError.geometry("The local mesh kernel could not allocate a result.") }
        defer { floe_manifold_result_destroy(raw) }
        try context.check()
        let status = floe_manifold_result_status(raw)
        if status == 3 { throw CancellationError() }
        let volume = floe_manifold_result_volume(raw)
        let message = String(String(cString: floe_manifold_result_message(raw)).prefix(512))
        let vertexCount = Int(floe_manifold_result_vertex_count(raw))
        let indexCount = Int(floe_manifold_result_index_count(raw))
        guard status == 0 else { return .init(status: status, volume: volume, message: message, triangles: 0, bounds: nil) }
        guard vertexCount > 0, vertexCount <= 3_000_000, indexCount > 0, indexCount <= 3_000_000,
              indexCount % 3 == 0, let positions = floe_manifold_result_xyz(raw) else {
            throw CADBuildingLocalComputationError.geometry("The local mesh kernel returned invalid intersection buffers.")
        }
        var lower = SIMD3<Double>(repeating: .greatestFiniteMagnitude), upper = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for index in 0..<vertexCount {
            if index % 512 == 0 { try context.check() }
            let point = SIMD3(Double(positions[3*index]), Double(positions[3*index+1]), Double(positions[3*index+2])) + origin
            guard [point.x, point.y, point.z].allSatisfy(\.isFinite) else { throw CADBuildingLocalComputationError.geometry("The local intersection contains non-finite coordinates.") }
            lower = simd_min(lower, point); upper = simd_max(upper, point)
        }
        return .init(status: status, volume: volume, message: message, triangles: indexCount / 3, bounds: (lower, upper))
    }

    /// Poll the caller's thread-safe token while native CSG is executing. The
    /// upstream ExecutionContext can be cancelled from this observer thread;
    /// the synchronous call is still joined before any result is returned.
    private nonisolated final class Context: @unchecked Sendable {
        let raw: OpaquePointer
        private let timer: DispatchSourceTimer
        private let deadline: Double
        private let cancelled: @Sendable () -> Bool
        private let lock = NSLock()
        private var expired = false, callerCancelled = false
        init(deadline: Double, cancelled: @escaping @Sendable () -> Bool) throws {
            guard let raw = floe_manifold_context_create() else { throw CADBuildingLocalComputationError.geometry("The local mesh kernel could not allocate a context.") }
            self.raw = raw; self.deadline = deadline; self.cancelled = cancelled
            timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.observe() }
            timer.resume()
        }
        private func observe() {
            let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            let stopped = cancelled()
            if timedOut || stopped {
                lock.lock(); expired = expired || timedOut; callerCancelled = callerCancelled || stopped; lock.unlock()
                floe_manifold_context_cancel(raw)
            }
        }
        func check() throws {
            observe()
            lock.lock(); let timeout = expired, stopped = callerCancelled; lock.unlock()
            if timeout { throw CADBuildingLocalComputationError.timedOut }
            if stopped || Task.isCancelled { throw CancellationError() }
        }
        deinit { timer.cancel(); floe_manifold_context_destroy(raw) }
    }
}

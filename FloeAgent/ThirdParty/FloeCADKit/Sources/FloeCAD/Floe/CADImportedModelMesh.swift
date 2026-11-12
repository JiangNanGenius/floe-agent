// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Validated, immutable render buffers in source-local millimetres. No exact
/// shape, CAD document or live kernel handle crosses this interface.
public nonisolated struct CADImportedModelMesh: Sendable {
    public let name: String
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let indices: [UInt32]
}

public nonisolated struct CADImportedModelGeometry: Sendable {
    public let meshes: [CADImportedModelMesh]
    public let triangleCount: Int
    public let bufferBytes: Int
    public let parsedOffMain: Bool
}

/// A small-model consumer of the existing exact import scheduler. Its limits
/// are deliberately below the general CAD editor's limits: a PCB can contain
/// many components. Callers still bound the number of models in their scene.
public nonisolated enum CADImportedModelMeshLoader {
    public static let maximumInputBytes = 16 * 1024 * 1024
    public static let maximumTriangles = 200_000
    public static let maximumVertices = 600_000
    public static let maximumMeshes = 128
    public static let maximumBufferBytes = 24 * 1024 * 1024
    public static let maximumAbsoluteCoordinateMM: Float = 10_000
    private static let maximumRetainedPlanBytes = 48 * 1024 * 1024

    /// Uses the one global CAD exact-reader gate, triangle/part budget and
    /// cooperative token. The retained plan is checked before buffer export;
    /// this is not a peak-allocation ceiling inside a synchronous OCCT call.
    /// Cancellation joins both parsing and export, fencing late completion.
    public static func loadExactOffMain(data: Data, format: String, fileName: String,
                                       cancellation: MeshImportCancellation)
        async throws -> CADImportedModelGeometry {
        try await withTaskCancellationHandler {
            try checkCancellation(cancellation)
            guard !data.isEmpty, data.count <= maximumInputBytes else {
                throw failure("import_over_budget", "Component model input exceeds the preview limit.")
            }
            let format = format.lowercased()
            guard ["step", "stp", "iges", "igs"].contains(format),
                  !fileName.isEmpty, fileName.utf8.count <= 4_096 else {
                throw failure("unsupported_format", "Use a supported exact model file.")
            }
            let plan = try await CADExactImportService.parseOffMain(
                data: data, format: format, fileName: fileName,
                limits: .init(maximumTriangles: maximumTriangles,
                              maximumParts: maximumMeshes,
                              maximumExpandedBytes: maximumRetainedPlanBytes,
                              maximumArchiveEntries: 1),
                cancellation: cancellation)
            try checkCancellation(cancellation)
            let worker = Task.detached(priority: .utility) {
                try validatedBuffers(from: plan, cancellation: cancellation)
            }
            return try await withTaskCancellationHandler {
                let value = try await worker.value
                try checkCancellation(cancellation)
                return value
            } onCancel: {
                cancellation.cancel()
                worker.cancel()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // Internal for malformed-buffer tests. Production only calls this on the
    // detached worker above. Arrays retain their value buffers with COW;
    // exported values do not retain the serialized exact plan or its edges.
    static func validatedBuffers(from plan: CADExactImportPlan,
                                 cancellation: MeshImportCancellation) throws -> CADImportedModelGeometry {
        try checkCancellation(cancellation)
        guard !plan.bodies.isEmpty, plan.bodies.count <= maximumMeshes,
              plan.skippedSurfaceCount == 0,
              plan.chargedBytes >= 0, plan.chargedBytes <= maximumRetainedPlanBytes,
              plan.retainedBytes >= 0, plan.retainedBytes <= maximumRetainedPlanBytes else {
            throw failure("invalid_component_model", "The model is incomplete or exceeds the preview limit.")
        }
        var meshes: [CADImportedModelMesh] = []
        meshes.reserveCapacity(plan.bodies.count)
        var vertices = 0, triangles = 0, bytes = 0
        for body in plan.bodies {
            try checkCancellation(cancellation)
            let mesh = body.render
            guard !mesh.positions.isEmpty, mesh.normals.count == mesh.positions.count,
                  !mesh.indices.isEmpty, mesh.indices.count % 3 == 0,
                  mesh.positions.count <= maximumVertices - vertices,
                  mesh.indices.count / 3 <= maximumTriangles - triangles else {
                throw failure("invalid_component_model", "The model has invalid or oversized geometry buffers.")
            }
            vertices += mesh.positions.count
            triangles += mesh.indices.count / 3
            // Counts have been bounded before any arithmetic or export.
            let size = mesh.positions.count * MemoryLayout<SIMD3<Float>>.stride * 2
                + mesh.indices.count * MemoryLayout<UInt32>.stride
            guard size <= maximumBufferBytes - bytes else {
                throw failure("import_over_budget", "Component model buffers exceed the preview limit.")
            }
            bytes += size
            for index in mesh.positions.indices {
                if index % 2_048 == 0 { try checkCancellation(cancellation) }
                let point = mesh.positions[index], normal = mesh.normals[index]
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                      abs(point.x) <= maximumAbsoluteCoordinateMM,
                      abs(point.y) <= maximumAbsoluteCoordinateMM,
                      abs(point.z) <= maximumAbsoluteCoordinateMM,
                      normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
                    throw failure("invalid_component_model", "The model contains invalid coordinates or normals.")
                }
            }
            for (offset, index) in mesh.indices.enumerated() {
                if offset % 8_192 == 0 { try checkCancellation(cancellation) }
                guard Int(index) < mesh.positions.count else {
                    throw failure("invalid_component_model", "The model contains an invalid triangle index.")
                }
            }
            meshes.append(.init(name: body.baseName, positions: mesh.positions,
                                normals: mesh.normals, indices: mesh.indices))
        }
        try checkCancellation(cancellation)
        guard triangles == plan.triangleCount else {
            throw failure("invalid_component_model", "The model triangle count does not match its buffers.")
        }
        return .init(meshes: meshes, triangleCount: triangles, bufferBytes: bytes,
                     parsedOffMain: plan.parsedOffMain && !Thread.isMainThread)
    }

    private static func checkCancellation(_ cancellation: any MeshImportCancellationChecking) throws {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw CancellationError() }
    }
    private static func failure(_ code: String, _ message: String) -> CADDocumentError {
        CADDocumentError(code: code, message: message)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import XAtlasShim
import simd

nonisolated final class CADUVCancellation: @unchecked Sendable {
    let native: OpaquePointer
    private let lock = NSLock()
    private var requested = false
    init() throws {
        guard let value = fxa_cancel_create() else { throw CADUVRecord.failure("uv_allocation", "The UV worker could not allocate cancellation state.") }
        native=value
    }
    deinit { fxa_cancel_destroy(native) }
    func cancel() { lock.lock(); requested=true; lock.unlock(); fxa_cancel_request(native) }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

nonisolated enum CADUVOperationBudget {
    // Root-directed heavy 3D task window. Explicitly passed through the new
    // adapter; the qualified xatlas algorithm archives are unchanged.
    static let wallClockLimitSeconds: Double = 15 * 60
}

nonisolated enum CADUVNative {
    static let algorithm = "xatlas-f700c779+qualified-cleanup-r1"
    static func generate(record: CADUVRecord, repacking: Bool, resolution: UInt32,
                         padding: UInt32, cancellation: CADUVCancellation,
                         wallClockLimitSeconds: Double = CADUVOperationBudget.wallClockLimitSeconds) throws -> CADUVSet {
        if cancellation.isCancelled { throw CADUVRecord.failure("cancelled", "UV editing was cancelled.") }
        let source=try MeshBlob.decode(record.sourceMesh)
        try CADUVRecord.validate(source)
        var outputUV = [Float](repeating:0,count:source.indices.count*2)
        var outputCharts=[UInt32](repeating:0,count:source.triangleCount)
        var width: UInt32=0, height: UInt32=0
        let status: Int32
        if repacking {
            guard let set=record.activeSet else { throw CADUVRecord.failure("missing_uv_set", "Unwrap this body before packing islands.") }
            let values=try CADUVRecord.unpack(set.cornerUVData).flatMap { [$0.x,$0.y] }
            status=values.withUnsafeBufferPointer { uv in set.faceCharts.withUnsafeBufferPointer { charts in
                fxa_pack(uv.baseAddress,UInt32(source.indices.count),charts.baseAddress,resolution,padding,
                         wallClockLimitSeconds,cancellation.native,&outputUV,&outputCharts,&width,&height)
            } }
        } else {
            let positions=source.positions.flatMap { [$0.x,$0.y,$0.z] }
            let normals=source.normals.flatMap { [$0.x,$0.y,$0.z] }
            let groups=try CADUVRecord.hardChartGroups(source:source,seams:record.seams)
            status=positions.withUnsafeBufferPointer { p in normals.withUnsafeBufferPointer { n in
                source.indices.withUnsafeBufferPointer { i in groups.withUnsafeBufferPointer { g in
                    fxa_unwrap(p.baseAddress,n.baseAddress,UInt32(source.positions.count),i.baseAddress,
                               UInt32(source.indices.count),g.baseAddress,resolution,padding,
                               wallClockLimitSeconds,cancellation.native,&outputUV,&outputCharts,&width,&height)
                } }
            } }
        }
        if cancellation.isCancelled { throw CADUVRecord.failure("cancelled", "UV editing was cancelled.") }
        guard status == 0 else {
            switch status {
            case 2: throw CADUVRecord.failure("cancelled", "UV editing was cancelled.")
            case 8: throw CADUVRecord.failure("uv_timeout", "The UV backend reached the configured heavy-task time budget; nothing was applied.")
            case 7: throw CADUVRecord.failure("uv_worker_busy", "Another UV operation is active. Retry when it finishes.")
            default: throw CADUVRecord.failure("uv_native_failed", "The UV backend refused this mesh (status \(status)); nothing was changed.")
            }
        }
        let values=(0..<source.indices.count).map { SIMD2(outputUV[$0*2],outputUV[$0*2+1]) }
        try CADUVRecord.validateUVs(values,cornerCount:source.indices.count)
        if !repacking {
            let edges=try CADUVRecord.edgeFaces(source)
            for seam in record.seams {
                if let faces=edges[seam], faces.count == 2,
                   outputCharts[faces[0]] == outputCharts[faces[1]] {
                    throw CADUVRecord.failure("uv_seam_not_respected", "The backend did not separate a marked seam; nothing was changed.")
                }
            }
        }
        let old=record.activeSet
        return CADUVSet(id:old?.id ?? UUID(),name:old?.name ?? "UV 1",
            cornerUVData:CADUVRecord.pack(values),faceCharts:outputCharts,
            seamSHA256:repacking ? (old?.seamSHA256 ?? record.seamSHA256) : record.seamSHA256,
            atlasWidth:width,atlasHeight:height,algorithm:algorithm)
    }
}

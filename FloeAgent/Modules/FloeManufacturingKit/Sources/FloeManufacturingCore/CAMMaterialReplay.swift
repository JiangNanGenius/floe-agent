// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMachiningNative
import Darwin

/// A completed-path checkpoint is an acceleration only. Seeking backwards
/// starts again from the source stock; partial cuts are never reused as if a
/// whole path had finished. The renderer and the tool share this exact cursor.
final class CAMMaterialReplay: @unchecked Sendable {
    struct Cursor: Sendable {
        var pathIndex: Int
        var pointIndex: Int
        var fraction: Double
    }
    struct Reply: Decodable, Sendable {
        var ok: Bool
        var vertices: [[Double]]
        var triangles: [[Int]]
        var stockState: ManufacturingStockState
        var checkpointState: ManufacturingStockState
        var checkpointCollisions: [ManufacturingResult.Collision]
        var collisions: [ManufacturingResult.Collision]
        var warnings: [String]
        var sampledPoses: Int
    }
    private struct Path: Encodable, Sendable {
        var kind: String
        var points: [[Double]]
        var toolAxes: [[Double]]?
        var tool: ManufacturingCAM.Tool?
    }
    private struct Request: Encodable, Sendable {
        var formatVersion = 1
        var stock: ManufacturingStudy.Stock
        var budget: ManufacturingStudy.Budget
        var paths: [Path]
        var pathIndex: Int
        var pointIndex: Int
        var fraction: Double
        var fromPathIndex: Int
        var initialStockState: ManufacturingStockState?
        var turningApproach: TurningApproach?
        var fixtures: [ManufacturingStudy.Fixture]
        var turningNoseRadiusMM: Double
    }
    private let study: ManufacturingStudy
    private let paths: [Path]
    private let initialStock: ManufacturingStockState?
    private let expectedFinal: ManufacturingStockState?
    private let lock = NSLock()
    private var checkpointPath = 0
    private var checkpoint: ManufacturingStockState?
    private var checkpointCollisions: [ManufacturingResult.Collision] = []
    init(study: ManufacturingStudy, artifact: ManufacturingArtifact, paths: [ManufacturingResult.Path], initialStock: ManufacturingStockState?) {
        self.study = study;self.initialStock = initialStock;expectedFinal = artifact.result.stockState
        self.paths = paths.map { path in
            var tool = study.cam?.tools.first { $0.id == path.toolID }
            var axes = path.toolAxes
            if tool == nil && ["milling-slot", "ac"].contains(path.kind) {
                var value = ManufacturingCAM.Tool(id:"legacy-cutter",name:"Cutting tool",diameterMM:study.milling.toolRadiusMM*2,cuttingLengthMM:study.milling.toolLengthMM)
                value.assembly = study.millingAssembly;tool = value
            }
            if path.kind == "milling-slot" && axes == nil {
                let angle = study.milling.angleDegrees * .pi/180
                axes = Array(repeating:[cos(angle),sin(angle),0],count:path.points.count)
            }
            return .init(kind:path.kind,points:path.points,toolAxes:axes,tool:tool)
        }
    }
    func snapshot(_ cursor: Cursor, control: ComputationControl) throws -> Reply {
        try control.check()
        return try lock.withLock {
            try control.check()
            let reuse = checkpoint != nil && cursor.pathIndex >= checkpointPath
            let base = reuse ? checkpoint : initialStock
            let previousCollisions = reuse ? checkpointCollisions : []
            let request = Request(stock:study.stock,budget:study.budget,paths:paths,pathIndex:cursor.pathIndex,
                pointIndex:cursor.pointIndex,fraction:cursor.fraction,fromPathIndex:reuse ? checkpointPath : 0,
                initialStockState:base,turningApproach:study.turningApproach,fixtures:study.fixtures,
                turningNoseRadiusMM:max(0.05,study.turning.toolNoseRadiusMM))
            let data = try ManufacturingStudy.encoder.encode(request)
            let context = Unmanaged.passUnretained(control).toOpaque()
            let reply = try String(decoding:data,as:UTF8.self).withCString { input -> Data in
                guard let output = fm_core_preview(input,nativeProgress,context) else { throw ManufacturingError.native("empty material replay response") }
                defer { fm_core_free(output) }
                // The C API returns a bounded, NUL-terminated JSON object.
                let data = Data(bytes:output,count:strlen(output))
                struct Failure:Decodable { var ok:Bool;var error:String? }
                let result = try JSONDecoder().decode(Failure.self,from:data)
                guard result.ok else {
                    if result.error == "cancelled" { throw ManufacturingError.cancelled }
                    throw ManufacturingError.native(result.error ?? "material replay failed")
                }
                return data
            }
            try control.check()
            var value = try JSONDecoder().decode(Reply.self,from:reply)
            try value.stockState.validate(for:study)
            try value.checkpointState.validate(for:study)
            if cursor.pathIndex == paths.count-1,cursor.pointIndex == paths[cursor.pathIndex].points.count-1,
               let expectedFinal,value.stockState.occupiedIndices != expectedFinal.occupiedIndices {
                throw ManufacturingError.native("Material replay differs from the saved execution. Regenerate the toolpaths before using this simulation for inspection.")
            }
            try control.check()
            checkpointPath = cursor.pathIndex;checkpoint = value.checkpointState
            checkpointCollisions = previousCollisions + value.checkpointCollisions
            value.collisions = previousCollisions + value.collisions
            return value
        }
    }
}

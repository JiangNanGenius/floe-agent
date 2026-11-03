import Foundation
import simd
import CryptoKit
import OCCTShim

/// Only immutable numeric/curve bytes cross the worker boundary. No live
/// OCCT handle, session, editor or document is sent to the worker.
nonisolated struct CADGuidedLoftSnapshot: Codable, Sendable {
    var loops: [Data]
    var conics: [Data]
    var segments: [Data]
    var planes: [SketchPlane]
    var guideCurves: [Data]
    var guidePlanes: [SketchPlane]
    var guideReversed: [Bool]
    var key: String? {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard let bytes=try? encoder.encode(self) else { return nil }
        return SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }
    static func accepts(_ definition: SketchCurveDefinition) -> Bool {
        switch definition.support { case .line,.conic:return true;default:return false }
    }
    static func validateSource(_ ref: ProfileRef,sketch: Sketch) throws {
        guard ref.holeEntityIDs.isEmpty else {
            throw LoftSurfaceError.unsupported("A guided loft currently requires sections without inner loops. Remove the guide to keep the existing exact paired-inner-loop loft.")
        }
        for entity in sketch.entities where ref.entityIDs.contains(entity.id) {
            switch entity {
            case .spline:throw LoftSurfaceError.unsupported("Guided sections require exact line/conic edges; fitted spline sections are not admitted.")
            case let .exactCurve(_,definition):
                guard accepts(definition) else { throw LoftSurfaceError.unsupported("The guided section contains a fitted or offset curve outside this operation's exact-input scope.") }
            default:break
            }
        }
    }
    init(sections: [(profile:Profile,holes:[Profile],plane:SketchPlane)],guide:SweepPathDefinition,
         sketch: (SketchID)->Sketch?) throws {
        guard (2...8).contains(sections.count),sections.allSatisfy({ $0.holes.isEmpty }),
              (1...8).contains(guide.segments.count) else {
            throw LoftSurfaceError.unsupported("Use 2–8 closed sections without inner loops and one guide of at most 8 exact edges.")
        }
        loops=[];conics=[];segments=[];planes=sections.map(\.plane)
        for section in sections {
            try FeaturePlaneReference.validate(section.plane)
            let p=OCCTKernel.packedProfile(section.profile,holes:[])
            guard section.profile.segments.count <= 64,section.profile.loop.count <= 1024 else {
                throw LoftSurfaceError.unsupported("A guided section exceeds its 64-edge/1024-point input budget.")
            }
            loops.append(p.loop);conics.append(p.conic);segments.append(p.segments)
        }
        guideCurves=[];guidePlanes=[];guideReversed=[]
        try guide.validate()
        for edge in guide.segments {
            guard let source=sketch(edge.sketchID),let entity=source.entities.first(where:{ $0.id == edge.entityID }) else {
                throw LoftSurfaceError.invalid("A guide edge was removed. Select its replacement explicitly.")
            }
            let curve=try SketchCurveDefinition(entity)
            guard !curve.interval.periodic,Self.accepts(curve) else {
                throw LoftSurfaceError.unsupported("A guide requires open exact line/conic edges; fitted spline/offset or closed edges are not admitted.")
            }
            try FeaturePlaneReference.validate(source.plane)
            guideCurves.append(curve.nativeRecord);guidePlanes.append(source.plane);guideReversed.append(edge.reversed)
        }
        let bytes=(loops+conics+segments+guideCurves).reduce(0) { $0+$1.count }
        guard bytes <= 2_097_152 else { throw LoftSurfaceError.invalid("The guided-loft numeric snapshot exceeds 2 MB.") }
    }
}

nonisolated struct CADGuidedLoftMetrics: Codable, Sendable {
    var nativeSurfaceError: Double
    var guideSampleDeviation: Double
    var sectionSampleDeviation: Double
    var guideSampleCount: Int
    var sectionSampleCount: Int
    var volume: Double
    var faceCount: Int
    var profileCount: Int
    var dictionary: [String:Any] {
        ["precision":"nativeToleranceBRep","method":"occt-multisection-auxiliary-contact",
         "tolerance_mm":1e-5,"native_surface_error_mm":nativeSurfaceError,
         "guide_sample_max_deviation_mm":guideSampleDeviation,"guide_sample_count":guideSampleCount,
         "section_sample_max_deviation_mm":sectionSampleDeviation,"section_sample_count":sectionSampleCount,
         "residual_scope":"finite independent samples; not a whole-curve distance certificate",
         "volume_mm3":volume,"faces":faceCount,"retained_section_count":profileCount,"hard_cancellation":false]
    }
}
nonisolated struct CADGuidedLoftPrepared: Sendable {
    var brep: Data
    var history: Data
    var metrics: CADGuidedLoftMetrics
    var bytes: Int { brep.count+history.count }
    func materialize() -> (handle:BRepHandle,ancestry:ShapeAncestry)? {
        guard let handle=OCCTKernel.deserialize(brep) else { return nil }
        let native=OCCTShapeHistory();native.rows=history;native.rowCount=history.count/(5*MemoryLayout<Int32>.size)
        return (handle,ShapeAncestry(native))
    }
}

/// Bounded immutable cache, shared by synchronous replay and the service-owned
/// worker. Eviction never changes a document. A main-actor cache miss refuses
/// and requests asynchronous preparation; it never runs PipeShell on main.
nonisolated final class CADGuidedLoftStore: @unchecked Sendable {
    static let shared=CADGuidedLoftStore()
    private let lock=NSLock()
    static let nativeLock=NSLock()
    private var values: [String:CADGuidedLoftPrepared]=[:]
    private var order: [String]=[]
    #if DEBUG
    func discardForTests() { lock.withLock { values.removeAll();order.removeAll() } }
    #endif
    func cached(_ snapshot:CADGuidedLoftSnapshot) -> CADGuidedLoftPrepared? {
        guard let key=snapshot.key else { return nil }
        return lock.withLock { values[key] }
    }
    func prepare(_ snapshot:CADGuidedLoftSnapshot,cancellation:CADMeshCancellation?=nil) -> CADGuidedLoftPrepared? {
        guard !Thread.isMainThread,let key=snapshot.key else { return nil }
        if cancellation?.isCancelled == true || Task.isCancelled { return nil }
        if let cached=cached(snapshot) { return cached }
        return Self.nativeLock.withLock {
            if cancellation?.isCancelled == true || Task.isCancelled { return nil }
            if let cached=cached(snapshot) { return cached }
            guard let prepared=OCCTKernel.buildGuidedLoft(snapshot),prepared.bytes <= 16*1024*1024,
                  cancellation?.isCancelled != true,!Task.isCancelled else { return nil }
            lock.withLock {
                while order.count >= 8 || values.values.reduce(prepared.bytes,{ $0+$1.bytes }) > 64*1024*1024 {
                    guard !order.isEmpty else { break };values.removeValue(forKey:order.removeFirst())
                }
                values[key]=prepared;order.append(key)
            }
            return prepared
        }
    }
    func replay(_ snapshot:CADGuidedLoftSnapshot) -> (handle:BRepHandle,ancestry:ShapeAncestry)? {
        (cached(snapshot) ?? prepare(snapshot))?.materialize()
    }
}
private actor CADGuidedLoftWorker {
    static let shared=CADGuidedLoftWorker()
    func prepare(_ snapshot:CADGuidedLoftSnapshot,cancellation:CADMeshCancellation,probe:(@Sendable ()->Void)?) -> CADGuidedLoftPrepared? {
        probe?()
        return CADGuidedLoftStore.shared.prepare(snapshot,cancellation:cancellation)
    }
}
nonisolated enum CADGuidedLoftPreparation {
    static func prepare(_ snapshots:[CADGuidedLoftSnapshot],probe:(@Sendable ()->Void)?=nil) async -> Bool {
        let cancellation=CADMeshCancellation()
        let task=Task.detached(priority:.userInitiated) {
            for snapshot in snapshots {
                guard !cancellation.isCancelled,!Task.isCancelled,
                      await CADGuidedLoftWorker.shared.prepare(snapshot,cancellation:cancellation,probe:probe) != nil else { return false }
            }
            return !cancellation.isCancelled && !Task.isCancelled
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { cancellation.cancel();task.cancel() }
    }
}
nonisolated extension OCCTKernel {
    static func buildGuidedLoft(_ input:CADGuidedLoftSnapshot) -> CADGuidedLoftPrepared? {
        guard !Thread.isMainThread else { return nil }
        let history=OCCTShapeHistory(),metrics=NSMutableDictionary(),status=OCCTOpStatus()
        guard let shape=OCCTBridge.guidedLoft(withOuterLoops:input.loops,outerConics:input.conics,
            outerSegments:input.segments,bases:input.planes.map(planeBasis),guideCurves:input.guideCurves,
            guideBases:input.guidePlanes.map(planeBasis),guideReversed:input.guideReversed.map { NSNumber(value:$0) },
            history:history,metrics:metrics,status:status),let bytes=serialize(BRepHandle(shape)),
              let error=metrics["native_surface_error"] as? Double,let guide=metrics["guide_sample_deviation"] as? Double,
              let section=metrics["section_sample_deviation"] as? Double,let volume=metrics["volume"] as? Double,
              let guideCount=metrics["guide_sample_count"] as? Int,let sectionCount=metrics["section_sample_count"] as? Int,
              let faces=metrics["faces"] as? Int,let profileCount=metrics["profile_count"] as? Int else { return nil }
        return CADGuidedLoftPrepared(brep:bytes,history:history.rows,
            metrics:.init(nativeSurfaceError:error,guideSampleDeviation:guide,sectionSampleDeviation:section,
                          guideSampleCount:guideCount,sectionSampleCount:sectionCount,volume:volume,faceCount:faces,profileCount:profileCount))
    }
}

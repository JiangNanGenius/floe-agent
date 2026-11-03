import Foundation
import simd
import CryptoKit
import OCCTShim

/// Immutable exact curve/control data, never a sampled render mesh or a live
/// session/shape. Endpoint vectors are in document coordinates, first -> last.
nonisolated struct CADLoftEndpointSnapshot:Codable,Sendable {
    var loops:[Data]
    var conics:[Data]
    var segments:[Data]
    var planes:[SketchPlane]
    var start:LoftDefinition.BoundaryConstraint?
    var end:LoftDefinition.BoundaryConstraint?
    var key:String? {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return (try? encoder.encode(self)).map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() }
    }
    static func validateSource(_ reference:ProfileRef,sketch:Sketch) throws {
        let ids=Set(reference.entityIDs+reference.holeEntityIDs.flatMap { $0 })
        for entity in sketch.entities where ids.contains(entity.id) {
            switch entity {
            case .spline:throw LoftSurfaceError.unsupported("Endpoint sections require exact line/conic curves; fitted splines are not admitted.")
            case let .exactCurve(_,curve):
                guard CADGuidedLoftSnapshot.accepts(curve) else { throw LoftSurfaceError.unsupported("The endpoint section contains a fitted or offset curve.") }
            default:break
            }
        }
    }
    init(sections:[(profile:Profile,plane:SketchPlane)],definition:LoftDefinition) throws {
        try definition.requireSupported(sectionCount:sections.count)
        guard definition.hasEndpointConstraints,definition.guides.isEmpty,(2...4).contains(sections.count),
              sections.allSatisfy({ $0.profile.segments.count<=16 && $0.profile.loop.count<=1024 }) else {
            throw LoftSurfaceError.unsupported("Use 2–4 compatible exact sections with at most 16 edges for endpoint constraints.")
        }
        loops=[];conics=[];segments=[];planes=sections.map(\.plane);start=definition.start;end=definition.end
        for section in sections {
            try FeaturePlaneReference.validate(section.plane)
            let packed=OCCTKernel.packedProfile(section.profile,holes:[])
            loops.append(packed.loop);conics.append(packed.conic);segments.append(packed.segments)
        }
        guard (loops+conics+segments).reduce(0,{ $0+$1.count })<=2_097_152 else { throw LoftSurfaceError.invalid("The endpoint snapshot exceeds 2 MB.") }
    }
    static func packed(_ value:LoftDefinition.BoundaryConstraint?) -> Data? {
        guard let value else { return nil }
        let t=value.tangent.point,k=value.curvature?.point ?? .zero
        let array:[Double]=[value.curvature == nil ? 1:2,t.x,t.y,t.z,k.x,k.y,k.z,value.angularTolerance,value.curvatureTolerance,0]
        return array.withUnsafeBytes { Data($0) }
    }
}
nonisolated struct CADLoftEndpointPrepared:Sendable {
    var brep:Data
    var history:Data
    var metrics:[String:Double]
    var bytes:Int { brep.count+history.count }
    var report:[String:Any] {
        var report:[String:Any]=metrics
        report["precision"]="exactSectionConstrainedBRep"
        report["method"]="occt-native-control-polygon-derivative-interpolation"
        report["constraint_scope"]="constant longitudinal direction / normal curvature vector over each whole endpoint; not G2 matching to an adjacent support face"
        report["section_certificate"]="positive common rational U weights and every section control-pole residual <= 1e-6 mm"
        report["boundary_certificate"]="constant prescribed pole D1/D2 with common positive U weights; actual surface jets independently sampled"
        report["hard_cancellation"]=false
        return report
    }
    func materialize() -> (handle:BRepHandle,ancestry:ShapeAncestry)? {
        guard let handle=OCCTKernel.deserialize(brep) else { return nil }
        let native=OCCTShapeHistory();native.rows=history;native.rowCount=history.count/(5*MemoryLayout<Int32>.size)
        return (handle,ShapeAncestry(native))
    }
}
nonisolated final class CADLoftEndpointStore:@unchecked Sendable {
    static let shared=CADLoftEndpointStore()
    private let lock=NSLock()
    private var values:[String:CADLoftEndpointPrepared]=[:]
    private var order:[String]=[]
    #if DEBUG
    func discardForTests() { lock.withLock { values.removeAll();order.removeAll() } }
    #endif
    func cached(_ snapshot:CADLoftEndpointSnapshot) -> CADLoftEndpointPrepared? {
        guard let key=snapshot.key else { return nil };return lock.withLock { values[key] }
    }
    func prepare(_ snapshot:CADLoftEndpointSnapshot,cancellation:CADMeshCancellation?=nil) -> CADLoftEndpointPrepared? {
        guard !Thread.isMainThread,let key=snapshot.key,!Task.isCancelled,cancellation?.isCancelled != true else { return nil }
        if let value=cached(snapshot) { return value }
        return CADGuidedLoftStore.nativeLock.withLock {
            guard !Task.isCancelled,cancellation?.isCancelled != true else { return nil }
            if let value=cached(snapshot) { return value }
            guard let value=OCCTKernel.buildEndpointLoft(snapshot),value.bytes<=16*1024*1024,
                  !Task.isCancelled,cancellation?.isCancelled != true else { return nil }
            lock.withLock {
                while order.count>=16 || values.values.reduce(value.bytes,{ $0+$1.bytes })>64*1024*1024 {
                    guard !order.isEmpty else { break };values.removeValue(forKey:order.removeFirst())
                }
                values[key]=value;order.append(key)
            }
            return value
        }
    }
    func replay(_ snapshot:CADLoftEndpointSnapshot) -> (handle:BRepHandle,ancestry:ShapeAncestry)? {
        (cached(snapshot) ?? prepare(snapshot))?.materialize()
    }
}
private actor CADLoftEndpointWorker {
    static let shared=CADLoftEndpointWorker()
    func prepare(_ snapshots:[CADLoftEndpointSnapshot],cancellation:CADMeshCancellation,probe:(@Sendable ()->Void)?) -> Bool {
        probe?()
        for snapshot in snapshots {
            guard !Task.isCancelled,!cancellation.isCancelled,CADLoftEndpointStore.shared.prepare(snapshot,cancellation:cancellation) != nil else { return false }
        }
        return !Task.isCancelled && !cancellation.isCancelled
    }
}
nonisolated enum CADLoftEndpointPreparation {
    static func prepare(_ snapshots:[CADLoftEndpointSnapshot],probe:(@Sendable ()->Void)?=nil) async -> Bool {
        guard snapshots.count<=8 else { return false }
        let cancellation=CADMeshCancellation()
        let task=Task.detached(priority:.userInitiated) { await CADLoftEndpointWorker.shared.prepare(snapshots,cancellation:cancellation,probe:probe) }
        return await withTaskCancellationHandler { await task.value } onCancel: { cancellation.cancel();task.cancel() }
    }
}
nonisolated extension OCCTKernel {
    static func buildEndpointLoft(_ input:CADLoftEndpointSnapshot) -> CADLoftEndpointPrepared? {
        guard !Thread.isMainThread else { return nil }
        let history=OCCTShapeHistory(),metrics=NSMutableDictionary(),status=OCCTOpStatus()
        guard let shape=OCCTBridge.endpointLoft(outerLoops:input.loops,outerConics:input.conics,outerSegments:input.segments,
            bases:input.planes.map(planeBasis),startBoundary:CADLoftEndpointSnapshot.packed(input.start),endBoundary:CADLoftEndpointSnapshot.packed(input.end),
            history:history,metrics:metrics,status:status),let bytes=serialize(BRepHandle(shape)) else { return nil }
        var numeric:[String:Double]=[:]
        for (key,value) in metrics { guard let key=key as? String,let value=value as? NSNumber,value.doubleValue.isFinite else { return nil };numeric[key]=value.doubleValue }
        guard numeric.count>=12 else { return nil }
        return .init(brep:bytes,history:history.rows,metrics:numeric)
    }
    static func endpointLoftJets(_ handle:BRepHandle) -> [String:Any] { OCCTBridge.endpointLoftJets(handle.shape) as? [String:Any] ?? [:] }
}

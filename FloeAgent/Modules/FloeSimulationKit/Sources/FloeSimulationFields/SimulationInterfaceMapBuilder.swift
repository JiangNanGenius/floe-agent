import Foundation
import FloeSimulationCore
import FloeSimulationGeometry

public enum SimulationInterfaceMapBuilder {
    public static func build(source: SimulationMesh, sourceBoundary: String, destination: SimulationMesh, destinationBoundary: String, toleranceMeters: Double = 1e-6, maximumComparisons: Int = 2_000_000) throws -> SimulationInterfaceMap {
        try source.validate(); try destination.validate()
        guard source.source == destination.source, toleranceMeters.isFinite, toleranceMeters > 0 else { throw SimulationError.invalidInput("Interface meshes must share a current source and a positive mapping tolerance.") }
        let selected = Set(try SimulationSelection.boundary(sourceBoundary).resolveNodes(in:source))
        let exterior = try SimulationMeshTopology.exteriorFaces(source)
        let faces: [SimulationSurfaceFace]
        if let facets = source.boundaries.first(where:{ $0.id == sourceBoundary })?.facets, !facets.isEmpty {
            let identities = Set(facets)
            faces = exterior.filter { identities.contains(.init(elementIndex:$0.elementIndex,localFace:$0.localFace)) }
            guard faces.count == identities.count else { throw SimulationError.invalidInput("An interface facet is not on the volume boundary.") }
        } else {
            faces = exterior.filter { $0.nodes.allSatisfy { selected.contains($0) } }
        }
        let destinationNodes = try SimulationSelection.boundary(destinationBoundary).resolveNodes(in:destination)
        guard !faces.isEmpty, faces.count <= maximumComparisons/max(1,destinationNodes.count) else { throw SimulationError.resourceLimit("The interface has no usable faces or exceeds the mapping work budget.") }
        var rows: [[SimulationInterfaceWeight]] = []
        for index in destinationNodes {
            let point = destination.nodes[index]
            var best: (Double,[SimulationInterfaceWeight])?
            for face in faces {
                let a = source.nodes[face.nodes[0]], b = source.nodes[face.nodes[1]], c = source.nodes[face.nodes[2]]
                let ab = b-a, ac = c-a, ap = point-a
                let aa = ab.dot(ab), bb = ab.dot(ac), cc = ac.dot(ac), d = ap.dot(ab), e = ap.dot(ac)
                let determinant = aa*cc-bb*bb
                guard determinant > 0 else { continue }
                let v = (cc*d-bb*e)/determinant, w = (aa*e-bb*d)/determinant
                var candidates: [(SimulationVector3,[Double])] = []
                if v >= 0, w >= 0, v+w <= 1 { candidates.append((a+ab*v+ac*w,[1-v-w,v,w])) }
                for (first,second,weights) in [(a,b,[0,1]),(a,c,[0,2]),(b,c,[1,2])] {
                    let delta = second-first, lengthSquared = delta.dot(delta)
                    guard lengthSquared > 0 else { continue }
                    let t = min(1,max(0,(point-first).dot(delta)/lengthSquared))
                    var row = [Double](repeating:0,count:3); row[weights[0]] = 1-t; row[weights[1]] = t
                    candidates.append((first+delta*t,row))
                }
                for (mapped,weights) in candidates {
                    let distance = (mapped-point).length
                    if best == nil || distance < best!.0 { best = (distance,zip(face.nodes,weights).filter { $0.1 > 0 }.map { .init(sourceNode:$0.0,weight:$0.1) }) }
                }
            }
            guard let best, best.0 <= toleranceMeters else { throw SimulationError.invalidInput("An interface node is outside the mapping tolerance.") }
            rows.append(best.1)
        }
        let mapping = SimulationInterfaceMap(sourceMeshID:source.id,destinationMeshID:destination.id,sourceNodeCount:source.nodes.count,rows:rows,destinationNodeIndices:destinationNodes)
        try mapping.validate(); return mapping
    }
}

public struct NativeCoupledSimulationBackend: SimulationBackend {
    private let driver: (any SimulationNativeDriver)?
    public init(driver: (any SimulationNativeDriver)? = nil) { self.driver = driver }
    public var descriptor: SimulationBackendDescriptor {
        driver?.descriptor ?? .init(id:"floe.coupled",version:"1",supportedStudies:[.conjugateHeatTransfer,.fluidStructure,.structuralAcoustics],isAvailable:false,unavailableReason:"The participating native solvers and checkpoint adapters are not linked in this host.")
    }
    public func validate(_ request: SimulationRequest) throws {
        try request.validate(); try request.study.configuration(as:CoupledSimulationConfiguration.self).validate()
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); guard let driver else { throw SimulationError.backendUnavailable(descriptor.id) }
        try Task.checkCancellation(); let result = try await driver.execute(request,progress:progress)
        try Task.checkCancellation(); try result.validate(for:request); return result
    }
}

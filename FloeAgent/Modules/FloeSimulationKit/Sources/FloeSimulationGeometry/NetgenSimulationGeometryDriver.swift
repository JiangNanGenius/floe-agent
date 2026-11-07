import Foundation
import FloeSimulationCore
#if canImport(FloeMeshingNative)
import FloeMeshingNative
#endif

public struct NetgenSimulationGeometryDriver: SimulationGeometryDriver {
    public init() {}
    public var isAvailable: Bool {
        #if canImport(FloeMeshingNative)
        true
        #else
        false
        #endif
    }
    public var supportsBRep: Bool {
        #if canImport(FloeMeshingNative)
        floe_mesh_supports_brep() == 1
        #else
        false
        #endif
    }
    public func generate(_ geometry: SimulationGeometrySnapshot, settings: SimulationMeshSettings, budget: SimulationBudget, progress: @escaping SimulationProgressHandler) async throws -> SimulationMesh {
        try geometry.validate(); try settings.validate(); try budget.validate(); try Task.checkCancellation()
        #if canImport(FloeMeshingNative)
        let session = try NetgenSession()
        let sourceIDs: [String:String]
        if let brep = geometry.brep {
            guard supportsBRep else { throw SimulationError.unsupported("Use an iOS host for B-rep meshing, or supply a tagged closed surface on this host.") }
            try brep.withUnsafeBytes { bytes in
                try geometry.effectiveRepresentationSHA256.withCString { prefix in
                    try session.check(floe_mesh_set_brep(session.pointer,bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count,geometry.sourceLengthToMeters,prefix))
                }
            }
            for tag in geometry.entityTags ?? [] {
                let kind: Int32 = switch tag.kind { case .face:0; case .solid:1; case .edge:2 }
                guard tag.nativeIndex <= Int(Int32.max) else { throw SimulationError.invalidInput("A CAD entity index is outside the native range.") }
                try tag.sourceEntityID.withCString { id in try tag.regionID.withCString { region in
                    try session.check(floe_mesh_set_entity(session.pointer,kind,Int32(tag.nativeIndex),id,region))
                } }
            }
            for (id,size) in settings.localSizes { try id.withCString { try session.check(floe_mesh_set_local_size(session.pointer,$0,size)) } }
            sourceIDs = [:]
        } else if let surface = geometry.surface {
            sourceIDs = try session.loadSurface(surface,prefix:geometry.effectiveRepresentationSHA256,settings:settings,budget:budget)
        } else { throw SimulationError.invalidInput("Capture a CAD solid or a closed tagged surface first.") }
        await progress(.init(stage:"meshing"))
        try await withTaskCancellationHandler {
            try session.check(floe_mesh_run(session.pointer,settings.maximumSizeMeters,settings.minimumSizeMeters,settings.growthRate,settings.curvatureRefinement ? 1 : 0,Int32(clamping:budget.maximumNodes),Int32(clamping:budget.maximumElements)))
        } onCancel: { session.cancel() }
        try Task.checkCancellation()
        let mesh = try session.readMesh(source:geometry.source,sourceIDs:sourceIDs,budget:budget)
        await progress(.init(stage:"complete",completed:1,total:1)); return mesh
        #else
        throw SimulationError.backendUnavailable("The Netgen native artifact is unavailable.")
        #endif
    }
}

#if canImport(FloeMeshingNative)
private final class NetgenSession: @unchecked Sendable {
    // The handle is immutable; cancellation only sets a native atomic flag.
    // Its lifetime includes both the worker and the cancellation handler.
    let pointer: OpaquePointer
    init() throws { guard let value = floe_mesh_create() else { throw SimulationError.resourceLimit("Unable to allocate the native meshing session.") }; pointer = value }
    deinit { floe_mesh_destroy(pointer) }
    func cancel() { floe_mesh_cancel(pointer) }
    func check(_ code: Int32) throws {
        guard code != 0 else { return }
        let message = floe_mesh_error(pointer).map { String(cString:$0) } ?? "Native meshing failed."
        switch code { case 1:throw SimulationError.invalidInput(message); case 2:throw SimulationError.unsupported(message); case 4:throw SimulationError.cancelled; case 5:throw SimulationError.resourceLimit(message); default:throw SimulationError.solverFailure(message) }
    }
    func loadSurface(_ mesh: SimulationMesh, prefix: String, settings: SimulationMeshSettings, budget: SimulationBudget) throws -> [String:String] {
        guard mesh.elements.allSatisfy({ $0.kind == .triangle3 }) else { throw SimulationError.unsupported("The closed-surface mesher requires triangular faces.") }
        let faceLimit = min(500_000,budget.maximumElements)*4
        guard mesh.nodes.count <= min(200_000,budget.maximumNodes), mesh.elements.count <= faceLimit else { throw SimulationError.resourceLimit("The input surface exceeds the mesh budget.") }
        var tagForElement: [Int:String] = [:], sourceIDs: [String:String] = [:]
        for boundary in mesh.boundaries {
            let indices: [Int]
            if let facets = boundary.facets, !facets.isEmpty {
                guard facets.allSatisfy({ $0.localFace == nil }) else { throw SimulationError.invalidInput("Surface tags must refer to whole triangles.") }
                indices = facets.map(\.elementIndex)
            } else {
                guard !boundary.elementIndices.isEmpty else { throw SimulationError.invalidInput("A surface face tag needs explicit triangle references.") }
                indices = boundary.elementIndices
            }
            for index in indices {
                guard tagForElement[index] == nil else { throw SimulationError.invalidInput("Two source face tags overlap on one triangle.") }
                tagForElement[index] = boundary.id
            }
            sourceIDs[boundary.id] = boundary.sourceEntityID
        }
        for index in mesh.elements.indices where tagForElement[index] == nil {
            let id = prefix+"/triangle/\(index)"; tagForElement[index] = id; sourceIDs[id] = id
        }
        let regionIDs = Set(mesh.elements.map(\.regionID)).sorted(), boundaryIDs = Set(tagForElement.values).sorted()
        let regionLookup = Dictionary(uniqueKeysWithValues:regionIDs.enumerated().map { ($0.element,Int32($0.offset)) })
        let boundaryLookup = Dictionary(uniqueKeysWithValues:boundaryIDs.enumerated().map { ($0.element,Int32($0.offset)) })
        let xyz = mesh.nodes.flatMap { [$0.x,$0.y,$0.z] }, triangles = mesh.elements.flatMap { $0.nodes.map(Int32.init) }
        let regions = mesh.elements.map { regionLookup[$0.regionID]! }, tags = mesh.elements.indices.map { boundaryLookup[tagForElement[$0]!]! }
        try withStrings(regionIDs) { regionNames in try withStrings(boundaryIDs) { boundaryNames in
            try xyz.withUnsafeBufferPointer { xyz in try triangles.withUnsafeBufferPointer { triangles in try regions.withUnsafeBufferPointer { regions in try tags.withUnsafeBufferPointer { tags in
                try check(floe_mesh_set_surface(pointer,xyz.baseAddress,Int32(mesh.nodes.count),triangles.baseAddress,Int32(mesh.elements.count),regions.baseAddress,regionNames,Int32(regionIDs.count),tags.baseAddress,boundaryNames,Int32(boundaryIDs.count)))
            } } } }
        } }
        for (sourceID,size) in settings.localSizes {
            let matching = sourceIDs.filter { $0.value == sourceID }.map(\.key)
            guard !matching.isEmpty else { throw SimulationError.invalidInput("A local size refers to a missing source face.") }
            for tag in matching { try tag.withCString { try check(floe_mesh_set_local_size(pointer,$0,size)) } }
        }
        return sourceIDs
    }
    private func withStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> T) rethrows -> T {
        let pointers = strings.map { string in
            let bytes = Array(string.utf8CString), pointer = UnsafeMutablePointer<CChar>.allocate(capacity:bytes.count)
            pointer.initialize(from:bytes,count:bytes.count); return pointer
        }
        defer { for pointer in pointers { pointer.deallocate() } }
        return try pointers.map { Optional(UnsafePointer($0)) }.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
    func readMesh(source: SimulationSourceRef, sourceIDs: [String:String], budget: SimulationBudget) throws -> SimulationMesh {
        let nodeCount = Int(floe_mesh_node_count(pointer)), elementCount = Int(floe_mesh_element_count(pointer)), faceCount = Int(floe_mesh_face_count(pointer))
        let regionCount = Int(floe_mesh_region_count(pointer)), boundaryCount = Int(floe_mesh_boundary_count(pointer))
        guard nodeCount > 0, nodeCount <= budget.maximumNodes, elementCount > 0, elementCount <= budget.maximumElements,
              faceCount > 0, faceCount <= elementCount*4, regionCount > 0, regionCount <= 4096, boundaryCount > 0, boundaryCount <= faceCount,
              let xyz = floe_mesh_nodes(pointer), let tetrahedra = floe_mesh_tetrahedra(pointer), let regions = floe_mesh_regions(pointer),
              let triangles = floe_mesh_triangles(pointer), let tags = floe_mesh_boundaries(pointer) else { throw SimulationError.solverFailure("Invalid native mesh response or resource budget.") }
        let regionIDs = try (0..<regionCount).map { index in guard let id = floe_mesh_region_id(pointer,Int32(index)) else { throw SimulationError.solverFailure("A material region lost its identity.") }; return String(cString:id) }
        let boundaryIDs = try (0..<boundaryCount).map { index in guard let id = floe_mesh_boundary_id(pointer,Int32(index)) else { throw SimulationError.solverFailure("A source face lost its identity.") }; return String(cString:id) }
        let nodes = (0..<nodeCount).map { SimulationVector3(xyz[$0*3],xyz[$0*3+1],xyz[$0*3+2]) }
        var elements: [SimulationElement] = [], incidence: [[Int]:[SimulationBoundaryFacet]] = [:]
        for index in 0..<elementCount {
            var indices = (0..<4).map { Int(tetrahedra[index*4+$0]) }; let region = Int(regions[index])
            guard indices.allSatisfy({ nodes.indices.contains($0) }), regionIDs.indices.contains(region) else { throw SimulationError.solverFailure("The native mesh returned invalid connectivity.") }
            let a = nodes[indices[0]], b = nodes[indices[1]], c = nodes[indices[2]], d = nodes[indices[3]]
            if (b-a).dot((c-a).cross(d-a)) < 0 { indices.swapAt(1,2) }
            let element = SimulationElement(kind:.tetrahedron4,nodes:indices,regionID:regionIDs[region]); elements.append(element)
            for (face,indices) in element.faceNodeIndices.enumerated() { incidence[indices.sorted(),default:[]].append(.init(elementIndex:index,localFace:face)) }
        }
        var boundaryNodes: [Int:Set<Int>] = [:], boundaryFacets: [Int:Set<SimulationBoundaryFacet>] = [:]
        for index in 0..<faceCount {
            let indices = (0..<3).map { Int(triangles[index*3+$0]) }, tag = Int(tags[index])
            guard boundaryIDs.indices.contains(tag), let facets = incidence[indices.sorted()], !facets.isEmpty, facets.count <= 2 else { throw SimulationError.solverFailure("A source face does not match the generated volume mesh.") }
            boundaryNodes[tag,default:[]].formUnion(indices); boundaryFacets[tag,default:[]].formUnion(facets)
        }
        let boundaries = try boundaryIDs.indices.map { index -> SimulationBoundary in
            guard let nodes = boundaryNodes[index], let faces = boundaryFacets[index], !faces.isEmpty else { throw SimulationError.solverFailure("A source boundary has no volume facets.") }
            let sorted = faces.sorted { $0.elementIndex == $1.elementIndex ? ($0.localFace ?? -1) < ($1.localFace ?? -1) : $0.elementIndex < $1.elementIndex }
            return .init(id:boundaryIDs[index],sourceEntityID:sourceIDs[boundaryIDs[index]] ?? boundaryIDs[index],nodeIndices:nodes.sorted(),elementIndices:Set(sorted.map(\.elementIndex)).sorted(),facets:sorted)
        }
        let mesh = SimulationMesh(source:source,nodes:nodes,elements:elements,boundaries:boundaries)
        try mesh.validate(); return mesh
    }
}
#endif

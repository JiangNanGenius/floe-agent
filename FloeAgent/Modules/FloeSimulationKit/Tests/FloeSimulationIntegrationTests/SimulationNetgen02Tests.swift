import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry

private func netgenSource() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"8",count:64)) }

private func taggedSurface(_ source: SimulationSourceRef, boxes: [(SimulationVector3,SimulationVector3,String,Bool)]) throws -> SimulationMesh {
    var nodes: [SimulationVector3] = [], elements: [SimulationElement] = [], boundaryElements: [String:[Int]] = [:]
    for (ordinal,box) in boxes.enumerated() {
        let volume = try SimulationBoxMesher.generate(source:source,minimum:box.0,maximum:box.1), offset = nodes.count
        nodes += volume.nodes
        let boundaryLookup = Dictionary(uniqueKeysWithValues:volume.boundaries.flatMap { boundary in (boundary.facets ?? []).map { ($0,boundary.id) } })
        for face in try SimulationMeshTopology.exteriorFaces(volume) {
            let key = "box\(ordinal)/"+(boundaryLookup[.init(elementIndex:face.elementIndex,localFace:face.localFace)] ?? "unknown")
            var indices = face.nodes.map { $0+offset }; if box.3 { indices.swapAt(1,2) }
            boundaryElements[key,default:[]].append(elements.count)
            elements.append(.init(kind:.triangle3,nodes:indices,regionID:box.2))
        }
    }
    let boundaries = boundaryElements.keys.sorted().map { id in
        let indices = boundaryElements[id]!
        return SimulationBoundary(id:id,sourceEntityID:"fixture/"+id,nodeIndices:Set(indices.flatMap { elements[$0].nodes }).sorted(),elementIndices:indices,facets:indices.map { .init(elementIndex:$0) })
    }
    return .init(source:source,nodes:nodes,elements:elements,boundaries:boundaries)
}
private func volume(_ mesh: SimulationMesh, region: String? = nil) -> Double {
    mesh.elements.filter { region == nil || $0.regionID == region }.reduce(0.0) { value,element in
        let p = element.nodes.map { mesh.nodes[$0] }
        return value+(p[1]-p[0]).dot((p[2]-p[0]).cross(p[3]-p[0]))/6
    }
}

@Test func netgen02HollowSurfaceKeepsCavityFaceTagsAndLocalRefinement() async throws {
    let source = netgenSource()
    let surface = try taggedSurface(source,boxes:[(.zero,.init(1,1,1),"solid",false),(.init(0.3,0.3,0.3),.init(0.7,0.7,0.7),"solid",true)])
    var settings = SimulationMeshSettings(maximumSizeMeters:0.25,minimumSizeMeters:0.02)
    settings.localSizes["fixture/box0/xmin"] = 0.12
    let geometry = SimulationGeometrySnapshot(source:source,surface:surface,sourceLengthToMeters:0.001)
    // Surface coordinates are already SI; the B-rep conversion factor must
    // never shrink this surface by another factor of 1000.
    let mesh = try await NativeSimulationMesher(driver:NetgenSimulationGeometryDriver()).mesh(geometry,settings:settings,budget:.init()) { _ in }
    #expect(abs(volume(mesh)-(1-pow(0.4,3))) < 1e-8)
    #expect(Set(mesh.boundaries.map(\.id)) == Set(surface.boundaries.map(\.id)))
    #expect(Set(mesh.boundaries.map(\.sourceEntityID)) == Set(surface.boundaries.map(\.sourceEntityID)))
    for element in mesh.elements {
        let center = element.nodes.reduce(SimulationVector3.zero) { $0+mesh.nodes[$1] }/4
        #expect(!(center.x > 0.3 && center.x < 0.7 && center.y > 0.3 && center.y < 0.7 && center.z > 0.3 && center.z < 0.7))
    }
    let refined = try #require(mesh.boundaries.first { $0.id == "box0/xmin" })
    #expect(refined.facets?.isEmpty == false)
    for facet in refined.facets ?? [] {
        let nodes = try mesh.nodes(of:facet).map { mesh.nodes[$0] }
        #expect(nodes.allSatisfy { abs($0.x) < 1e-12 })
        for index in nodes.indices { #expect((nodes[index]-nodes[(index+1)%3]).length <= 0.12*(1+1e-10)) }
    }
}

@Test func netgen02SeparateRegionsKeepDistinctMaterialVolumes() async throws {
    let source = netgenSource(), surface = try taggedSurface(source,boxes:[(.zero,.init(0.1,0.1,0.1),"first",false),(.init(0.3,0,0),.init(0.5,0.2,0.2),"second",false)])
    let mesh = try await NativeSimulationMesher(driver:NetgenSimulationGeometryDriver()).mesh(.init(source:source,surface:surface),settings:.init(maximumSizeMeters:0.05,minimumSizeMeters:0.01),budget:.init()) { _ in }
    #expect(abs(volume(mesh,region:"first")-0.001) < 1e-10)
    #expect(abs(volume(mesh,region:"second")-0.008) < 1e-10)
}

@Test func netgen02OpenSurfaceAndExcessiveRefinementFailExplicitly() async throws {
    let source = netgenSource()
    let surface = try taggedSurface(source,boxes:[(.zero,.init(0.1,0.1,0.1),"body",false)])
    var open = surface;open.elements.removeLast();open.boundaries = []
    await #expect(throws:SimulationError.self) { try await NetgenSimulationGeometryDriver().generate(.init(source:source,surface:open),settings:.init(maximumSizeMeters:0.05,minimumSizeMeters:0.001),budget:.init()) { _ in } }
    do {
        _ = try await NetgenSimulationGeometryDriver().generate(.init(source:source,surface:surface),settings:.init(maximumSizeMeters:0.005,minimumSizeMeters:0.001),budget:.init(maximumNodes:64)) { _ in }
        Issue.record("An oversized mesh must fail before exhausting memory")
    } catch SimulationError.resourceLimit { }
}

@Test func netgen02RepresentationDigestIgnoresSessionAndMeshUUIDs() throws {
    let source = netgenSource();var surface = try taggedSurface(source,boxes:[(.zero,.init(1,1,1),"body",false)])
    let first = SimulationGeometrySnapshot(source:source,surface:surface).effectiveRepresentationSHA256
    surface.id = UUID();surface.source.revision += 1;surface.source.contentSHA256 = String(repeating:"9",count:64)
    let second = SimulationGeometrySnapshot(source:surface.source,surface:surface).effectiveRepresentationSHA256
    #expect(first == second)
}

import Foundation
import CryptoKit

private struct SurfaceRepresentation: Encodable {
    var nodes: [SimulationVector3]
    var elements: [SimulationElement]
    var boundaries: [SimulationBoundary]
}

public enum SimulationGeometryEntityKind: String, Codable, Hashable, Sendable { case solid, face, edge }

/// nativeIndex is a transient one-based TopExp index inside this exact B-rep,
/// never a replacement for the host's persistent sourceEntityID.
public struct SimulationGeometryEntityTag: Codable, Hashable, Sendable {
    public var kind: SimulationGeometryEntityKind
    public var nativeIndex: Int
    public var sourceEntityID: String
    public var regionID: String
    public init(kind: SimulationGeometryEntityKind, nativeIndex: Int, sourceEntityID: String, regionID: String = "body") {
        self.kind = kind; self.nativeIndex = nativeIndex; self.sourceEntityID = sourceEntityID; self.regionID = regionID
    }
}

public struct SimulationBoundaryFacet: Codable, Hashable, Sendable {
    public var elementIndex: Int
    /// nil refers to the entire triangle/quad surface element; volume elements
    /// use the local face order defined by SimulationElement.faceNodeIndices.
    public var localFace: Int?
    public init(elementIndex: Int, localFace: Int? = nil) { self.elementIndex = elementIndex; self.localFace = localFace }
}

public extension SimulationElement {
    var faceNodeIndices: [[Int]] {
        guard nodes.count == kind.nodeCount else { return [] }
        return switch kind {
        case .tetrahedron4: (0..<4).map { face in nodes.enumerated().filter { $0.offset != face }.map(\.element) }
        case .hexahedron8:
            [[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]].map { $0.map { nodes[$0] } }
        case .triangle3,.quadrilateral4: [nodes]
        case .line2: nodes.map { [$0] }
        }
    }
}

public extension SimulationMesh {
    func nodes(of facet: SimulationBoundaryFacet) throws -> [Int] {
        guard elements.indices.contains(facet.elementIndex) else { throw SimulationError.invalidInput("A facet refers to a missing element.") }
        let element = elements[facet.elementIndex]
        guard element.nodes.count == element.kind.nodeCount,
              element.nodes.allSatisfy({ nodes.indices.contains($0) }) else { throw SimulationError.invalidInput("A facet has invalid element connectivity.") }
        if let localFace = facet.localFace {
            guard element.faceNodeIndices.indices.contains(localFace) else { throw SimulationError.invalidInput("A local face is outside its element.") }
            return element.faceNodeIndices[localFace]
        }
        guard element.kind == .triangle3 || element.kind == .quadrilateral4 else { throw SimulationError.invalidInput("Volume facets require an explicit local face.") }
        return element.nodes
    }
}

public extension SimulationGeometrySnapshot {
    var effectiveRepresentationSHA256: String {
        if let brep { return SHA256.hash(data:brep).map { String(format:"%02x",$0) }.joined() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let surface else { return "" }
        let representation = SurfaceRepresentation(nodes:surface.nodes,elements:surface.elements,boundaries:surface.boundaries)
        return (try? encoder.encode(representation)).map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() } ?? ""
    }
    func validate() throws {
        try source.validate()
        guard sourceLengthToMeters.isFinite, sourceLengthToMeters > 0, brep != nil || surface != nil,
              brep.map({ !$0.isEmpty && $0.count <= 64_000_000 }) ?? true else { throw SimulationError.invalidInput("Invalid geometry representation, units or B-rep budget.") }
        if let surface { try surface.validate(); guard surface.source == source else { throw SimulationError.staleSource } }
        if let representationSHA256, representationSHA256 != effectiveRepresentationSHA256 { throw SimulationError.staleSource }
        let tags = entityTags ?? []
        guard tags.count <= 1_000_000, Set(tags.map { $0.kind.rawValue+"/"+String($0.nativeIndex) }).count == tags.count,
              tags.allSatisfy({ $0.nativeIndex > 0 && !$0.sourceEntityID.isEmpty && !$0.regionID.isEmpty }) else { throw SimulationError.invalidInput("Invalid or ambiguous CAD entity tags.") }
    }
}

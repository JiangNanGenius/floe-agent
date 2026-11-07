import Foundation

/// All calculation interfaces use SI. CAD hosts convert their document units once.
public struct SimulationVector3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public static let zero = Self()
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public var length: Double { sqrt(x * x + y * y + z * z) }
    public static func + (a: Self, b: Self) -> Self { .init(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Self, b: Self) -> Self { .init(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Self) -> Self { .init(-a.x, -a.y, -a.z) }
    public static func * (a: Self, b: Double) -> Self { .init(a.x * b, a.y * b, a.z * b) }
    public static func / (a: Self, b: Double) -> Self { .init(a.x / b, a.y / b, a.z / b) }
    public func dot(_ b: Self) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Self) -> Self { .init(y*b.z-z*b.y, z*b.x-x*b.z, x*b.y-y*b.x) }
}

public struct SimulationQuaternion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0, w: Double = 1) { self.x = x; self.y = y; self.z = z; self.w = w }
    public static let identity = Self()
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

public struct SimulationSourceRef: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var documentID: UUID
    public var revision: UInt64
    public var contentSHA256: String
    public init(projectID: UUID, documentID: UUID, revision: UInt64, contentSHA256: String) {
        self.projectID = projectID; self.documentID = documentID; self.revision = revision; self.contentSHA256 = contentSHA256
    }
    public func validate() throws {
        guard contentSHA256.count == 64, contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SimulationError.invalidInput("A lowercase SHA-256 source digest is required.")
        }
    }
}

public enum SimulationStudyKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case rigidBody, skeletalPhysics, cloth, rope, softBody, particles
    case structuralStatic, beamShell, laminate, modal, buckling, nonlinearContact
    case thermalSteady, thermalTransient, thermalStress
    case incompressibleFlow, compressibleFlow, turbulentFlow, conjugateHeatTransfer, fluidStructure
    case pressureAcoustics, structuralAcoustics
    case electrostatic, magnetostatic, eddyCurrent
    case radioFrequency, electromagneticModes, antenna
    public var id: String { rawValue }
}

public enum SimulationElementKind: String, Codable, Sendable, CaseIterable {
    case line2, triangle3, quadrilateral4, tetrahedron4, hexahedron8
    public var nodeCount: Int {
        switch self { case .line2: 2; case .triangle3: 3; case .quadrilateral4, .tetrahedron4: 4; case .hexahedron8: 8 }
    }
}

public struct SimulationElement: Codable, Hashable, Sendable {
    public var kind: SimulationElementKind
    public var nodes: [Int]
    public var regionID: String
    public init(kind: SimulationElementKind, nodes: [Int], regionID: String) { self.kind = kind; self.nodes = nodes; self.regionID = regionID }
}

public struct SimulationBoundary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceEntityID: String
    public var nodeIndices: [Int]
    public var elementIndices: [Int]
    public var facets: [SimulationBoundaryFacet]?
    public init(id: String, sourceEntityID: String, nodeIndices: [Int], elementIndices: [Int] = [], facets: [SimulationBoundaryFacet]? = nil) {
        self.id = id; self.sourceEntityID = sourceEntityID; self.nodeIndices = nodeIndices; self.elementIndices = elementIndices; self.facets = facets
    }
}

public struct SimulationMesh: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var nodes: [SimulationVector3]
    public var elements: [SimulationElement]
    public var boundaries: [SimulationBoundary]
    public init(id: UUID = UUID(), source: SimulationSourceRef, nodes: [SimulationVector3], elements: [SimulationElement], boundaries: [SimulationBoundary] = []) {
        self.id = id; self.source = source; self.nodes = nodes; self.elements = elements; self.boundaries = boundaries
    }
    public func validate() throws {
        try source.validate()
        guard !nodes.isEmpty, !elements.isEmpty, nodes.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("The mesh is empty or contains non-finite coordinates.") }
        for element in elements {
            guard element.nodes.count == element.kind.nodeCount, Set(element.nodes).count == element.nodes.count,
                  element.nodes.allSatisfy({ nodes.indices.contains($0) }), !element.regionID.isEmpty, !element.regionID.contains("\0") else {
                throw SimulationError.invalidInput("An element has invalid connectivity or region identity.")
            }
            if element.kind == .tetrahedron4 {
                let a = nodes[element.nodes[0]], b = nodes[element.nodes[1]], c = nodes[element.nodes[2]], d = nodes[element.nodes[3]]
                let jacobian = (b-a).dot((c-a).cross(d-a))
                guard jacobian.isFinite, jacobian > 0 else { throw SimulationError.invalidInput("Tetrahedron Jacobians must be positive and finite.") }
            } else if element.kind == .triangle3 {
                let area = (nodes[element.nodes[1]]-nodes[element.nodes[0]]).cross(nodes[element.nodes[2]]-nodes[element.nodes[0]]).length
                guard area.isFinite, area > 0 else { throw SimulationError.invalidInput("A surface triangle is degenerate.") }
            }
        }
        guard Set(boundaries.map(\.id)).count == boundaries.count else { throw SimulationError.invalidInput("Boundary identities must be unique.") }
        for boundary in boundaries {
            guard !boundary.id.isEmpty, !boundary.sourceEntityID.isEmpty, !boundary.id.contains("\0"), !boundary.sourceEntityID.contains("\0"),
                  boundary.nodeIndices.allSatisfy({ nodes.indices.contains($0) }),
                  boundary.elementIndices.allSatisfy({ elements.indices.contains($0) }) else { throw SimulationError.invalidInput("A boundary has invalid source or mesh references.") }
            let facets = boundary.facets ?? []
            guard Set(facets).count == facets.count else { throw SimulationError.invalidInput("A boundary contains duplicate facets.") }
            let selected = Set(boundary.nodeIndices)
            for facet in facets {
                let indices = try self.nodes(of:facet)
                guard indices.allSatisfy({ selected.contains($0) }) else { throw SimulationError.invalidInput("Boundary facet nodes do not match their boundary selection.") }
            }
        }
    }
}

public struct SimulationGeometrySnapshot: Codable, Equatable, Sendable {
    public var source: SimulationSourceRef
    public var brep: Data?
    public var surface: SimulationMesh?
    /// Applies to B-rep coordinates only. Surface mesh coordinates are already SI.
    public var sourceLengthToMeters: Double
    public var representationSHA256: String?
    public var entityTags: [SimulationGeometryEntityTag]?
    public init(source: SimulationSourceRef, brep: Data? = nil, surface: SimulationMesh? = nil, sourceLengthToMeters: Double = 0.001, representationSHA256: String? = nil, entityTags: [SimulationGeometryEntityTag]? = nil) {
        self.source = source; self.brep = brep; self.surface = surface; self.sourceLengthToMeters = sourceLengthToMeters; self.representationSHA256 = representationSHA256; self.entityTags = entityTags
    }
}

public struct SimulationLaminateLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var materialID: UUID
    public var thicknessMeters: Double
    public var angleRadians: Double
    public init(id: UUID = UUID(), materialID: UUID, thicknessMeters: Double, angleRadians: Double) {
        self.id = id; self.materialID = materialID; self.thicknessMeters = thicknessMeters; self.angleRadians = angleRadians
    }
}

public struct SimulationMaterial: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Domain-specific, named SI properties. Adapters must reject absent required values.
    public var properties: [String: Double]
    public var direction: SimulationQuaternion
    public var layers: [SimulationLaminateLayer]
    public var provenance: String
    public init(id: UUID = UUID(), name: String, properties: [String: Double], direction: SimulationQuaternion = .identity, layers: [SimulationLaminateLayer] = [], provenance: String = "user") {
        self.id = id; self.name = name; self.properties = properties; self.direction = direction; self.layers = layers; self.provenance = provenance
    }
}

public struct SimulationStudy: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var revision: UInt64 = 0
    public var name: String
    public var kind: SimulationStudyKind
    public var meshID: UUID?
    /// Codable domain configurations are stored without coupling Core to any backend.
    public var configuration: Data
    public var materialAssignments: [String: UUID]
    public init(id: UUID = UUID(), name: String, kind: SimulationStudyKind, configuration: Data = Data("{}".utf8), materialAssignments: [String: UUID] = [:]) {
        self.id = id; self.name = name; self.kind = kind; self.configuration = configuration; self.materialAssignments = materialAssignments
    }
    public func configuration<T: Decodable>(as type: T.Type) throws -> T { try JSONDecoder().decode(type, from: configuration) }
    public mutating func touch() throws {
        guard revision < UInt64.max else { throw SimulationError.invalidInput("The study revision is exhausted.") }
        revision += 1
    }
    public mutating func setConfiguration<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value); try touch(); configuration = encoded
    }
}

public struct SimulationBudget: Codable, Equatable, Sendable {
    public var maximumNodes: Int
    public var maximumElements: Int
    public var maximumResultValues: Int
    public var maximumIterations: Int
    public init(maximumNodes: Int = 200_000, maximumElements: Int = 1_000_000, maximumResultValues: Int = 10_000_000, maximumIterations: Int = 10_000) {
        self.maximumNodes = maximumNodes; self.maximumElements = maximumElements; self.maximumResultValues = maximumResultValues; self.maximumIterations = maximumIterations
    }
    public func validate() throws {
        guard maximumNodes > 0, maximumElements > 0, maximumResultValues > 0, maximumIterations > 0 else { throw SimulationError.invalidInput("Resource budgets must be positive.") }
    }
}

public struct SimulationRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var study: SimulationStudy
    public var mesh: SimulationMesh?
    public var materials: [SimulationMaterial]
    public var budget: SimulationBudget
    public init(id: UUID = UUID(), source: SimulationSourceRef, study: SimulationStudy, mesh: SimulationMesh? = nil, materials: [SimulationMaterial] = [], budget: SimulationBudget = .init()) {
        self.id = id; self.source = source; self.study = study; self.mesh = mesh; self.materials = materials; self.budget = budget
    }
    public func validate() throws {
        try source.validate(); try budget.validate()
        guard !study.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, study.name.utf8.count <= 2048 else { throw SimulationError.invalidInput("The study needs a name within the document text budget.") }
        if let mesh {
            try mesh.validate()
            if let meshID = study.meshID, mesh.id != meshID { throw SimulationError.invalidInput("The request mesh does not match the study.") }
            guard mesh.source == source else { throw SimulationError.staleSource }
            guard mesh.nodes.count <= budget.maximumNodes, mesh.elements.count <= budget.maximumElements else { throw SimulationError.resourceLimit("The mesh exceeds this study's resource budget.") }
        }
        else if study.meshID != nil { throw SimulationError.invalidInput("The study's mesh is missing.") }
        guard Set(materials.map(\.id)).count == materials.count else { throw SimulationError.invalidInput("Material identities must be unique.") }
        let materialIDs = Set(materials.map(\.id))
        guard study.materialAssignments.values.allSatisfy({ materialIDs.contains($0) }) else { throw SimulationError.invalidInput("A region refers to a missing material.") }
        for material in materials {
            guard material.properties.values.allSatisfy(\.isFinite), material.direction.isFinite,
                  material.layers.allSatisfy({ $0.thicknessMeters.isFinite && $0.thicknessMeters > 0 && $0.angleRadians.isFinite && materialIDs.contains($0.materialID) }) else { throw SimulationError.invalidInput("Material properties or laminate layers are invalid.") }
        }
    }
}

public enum SimulationError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String), resourceLimit(String), backendUnavailable(String), unsupported(String), solverFailure(String), corruptArchive(String)
    case staleSource, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s), .resourceLimit(let s), .backendUnavailable(let s), .unsupported(let s), .solverFailure(let s), .corruptArchive(let s): s
        case .staleSource: "The source has changed. Run the study again."
        case .cancelled: "The simulation was cancelled."
        }
    }
}

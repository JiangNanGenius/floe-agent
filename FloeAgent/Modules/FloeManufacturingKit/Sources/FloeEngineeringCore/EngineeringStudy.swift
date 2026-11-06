// SPDX-License-Identifier: MPL-2.0
import Foundation

/// An engineering study: one mesh, one material, optional structural and thermal
/// analyses, and optional manufacturability screening. This is the single public
/// model Root archives and replays; every field is Codable and Sendable, and the
/// request hash covers all of it (mesh, material with provenance, loads,
/// boundary conditions, tolerances, budgets).
public struct EngineeringStudy: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var meshNodes: [MeshNode]
    public var meshElements: [Tetrahedron]
    public var material: EngineeringMaterial
    public var structural: StructuralConfig?
    public var thermal: ThermalConfig?
    public var manufacturability: ManufacturabilityConfig?

    public struct StructuralConfig: Codable, Sendable, Equatable {
        public var concentratedLoads: [ConcentratedLoad]
        public var bodyLoads: [BodyLoad]
        public var pressureLoads: [PressureLoad]
        public var displacementBCs: [DisplacementBC]
        public var tolerance: EngineeringTolerance
        public var budget: EngineeringBudget
        public init(concentratedLoads: [ConcentratedLoad] = [], bodyLoads: [BodyLoad] = [],
                    pressureLoads: [PressureLoad] = [], displacementBCs: [DisplacementBC] = [],
                    tolerance: EngineeringTolerance = EngineeringTolerance(),
                    budget: EngineeringBudget = EngineeringBudget()) {
            self.concentratedLoads = concentratedLoads
            self.bodyLoads = bodyLoads
            self.pressureLoads = pressureLoads
            self.displacementBCs = displacementBCs
            self.tolerance = tolerance
            self.budget = budget
        }
    }

    public struct ThermalConfig: Codable, Sendable, Equatable {
        public var fixedTemperatures: [FixedTemperatureBC]
        public var sources: [ThermalSource]
        public var faceFluxes: [ThermalFlux]
        public var tolerance: EngineeringTolerance
        public var budget: EngineeringBudget
        public init(fixedTemperatures: [FixedTemperatureBC] = [], sources: [ThermalSource] = [],
                    faceFluxes: [ThermalFlux] = [], tolerance: EngineeringTolerance = EngineeringTolerance(),
                    budget: EngineeringBudget = EngineeringBudget()) {
            self.fixedTemperatures = fixedTemperatures
            self.sources = sources
            self.faceFluxes = faceFluxes
            self.tolerance = tolerance
            self.budget = budget
        }
    }

    public struct ManufacturabilityConfig: Codable, Sendable, Equatable {
        public var minimumWallThicknessMM: Double?
        public var cuttingForceWidthMM: Double?
        public var cuttingForceChipThicknessMM: Double?
        public init(minimumWallThicknessMM: Double? = nil, cuttingForceWidthMM: Double? = nil,
                    cuttingForceChipThicknessMM: Double? = nil) {
            self.minimumWallThicknessMM = minimumWallThicknessMM
            self.cuttingForceWidthMM = cuttingForceWidthMM
            self.cuttingForceChipThicknessMM = cuttingForceChipThicknessMM
        }
    }

    public init(id: String, name: String, meshNodes: [MeshNode], meshElements: [Tetrahedron],
                material: EngineeringMaterial, structural: StructuralConfig? = nil,
                thermal: ThermalConfig? = nil, manufacturability: ManufacturabilityConfig? = nil) {
        self.id = id
        self.name = name
        self.meshNodes = meshNodes
        self.meshElements = meshElements
        self.material = material
        self.structural = structural
        self.thermal = thermal
        self.manufacturability = manufacturability
    }

    /// Validated mesh under the given budget (shared by every analysis).
    public func validatedMesh(budget: EngineeringBudget) throws -> ValidatedTetraMesh {
        try ValidatedTetraMesh(nodes: meshNodes, elements: meshElements, budget: budget)
    }

    public func structuralRequest() throws -> StructuralRequest {
        guard let structural else { throw EngineeringError.invalidInput("study has no structural configuration") }
        return StructuralRequest(meshNodes: meshNodes, meshElements: meshElements, material: material,
                                 concentratedLoads: structural.concentratedLoads,
                                 bodyLoads: structural.bodyLoads,
                                 pressureLoads: structural.pressureLoads,
                                 displacementBCs: structural.displacementBCs,
                                 tolerance: structural.tolerance, budget: structural.budget)
    }

    public func thermalRequest() throws -> ThermalRequest {
        guard let thermal else { throw EngineeringError.invalidInput("study has no thermal configuration") }
        return ThermalRequest(meshNodes: meshNodes, meshElements: meshElements, material: material,
                              fixedTemperatures: thermal.fixedTemperatures, sources: thermal.sources,
                              faceFluxes: thermal.faceFluxes,
                              tolerance: thermal.tolerance, budget: thermal.budget)
    }

    /// Runs whichever analyses are configured, in structural -> thermal order,
    /// plus manufacturability screening. Throws on the first failure; nothing is
    /// reported as successful unless it actually converged.
    public func run(control: EngineeringSolveControl = EngineeringSolveControl()) throws -> StudyRunResult {
        var structuralResult: StructuralResult? = nil
        var thermalResult: ThermalResult? = nil
        var mfg: ManufacturabilityReport? = nil
        if structural != nil {
            structuralResult = try structuralRequest().solve(control: control)
        }
        if thermal != nil {
            thermalResult = try thermalRequest().solve(control: control)
        }
        if let cfg = manufacturability {
            let budget = structural?.budget ?? thermal?.budget ?? EngineeringBudget()
            let mesh = try validatedMesh(budget: budget)
            var wall: WallThicknessReport? = nil
            var force: CuttingForceEstimate? = nil
            if let minT = cfg.minimumWallThicknessMM {
                wall = try ManufacturabilityCheck.wallThickness(mesh: mesh, minimumMM: minT)
            }
            if let w = cfg.cuttingForceWidthMM, let h = cfg.cuttingForceChipThicknessMM {
                force = try ManufacturabilityCheck.cuttingForce(widthMM: w, chipThicknessMM: h)
            }
            mfg = ManufacturabilityReport(wallThickness: wall, cuttingForce: force)
        }
        return StudyRunResult(study: self, structural: structuralResult, thermal: thermalResult,
                              manufacturability: mfg)
    }

    /// Builds a persistable session record from run outputs.
    public func exportSession(structural: StructuralResult? = nil, thermal: ThermalResult? = nil,
                              manufacturability: ManufacturabilityReport? = nil) throws -> EngineeringExport.SessionRecord {
        try EngineeringExport.SessionRecord(study: self, structuralResult: structural,
                                            thermalResult: thermal, manufacturability: manufacturability)
    }
}

/// Outputs of `EngineeringStudy.run`, kept together for archiving.
public struct StudyRunResult: Sendable {
    public var study: EngineeringStudy
    public var structural: StructuralResult?
    public var thermal: ThermalResult?
    public var manufacturability: ManufacturabilityReport?
}

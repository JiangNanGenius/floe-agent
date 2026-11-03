import Foundation
import simd

nonisolated enum LoftSurfaceError: Error, LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self { case let .invalid(message), let .unsupported(message): return message }
    }
}

/// Extra semantic intent on the existing loft node. A nil definition preserves
/// legacy smooth lofts; a real definition raises only its document to format 7.
/// Guides/end conditions are explicit reservations, never passed to OCCT as
/// global smoothing/continuity switches and never silently ignored.
nonisolated struct LoftDefinition: Codable, Sendable {
    static let supportedVersion = 1
    var version: Int = 1
    var ruled: Bool = false
    var guides: [SweepPathDefinition] = []
    var start: BoundaryConstraint?
    var end: BoundaryConstraint?
    nonisolated struct BoundaryConstraint: Codable, Sendable {
        var tangent: PointWrapper
        /// Normal curvature vector in 1/mm; nil requests tangent only.
        var curvature: PointWrapper?
        var angularTolerance: Double
        var curvatureTolerance: Double
    }
    init(version: Int = 1, ruled: Bool = false, guides: [SweepPathDefinition] = [],
         start: BoundaryConstraint? = nil, end: BoundaryConstraint? = nil) {
        self.version=version; self.ruled=ruled; self.guides=guides; self.start=start; self.end=end
    }
    private enum CodingKeys: String, CodingKey { case version,ruled,guides,start,end }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        guard version == Self.supportedVersion else { throw AssociativeGeometryError.unsupportedSemanticVersion(version) }
        ruled=try c.decodeIfPresent(Bool.self,forKey:.ruled) ?? false
        guides=try c.decodeIfPresent([SweepPathDefinition].self,forKey:.guides) ?? []
        start=try c.decodeIfPresent(BoundaryConstraint.self,forKey:.start)
        end=try c.decodeIfPresent(BoundaryConstraint.self,forKey:.end)
        try validate(sectionCount:2)
    }
    func validate(sectionCount: Int) throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        guard (2...64).contains(sectionCount), guides.count <= 16 else {
            throw LoftSurfaceError.invalid("A loft needs 2–64 sections and at most 16 guides.")
        }
        for guide in guides { try guide.validate() }
        for boundary in [start, end].compactMap({ $0 }) {
            let t = boundary.tangent.point
            let k = boundary.curvature?.point
            guard [t.x,t.y,t.z,boundary.angularTolerance,boundary.curvatureTolerance].allSatisfy(\.isFinite),
                  simd_length(t) > 1e-9, boundary.angularTolerance > 0, boundary.angularTolerance <= 0.1,
                  boundary.curvatureTolerance > 0,
                  k.map({ [$0.x,$0.y,$0.z].allSatisfy(\.isFinite) }) ?? true else {
                throw LoftSurfaceError.invalid("The loft boundary constraint is invalid.")
            }
        }
    }
    func requireSupported(sectionCount: Int) throws {
        try validate(sectionCount: sectionCount)
        guard guides.isEmpty else {
            throw LoftSurfaceError.unsupported("Guide-constrained lofts are not available. No guide was ignored and nothing changed.")
        }
        guard start == nil, end == nil else {
            throw LoftSurfaceError.unsupported("Specified end tangency and curvature are not available. Nothing changed.")
        }
    }
}

/// Surface steps are real graph nodes, each storing identity-bound inputs.
/// Their cached render mesh is never a replay input. The first source body ID
/// is retained through trim/patch/sew/thicken; edit replaces this same feature.
nonisolated struct CADSurfaceDefinition: Codable, Sendable {
    static let supportedVersion = 1
    nonisolated enum Operation: String, Codable, Sendable { case loft, trim, patch, sew, thicken }
    nonisolated struct UVTrim: Codable, Sendable {
        var uMin: Double; var uMax: Double; var vMin: Double; var vMax: Double
    }
    var version: Int = 1
    var operation: Operation
    var sections: [SweepPathDefinition] = []
    var sources: [BodyRef] = []
    var ruled: Bool = false
    var tolerance: Double = 1e-6
    var trim: UVTrim?
    /// Signed offset in mm. On an open sheet, positive follows its normal.
    /// On a closed shell, positive grows outward from its enclosed volume.
    var thickness: Double?
    /// Sewing may leave an open shell only when explicitly requested.
    var requireClosed: Bool = false

    init(version: Int = 1, operation: Operation, sections: [SweepPathDefinition] = [], sources: [BodyRef] = [],
         ruled: Bool = false, tolerance: Double = 1e-6, trim: UVTrim? = nil,
         thickness: Double? = nil, requireClosed: Bool = false) {
        self.version=version; self.operation=operation; self.sections=sections; self.sources=sources
        self.ruled=ruled; self.tolerance=tolerance; self.trim=trim; self.thickness=thickness; self.requireClosed=requireClosed
    }
    private enum CodingKeys: String, CodingKey { case version,operation,sections,sources,ruled,tolerance,trim,thickness,requireClosed }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        guard version == Self.supportedVersion else { throw AssociativeGeometryError.unsupportedSemanticVersion(version) }
        operation=try c.decode(Operation.self,forKey:.operation)
        sections=try c.decodeIfPresent([SweepPathDefinition].self,forKey:.sections) ?? []
        sources=try c.decodeIfPresent([BodyRef].self,forKey:.sources) ?? []
        ruled=try c.decodeIfPresent(Bool.self,forKey:.ruled) ?? false
        tolerance=try c.decodeIfPresent(Double.self,forKey:.tolerance) ?? 1e-6
        trim=try c.decodeIfPresent(UVTrim.self,forKey:.trim)
        thickness=try c.decodeIfPresent(Double.self,forKey:.thickness)
        requireClosed=try c.decodeIfPresent(Bool.self,forKey:.requireClosed) ?? false
        try validate()
    }
    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        guard tolerance.isFinite, (1e-7...1e-3).contains(tolerance), sources.count <= 64,
              Set(sources.map(\.bodyID)).count == sources.count else {
            throw LoftSurfaceError.invalid("Use unique surface sources and a tolerance from 0.0000001 to 0.001 mm.")
        }
        if operation == .loft {
            guard (2...64).contains(sections.count), sources.isEmpty, trim == nil, thickness == nil,
                  !requireClosed, let count = sections.first?.segments.count, (1...256).contains(count),
                  sections.allSatisfy({ $0.segments.count == count }),
                  sections.reduce(0, { $0 + $1.segments.count }) <= 2048 else {
                throw LoftSurfaceError.invalid("A surface loft needs 2–64 equally segmented open sections.")
            }
            for section in sections { try section.validate() }
        } else {
            guard sections.isEmpty, !ruled,
                  (operation == .sew ? sources.count >= 2 : sources.count == 1) else {
                throw LoftSurfaceError.invalid("Select the exact surface inputs for this operation.")
            }
            guard operation == .sew || !requireClosed else {
                throw LoftSurfaceError.invalid("Closure is checked by the sewing operation.")
            }
            if operation == .trim {
                guard let trim, [trim.uMin,trim.uMax,trim.vMin,trim.vMax].allSatisfy(\.isFinite),
                      trim.uMax - trim.uMin > 1e-9, trim.vMax - trim.vMin > 1e-9, thickness == nil else {
                    throw LoftSurfaceError.invalid("Provide a nonempty finite UV trim rectangle.")
                }
            } else if trim != nil { throw LoftSurfaceError.invalid("This operation does not accept a trim rectangle.") }
            if operation == .thicken {
                guard let thickness, thickness.isFinite, abs(thickness) >= 1e-5, abs(thickness) <= 10_000 else {
                    throw LoftSurfaceError.invalid("Use a nonzero thickness from 0.00001 to 10000 mm.")
                }
            } else if thickness != nil { throw LoftSurfaceError.invalid("This operation does not accept thickness.") }
        }
    }
    var sketchIDs: Set<SketchID> { Set(sections.flatMap { $0.segments.map(\.sketchID) }) }

    /// Each open section belongs to one actual sketch plane. Native OCCT
    /// materializes the exact curve definition; sampledSpine is never used.
    func resolvedSections(sketch: (SketchID) -> Sketch?) throws
        -> [(curves: [Data], reversed: [Bool], plane: SketchPlane)] {
        try validate()
        var totalBytes=0
        return try sections.map { section in
            guard let id = section.segments.first?.sketchID,
                  section.segments.allSatisfy({ $0.sketchID == id }), let source = sketch(id) else {
                throw LoftSurfaceError.invalid("Each open section must reference one existing sketch plane.")
            }
            try FeaturePlaneReference.validate(source.plane)
            var curves: [Data] = []
            for segment in section.segments {
                guard let entity = source.entities.first(where: { $0.id == segment.entityID }) else {
                    throw LoftSurfaceError.invalid("A surface section edge was removed. Select its replacement explicitly.")
                }
                let definition = try SketchCurveDefinition(entity)
                guard !definition.interval.periodic else {
                    throw LoftSurfaceError.invalid("A surface loft requires open section edges.")
                }
                let record=definition.nativeRecord
                guard record.count <= 1_048_576, record.count <= 8_388_608-totalBytes else {
                    throw LoftSurfaceError.invalid("The exact surface sections exceed the 8 MB rebuild budget.")
                }
                totalBytes += record.count
                curves.append(record)
            }
            return (curves, section.segments.map(\.reversed), source.plane)
        }
    }
}

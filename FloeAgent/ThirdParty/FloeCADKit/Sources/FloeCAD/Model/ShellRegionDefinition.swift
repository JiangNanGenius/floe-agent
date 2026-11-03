import Foundation

/// A region is one exact, named INPUT face, never a tessellated patch or an
/// ordinal. Unlisted faces keep the common thickness. All offsets use the
/// same side of the original body; mixed signs cannot describe one cavity.
nonisolated struct ShellRegionDefinition: Codable, Hashable, Sendable {
    static let supportedVersion = 1
    var version: Int = supportedVersion
    var thickness: Expr
    var regions: [Region]

    nonisolated struct Region: Codable, Hashable, Sendable, Identifiable {
        var id: UUID = UUID()
        var face: FaceRef
        var thickness: Expr
        var parameterKey: String { "region_" + id.uuidString.lowercased() + "_thickness" }
    }
    nonisolated enum Failure: Error, LocalizedError {
        case unsupportedVersion(Int), invalid
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): return "Unsupported shell definition version \(version)."
            case .invalid: return "Use distinct named wall faces and non-zero thicknesses on the same side."
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case version, thickness, regions }
    init(thickness: Expr, regions: [Region], version: Int = supportedVersion) {
        self.version = version; self.thickness = thickness; self.regions = regions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else { throw Failure.unsupportedVersion(version) }
        thickness = try c.decode(Expr.self, forKey: .thickness)
        regions = try c.decode([Region].self, forKey: .regions)
    }
    func validate(body: BodyRef, openFaces: [FaceRef]) throws {
        guard version == Self.supportedVersion else { throw Failure.unsupportedVersion(version) }
        let values = [thickness.value] + regions.map { $0.thickness.value }
        let names = regions.compactMap { $0.face.elementName }
        let openNames = openFaces.compactMap(\.elementName)
        guard !regions.isEmpty, regions.count <= 128,
              values.allSatisfy({ $0.isFinite && abs($0) > 1e-6 && ($0 > 0) == (thickness.value > 0) }),
              Set(regions.map(\.id)).count == regions.count,
              names.count == regions.count, Set(names).count == names.count,
              names.allSatisfy(\.isStableFaceIdentity),
              openNames.count == openFaces.count, Set(openNames).count == openNames.count,
              Set(names).isDisjoint(with: Set(openNames)),
              (openFaces + regions.map(\.face)).allSatisfy({
                  guard $0.body == body, $0.elementName?.isStableFaceIdentity == true else { return false }
                  if case let .nativeSurface(type) = $0.signature.kind { return (2...10).contains(type) }
                  return true
              })
        else { throw Failure.invalid }
    }
}
nonisolated extension FeatureKind {
    var shellParameters: (body: BodyRef, openFaces: [FaceRef], thickness: Expr, regions: ShellRegionDefinition?)? {
        switch self {
        case let .shell(body, faces, thickness): return (body, faces, thickness, nil)
        case let .regionShell(body, faces, definition): return (body, faces, definition.thickness, definition)
        default: return nil
        }
    }
}

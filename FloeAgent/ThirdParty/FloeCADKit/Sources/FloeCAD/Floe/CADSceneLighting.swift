// SPDX-License-Identifier: MPL-2.0
// Authored scene lighting shares the existing appearance/undo/save authority.
import Foundation
import ImageIO
import simd

nonisolated enum CADSceneLightingError: Error, LocalizedError {
    case invalidLight, lightLimit, invalidMap, mapTooLarge, missingMap, damagedMap
    var errorDescription: String? {
        switch self {
        case .invalidLight: FloeCADStrings.text("cad.lights.invalid", "Check the light's values and try again.")
        case .lightLimit: FloeCADStrings.text("cad.lights.limit", "Up to eight scene lights can be used at once.")
        case .invalidMap: FloeCADStrings.text("cad.environment.invalidMap", "Choose a readable panoramic image with a 2:1 aspect ratio.")
        case .mapTooLarge: FloeCADStrings.text("cad.environment.mapTooLarge", "This environment image is too large. Choose a smaller image.")
        case .missingMap: FloeCADStrings.text("cad.environment.missingMap", "The environment image is missing. Import it again.")
        case .damagedMap: FloeCADStrings.text("cad.environment.damagedMap", "The environment image could not be read. Import it again.")
        }
    }
}

nonisolated struct CADSceneLight: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case directional, point, spot }
    static let maximumCount = 8 // RealityKit's documented dynamic-light limit.
    var version: Int = 1
    var id: UUID = UUID()
    var name: String
    var kind: Kind
    var enabled: Bool = true
    /// Positions and directions use the document's model coordinates.
    var positionMM: [Double] = [250,250,250]
    var direction: [Double] = [-1,-1,-1]
    var color: [Double] = [1,1,1]
    /// Lux for directional lights, lumens for point/spot lights, as RealityKit.
    var intensity: Double = 1500
    var radiusMM: Double = 5000
    var innerAngleDegrees: Double = 20
    var outerAngleDegrees: Double = 45
    var castsShadow: Bool = false

    func validate() throws {
        func vector(_ a:[Double], maximum:Double) -> Bool {
            a.count == 3 && a.allSatisfy { $0.isFinite && abs($0) <= maximum }
        }
        guard version == 1, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.count <= 80,
              vector(positionMM,maximum:1e9), vector(direction,maximum:1e9),
              simd_length(SIMD3(direction[0],direction[1],direction[2])) > 1e-8,
              vector(color,maximum:1), color.allSatisfy({ $0 >= 0 }),
              intensity.isFinite, (0...1e6).contains(intensity), radiusMM.isFinite, (0.01...1e9).contains(radiusMM),
              innerAngleDegrees.isFinite, outerAngleDegrees.isFinite,
              (0...179).contains(innerAngleDegrees), (0.01...179.9).contains(outerAngleDegrees),
              innerAngleDegrees <= outerAngleDegrees else { throw CADSceneLightingError.invalidLight }
        guard kind != .point || !castsShadow else { throw CADSceneLightingError.invalidLight }
    }
    static func validate(_ lights:[Self]?) throws {
        guard let lights else { return }
        guard lights.count <= maximumCount else { throw CADSceneLightingError.lightLimit }
        guard Set(lights.map(\.id)).count == lights.count else { throw CADSceneLightingError.invalidLight }
        for light in lights { try light.validate() }
    }
    var summaryJSON: [String:Any] {
        ["version":version,"id":id.uuidString,"name":name,"kind":kind.rawValue,"enabled":enabled,
         "position_mm":positionMM,"direction":direction,"color":color,"intensity":intensity,
         "radius_mm":radiusMM,"inner_angle_degrees":innerAngleDegrees,"outer_angle_degrees":outerAngleDegrees,
         "casts_shadow":castsShadow]
    }
}

nonisolated struct CADEnvironmentMap: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 64 * 1024 * 1024
    static let maximumPixels = 16 * 1024 * 1024
    var version: Int = 1
    var name: String
    var sha256: String
    var width: Int
    var height: Int
    /// Self-contained original image, like existing persisted material maps.
    /// Nil preserves a missing resource's identity and reports it explicitly.
    var bytes: Data?
    var rotationDegrees: Double = 0
    var intensity: Double = 1
    var showsBackground: Bool = false

    static func imported(data:Data, name:String) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else { throw CADSceneLightingError.mapTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw CADSceneLightingError.invalidMap }
        guard width <= 8192, height <= 8192, width <= maximumPixels/height else { throw CADSceneLightingError.mapTooLarge }
        guard abs(width-2*height) <= 1 else { throw CADSceneLightingError.invalidMap }
        let value = Self(name:String(URL(fileURLWithPath:name).lastPathComponent.prefix(160)),
                         sha256:CADMaterialTexture.digest(data),width:width,height:height,bytes:data)
        try value.validate()
        return value
    }
    func validate() throws {
        guard version == 1, !name.isEmpty, name.count <= 160, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }), width > 0, height > 0,
              width <= 8192, height <= 8192, width <= Self.maximumPixels/height,
              abs(width-2*height) <= 1,
              rotationDegrees.isFinite, abs(rotationDegrees) <= 1e6,
              intensity.isFinite, (0...16).contains(intensity) else { throw CADSceneLightingError.invalidMap }
        if let bytes, bytes.count > Self.maximumEncodedBytes { throw CADSceneLightingError.mapTooLarge }
    }
    func checkedBytes() throws -> Data {
        try validate()
        guard let bytes, !bytes.isEmpty else { throw CADSceneLightingError.missingMap }
        guard CADMaterialTexture.digest(bytes) == sha256 else { throw CADSceneLightingError.damagedMap }
        return bytes
    }
    var summaryJSON:[String:Any] {
        ["version":version,"name":name,"sha256":sha256,"width":width,"height":height,
         "byte_count":bytes?.count ?? 0,"rotation_degrees":rotationDegrees,"intensity":intensity,
         "shows_background":showsBackground,"available":bytes?.isEmpty == false]
    }
}

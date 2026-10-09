//
//  Materials.swift
//  openshape3d
//
//  Visualization-lite body materials (plan §B15): a persisted per-body
//  appearance (flat color + metallic/roughness) plus the small preset
//  library the Material sheet offers. Model space is Double; the editor
//  bridges to the Float32 BodyMaterial render uniform.
//

import Foundation
import simd

/// Persisted appearance of a body. Backward compatible: absent on old
/// documents (decodeIfPresent on the owning blob → nil keeps the legacy
/// default look).
nonisolated struct BodyMaterialSpec: Codable, Equatable, Sendable {
    /// Linear-ish RGBA in 0…1 (matches the renderer's baseColor space).
    var baseColor: SIMD4<Double>
    /// 0 = dielectric (legacy shading path), 1 = metal.
    var metallic: Double = 0
    /// 0 keeps the legacy fixed highlight; > 0 widens/softens it.
    var roughness: Double = 0
    /// Encoded image bytes (PNG/JPEG) multiplied into `baseColor` where the
    /// body's mesh carries texture coordinates — how an imported OBJ, glTF or
    /// USDZ keeps its look. Nil for every modelled body. Optional in the
    /// JSON, so pre-texture material records decode unchanged.
    var baseColorTexture: Data? = nil

    /// The document default — identical to the pre-material body color and
    /// shading, so assigning it changes nothing visually.
    static let `default` = BodyMaterialSpec(
        baseColor: SIMD4(0.72, 0.74, 0.78, 1), metallic: 0, roughness: 0
    )

    /// Clamped copy: colors and factors pinned to 0…1 (slider/decode safety).
    var clamped: BodyMaterialSpec {
        BodyMaterialSpec(
            baseColor: simd_clamp(baseColor, SIMD4(repeating: 0), SIMD4(repeating: 1)),
            metallic: min(max(metallic, 0), 1),
            roughness: min(max(roughness, 0), 1),
            baseColorTexture: baseColorTexture
        )
    }
}

/// A named entry in the (small, growing) preset library.
nonisolated struct MaterialPreset: Identifiable, Sendable {
    var name: String
    var spec: BodyMaterialSpec
    var id: String { name }

    /// Flat-color starter set (plan §B15): metals + plastics + rubber/wood.
    /// Names route through the host catalog (the preset identity stays the
    /// English `id`; only display localizes).
    static var library: [MaterialPreset] {
        [MaterialPreset(name: FloeCADStrings.text("cad.material.steel", "Steel"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.62, 0.64, 0.67, 1), metallic: 1, roughness: 0.35
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.aluminum", "Aluminum"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.83, 0.85, 0.87, 1), metallic: 1, roughness: 0.22
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.brass", "Brass"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.83, 0.68, 0.32, 1), metallic: 1, roughness: 0.3
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.plasticMatte", "Plastic Matte"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.85, 0.86, 0.88, 1), metallic: 0, roughness: 0.8
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.plasticGloss", "Plastic Gloss"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.9, 0.91, 0.93, 1), metallic: 0, roughness: 0.25
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.rubber", "Rubber"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.15, 0.15, 0.16, 1), metallic: 0, roughness: 0.95
        )),
        MaterialPreset(name: FloeCADStrings.text("cad.material.wood", "Wood"), spec: BodyMaterialSpec(
            baseColor: SIMD4(0.58, 0.4, 0.24, 1), metallic: 0, roughness: 0.7
        ))]
    }
}

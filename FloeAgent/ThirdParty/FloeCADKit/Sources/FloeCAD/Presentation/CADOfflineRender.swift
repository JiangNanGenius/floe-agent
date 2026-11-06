// SPDX-License-Identifier: MPL-2.0
// Immutable exchange values for offline path tracers. No process, document,
// renderer or execution-environment ownership lives in this file.
import Foundation

public nonisolated struct CADOfflineRenderSettings: Codable, Equatable, Sendable {
    public nonisolated enum Quality: String, Codable, CaseIterable, Sendable {
        case preview, studio, final
        public var samples: Int { switch self { case .preview: 16; case .studio: 64; case .final: 256 } }
    }
    public var quality: Quality
    public var width: Int
    public var height: Int
    public var maximumBounces: Int
    public var exposureEV: Double
    public init(quality: Quality = .studio, width: Int = 1280, height: Int = 960,
                maximumBounces: Int = 8, exposureEV: Double = 0) {
        self.quality = quality; self.width = width; self.height = height
        self.maximumBounces = maximumBounces; self.exposureEV = exposureEV
    }
    public func validate() throws {
        guard (64...4096).contains(width), (64...4096).contains(height),
              width * height <= 8_388_608, (2...16).contains(maximumBounces),
              exposureEV.isFinite, (-6...6).contains(exposureEV) else {
            throw CADOfflineRenderError.invalidSettings
        }
    }
}

public nonisolated enum CADOfflineRenderError: Error, LocalizedError, Sendable {
    case invalidSettings, invalidScene, tooLarge, sourceChanged, unsupportedSection, unsupportedEnvironmentImage
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "Choose a valid image size and path tracing settings."
        case .invalidScene: "This scene contains invalid geometry or camera values."
        case .tooLarge: "This scene exceeds the offline export limit. Hide some objects and try again."
        case .sourceChanged: "The model changed while its render scene was being prepared. Try again."
        case .unsupportedSection: "Turn off the section view before preparing an offline render."
        case .unsupportedEnvironmentImage: "Use an HDR, EXR, PNG or JPEG environment image for offline rendering."
        }
    }
}

/// One frozen render input. Millimetres have already been converted to metres
/// by the presentation adapter. This is an exchange snapshot, never an editor.
public nonisolated struct CADOfflineRenderScene: Codable, Sendable {
    public nonisolated struct Camera: Codable, Sendable {
        public var eye, target, up: [Double]
        public var verticalFOV: Double
        public var orthographicHalfHeight: Double?
        public init(eye: [Double], target: [Double], up: [Double] = [0, 1, 0],
                    verticalFOV: Double = 60, orthographicHalfHeight: Double? = nil) {
            self.eye = eye; self.target = target; self.up = up
            self.verticalFOV = verticalFOV; self.orthographicHalfHeight = orthographicHalfHeight
        }
    }
    public nonisolated struct Material: Codable, Sendable {
        public var color: [Double], metallic: Double, roughness: Double, opacity: Double
        public var emissive: [Double]
        public var baseColorImage: String?
        public var imageIsLinear: Bool
        public var flipImageV: Bool
        public init(color: [Double] = [0.65, 0.67, 0.7], metallic: Double = 0,
                    roughness: Double = 0.5, opacity: Double = 1,
                    emissive: [Double] = [0, 0, 0], baseColorImage: String? = nil,
                    imageIsLinear: Bool = false, flipImageV: Bool = false) {
            self.color = color; self.metallic = metallic; self.roughness = roughness
            self.opacity = opacity; self.emissive = emissive; self.baseColorImage = baseColorImage
            self.imageIsLinear = imageIsLinear; self.flipImageV = flipImageV
        }
    }
    public nonisolated struct Mesh: Codable, Sendable {
        /// Flat xyz, normal xyz and uv arrays in world metres.
        public var positions: [Double], normals: [Double], uvs: [Double]
        public var indices: [UInt32]
        public var material: Material
        public init(positions: [Double], normals: [Double] = [], uvs: [Double] = [],
                    indices: [UInt32], material: Material = .init()) {
            self.positions = positions; self.normals = normals; self.uvs = uvs
            self.indices = indices; self.material = material
        }
    }
    public nonisolated struct Light: Codable, Sendable {
        public nonisolated enum Kind: String, Codable, Sendable { case directional, point, spot }
        public var kind: Kind
        public var position, direction, color: [Double]
        /// Same authored lux/lumens value as the realtime scene.
        public var intensity: Double
        public var innerAngle, outerAngle: Double
        public init(kind: Kind, position: [Double] = [0, 0, 0],
                    direction: [Double] = [-1, -1, -1], color: [Double] = [1, 1, 1],
                    intensity: Double = 1500, innerAngle: Double = 20, outerAngle: Double = 45) {
            self.kind = kind; self.position = position; self.direction = direction
            self.color = color; self.intensity = intensity
            self.innerAngle = innerAngle; self.outerAngle = outerAngle
        }
    }
    public var camera: Camera
    public var meshes: [Mesh]
    public var lights: [Light]
    public var assets: [String: Data]
    public var environmentImage: String?
    public var environmentRotation: Double = 0
    public var environmentIntensity: Double = 1
    public var environmentShowsBackground: Bool = true
    public var backgroundColor: [Double] = [0.025, 0.03, 0.04]
    public var warnings: [String] = []
    public init(camera: Camera, meshes: [Mesh], lights: [Light] = [], assets: [String: Data] = [:]) {
        self.camera = camera; self.meshes = meshes; self.lights = lights; self.assets = assets
    }
}

/// Local WebGL2 path-tracing exchange. PBRT remains a historical export type;
/// no process or package installer is needed for this on-device input.
public nonisolated enum CADNativeSceneExporter {
    public static let backendID = "three-gpu-pathtracer-webgl2"
    public static let backendRevision = "0.0.24-three0.181.1-bvh0.9.5"
    public static let maximumTriangles = 250_000
    public static let maximumPackageBytes = 64 * 1024 * 1024
    private nonisolated struct Envelope: Codable, Sendable {
        var schemaVersion = 1
        var backend = CADNativeSceneExporter.backendID
        var scene: CADOfflineRenderScene
        var settings: CADOfflineRenderSettings
    }
    public static func export(_ scene: CADOfflineRenderScene, settings: CADOfflineRenderSettings,
                              revision: Int = 0, changeCount: Int = 0,
                              sourceSHA256: String = "") throws -> CADOfflineRenderPackage {
        try settings.validate(); try Task.checkCancellation()
        func vector(_ values: [Double], count: Int = 3) -> Bool {
            values.count == count && values.allSatisfy { $0.isFinite && abs($0) <= 1e12 }
        }
        let camera = scene.camera
        guard !scene.meshes.isEmpty, vector(camera.eye), vector(camera.target), vector(camera.up),
              camera.verticalFOV.isFinite, (10...150).contains(camera.verticalFOV) else { throw CADOfflineRenderError.invalidScene }
        let direction = zip(camera.target, camera.eye).map(-)
        let cross = [direction[1] * camera.up[2] - direction[2] * camera.up[1],
                     direction[2] * camera.up[0] - direction[0] * camera.up[2],
                     direction[0] * camera.up[1] - direction[1] * camera.up[0]]
        guard cross.reduce(0, { $0 + $1 * $1 }) > 1e-18,
              camera.orthographicHalfHeight.map({ $0.isFinite && $0 > 0 }) ?? true,
              vector(scene.backgroundColor), scene.environmentIntensity.isFinite,
              (0...16).contains(scene.environmentIntensity), scene.environmentRotation.isFinite else { throw CADOfflineRenderError.invalidScene }
        var triangles = 0
        for mesh in scene.meshes {
            try Task.checkCancellation(); triangles += mesh.indices.count / 3
            guard triangles <= maximumTriangles, mesh.positions.count <= maximumTriangles * 9 else { throw CADOfflineRenderError.tooLarge }
            guard !mesh.positions.isEmpty, mesh.positions.count % 3 == 0,
                  !mesh.indices.isEmpty, mesh.indices.count % 3 == 0,
                  mesh.indices.allSatisfy({ Int($0) < mesh.positions.count / 3 }),
                  mesh.positions.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
                  mesh.normals.isEmpty || (mesh.normals.count == mesh.positions.count && mesh.normals.allSatisfy(\.isFinite)),
                  mesh.uvs.isEmpty || (mesh.uvs.count * 3 == mesh.positions.count * 2 && mesh.uvs.allSatisfy(\.isFinite)),
                  vector(mesh.material.color), mesh.material.color.allSatisfy({ (0...1).contains($0) }),
                  vector(mesh.material.emissive), mesh.material.emissive.allSatisfy({ $0 >= 0 }),
                  [mesh.material.metallic, mesh.material.roughness, mesh.material.opacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CADOfflineRenderError.invalidScene }
            if let name = mesh.material.baseColorImage, scene.assets[name] == nil { throw CADOfflineRenderError.invalidScene }
        }
        for light in scene.lights {
            guard vector(light.position), vector(light.direction), vector(light.color),
                  light.direction.contains(where: { abs($0) > 1e-8 }), light.color.allSatisfy({ (0...1).contains($0) }),
                  light.intensity.isFinite, (0...1e6).contains(light.intensity),
                  light.innerAngle.isFinite, light.outerAngle.isFinite,
                  light.innerAngle >= 0, light.outerAngle >= light.innerAngle, light.outerAngle < 180 else { throw CADOfflineRenderError.invalidScene }
        }
        guard scene.assets.allSatisfy({ name, bytes in
            name.hasPrefix("assets/") && !name.contains("..") && !name.contains("\\") && !bytes.isEmpty
                && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,47,95].contains($0) }
        }), scene.assets.values.reduce(0, { $0 + $1.count }) <= maximumPackageBytes,
              scene.environmentImage.map({ scene.assets[$0] != nil }) ?? true else { throw CADOfflineRenderError.invalidScene }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(scene: scene, settings: settings))
        guard data.count <= maximumPackageBytes else { throw CADOfflineRenderError.tooLarge }
        var warnings = scene.warnings
        if scene.meshes.contains(where: { $0.material.opacity < 0.999 }) {
            warnings.append("Opacity uses surface coverage; glass refraction is not transferred.")
        }
        return CADOfflineRenderPackage(files: ["scene.json": data], warnings: Array(Set(warnings)).sorted(),
            settings: settings, revision: revision, changeCount: changeCount, sourceSHA256: sourceSHA256)
    }
}

public nonisolated struct CADOfflineRenderPackage: Sendable {
    public var files: [String: Data]
    public var warnings: [String]
    public var settings: CADOfflineRenderSettings
    public var revision: Int
    public var changeCount: Int
    public var sourceSHA256: String
}

public nonisolated enum CADPBRTSceneExporter {
    public static let backendRevision = "b0bdf461ba5dd6504b70ebf0932acc0fe7aa744f"
    public static let maximumTriangles = 1_000_000
    public static let maximumPackageBytes = 128 * 1024 * 1024

    public static func export(_ scene: CADOfflineRenderScene, settings: CADOfflineRenderSettings,
                              revision: Int = 0, changeCount: Int = 0,
                              sourceSHA256: String = "") throws -> CADOfflineRenderPackage {
        try settings.validate(); try Task.checkCancellation()
        func vector(_ v: [Double], count: Int = 3) -> Bool {
            v.count == count && v.allSatisfy { $0.isFinite && abs($0) <= 1e12 }
        }
        func values(_ v: [Double]) -> String { v.map(number).joined(separator: " ") }
        func safeAsset(_ name: String) -> Bool {
            name.hasPrefix("assets/") && !name.contains("..") && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
            }
        }
        let camera = scene.camera
        guard vector(camera.eye), vector(camera.target), vector(camera.up),
              camera.eye != camera.target, camera.up.contains(where: { abs($0) > 1e-8 }),
              camera.verticalFOV.isFinite, (10...150).contains(camera.verticalFOV),
              !scene.meshes.isEmpty else { throw CADOfflineRenderError.invalidScene }
        let direction = zip(camera.target, camera.eye).map(-)
        let cross = [direction[1] * camera.up[2] - direction[2] * camera.up[1],
                     direction[2] * camera.up[0] - direction[0] * camera.up[2],
                     direction[0] * camera.up[1] - direction[1] * camera.up[0]]
        guard cross.reduce(0, { $0 + $1 * $1 }) > 1e-18 else { throw CADOfflineRenderError.invalidScene }
        var files = scene.assets
        guard files.allSatisfy({ safeAsset($0.key) && !$0.value.isEmpty }),
              files.values.reduce(0, { $0 + $1.count }) <= maximumPackageBytes else { throw CADOfflineRenderError.tooLarge }
        var out = "# Floe immutable scene; pbrt-v4; units metres\n"
        // PBRT cameras look along +Z; the CAD camera looks along -Z. Flip
        // camera X before LookAt so the output retains CAD's screen handedness.
        out += "Scale -1 1 1\nLookAt \(values(camera.eye)) \(values(camera.target)) \(values(camera.up))\n"
        let aspect = Double(settings.width) / Double(settings.height)
        if let half = camera.orthographicHalfHeight {
            guard half.isFinite, half > 0 else { throw CADOfflineRenderError.invalidScene }
            out += "Camera \"orthographic\" \"float screenwindow\" [\(values([-half * aspect, half * aspect, -half, half]))] \"float shutterclose\" [0.001]\n"
        } else {
            // PBRT's fov is the narrower dimension; our saved camera is vertical.
            let fov = aspect < 1 ? atan(tan(camera.verticalFOV * .pi / 360) * aspect) * 360 / .pi : camera.verticalFOV
            out += "Camera \"perspective\" \"float fov\" [\(number(fov))] \"float shutterclose\" [0.001]\n"
        }
        // PBRT's passthrough sensor otherwise integrates one full second of
        // authored lux/lumens and clips ordinary studio lights. Use a fixed
        // millisecond exposure; the EV control scales it without changing lights.
        out += "Film \"rgb\" \"integer xresolution\" [\(settings.width)] \"integer yresolution\" [\(settings.height)] \"string filename\" [\"render.png\"] \"float iso\" [\(number(100 * pow(2, settings.exposureEV)))]\n"
        out += "Sampler \"sobol\" \"integer pixelsamples\" [\(settings.quality.samples)]\n"
        out += "Integrator \"volpath\" \"integer maxdepth\" [\(settings.maximumBounces)]\nWorldBegin\n"
        if let image = scene.environmentImage {
            guard safeAsset(image), files[image] != nil, scene.environmentRotation.isFinite,
                  scene.environmentIntensity.isFinite, (0...16).contains(scene.environmentIntensity) else { throw CADOfflineRenderError.invalidScene }
            // Lat-long maps use +Z as their pole in pbrt, +Y in the CAD scene.
            out += "AttributeBegin\nRotate \(number(scene.environmentRotation)) 0 1 0\nRotate -90 1 0 0\nLightSource \"infinite\" \"string filename\" [\"\(image)\"] \"float scale\" [\(number(scene.environmentIntensity))]\nAttributeEnd\n"
        }
        for light in scene.lights {
            guard vector(light.position), vector(light.direction), vector(light.color),
                  light.direction.contains(where: { abs($0) > 1e-8 }),
                  light.color.allSatisfy({ (0...1).contains($0) }), light.intensity.isFinite,
                  (0...1e6).contains(light.intensity) else { throw CADOfflineRenderError.invalidScene }
            if light.intensity == 0 || !light.color.contains(where: { $0 > 0 }) { continue }
            let from = light.position, to = zip(from, light.direction).map(+)
            switch light.kind {
            case .directional:
                // pbrt distant's vector points toward the source; CAD stores
                // the direction travelled by light, hence from -> to.
                out += "LightSource \"distant\" \"point3 from\" [\(values(from))] \"point3 to\" [\(values(to))] \"rgb L\" [\(values(light.color))] \"float illuminance\" [\(number(light.intensity))]\n"
            case .point:
                out += "LightSource \"point\" \"point3 from\" [\(values(from))] \"rgb I\" [\(values(light.color))] \"float power\" [\(number(light.intensity))]\n"
            case .spot:
                guard light.innerAngle.isFinite, light.outerAngle.isFinite,
                      light.innerAngle >= 0, light.innerAngle <= light.outerAngle,
                      light.outerAngle < 179.9 else { throw CADOfflineRenderError.invalidScene }
                if light.outerAngle == 0 { continue }
                out += "LightSource \"spot\" \"point3 from\" [\(values(from))] \"point3 to\" [\(values(to))] \"rgb I\" [\(values(light.color))] \"float power\" [\(number(light.intensity))] \"float coneangle\" [\(number(light.innerAngle / 2))] \"float conedeltaangle\" [\(number((light.outerAngle - light.innerAngle) / 2))]\n"
            }
        }
        var triangleCount = 0
        var warnings = scene.warnings
        for (index, mesh) in scene.meshes.enumerated() {
            try Task.checkCancellation()
            triangleCount += mesh.indices.count / 3
            guard triangleCount <= maximumTriangles else { throw CADOfflineRenderError.tooLarge }
            guard !mesh.positions.isEmpty, mesh.positions.count % 3 == 0,
                  mesh.positions.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }),
                  !mesh.indices.isEmpty, mesh.indices.count % 3 == 0,
                  mesh.indices.allSatisfy({ Int($0) < mesh.positions.count / 3 }),
                  (mesh.normals.isEmpty || (mesh.normals.count == mesh.positions.count && mesh.normals.allSatisfy(\.isFinite))),
                  (mesh.uvs.isEmpty || (mesh.uvs.count * 3 == mesh.positions.count * 2 && mesh.uvs.allSatisfy(\.isFinite))) else { throw CADOfflineRenderError.invalidScene }
            let m = mesh.material
            guard vector(m.color), vector(m.emissive), m.color.allSatisfy({ (0...1).contains($0) }),
                  m.emissive.allSatisfy({ $0 >= 0 }), m.metallic.isFinite, (0...1).contains(m.metallic),
                  m.roughness.isFinite, (0...1).contains(m.roughness),
                  m.opacity.isFinite, (0...1).contains(m.opacity) else { throw CADOfflineRenderError.invalidScene }
            out += "AttributeBegin\n"
            var reflectance = "\"rgb reflectance\" [\(values(m.color))]"
            if let image = m.baseColorImage, !mesh.uvs.isEmpty {
                guard safeAsset(image), files[image] != nil else { throw CADOfflineRenderError.invalidScene }
                out += "Texture \"map\(index)\" \"spectrum\" \"imagemap\" \"string filename\" [\"\(image)\"] \"string encoding\" [\"\(m.imageIsLinear ? "linear" : "sRGB")\"]"
                if m.flipImageV { out += " \"float vscale\" [-1] \"float vdelta\" [1]" }
                out += "\n"
                reflectance = "\"texture reflectance\" [\"map\(index)\"]"
                warnings.append("Base-color image tint is not multiplied in the offline material.")
            }
            let roughness = "\"float roughness\" [\(number(m.roughness))]"
            if m.metallic < 0.001 {
                out += "Material \"coateddiffuse\" \(reflectance) \(roughness)\n"
            } else if m.metallic > 0.999 {
                out += "Material \"conductor\" \(reflectance) \(roughness)\n"
            } else {
                out += "MakeNamedMaterial \"diffuse\(index)\" \"string type\" [\"coateddiffuse\"] \(reflectance) \(roughness)\n"
                out += "MakeNamedMaterial \"metal\(index)\" \"string type\" [\"conductor\"] \(reflectance) \(roughness)\n"
                out += "Material \"mix\" \"string materials\" [\"diffuse\(index)\" \"metal\(index)\"] \"float amount\" [\(number(m.metallic))]\n"
            }
            if m.emissive.contains(where: { $0 > 0 }) {
                out += "AreaLightSource \"diffuse\" \"rgb L\" [\(values(m.emissive))] \"bool twosided\" [true]\n"
            }
            out += "Shape \"trianglemesh\" \"point3 P\" [\(values(mesh.positions))] \"integer indices\" [\(mesh.indices.map(String.init).joined(separator: " "))]"
            if !mesh.normals.isEmpty { out += " \"normal N\" [\(values(mesh.normals))]" }
            if !mesh.uvs.isEmpty { out += " \"point2 uv\" [\(values(mesh.uvs))]" }
            if m.opacity < 0.999 {
                out += " \"float alpha\" [\(number(m.opacity))]"
                warnings.append("Opacity uses surface coverage; glass refraction is not transferred.")
            }
            out += "\nAttributeEnd\n"
            guard out.utf8.count <= maximumPackageBytes else { throw CADOfflineRenderError.tooLarge }
        }
        files["scene.pbrt"] = Data(out.utf8)
        guard files.values.reduce(0, { $0 + $1.count }) <= maximumPackageBytes else { throw CADOfflineRenderError.tooLarge }
        return CADOfflineRenderPackage(files: files, warnings: Array(Set(warnings)).sorted(), settings: settings,
            revision: revision, changeCount: changeCount, sourceSHA256: sourceSHA256)
    }

    private static func number(_ value: Double) -> String {
        // POSIX decimal point, independent of the device's region settings.
        String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
